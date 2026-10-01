//
//  MetalVideoPresenter.m
//  Artemis
//

#import "MetalVideoPresenter.h"

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>
#import <simd/simd.h>
#include <stdatomic.h>

#include "Limelight.h"
#include "ColorConversion.h"

// Draws a decoded bi-planar Y'CbCr frame (NV12 or P010). Compiled at runtime with
// newLibraryWithSource:, so building the app doesn't need Xcode's separate Metal toolchain.
static NSString *const kVideoShaderSource = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "// Must match ArtemisCscParams in ColorConversion.h\n"
    "struct CscParams {\n"
    "    float4 row0;     // R = dot(row0.xyz, yuv - offsets)\n"
    "    float4 row1;     // G\n"
    "    float4 row2;     // B\n"
    "    float4 offsets;  // xyz: Y, Cb, Cr offsets in normalized texture units\n"
    "};\n"
    "\n"
    "struct VertexOut {\n"
    "    float4 position [[position]];\n"
    "    float2 texCoord;\n"
    "};\n"
    "\n"
    "// Full-screen triangle strip; the viewport does the letterboxing. texScale crops away\n"
    "// decoder padding (e.g. a 1088-line coded frame for a 1080p stream).\n"
    "vertex VertexOut videoVertex(uint vid [[vertex_id]],\n"
    "                             constant float2 &texScale [[buffer(0)]]) {\n"
    "    const float2 positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };\n"
    "    const float2 texCoords[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };\n"
    "\n"
    "    VertexOut out;\n"
    "    out.position = float4(positions[vid], 0.0, 1.0);\n"
    "    out.texCoord = texCoords[vid] * texScale;\n"
    "    return out;\n"
    "}\n"
    "\n"
    "fragment float4 videoFragment(VertexOut in [[stage_in]],\n"
    "                              texture2d<float> lumaTexture [[texture(0)]],\n"
    "                              texture2d<float> chromaTexture [[texture(1)]],\n"
    "                              constant CscParams &csc [[buffer(0)]]) {\n"
    "    constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
    "\n"
    "    float3 yuv = float3(lumaTexture.sample(s, in.texCoord).r,\n"
    "                        chromaTexture.sample(s, in.texCoord).rg);\n"
    "    yuv -= csc.offsets.xyz;\n"
    "\n"
    "    float3 rgb = float3(dot(yuv, csc.row0.xyz),\n"
    "                        dot(yuv, csc.row1.xyz),\n"
    "                        dot(yuv, csc.row2.xyz));\n"
    "    return float4(saturate(rgb), 1.0);\n"
    "}\n";

#pragma mark - Metal view

// Layer-hosting view whose CAMetalLayer always matches the view's size in pixels
@interface ArtemisMetalView : NSView
@property (nonatomic, readonly) CAMetalLayer *metalLayer;
@end

@implementation ArtemisMetalView

- (instancetype)initWithFrame:(NSRect)frame device:(id<MTLDevice>)device {
    self = [super initWithFrame:frame];
    if (self) {
        _metalLayer = [CAMetalLayer layer];
        _metalLayer.device = device;
        _metalLayer.framebufferOnly = YES;
        _metalLayer.opaque = YES;
        _metalLayer.maximumDrawableCount = 2;
        _metalLayer.presentsWithTransaction = NO;
        _metalLayer.backgroundColor = NSColor.blackColor.CGColor;

        self.layer = _metalLayer;
        self.wantsLayer = YES;
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }
    return self;
}

- (void)updateDrawableSize {
    CGFloat scale = self.window != nil ? self.window.backingScaleFactor : NSScreen.mainScreen.backingScaleFactor;
    self.metalLayer.contentsScale = scale;
    CGSize size = CGSizeMake(round(self.bounds.size.width * scale), round(self.bounds.size.height * scale));
    if (size.width > 0 && size.height > 0) {
        self.metalLayer.drawableSize = size;
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self updateDrawableSize];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateDrawableSize];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self updateDrawableSize];
}

// Mouse events belong to the stream view underneath
- (NSView *)hitTest:(NSPoint)point {
    return nil;
}

@end


#pragma mark - Presenter

@interface MetalVideoPresenter () <CAMetalDisplayLinkDelegate>
@end

@implementation MetalVideoPresenter {
    VideoStats *_stats;
    ArtemisMetalView *_view;
    CAMetalLayer *_layer;

    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLLibrary> _library;
    id<MTLRenderPipelineState> _pipeline;
    MTLPixelFormat _pipelinePixelFormat;
    CVMetalTextureCacheRef _textureCache;

    CGSize _videoSize;
    int _frameRate;
    BOOL _vsync;
    int _defaultColorspace;
    BOOL _hdrOutput;

    // The latest-frame slot
    os_unfair_lock _slotLock;
    CVPixelBufferRef _slotFrame;
    ArtemisFrameTiming _slotTiming;
    dispatch_semaphore_t _frameAvailable;

    atomic_bool _started;
    atomic_bool _stopping;
    dispatch_semaphore_t _threadExited;
    CAMetalDisplayLink *_displayLink;

    // Keep-alive (v-sync off, windowed). _keepAliveWanted and _windowed are main thread only;
    // the render thread follows _keepAliveActive.
    CAMetalLayer *_keepAliveLayer;
    uint64_t _keepAliveIntervalUs;
    uint64_t _nextKeepAliveUs;
    BOOL _keepAliveWanted;
    BOOL _windowed;
    atomic_bool _keepAliveActive;
}

- (instancetype)initWithContainerView:(NSView *)containerView stats:(VideoStats *)stats {
    NSAssert(NSThread.isMainThread, @"MetalVideoPresenter must be created on the main thread");

    self = [super init];
    if (self == nil) {
        return nil;
    }

    _device = MTLCreateSystemDefaultDevice();
    _commandQueue = [_device newCommandQueue];
    if (_device == nil || _commandQueue == nil) {
        Log(LOG_E, @"Metal is unavailable");
        return nil;
    }
    NSError *error = nil;
    _library = [_device newLibraryWithSource:kVideoShaderSource options:nil error:&error];
    if (_library == nil) {
        Log(LOG_E, @"Failed to compile the video shaders: %@", error);
        return nil;
    }
    if (CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, _device, NULL, &_textureCache) != kCVReturnSuccess) {
        Log(LOG_E, @"CVMetalTextureCacheCreate() failed");
        return nil;
    }

    _stats = stats;
    _slotLock = OS_UNFAIR_LOCK_INIT;
    _frameAvailable = dispatch_semaphore_create(0);
    _threadExited = dispatch_semaphore_create(0);

    _view = [[ArtemisMetalView alloc] initWithFrame:containerView.bounds device:_device];
    [containerView addSubview:_view positioned:NSWindowBelow relativeTo:nil];
    _layer = _view.metalLayer;
    [self configureLayerForHdr:NO];

    // A transparent pixel in the bottom-left corner, presented by the keep-alive
    _keepAliveLayer = [CAMetalLayer layer];
    _keepAliveLayer.device = _device;
    _keepAliveLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _keepAliveLayer.framebufferOnly = YES;
    _keepAliveLayer.opaque = NO;
    _keepAliveLayer.displaySyncEnabled = NO;
    _keepAliveLayer.frame = CGRectMake(0, 0, 1, 1);
    _keepAliveLayer.drawableSize = CGSizeMake(2, 2);
    NSScreen *screen = containerView.window.screen ?: NSScreen.mainScreen;
    _keepAliveIntervalUs = (uint64_t)((screen.minimumRefreshInterval > 0 ? screen.minimumRefreshInterval : 1.0 / 60) * 1e6);
    _windowed = (containerView.window.styleMask & NSWindowStyleMaskFullScreen) == 0;
    for (NSNotificationName name in @[NSWindowWillEnterFullScreenNotification, NSWindowDidExitFullScreenNotification,
                                      NSWindowDidChangeOcclusionStateNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowStateChanged:) name:name object:nil];
    }

    return self;
}

- (void)dealloc {
    [self stop];
    [self clearSlot];
    if (_textureCache != NULL) {
        CFRelease(_textureCache);
    }
}

- (void)startWithVideoSize:(CGSize)videoSize frameRate:(int)frameRate vsync:(BOOL)vsync defaultColorspace:(int)colorspace {
    if (atomic_exchange(&_started, true)) {
        return;
    }

    _videoSize = videoSize;
    _frameRate = frameRate;
    _vsync = vsync;
    _defaultColorspace = colorspace;
    _layer.displaySyncEnabled = vsync;
    // Every refresh, or every frame for a stream slower than the display
    _keepAliveIntervalUs = MAX(_keepAliveIntervalUs, 1000000 / (uint64_t)MAX(frameRate, 1));

    NSThread *thread = [[NSThread alloc] initWithTarget:self
                                               selector:vsync ? @selector(displayLinkThreadMain) : @selector(renderThreadMain)
                                                 object:nil];
    thread.name = vsync ? @"Artemis display link" : @"Artemis render";
    thread.qualityOfService = NSQualityOfServiceUserInteractive;
    [thread start];

    if (!vsync) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_keepAliveWanted = YES;
            [self updateKeepAlive];
        });
    }

    Log(LOG_I, @"Video presenter started: %dx%d at %d FPS, v-sync %@", (int)videoSize.width, (int)videoSize.height, frameRate, vsync ? @"on (CAMetalDisplayLink)" : @"off (present immediately)");
}

- (void)stop {
    if (!atomic_load(&_started) || atomic_exchange(&_stopping, true)) {
        return;
    }

    dispatch_semaphore_signal(_frameAvailable);
    if (dispatch_semaphore_wait(_threadExited, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0) {
        Log(LOG_W, @"Video render thread didn't exit in time");
    }
    [self clearSlot];
}


#pragma mark - Latest-frame slot

- (void)submitFrame:(CVPixelBufferRef)pixelBuffer timing:(const ArtemisFrameTiming *)timing {
    if (atomic_load(&_stopping)) {
        return;
    }

    CVPixelBufferRetain(pixelBuffer);
    os_unfair_lock_lock(&_slotLock);
    CVPixelBufferRef replaced = _slotFrame;
    ArtemisFrameTiming replacedTiming = _slotTiming;
    _slotFrame = pixelBuffer;
    _slotTiming = *timing;
    os_unfair_lock_unlock(&_slotLock);

    if (replaced != NULL) {
        CVPixelBufferRelease(replaced);
        [_stats recordSupersededFrame:&replacedTiming];
    }
    dispatch_semaphore_signal(_frameAvailable);
}

- (CVPixelBufferRef)takeFrame:(ArtemisFrameTiming *)timing CF_RETURNS_RETAINED {
    os_unfair_lock_lock(&_slotLock);
    CVPixelBufferRef frame = _slotFrame;
    _slotFrame = NULL;
    if (frame != NULL) {
        *timing = _slotTiming;
    }
    os_unfair_lock_unlock(&_slotLock);
    return frame;
}

- (BOOL)slotHasFrame {
    os_unfair_lock_lock(&_slotLock);
    BOOL has = _slotFrame != NULL;
    os_unfair_lock_unlock(&_slotLock);
    return has;
}

- (void)clearSlot {
    ArtemisFrameTiming unused;
    CVPixelBufferRef frame = [self takeFrame:&unused];
    if (frame != NULL) {
        CVPixelBufferRelease(frame);
    }
}


#pragma mark - V-sync off: render as soon as a frame is decoded

- (void)renderThreadMain {
    while (!atomic_load(&_stopping)) {
        BOOL keepAliveDue = dispatch_semaphore_wait(_frameAvailable, [self keepAliveDeadline]) != 0;
        if (atomic_load(&_stopping)) {
            break;
        }

        if (![self slotHasFrame]) {
            // The keep-alive is due, or a wakeup for a frame that an earlier pass already drew
            // (or a newer one replaced)
            if (keepAliveDue && atomic_load(&_keepAliveActive)) {
                @autoreleasepool {
                    [self presentKeepAlive];
                }
                [self scheduleKeepAliveAfterNewFrame:NO];
            }
            continue;
        }

        @autoreleasepool {
            [self renderLatestFrame];
        }
        [self scheduleKeepAliveAfterNewFrame:YES];
    }

    dispatch_semaphore_signal(_threadExited);
}

// Our drawable is released as soon as we drop it, rather than when an outer pool drains
- (nullable id<CAMetalDrawable>)nextDrawableWaitingUs:(uint64_t *)waitUs {
    id<CAMetalDrawable> drawable;
    uint64_t start = [VideoStats nowUs];
    @autoreleasepool {
        drawable = [_layer nextDrawable];
    }
    *waitUs += [VideoStats nowUs] - start;
    return drawable;
}

// Gets the drawable before choosing the frame. nextDrawable blocks while the display still
// holds both drawables (two frames within one refresh, as happens when the stream's frame
// rate is above the display's), and a frame decoded during that wait should replace the one
// that woke us instead of being drawn after it.
- (void)renderLatestFrame {
    uint64_t drawableWaitUs = 0;
    id<CAMetalDrawable> drawable = [self nextDrawableWaitingUs:&drawableWaitUs];

    ArtemisFrameTiming timing;
    CVPixelBufferRef frame = [self takeFrame:&timing];
    if (frame == NULL) {
        return;
    }

    BOOL wantHdr = [self frameWantsHdr:frame];
    if (wantHdr != _hdrOutput) {
        // That drawable has the old pixel format
        drawable = nil;
        [self configureLayerForHdr:wantHdr];
        drawable = [self nextDrawableWaitingUs:&drawableWaitUs];
    }

    if (drawable != nil) {
        [self renderFrame:frame timing:&timing drawable:drawable drawableWaitUs:drawableWaitUs];
    }
    CVPixelBufferRelease(frame);
}


#pragma mark - Keep-alive

// A windowed stream goes through WindowServer's compositor, which adds about two refreshes
// (35-40 ms) to a present that follows a refresh without one. Sparse content (a 24-30 fps
// video, an idle desktop) hits that on most frames. So when no new frame arrives within a
// refresh, we present a transparent pixel instead: the compositor stays busy, and the video
// layer's drawables stay free for the next real frame. Measured on a 60 Hz MacBook Air with
// ~20 fps content: Present 19-23 ms -> 13-14 ms.

- (dispatch_time_t)keepAliveDeadline {
    if (!atomic_load(&_keepAliveActive)) {
        return DISPATCH_TIME_FOREVER;
    }
    uint64_t now = [VideoStats nowUs];
    return _nextKeepAliveUs > now ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)((_nextKeepAliveUs - now) * NSEC_PER_USEC)) : DISPATCH_TIME_NOW;
}

// Keep-alives stay on a fixed grid from the last new frame, so timer slop can't add up to
// a refresh without a present
- (void)scheduleKeepAliveAfterNewFrame:(BOOL)newFrame {
    uint64_t now = [VideoStats nowUs];
    _nextKeepAliveUs = newFrame ? now + _keepAliveIntervalUs : _nextKeepAliveUs + _keepAliveIntervalUs;
    if (_nextKeepAliveUs <= now) {
        _nextKeepAliveUs = now + _keepAliveIntervalUs;
    }
}

- (void)presentKeepAlive {
    uint64_t start = [VideoStats nowUs];
    id<CAMetalDrawable> drawable;
    @autoreleasepool {
        drawable = [_keepAliveLayer nextDrawable];
    }
    if (drawable == nil) {
        return;
    }

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    [[commandBuffer renderCommandEncoderWithDescriptor:pass] endEncoding];

    uint64_t committed = [VideoStats nowUs];
    ArtemisPresentTiming presentTiming = { .drawableWaitUs = committed - start, .committedTimeUs = committed };
    VideoStats *stats = _stats;
    [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
        ArtemisPresentTiming p = presentTiming;
        if (presented.presentedTime > 0) {
            p.presentedTimeUs = [VideoStats microsecondsFromMediaTime:presented.presentedTime];
        }
        [stats recordKeepAlivePresent:&p];
    }];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

// Main thread
- (void)windowStateChanged:(NSNotification *)notification {
    if (notification.object != _view.window) {
        return;
    }
    // Off before the full screen transition starts, so the extra layer is gone by the time it ends
    if ([notification.name isEqualToString:NSWindowWillEnterFullScreenNotification]) {
        _windowed = NO;
    } else if ([notification.name isEqualToString:NSWindowDidExitFullScreenNotification]) {
        _windowed = YES;
    }
    [self updateKeepAlive];
}

// Main thread. Only a windowed stream needs the keep-alive: in full screen the video layer
// flips straight to the display ("Direct" in the Metal HUD), which stays fast with sparse
// frames, and a second layer would force it back through the compositor.
- (void)updateKeepAlive {
    NSWindow *window = _view.window;
    BOOL attach = _keepAliveWanted && _windowed;
    BOOL active = attach && (window.occlusionState & NSWindowOcclusionStateVisible) != 0;

    if (attach != (_keepAliveLayer.superlayer != nil)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        if (attach) {
            [_layer addSublayer:_keepAliveLayer];
        } else {
            [_keepAliveLayer removeFromSuperlayer];
        }
        [CATransaction commit];
    }
    if (atomic_exchange(&_keepAliveActive, active) != active && active) {
        // Wake the render thread so it picks up a deadline
        dispatch_semaphore_signal(_frameAvailable);
    }
}


#pragma mark - V-sync on: CAMetalDisplayLink

- (void)displayLinkThreadMain {
    @autoreleasepool {
        _displayLink = [[CAMetalDisplayLink alloc] initWithMetalLayer:_layer];
        _displayLink.delegate = self;
        _displayLink.preferredFrameLatency = 1.0;
        _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(_frameRate, _frameRate, _frameRate);
        [_displayLink addToRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];
    }

    while (!atomic_load(&_stopping)) {
        @autoreleasepool {
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
    }

    [_displayLink invalidate];
    _displayLink = nil;
    dispatch_semaphore_signal(_threadExited);
}

- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update {
    if (atomic_load(&_stopping)) {
        return;
    }

    ArtemisFrameTiming timing;
    CVPixelBufferRef frame = [self takeFrame:&timing];

    // No new frame yet: wait up to half the time left before this refresh for one to arrive
    while (frame == NULL) {
        CFTimeInterval waitTime = (update.targetTimestamp - CACurrentMediaTime()) / 2;
        if (waitTime <= 0 ||
            dispatch_semaphore_wait(_frameAvailable, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(waitTime * NSEC_PER_SEC))) != 0 ||
            atomic_load(&_stopping)) {
            break;
        }
        frame = [self takeFrame:&timing];
    }

    if (frame != NULL) {
        [self renderFrame:frame timing:&timing drawable:update.drawable drawableWaitUs:0];
        CVPixelBufferRelease(frame);
    }
}


#pragma mark - Drawing

- (void)configureLayerForHdr:(BOOL)hdr {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGColorSpaceRef colorspace;
    if (hdr) {
        _layer.pixelFormat = MTLPixelFormatBGR10A2Unorm;
        colorspace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
        _layer.wantsExtendedDynamicRangeContent = YES;
    } else {
        _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        // Games and desktops are rendered in sRGB on the host, so present them as sRGB
        colorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        _layer.wantsExtendedDynamicRangeContent = NO;
    }
    _layer.colorspace = colorspace;
    CGColorSpaceRelease(colorspace);
    [CATransaction commit];

    _hdrOutput = hdr;
}

- (BOOL)ensurePipelineForPixelFormat:(MTLPixelFormat)pixelFormat {
    if (_pipeline != nil && _pipelinePixelFormat == pixelFormat) {
        return YES;
    }

    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = [_library newFunctionWithName:@"videoVertex"];
    descriptor.fragmentFunction = [_library newFunctionWithName:@"videoFragment"];
    descriptor.colorAttachments[0].pixelFormat = pixelFormat;

    NSError *error = nil;
    _pipeline = [_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (_pipeline == nil) {
        Log(LOG_E, @"Failed to create the video pipeline: %@", error);
        return NO;
    }
    _pipelinePixelFormat = pixelFormat;
    return YES;
}

- (int)colorspaceOfFrame:(CVPixelBufferRef)frame {
    int colorspace = _defaultColorspace;
    CFTypeRef matrix = CVBufferCopyAttachment(frame, kCVImageBufferYCbCrMatrixKey, NULL);
    if (matrix != NULL) {
        if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4)) {
            colorspace = COLORSPACE_REC_601;
        } else if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) {
            colorspace = COLORSPACE_REC_709;
        } else if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020)) {
            colorspace = COLORSPACE_REC_2020;
        }
        CFRelease(matrix);
    }
    return colorspace;
}

- (BOOL)frameWantsHdr:(CVPixelBufferRef)frame {
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(frame);
    BOOL tenBit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                  pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    return tenBit && [self isPqFrame:frame];
}

- (BOOL)isPqFrame:(CVPixelBufferRef)frame {
    CFTypeRef transfer = CVBufferCopyAttachment(frame, kCVImageBufferTransferFunctionKey, NULL);
    BOOL pq = transfer != NULL && CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ);
    if (transfer != NULL) {
        CFRelease(transfer);
    }
    return pq;
}

// Draws frame into drawable and presents it
- (void)renderFrame:(CVPixelBufferRef)frame timing:(const ArtemisFrameTiming *)timing drawable:(id<CAMetalDrawable>)drawable drawableWaitUs:(uint64_t)drawableWaitUs {
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(frame);
    BOOL tenBit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                  pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    BOOL fullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                     pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    if (CVPixelBufferGetPlaneCount(frame) != 2) {
        Log(LOG_E, @"Unsupported decoder output format: %u", (unsigned)pixelFormat);
        return;
    }

    if (![self ensurePipelineForPixelFormat:drawable.texture.pixelFormat]) {
        return;
    }

    CVMetalTextureRef lumaRef = NULL, chromaRef = NULL;
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, frame, NULL,
                                              tenBit ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm,
                                              CVPixelBufferGetWidthOfPlane(frame, 0), CVPixelBufferGetHeightOfPlane(frame, 0),
                                              0, &lumaRef);
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, frame, NULL,
                                              tenBit ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm,
                                              CVPixelBufferGetWidthOfPlane(frame, 1), CVPixelBufferGetHeightOfPlane(frame, 1),
                                              1, &chromaRef);
    if (lumaRef == NULL || chromaRef == NULL) {
        Log(LOG_E, @"CVMetalTextureCacheCreateTextureFromImage() failed");
        if (lumaRef != NULL) CFRelease(lumaRef);
        if (chromaRef != NULL) CFRelease(chromaRef);
        return;
    }

    // Letterbox the video inside the drawable
    double drawableWidth = drawable.texture.width;
    double drawableHeight = drawable.texture.height;
    double videoWidth = _videoSize.width > 0 ? _videoSize.width : CVPixelBufferGetWidth(frame);
    double videoHeight = _videoSize.height > 0 ? _videoSize.height : CVPixelBufferGetHeight(frame);
    double scale = MIN(drawableWidth / videoWidth, drawableHeight / videoHeight);
    double viewportWidth = round(videoWidth * scale);
    double viewportHeight = round(videoHeight * scale);
    MTLViewport viewport = {
        .originX = floor((drawableWidth - viewportWidth) / 2),
        .originY = floor((drawableHeight - viewportHeight) / 2),
        .width = viewportWidth,
        .height = viewportHeight,
        .znear = 0,
        .zfar = 1,
    };

    // Crop decoder padding: sample only the part of the buffer that holds the picture
    simd_float2 texScale = simd_make_float2(MIN(1.0, videoWidth / CVPixelBufferGetWidth(frame)),
                                            MIN(1.0, videoHeight / CVPixelBufferGetHeight(frame)));
    ArtemisCscParams csc = ArtemisMakeCscParams([self colorspaceOfFrame:frame], fullRange, tenBit ? 10 : 8);

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setViewport:viewport];
    [encoder setVertexBytes:&texScale length:sizeof(texScale) atIndex:0];
    [encoder setFragmentTexture:CVMetalTextureGetTexture(lumaRef) atIndex:0];
    [encoder setFragmentTexture:CVMetalTextureGetTexture(chromaRef) atIndex:1];
    [encoder setFragmentBytes:&csc length:sizeof(csc) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];

    // Measure when the frame actually reached the display. A drawable that never did
    // (replaced by a newer one, or the window is hidden) reports a presentedTime of 0.
    ArtemisFrameTiming frameTiming = *timing;
    ArtemisPresentTiming presentTiming = { .drawableWaitUs = drawableWaitUs, .committedTimeUs = [VideoStats nowUs] };
    VideoStats *stats = _stats;
    [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
        ArtemisPresentTiming p = presentTiming;
        if (commandBuffer.status == MTLCommandBufferStatusCompleted && commandBuffer.GPUEndTime > 0) {
            p.gpuDoneTimeUs = [VideoStats microsecondsFromMediaTime:commandBuffer.GPUEndTime];
        }
        if (presented.presentedTime > 0) {
            p.presentedTimeUs = [VideoStats microsecondsFromMediaTime:presented.presentedTime];
        }
        [stats recordPresentedFrame:&frameTiming present:&p];
    }];

    // The textures (and the decoded buffer behind them) must outlive the GPU work
    CVPixelBufferRetain(frame);
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        CFRelease(lumaRef);
        CFRelease(chromaRef);
        CVPixelBufferRelease(frame);
    }];

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

@end
