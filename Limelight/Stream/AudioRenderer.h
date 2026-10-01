//
//  AudioRenderer.h
//  Artemis
//
//  Low-latency audio output: Opus is decoded on moonlight-common-c's audio thread into
//  a lock-free ring buffer that a HAL AudioUnit drains with a ~5 ms device buffer.
//  Bursts from the network are absorbed, then the queue is trimmed back to ~5 ms of
//  cushion, so audio can't drift behind the video.
//

#import <Foundation/Foundation.h>

#include "Limelight.h"

NS_ASSUME_NONNULL_BEGIN

// Returns 0 on success
int ArtemisAudioInit(POPUS_MULTISTREAM_CONFIGURATION opusConfig);
void ArtemisAudioCleanup(void);

// Called on moonlight-common-c's audio thread. sampleData is NULL for a lost packet,
// which the Opus decoder conceals.
void ArtemisAudioDecodeAndPlay(const char *_Nullable sampleData, int sampleLength);

// 0.0 - 1.0, applied to decoded samples
void ArtemisAudioSetVolume(float volume);

// Audio decoded but not yet handed to the output device, in milliseconds
uint32_t ArtemisAudioQueuedMs(void);

typedef struct {
    // Since the stream started
    uint32_t underruns;           // times the output ran dry while audio was playing
    uint32_t underrunMs;          // total silence padded during those
    uint32_t overflowDrops;       // packets dropped because the queue hit its limit
    uint32_t trimmedPackets;      // packets skipped to bring the queue back down
    // Since the previous call
    uint32_t minQueuedMs;         // queue level seen by the render callback
    uint32_t maxQueuedMs;
    uint32_t maxCallbackFrames;   // largest single pull by the output device
    float maxCallbackGapMs;       // longest time between pulls
} ArtemisAudioStats;

// Main thread; resets the "since the previous call" values
void ArtemisAudioTakeStats(ArtemisAudioStats *stats);

NS_ASSUME_NONNULL_END
