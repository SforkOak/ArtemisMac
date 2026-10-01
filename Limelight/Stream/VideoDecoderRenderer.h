//
//  VideoDecoderRenderer.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//
//  Hardware decodes frames with VideoToolbox as soon as moonlight-common-c has
//  reassembled them, and hands the decoded images to MetalVideoPresenter.
//

#import <Foundation/Foundation.h>

#import "StreamConfiguration.h"
#import "VideoStats.h"

#include "Limelight.h"

NS_ASSUME_NONNULL_BEGIN

@interface VideoDecoderRenderer : NSObject

@property (nonatomic, readonly) VideoStats *stats;

// Must be called on the main thread. vsync = NO presents each frame the moment it's decoded.
- (nullable instancetype)initWithView:(OSView *)view vsync:(BOOL)vsync;

- (void)setupWithVideoFormat:(int)videoFormat width:(int)width height:(int)height frameRate:(int)frameRate;
- (void)start;
// May be followed by a few more submitDecodeUnit: calls, which are ignored
- (void)stop;
// Called once no more decode units can arrive
- (void)cleanup;

// Called on moonlight-common-c's receive thread (CAPABILITY_DIRECT_SUBMIT)
- (int)submitDecodeUnit:(PDECODE_UNIT)decodeUnit;

- (void)setHdrMode:(BOOL)enabled;

@end

NS_ASSUME_NONNULL_END
