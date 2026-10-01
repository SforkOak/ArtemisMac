//
//  AudioRenderer.m
//  Artemis
//

#import "AudioRenderer.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#include <stdatomic.h>

#include "opus_multistream.h"

// Never let more than this much audio wait in the ring: newer packets are dropped instead
#define MAX_QUEUED_MS 30
// Ring capacity; only needs to be comfortably above MAX_QUEUED_MS
#define RING_MS 120
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
static _Atomic uint64_t sWritePos;
static _Atomic uint64_t sReadPos;

static _Atomic float sVolume = 1.0f;

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

    uint32_t copied = 0;
    while (copied < frames) {
        uint32_t index = (uint32_t)((read + copied) % sRingFrames);
        uint32_t chunk = MIN(frames - copied, sRingFrames - index);
        memcpy(out + copied * sChannels, sRing + index * sChannels, chunk * sChannels * sizeof(int16_t));
        copied += chunk;
    }
    if (frames < inNumberFrames) {
        // Underrun: play silence rather than waiting for data
        memset(out + frames * sChannels, 0, (inNumberFrames - frames) * sChannels * sizeof(int16_t));
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
    sRing = calloc((size_t)sRingFrames * sChannels, sizeof(int16_t));
    sDecodeBuffer = calloc((size_t)sSamplesPerFrame * sChannels, sizeof(int16_t));
    atomic_store(&sWritePos, 0);
    atomic_store(&sReadPos, 0);
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
    Log(LOG_I, @"Audio: %d channels at %d Hz, %d-sample packets, device buffer %u frames, max queue %d ms",
        sChannels, sSampleRate, sSamplesPerFrame, actualFrames, MAX_QUEUED_MS);
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

void ArtemisAudioDecodeAndPlay(const char *sampleData, int sampleLength) {
    if (sDecoder == NULL || sRing == NULL) {
        return;
    }

    uint64_t write = atomic_load_explicit(&sWritePos, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&sReadPos, memory_order_acquire);
    uint32_t queued = (uint32_t)(write - read);
    if (queued >= sMaxQueuedFrames) {
        // The output is behind; drop this packet so latency stays bounded
        return;
    }

    int frames = opus_multistream_decode(sDecoder, (const unsigned char *)sampleData, sampleLength,
                                         sDecodeBuffer, sSamplesPerFrame, 0);
    if (frames <= 0 || queued + (uint32_t)frames > sRingFrames) {
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
