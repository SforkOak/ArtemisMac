//
//  VideoStats.m
//  Artemis
//

#import "VideoStats.h"

#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>

#include "Limelight.h"

typedef struct {
    uint64_t startUs;
    int lastFrameNumber;

    uint32_t received, decoded, presented, lost, decoderDropped, superseded, notDisplayed;

    uint64_t hostLatencySum;      // 1/10 ms
    uint32_t hostLatencyCount;
    uint64_t networkReceiveSumUs;
    uint64_t queueDelaySumUs;
    uint64_t decodeSumUs;
    uint32_t decodeCount;
    uint64_t renderSumUs;
    uint64_t drawableWaitSumUs;
    uint64_t drawableWaitMaxUs;
    uint64_t drawSumUs;
    uint32_t drawCount;
    uint64_t clientTotalSumUs;
    uint64_t clientTotalMaxUs;
} Window;

@implementation VideoStats {
    os_unfair_lock _lock;
    Window _current;
    ArtemisVideoStatsSnapshot _last;
    BOOL _hasLast;
    FILE *_trace;
}

+ (uint64_t)nowUs {
    return LiGetMicroseconds();
}

+ (uint64_t)microsecondsFromMediaTime:(CFTimeInterval)mediaTime {
    // Both clocks are CLOCK_UPTIME_RAW; LiGetMicroseconds() is just offset to its first use
    int64_t offsetUs = (int64_t)(CACurrentMediaTime() * 1e6) - (int64_t)LiGetMicroseconds();
    int64_t us = (int64_t)(mediaTime * 1e6) - offsetUs;
    return us > 0 ? (uint64_t)us : 0;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        [self reset];
    }
    return self;
}

- (void)dealloc {
    [self closeTrace];
}

- (void)reset {
    os_unfair_lock_lock(&_lock);
    memset(&_current, 0, sizeof(_current));
    _current.startUs = [VideoStats nowUs];
    _hasLast = NO;
    os_unfair_lock_unlock(&_lock);
    [self closeTrace];
}

- (void)startTraceAtPath:(NSString *)path {
    FILE *file = fopen(path.fileSystemRepresentation, "w");
    if (file == NULL) {
        Log(LOG_W, @"Couldn't open the frame trace at %@: %s", path, strerror(errno));
        return;
    }
    // Times are microseconds on nowUs's clock; 0 means it didn't happen
    fprintf(file, "kind,frame,receive_us,decoded_us,drawable_wait_us,committed_us,gpu_done_us,presented_us\n");
    os_unfair_lock_lock(&_lock);
    FILE *old = _trace;
    _trace = file;
    os_unfair_lock_unlock(&_lock);
    if (old != NULL) {
        fclose(old);
    }
    Log(LOG_I, @"Writing a frame trace to %@", path);
}

- (void)closeTrace {
    os_unfair_lock_lock(&_lock);
    FILE *file = _trace;
    _trace = NULL;
    os_unfair_lock_unlock(&_lock);
    if (file != NULL) {
        fclose(file);
    }
}

// Called with the lock held
- (void)rollWindowIfNeeded {
    uint64_t now = [VideoStats nowUs];
    if (now - _current.startUs < 1000000) {
        return;
    }

    ArtemisVideoStatsSnapshot s = {0};
    s.windowSeconds = (now - _current.startUs) / 1e6;
    s.framesReceived = _current.received;
    s.framesDecoded = _current.decoded;
    s.framesPresented = _current.presented;
    s.framesLostInNetwork = _current.lost;
    s.framesDroppedByDecoder = _current.decoderDropped;
    s.framesSuperseded = _current.superseded;
    s.framesNotDisplayed = _current.notDisplayed;
    if (_current.hostLatencyCount > 0) {
        s.hostLatencyMs = _current.hostLatencySum / 10.0 / _current.hostLatencyCount;
    }
    if (_current.decodeCount > 0) {
        s.networkReceiveMs = _current.networkReceiveSumUs / 1000.0 / _current.decodeCount;
        s.queueDelayMs = _current.queueDelaySumUs / 1000.0 / _current.decodeCount;
        s.decodeMs = _current.decodeSumUs / 1000.0 / _current.decodeCount;
    }
    if (_current.presented > 0) {
        s.renderMs = _current.renderSumUs / 1000.0 / _current.presented;
        s.drawableWaitMs = _current.drawableWaitSumUs / 1000.0 / _current.presented;
        s.clientTotalMs = _current.clientTotalSumUs / 1000.0 / _current.presented;
        s.maxClientTotalMs = _current.clientTotalMaxUs / 1000.0;
    }
    s.maxDrawableWaitMs = _current.drawableWaitMaxUs / 1000.0;
    if (_current.drawCount > 0) {
        s.drawMs = _current.drawSumUs / 1000.0 / _current.drawCount;
        // The rest of the way from decoded to the display
        s.displayMs = MAX(0, s.renderMs - s.drawMs);
    }

    uint32_t rtt = 0, rttVariance = 0;
    if (LiGetEstimatedRttInfo(&rtt, &rttVariance)) {
        s.rttMs = rtt;
        s.rttVarianceMs = rttVariance;
    }

    _last = s;
    _hasLast = YES;
    if (_trace != NULL) {
        fflush(_trace);
    }

    int lastFrameNumber = _current.lastFrameNumber;
    memset(&_current, 0, sizeof(_current));
    _current.startUs = now;
    _current.lastFrameNumber = lastFrameNumber;
}

- (void)recordReceivedFrame:(int)frameNumber {
    os_unfair_lock_lock(&_lock);
    [self rollWindowIfNeeded];
    if (_current.lastFrameNumber != 0 && frameNumber > _current.lastFrameNumber + 1) {
        _current.lost += frameNumber - (_current.lastFrameNumber + 1);
    }
    _current.lastFrameNumber = frameNumber;
    _current.received++;
    os_unfair_lock_unlock(&_lock);
}

- (void)recordDecodedFrame:(const ArtemisFrameTiming *)t {
    os_unfair_lock_lock(&_lock);
    _current.decoded++;
    _current.decodeCount++;
    if (t->hostProcessingLatency != 0) {
        _current.hostLatencySum += t->hostProcessingLatency;
        _current.hostLatencyCount++;
    }
    if (t->enqueueTimeUs >= t->receiveTimeUs) {
        _current.networkReceiveSumUs += t->enqueueTimeUs - t->receiveTimeUs;
    }
    if (t->submitTimeUs >= t->enqueueTimeUs) {
        _current.queueDelaySumUs += t->submitTimeUs - t->enqueueTimeUs;
    }
    if (t->decodedTimeUs >= t->submitTimeUs) {
        _current.decodeSumUs += t->decodedTimeUs - t->submitTimeUs;
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)recordDecoderDrop {
    os_unfair_lock_lock(&_lock);
    _current.decoderDropped++;
    os_unfair_lock_unlock(&_lock);
}

- (void)recordSupersededFrame:(const ArtemisFrameTiming *)t {
    os_unfair_lock_lock(&_lock);
    _current.superseded++;
    if (_trace != NULL) {
        fprintf(_trace, "S,%d,%llu,%llu,0,0,0,0\n", t->frameNumber, t->receiveTimeUs, t->decodedTimeUs);
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)recordPresentedFrame:(const ArtemisFrameTiming *)t present:(const ArtemisPresentTiming *)p {
    os_unfair_lock_lock(&_lock);
    if (_trace != NULL) {
        fprintf(_trace, "P,%d,%llu,%llu,%llu,%llu,%llu,%llu\n", t->frameNumber, t->receiveTimeUs, t->decodedTimeUs,
                p->drawableWaitUs, p->committedTimeUs, p->gpuDoneTimeUs, p->presentedTimeUs);
    }
    if (p->presentedTimeUs == 0) {
        _current.notDisplayed++;
        os_unfair_lock_unlock(&_lock);
        return;
    }

    uint64_t presentedTimeUs = p->presentedTimeUs;
    _current.presented++;
    _current.drawableWaitSumUs += p->drawableWaitUs;
    _current.drawableWaitMaxUs = MAX(_current.drawableWaitMaxUs, p->drawableWaitUs);
    if (p->gpuDoneTimeUs >= t->decodedTimeUs && p->gpuDoneTimeUs <= presentedTimeUs) {
        _current.drawSumUs += p->gpuDoneTimeUs - t->decodedTimeUs;
        _current.drawCount++;
    }
    if (presentedTimeUs >= t->decodedTimeUs) {
        _current.renderSumUs += presentedTimeUs - t->decodedTimeUs;
    }
    if (presentedTimeUs >= t->receiveTimeUs) {
        uint64_t total = presentedTimeUs - t->receiveTimeUs;
        _current.clientTotalSumUs += total;
        if (total > _current.clientTotalMaxUs) {
            _current.clientTotalMaxUs = total;
        }
    }
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)lastWindow:(ArtemisVideoStatsSnapshot *)snapshot {
    os_unfair_lock_lock(&_lock);
    [self rollWindowIfNeeded];
    BOOL has = _hasLast;
    if (has) {
        *snapshot = _last;
    }
    os_unfair_lock_unlock(&_lock);
    return has;
}

@end
