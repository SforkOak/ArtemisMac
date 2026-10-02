//
//  StreamManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamConfiguration.h"
#import "Connection.h"
#import "VideoStats.h"

@interface StreamManager : NSOperation

- (id) initWithConfig:(StreamConfiguration*)config renderView:(OSView*)view connectionCallbacks:(id<ConnectionCallbacks>)callback;

- (void) stopStream;

// The resolution, FPS and display mode a host's running app was launched with, as
// {width, height, fps, virtualDisplay, appId}, or nil if unknown. Resuming keeps these
// (Apollo doesn't resize the session), so callers can offer to restart instead.
+ (NSDictionary *)launchedSessionForHost:(NSString *)hostUUID;
+ (void)forgetLaunchedSessionForHost:(NSString *)hostUUID;

// Latency statistics for the running stream (nil until the stream starts)
@property (atomic, readonly, strong) VideoStats* videoStats;

// Main thread. Text drawn over the video, or nil for none (ignored until the stream starts).
- (void) setStatsOverlayText:(NSString *)text;

@end
