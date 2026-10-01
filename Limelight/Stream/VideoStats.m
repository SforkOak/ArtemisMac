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

    uint32_t received, decoded, presented, lost, decoderDropped, superseded;

    uint64_t hostLatencySum;      // 1/10 ms
    uint32_t hostLatencyCount;
    uint64_t networkReceiveSumUs;
    uint64_t queueDelaySumUs;
    uint64_t decodeSumUs;
    uint32_t decodeCount;
    uint64_t renderSumUs;
    uint64_t clientTotalSumUs;
    uint64_t clientTotalMaxUs;
} Window;

@implementation VideoStats {
    os_unfair_lock _lock;
    Window _current;
    ArtemisVideoStatsSnapshot _last;
    BOOL _hasLast;
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

- (void)reset {
    os_unfair_lock_lock(&_lock);
    memset(&_current, 0, sizeof(_current));
    _current.startUs = [VideoStats nowUs];
    _hasLast = NO;
    os_unfair_lock_unlock(&_lock);
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
        s.clientTotalMs = _current.clientTotalSumUs / 1000.0 / _current.presented;
        s.maxClientTotalMs = _current.clientTotalMaxUs / 1000.0;
    }

    uint32_t rtt = 0, rttVariance = 0;
    if (LiGetEstimatedRttInfo(&rtt, &rttVariance)) {
        s.rttMs = rtt;
        s.rttVarianceMs = rttVariance;
    }

    _last = s;
    _hasLast = YES;

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

- (void)recordSupersededFrame {
    os_unfair_lock_lock(&_lock);
    _current.superseded++;
    os_unfair_lock_unlock(&_lock);
}

- (void)recordPresentedFrame:(const ArtemisFrameTiming *)t presentedTimeUs:(uint64_t)presentedTimeUs {
    os_unfair_lock_lock(&_lock);
    _current.presented++;
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
