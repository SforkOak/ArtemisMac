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

// Latency statistics for the running stream (nil until the stream starts)
@property (atomic, readonly, strong) VideoStats* videoStats;

@end
