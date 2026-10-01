//
//  AudioRenderer.h
//  Artemis
//
//  Low-latency audio output: Opus is decoded on moonlight-common-c's audio thread into
//  a lock-free ring buffer that a HAL AudioUnit drains with a ~5 ms device buffer.
//  At most ~30 ms of audio is ever queued, so audio can't drift behind the video.
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

NS_ASSUME_NONNULL_END
