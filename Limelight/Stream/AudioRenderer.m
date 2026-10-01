//
//  AudioRenderer.m
//  Artemis
//

#import "AudioRenderer.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>
#include <stdatomic.h>

#include "opus_multistream.h"

// Wi-Fi delivers audio in clumps (scans, AWDL, busy airtime). Clumps are absorbed rather
// than dropped, then the queue is trimmed back down: once per window, the smallest
// cushion the output device actually needed is measured, and anything above the target
// is removed by dropping a decoded packet now and then.
// The target starts at the minimum and grows after each underrun, so during a bad patch
// the cushion the gaps built up is kept instead of trimmed away to run dry again. It
// shrinks slowly once the underruns stop, so on good Wi-Fi it stays at the minimum.
#define TARGET_SLACK_MIN_MS 5
#define TARGET_SLACK_MAX_MS 30
#define TARGET_SLACK_GROWTH_MS 5                // per underrun
#define TARGET_SLACK_DECAY_MS 1                 // per interval without an underrun
#define TARGET_SLACK_DECAY_INTERVAL_MS 5000
#define TRIM_WINDOW_MS 1000
// At most one trimmed packet per this many, so trimming is spread out
#define TRIM_SPACING_PACKETS 8
// Don't trim for this long after the output ran dry, so the cushion that built up stays
#define TRIM_HOLD_AFTER_UNDERRUN_MS 5000
// A gap longer than this means the host stopped sending (silence), not an underrun
#define SILENCE_GAP_MS 200
// Backstop: never queue more than this
#define MAX_QUEUED_MS 150
#define RING_MS 250
// Ask the output device for small I/O buffers (5 ms at 48 kHz)
#define DEVICE_BUFFER_FRAMES 240

static AudioUnit sOutputUnit;
static OpusMSDecoder *sDecoder;
static int sChannels;
static int sSampleRate;
static int sSamplesPerFrame;
static int16_t *sDecodeBuffer;

// Single producer (the audio receive thread), single consumer (the render callback).
// Positions count frames and only ever increase.
static int16_t *sRing;
static uint32_t sRingFrames;
static uint32_t sMaxQueuedFrames;
static uint32_t sSilenceGapFrames;
static _Atomic uint64_t sWritePos;
static _Atomic uint64_t sReadPos;

static _Atomic float sVolume = 1.0f;

// Render callback state (render thread only)
static uint32_t sGapFrames;               // silence padded in the current gap
// Smallest (queued - pulled) seen by the render callback since the producer last looked
static _Atomic uint32_t sMinSlackFrames = UINT32_MAX;

// Trimming state (audio receive thread only)
static uint64_t sTrimWindowTicks;
static uint64_t sTrimHoldTicks;
static uint64_t sTargetSlackDecayTicks;
static uint64_t sTrimWindowStart;
static uint64_t sTrimHoldUntil;
static uint64_t sTargetSlackDecayAt;
static uint32_t sTrimBudgetFrames;
static uint32_t sPacketsSinceTrim;
static uint32_t sUnderrunsSeen;
// Written by the audio receive thread, also read by the stats
static _Atomic uint32_t sTargetSlackFrames;

// Diagnostics. Each counter has a single writer; the stats reader may race a window
// reset with an update, which at worst carries one value into the next window.
static _Atomic uint32_t sUnderruns;       // gaps that ended with audio arriving again
static _Atomic uint64_t sUnderrunFrames;
static _Atomic uint32_t sOverflowDrops;
static _Atomic uint32_t sTrimmedPackets;
static _Atomic uint32_t sWindowMinQueuedFrames = UINT32_MAX;
static _Atomic uint32_t sWindowMaxQueuedFrames;
static _Atomic uint32_t sWindowMaxCallbackFrames;
static _Atomic uint64_t sWindowMaxCallbackGap;   // host time units
static _Atomic uint64_t sLastCallbackHostTime;

static inline uint32_t FramesForMs(uint32_t ms) {
    return (uint32_t)sSampleRate * ms / 1000;
}

static inline void StoreMax32(_Atomic uint32_t *value, uint32_t candidate) {
    if (candidate > atomic_load_explicit(value, memory_order_relaxed)) {
        atomic_store_explicit(value, candidate, memory_order_relaxed);
    }
}

// Real-time render thread: no locks, no allocation, no Objective-C
static OSStatus RenderCallback(void *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp *inTimeStamp,
                               UInt32 inBusNumber,
                               UInt32 inNumberFrames,
                               AudioBufferList *ioData) {
    int16_t *out = (int16_t *)ioData->mBuffers[0].mData;
    uint64_t read = atomic_load_explicit(&sReadPos, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&sWritePos, memory_order_acquire);
    uint32_t available = (uint32_t)(write - read);
    uint32_t frames = available < inNumberFrames ? available : inNumberFrames;

    uint32_t slack = available - frames;
    if (slack < atomic_load_explicit(&sMinSlackFrames, memory_order_relaxed)) {
        atomic_store_explicit(&sMinSlackFrames, slack, memory_order_relaxed);
    }
    if (available < atomic_load_explicit(&sWindowMinQueuedFrames, memory_order_relaxed)) {
        atomic_store_explicit(&sWindowMinQueuedFrames, available, memory_order_relaxed);
    }
    StoreMax32(&sWindowMaxQueuedFrames, available);
    StoreMax32(&sWindowMaxCallbackFrames, inNumberFrames);
    if (inTimeStamp->mFlags & kAudioTimeStampHostTimeValid) {
        uint64_t last = atomic_exchange_explicit(&sLastCallbackHostTime, inTimeStamp->mHostTime, memory_order_relaxed);
        if (last != 0 && inTimeStamp->mHostTime > last) {
            uint64_t gap = inTimeStamp->mHostTime - last;
            if (gap > atomic_load_explicit(&sWindowMaxCallbackGap, memory_order_relaxed)) {
                atomic_store_explicit(&sWindowMaxCallbackGap, gap, memory_order_relaxed);
            }
        }
    }

    uint32_t copied = 0;
    while (copied < frames) {
        uint32_t index = (uint32_t)((read + copied) % sRingFrames);
        uint32_t chunk = MIN(frames - copied, sRingFrames - index);
        memcpy(out + copied * sChannels, sRing + index * sChannels, chunk * sChannels * sizeof(int16_t));
        copied += chunk;
    }
    if (frames < inNumberFrames) {
        // Ran dry: play silence rather than waiting for data
        memset(out + frames * sChannels, 0, (inNumberFrames - frames) * sChannels * sizeof(int16_t));
        sGapFrames = MIN(sGapFrames + (inNumberFrames - frames), sSilenceGapFrames + 1);
    } else if (sGapFrames > 0) {
        // Audio is flowing again. A short gap was an underrun; a long one was the host
        // sending nothing because nothing was playing.
        if (sGapFrames <= sSilenceGapFrames) {
            atomic_fetch_add_explicit(&sUnderruns, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&sUnderrunFrames, sGapFrames, memory_order_relaxed);
        }
        sGapFrames = 0;
    }

    atomic_store_explicit(&sReadPos, read + frames, memory_order_release);
    return noErr;
}

int ArtemisAudioInit(POPUS_MULTISTREAM_CONFIGURATION originalConfig) {
    OPUS_MULTISTREAM_CONFIGURATION opusConfig = *originalConfig;
    AudioChannelLayout channelLayout = {0};

    switch (opusConfig.channelCount) {
        case 2:
            channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
            break;
        case 4:
            channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Quadraphonic;
            break;
        case 6:
            channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_AudioUnit_5_1;
            break;
        case 8:
            channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_AudioUnit_7_1;

            // Swap SL/SR and RL/RR to match the selected channel layout
            opusConfig.mapping[4] = originalConfig->mapping[6];
            opusConfig.mapping[5] = originalConfig->mapping[7];
            opusConfig.mapping[6] = originalConfig->mapping[4];
            opusConfig.mapping[7] = originalConfig->mapping[5];
            break;
        default:
            Log(LOG_E, @"Unsupported channel count: %d", opusConfig.channelCount);
            return -1;
    }

    sChannels = opusConfig.channelCount;
    sSampleRate = opusConfig.sampleRate;
    sSamplesPerFrame = opusConfig.samplesPerFrame;

    int err = 0;
    sDecoder = opus_multistream_decoder_create(opusConfig.sampleRate, opusConfig.channelCount,
                                               opusConfig.streams, opusConfig.coupledStreams,
                                               opusConfig.mapping, &err);
    if (sDecoder == NULL) {
        Log(LOG_E, @"Failed to create the Opus decoder: %d", err);
        return -1;
    }

    sRingFrames = (uint32_t)(sSampleRate * RING_MS / 1000);
    sMaxQueuedFrames = (uint32_t)(sSampleRate * MAX_QUEUED_MS / 1000);
    sSilenceGapFrames = (uint32_t)(sSampleRate * SILENCE_GAP_MS / 1000);
    sRing = calloc((size_t)sRingFrames * sChannels, sizeof(int16_t));
    sDecodeBuffer = calloc((size_t)sSamplesPerFrame * sChannels, sizeof(int16_t));
    atomic_store(&sWritePos, 0);
    atomic_store(&sReadPos, 0);

    // The output unit isn't running yet, so the render thread's state can be reset here too.
    // Start as if in a long silence, so waiting for the first packet isn't an underrun.
    sGapFrames = sSilenceGapFrames + 1;
    atomic_store(&sMinSlackFrames, UINT32_MAX);
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    sTrimWindowTicks = (uint64_t)TRIM_WINDOW_MS * NSEC_PER_MSEC * timebase.denom / timebase.numer;
    sTrimHoldTicks = (uint64_t)TRIM_HOLD_AFTER_UNDERRUN_MS * NSEC_PER_MSEC * timebase.denom / timebase.numer;
    sTargetSlackDecayTicks = (uint64_t)TARGET_SLACK_DECAY_INTERVAL_MS * NSEC_PER_MSEC * timebase.denom / timebase.numer;
    sTrimWindowStart = mach_absolute_time();
    sTrimHoldUntil = 0;
    sTargetSlackDecayAt = 0;
    atomic_store(&sTargetSlackFrames, FramesForMs(TARGET_SLACK_MIN_MS));
    sTrimBudgetFrames = 0;
    sPacketsSinceTrim = 0;
    sUnderrunsSeen = 0;

    atomic_store(&sUnderruns, 0);
    atomic_store(&sUnderrunFrames, 0);
    atomic_store(&sOverflowDrops, 0);
    atomic_store(&sTrimmedPackets, 0);
    atomic_store(&sLastCallbackHostTime, 0);
    if (sRing == NULL || sDecodeBuffer == NULL) {
        ArtemisAudioCleanup();
        return -1;
    }

    AudioComponentDescription description = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_DefaultOutput,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    OSStatus status = component != NULL ? AudioComponentInstanceNew(component, &sOutputUnit) : -1;
    if (status != noErr) {
        Log(LOG_E, @"Failed to create the audio output unit: %d", (int)status);
        ArtemisAudioCleanup();
        return -1;
    }

    AudioStreamBasicDescription format = {
        .mSampleRate = sSampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        .mFramesPerPacket = 1,
        .mChannelsPerFrame = (UInt32)sChannels,
        .mBitsPerChannel = 16,
        .mBytesPerFrame = (UInt32)(sChannels * sizeof(int16_t)),
        .mBytesPerPacket = (UInt32)(sChannels * sizeof(int16_t)),
    };
    status = AudioUnitSetProperty(sOutputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format));
    if (status != noErr) {
        Log(LOG_E, @"Failed to set the audio format: %d", (int)status);
        ArtemisAudioCleanup();
        return -1;
    }

    status = AudioUnitSetProperty(sOutputUnit, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Input, 0, &channelLayout, sizeof(channelLayout));
    if (status != noErr) {
        Log(LOG_W, @"Failed to set the audio channel layout: %d", (int)status);
    }

    // Small device buffers keep output latency low. Not fatal if the device refuses.
    UInt32 bufferFrames = DEVICE_BUFFER_FRAMES;
    status = AudioUnitSetProperty(sOutputUnit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &bufferFrames, sizeof(bufferFrames));
    if (status != noErr) {
        Log(LOG_W, @"Failed to set the audio device buffer size: %d", (int)status);
    }

    AURenderCallbackStruct callback = { RenderCallback, NULL };
    status = AudioUnitSetProperty(sOutputUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    if (status == noErr) {
        status = AudioUnitInitialize(sOutputUnit);
    }
    if (status == noErr) {
        status = AudioOutputUnitStart(sOutputUnit);
    }
    if (status != noErr) {
        Log(LOG_E, @"Failed to start audio output: %d", (int)status);
        ArtemisAudioCleanup();
        return -1;
    }

    UInt32 actualFrames = 0;
    UInt32 size = sizeof(actualFrames);
    AudioUnitGetProperty(sOutputUnit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &actualFrames, &size);
    Log(LOG_I, @"Audio: %d channels at %d Hz, %d-sample packets, device buffer %u frames, target cushion %d–%d ms, max queue %d ms",
        sChannels, sSampleRate, sSamplesPerFrame, actualFrames, TARGET_SLACK_MIN_MS, TARGET_SLACK_MAX_MS, MAX_QUEUED_MS);
    return 0;
}

void ArtemisAudioCleanup(void) {
    if (sOutputUnit != NULL) {
        AudioOutputUnitStop(sOutputUnit);
        AudioUnitUninitialize(sOutputUnit);
        AudioComponentInstanceDispose(sOutputUnit);
        sOutputUnit = NULL;
    }
    if (sDecoder != NULL) {
        opus_multistream_decoder_destroy(sDecoder);
        sDecoder = NULL;
    }
    free(sRing);
    sRing = NULL;
    free(sDecodeBuffer);
    sDecodeBuffer = NULL;
}

// Audio receive thread. Adjusts the target cushion, and once per window works out how
// much queued audio the output never needed, which becomes the amount to trim during
// the next window.
static void UpdateTrimBudget(void) {
    uint64_t now = mach_absolute_time();
    uint32_t underruns = atomic_load_explicit(&sUnderruns, memory_order_relaxed);
    uint32_t target = atomic_load_explicit(&sTargetSlackFrames, memory_order_relaxed);
    if (underruns != sUnderrunsSeen) {
        // The output ran dry, so keep the cushion that has built up for a while, and
        // aim for a bigger one from now on
        target = MIN(target + (underruns - sUnderrunsSeen) * FramesForMs(TARGET_SLACK_GROWTH_MS),
                     FramesForMs(TARGET_SLACK_MAX_MS));
        sUnderrunsSeen = underruns;
        sTrimHoldUntil = now + sTrimHoldTicks;
        sTargetSlackDecayAt = now + sTargetSlackDecayTicks;
        sTrimBudgetFrames = 0;
    } else if (now >= sTargetSlackDecayAt && target > FramesForMs(TARGET_SLACK_MIN_MS)) {
        target = MAX(target - FramesForMs(TARGET_SLACK_DECAY_MS), FramesForMs(TARGET_SLACK_MIN_MS));
        sTargetSlackDecayAt = now + sTargetSlackDecayTicks;
    }
    atomic_store_explicit(&sTargetSlackFrames, target, memory_order_relaxed);

    if (now - sTrimWindowStart < sTrimWindowTicks) {
        return;
    }
    sTrimWindowStart = now;

    uint32_t minSlack = atomic_exchange_explicit(&sMinSlackFrames, UINT32_MAX, memory_order_relaxed);
    if (now < sTrimHoldUntil || minSlack == UINT32_MAX || minSlack <= target) {
        sTrimBudgetFrames = 0;
    } else {
        sTrimBudgetFrames = minSlack - target;
    }
}

void ArtemisAudioDecodeAndPlay(const char *sampleData, int sampleLength) {
    if (sDecoder == NULL || sRing == NULL) {
        return;
    }

    UpdateTrimBudget();

    // Always decode, even a packet that will be dropped, so the decoder's state stays continuous
    int frames = opus_multistream_decode(sDecoder, (const unsigned char *)sampleData, sampleLength,
                                         sDecodeBuffer, sSamplesPerFrame, 0);
    if (frames <= 0) {
        return;
    }

    uint64_t write = atomic_load_explicit(&sWritePos, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&sReadPos, memory_order_acquire);
    uint32_t queued = (uint32_t)(write - read);
    if (queued + (uint32_t)frames > sMaxQueuedFrames) {
        // The output has fallen far behind; drop this packet so latency stays bounded
        atomic_fetch_add_explicit(&sOverflowDrops, 1, memory_order_relaxed);
        return;
    }
    sPacketsSinceTrim++;
    if (sTrimBudgetFrames >= (uint32_t)frames && sPacketsSinceTrim >= TRIM_SPACING_PACKETS) {
        // More audio is waiting than the output has needed lately; skip this packet
        sTrimBudgetFrames -= (uint32_t)frames;
        sPacketsSinceTrim = 0;
        atomic_fetch_add_explicit(&sTrimmedPackets, 1, memory_order_relaxed);
        return;
    }

    float volume = atomic_load_explicit(&sVolume, memory_order_relaxed);
    if (volume < 0.999f) {
        for (int i = 0; i < frames * sChannels; i++) {
            sDecodeBuffer[i] = (int16_t)(sDecodeBuffer[i] * volume);
        }
    }

    uint32_t copied = 0;
    while (copied < (uint32_t)frames) {
        uint32_t index = (uint32_t)((write + copied) % sRingFrames);
        uint32_t chunk = MIN((uint32_t)frames - copied, sRingFrames - index);
        memcpy(sRing + index * sChannels, sDecodeBuffer + copied * sChannels, chunk * sChannels * sizeof(int16_t));
        copied += chunk;
    }
    atomic_store_explicit(&sWritePos, write + (uint64_t)frames, memory_order_release);
}

void ArtemisAudioSetVolume(float volume) {
    atomic_store_explicit(&sVolume, MAX(0.0f, MIN(1.0f, volume)), memory_order_relaxed);
}

uint32_t ArtemisAudioQueuedMs(void) {
    if (sSampleRate == 0) {
        return 0;
    }
    uint64_t write = atomic_load(&sWritePos);
    uint64_t read = atomic_load(&sReadPos);
    return (uint32_t)((write - read) * 1000 / sSampleRate);
}

void ArtemisAudioTakeStats(ArtemisAudioStats *stats) {
    *stats = (ArtemisAudioStats){0};
    if (sSampleRate == 0) {
        return;
    }
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) {
        mach_timebase_info(&timebase);
    }

    stats->underruns = atomic_load(&sUnderruns);
    stats->underrunMs = (uint32_t)(atomic_load(&sUnderrunFrames) * 1000 / sSampleRate);
    stats->overflowDrops = atomic_load(&sOverflowDrops);
    stats->trimmedPackets = atomic_load(&sTrimmedPackets);
    stats->targetCushionMs = atomic_load(&sTargetSlackFrames) * 1000 / sSampleRate;

    uint32_t minFrames = atomic_exchange(&sWindowMinQueuedFrames, UINT32_MAX);
    stats->minQueuedMs = minFrames == UINT32_MAX ? 0 : minFrames * 1000 / sSampleRate;
    stats->maxQueuedMs = atomic_exchange(&sWindowMaxQueuedFrames, 0) * 1000 / sSampleRate;
    stats->maxCallbackFrames = atomic_exchange(&sWindowMaxCallbackFrames, 0);
    uint64_t gap = atomic_exchange(&sWindowMaxCallbackGap, 0);
    stats->maxCallbackGapMs = (float)((double)gap * timebase.numer / timebase.denom / 1e6);
}
