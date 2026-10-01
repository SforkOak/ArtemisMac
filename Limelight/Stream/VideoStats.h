//
//  VideoStats.h
//  Artemis
//
//  Per-frame latency accounting for the video pipeline. Every timestamp is in
//  microseconds on moonlight-common-c's clock (LiGetMicroseconds(), which is
//  CLOCK_UPTIME_RAW - the same base as CACurrentMediaTime()).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Timing that travels with a frame from the network, through the decoder, to the screen
typedef struct {
    int frameNumber;
    uint16_t hostProcessingLatency;  // 1/10 ms units, 0 if the host didn't report it
    uint64_t receiveTimeUs;          // first packet of the frame arrived
    uint64_t enqueueTimeUs;          // frame fully reassembled by moonlight-common-c
    uint64_t submitTimeUs;           // handed to VideoToolbox
    uint64_t decodedTimeUs;          // VideoToolbox returned the image
} ArtemisFrameTiming;

// What happened to a frame after the presenter took it, on the same clock
typedef struct {
    uint64_t drawableWaitUs;         // time blocked getting a drawable
    uint64_t committedTimeUs;        // drawing and the present were handed to the GPU
    uint64_t gpuDoneTimeUs;          // GPU finished drawing, 0 if not known
    uint64_t presentedTimeUs;        // MTLDrawable.presentedTime, 0 if it never reached the display
} ArtemisPresentTiming;

// One completed measurement window (about a second)
typedef struct {
    double windowSeconds;
    uint32_t framesReceived;
    uint32_t framesDecoded;
    uint32_t framesPresented;
    uint32_t framesLostInNetwork;    // frame number gaps
    uint32_t framesDroppedByDecoder;
    uint32_t framesSuperseded;       // decoded, but a newer frame took the slot before it was drawn
    uint32_t framesNotDisplayed;     // drawn and presented, but never reached the display
    uint32_t keepAlivePresents;      // refreshes with no new frame, filled in by the presenter's keep-alive

    // Averages in milliseconds (0 when nothing was measured)
    double hostLatencyMs;
    double networkReceiveMs;         // first packet -> frame reassembled
    double queueDelayMs;             // reassembled -> submitted to the decoder
    double decodeMs;                 // submitted -> decoded
    double renderMs;                 // decoded -> presented on the display
    double drawableWaitMs;           // part of renderMs spent waiting for a drawable
    double maxDrawableWaitMs;
    double drawMs;                   // decoded -> GPU finished drawing
    double displayMs;                // GPU finished drawing -> presented on the display
    double clientTotalMs;            // first packet -> presented on the display
    double maxClientTotalMs;

    uint32_t rttMs;                  // network round-trip estimate from moonlight-common-c
    uint32_t rttVarianceMs;
} ArtemisVideoStatsSnapshot;

@interface VideoStats : NSObject

// e.g. "AV1 10-bit 2880x1864 60 FPS", set when the decoder is set up
@property (atomic, copy, nullable) NSString *streamDescription;

// Microseconds on moonlight-common-c's clock
+ (uint64_t)nowUs;
// Converts a CoreAnimation/Metal timestamp (seconds, e.g. MTLDrawable.presentedTime) to nowUs's clock
+ (uint64_t)microsecondsFromMediaTime:(CFTimeInterval)mediaTime;

- (void)reset;
- (void)recordReceivedFrame:(int)frameNumber;
- (void)recordDecodedFrame:(const ArtemisFrameTiming *)timing;
- (void)recordDecoderDrop;
- (void)recordSupersededFrame:(const ArtemisFrameTiming *)timing;
- (void)recordPresentedFrame:(const ArtemisFrameTiming *)timing present:(const ArtemisPresentTiming *)present;
// A present that carries no new frame (see MetalVideoPresenter). Not in the latency averages.
- (void)recordKeepAlivePresent:(const ArtemisPresentTiming *)present;

// Writes one CSV line per frame to path until the stats are reset, for offline analysis
- (void)startTraceAtPath:(NSString *)path;

// Returns NO until the first window completes
- (BOOL)lastWindow:(ArtemisVideoStatsSnapshot *)snapshot;

@end

NS_ASSUME_NONNULL_END
