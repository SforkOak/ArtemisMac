//
//  MetalVideoPresenter.h
//  Artemis
//
//  Puts decoded frames on screen with as little delay as possible. Frames go into a
//  single "latest frame" slot, so a newer frame always replaces one that hasn't been
//  drawn yet and nothing ever queues up behind the display.
//
//  - V-sync off: a dedicated render thread draws each frame the moment it's decoded,
//    into a CAMetalLayer with displaySyncEnabled = NO.
//  - V-sync on: a CAMetalDisplayLink asks for a frame once per refresh, and we draw the
//    newest frame that has arrived.
//

#import <Cocoa/Cocoa.h>
#import <CoreVideo/CoreVideo.h>

#import "VideoStats.h"

NS_ASSUME_NONNULL_BEGIN

@interface MetalVideoPresenter : NSObject

// Must be called on the main thread. Adds a Metal-backed view filling containerView.
- (nullable instancetype)initWithContainerView:(NSView *)containerView stats:(VideoStats *)stats;

// colorspace is the COLORSPACE_* the stream was set up with, used when frames don't say
- (void)startWithVideoSize:(CGSize)videoSize frameRate:(int)frameRate vsync:(BOOL)vsync defaultColorspace:(int)colorspace;
// Safe from any thread. Blocks until the render thread has exited.
- (void)stop;

// Called from VideoToolbox's output thread. Retains pixelBuffer while it's needed.
- (void)submitFrame:(CVPixelBufferRef)pixelBuffer timing:(const ArtemisFrameTiming *)timing;

@end

NS_ASSUME_NONNULL_END
