//
//  StreamViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 25/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "StreamViewController.h"
#import "StreamViewMac.h"
#import "AppsViewController.h"
#import "NSWindow+Moonlight.h"
#import "AlertPresenter.h"

#import "Connection.h"
#import "StreamConfiguration.h"
#import "DataManager.h"
#import "ControllerSupport.h"
#import "StreamManager.h"
#import "VideoDecoderRenderer.h"
#import "HIDSupport.h"
#import "ApolloSession.h"
#import "AudioRenderer.h"

#import "Moonlight-Swift.h"

#include "Limelight.h"

@import VideoToolbox;

#import <IOKit/pwr_mgt/IOPMLib.h>
#import <Carbon/Carbon.h>

@interface StreamViewController () <ConnectionCallbacks, KeyboardNotifiableDelegate, InputPresenceDelegate>

@property (nonatomic, strong) ControllerSupport *controllerSupport;
@property (nonatomic, strong) HIDSupport *hidSupport;
@property (nonatomic) BOOL useSystemControllerDriver;
@property (nonatomic, strong) StreamManager *streamMan;
@property (nonatomic, strong) ApolloSession *apolloSession;
@property (nonatomic, strong) NSMenuItem *apolloMenuItem;
@property (nonatomic, strong) NSTextField *statsOverlay;
@property (nonatomic, strong) NSTimer *statsTimer;
@property (nonatomic) NSUInteger statsTicks;
@property (nonatomic, strong) id<NSObject> streamActivity;
@property (nonatomic, readonly) StreamViewMac *streamView;
@property (nonatomic, strong) id windowDidExitFullScreenNotification;
@property (nonatomic, strong) id windowDidEnterFullScreenNotification;
@property (nonatomic, strong) id windowDidResignKeyNotification;
@property (nonatomic, strong) id windowDidBecomeKeyNotification;
@property (nonatomic, strong) id windowWillCloseNotification;
@property (nonatomic) int cursorHiddenCounter;

@property (nonatomic) IOPMAssertionID powerAssertionID;

@end

@implementation StreamViewController

#pragma mark - Lifecycle

- (BOOL)useSystemControllerDriver {
    return [SettingsClass controllerDriverFor:self.app.host.uuid] == 1;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.cursorHiddenCounter = 0;
    
    [self prepareForStreaming];
    
    __weak typeof(self) weakSelf = self;

    self.windowDidExitFullScreenNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidExitFullScreenNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            if ([weakSelf.view.window isKeyWindow]) {
                [weakSelf uncaptureMouse];
                [weakSelf captureMouse];
            }
        }
    }];

    self.windowDidEnterFullScreenNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidEnterFullScreenNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            if ([weakSelf isWindowInCurrentSpace]) {
                if ([weakSelf isWindowFullscreen]) {
                    if ([weakSelf.view.window isKeyWindow]) {
                        [weakSelf uncaptureMouse];
                        [weakSelf captureMouse];
                    }
                }
            }
        }
    }];
    
    self.windowDidResignKeyNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResignKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            [weakSelf.apolloSession streamWindowDidResignKey];
            if (![weakSelf isWindowInCurrentSpace] || ![weakSelf isWindowFullscreen]) {
                [weakSelf uncaptureMouse];
            }
        }
    }];
    self.windowDidBecomeKeyNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            [weakSelf.apolloSession streamWindowDidBecomeKey];
            if ([weakSelf isWindowInCurrentSpace]) {
                if ([weakSelf isWindowFullscreen]) {
                    if ([weakSelf.view.window isKeyWindow]) {
                        [weakSelf uncaptureMouse];
                        [weakSelf captureMouse];
                    }
                }
            }
        } else {
            [weakSelf uncaptureMouse];
        }
    }];
    
    self.windowWillCloseNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            // Stop the keepalive and stats before the connection is torn down
            [weakSelf.apolloSession streamWillStop];
            [weakSelf stopStatsTimer];
            [weakSelf endStreamActivity];
            [weakSelf removeApolloMenu];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (weakSelf.useSystemControllerDriver) {
                    [weakSelf.controllerSupport cleanup];
                }
                [weakSelf.streamMan stopStream];
            });
        }
    }];
    
}

- (void)viewDidAppear {
    [super viewDidAppear];
    
    self.streamView.keyboardNotifiable = self;
    self.streamView.appName = self.app.name;
    self.streamView.statusText = @"Starting";
    self.view.window.tabbingMode = NSWindowTabbingModeDisallowed;
    [self.view.window makeFirstResponder:self];
    
    self.view.window.contentAspectRatio = NSMakeSize([self.class getResolution].width, [self.class getResolution].height);
    self.view.window.frameAutosaveName = @"Stream Window";
    [self.view.window moonlight_centerWindowOnFirstRunWithSize:CGSizeMake(1008, 595)];
    
    self.view.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidExitFullScreenNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidEnterFullScreenNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidResignKeyNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidBecomeKeyNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowWillCloseNotification];

    [self removeApolloMenu];
    [self stopStatsTimer];
    [self endStreamActivity];
    [self.hidSupport tearDownHidManager];
    self.hidSupport = nil;
}

- (void)flagsChanged:(NSEvent *)event {
    [self.hidSupport flagsChanged:event];
    
    if (event.modifierFlags == 786721) {
        [self.hidSupport releaseAllModifierKeys];
        [self uncaptureMouse];
    }
}

- (void)keyDown:(NSEvent *)event {
    [self.hidSupport keyDown:event];
}

- (void)keyUp:(NSEvent *)event {
    [self.hidSupport keyUp:event];
}


- (void)mouseDown:(NSEvent *)event {
    [self.hidSupport mouseDown:event withButton:BUTTON_LEFT];
    [self captureMouse];
}

- (void)mouseUp:(NSEvent *)event {
    [self.hidSupport mouseUp:event withButton:BUTTON_LEFT];
}

- (void)rightMouseDown:(NSEvent *)event {
    [self.hidSupport mouseDown:event withButton:BUTTON_RIGHT];
}

- (void)rightMouseUp:(NSEvent *)event {
    [self.hidSupport mouseUp:event withButton:BUTTON_RIGHT];
}

- (void)otherMouseDown:(NSEvent *)event {
    int button = [self getMouseButtonFromEvent:event];
    if (button == 0) {
        return;
    }
    [self.hidSupport mouseDown:event withButton:button];
}

- (void)otherMouseUp:(NSEvent *)event {
    int button = [self getMouseButtonFromEvent:event];
    if (button == 0) {
        return;
    }
    [self.hidSupport mouseUp:event withButton:button];
}

- (void)mouseMoved:(NSEvent *)event {
    [self.hidSupport mouseMoved:event];
}

- (void)mouseDragged:(NSEvent *)event {
    [self.hidSupport mouseMoved:event];
}

- (void)rightMouseDragged:(NSEvent *)event {
    [self.hidSupport mouseMoved:event];
}

- (void)otherMouseDragged:(NSEvent *)event {
    [self.hidSupport mouseMoved:event];
}

- (void)scrollWheel:(NSEvent *)event {
    [self.hidSupport scrollWheel:event];
}

- (int)getMouseButtonFromEvent:(NSEvent *)event {
    int button;
    switch (event.buttonNumber) {
        case 2:
            button = BUTTON_MIDDLE;
            break;
        case 3:
            button = BUTTON_X1;
            break;
        case 4:
            button = BUTTON_X2;
            break;
        default:
            return 0;
            break;
    }
    
    return button;
}


#pragma mark - KeyboardNotifiable

- (BOOL)onKeyboardEquivalent:(NSEvent *)event {
    const NSEventModifierFlags modifierFlags = NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand | NSEventModifierFlagFunction;
    const NSEventModifierFlags eventModifierFlags = event.modifierFlags & modifierFlags;
    
    if (event.keyCode == kVK_ANSI_1 && eventModifierFlags == NSEventModifierFlagCommand) {
        [self.hidSupport releaseAllModifierKeys];
        return NO;
    }
    
    if ((event.keyCode == kVK_ANSI_Grave && eventModifierFlags == NSEventModifierFlagCommand)
        || (event.keyCode == kVK_ANSI_H && eventModifierFlags == NSEventModifierFlagCommand)
        ) {
        if (![self isWindowFullscreen]) {
            [self.hidSupport releaseAllModifierKeys];
            return NO;
        }
    }
    
    // Ctrl-Opt-Cmd-S: performance stats overlay
    if (event.keyCode == kVK_ANSI_S
        && eventModifierFlags == (NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand)) {
        [self.hidSupport releaseAllModifierKeys];
        [self toggleStatsOverlay:nil];
        return YES;
    }

    // Apollo menu shortcuts: Send Clipboard / Get Clipboard
    if (self.apolloMenuItem != nil
        && (event.keyCode == kVK_ANSI_V || event.keyCode == kVK_ANSI_C)
        && eventModifierFlags == (NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand)) {
        [self.hidSupport releaseAllModifierKeys];
        return NO;
    }

    if ((event.keyCode == kVK_ANSI_F && eventModifierFlags == (NSEventModifierFlagControl | NSEventModifierFlagCommand))
        || (event.keyCode == kVK_ANSI_F && eventModifierFlags == NSEventModifierFlagFunction)
        || (event.keyCode == kVK_ANSI_W && eventModifierFlags == (NSEventModifierFlagOption | NSEventModifierFlagControl))
        || (event.keyCode == kVK_ANSI_W && eventModifierFlags == (NSEventModifierFlagShift | NSEventModifierFlagControl))
        || (event.keyCode == kVK_ANSI_W && eventModifierFlags == NSEventModifierFlagCommand)
        ) {
        [self.hidSupport releaseAllModifierKeys];
        return NO;
    }
    
    [self.hidSupport keyDown:event];
    [self.hidSupport keyUp:event];
    
    return YES;
}


#pragma mark - Actions


- (IBAction)performClose:(id)sender {
    [self uncaptureMouse];
    
    NSAlert *alert = [[NSAlert alloc] init];
    
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = @"Disconnect from Stream, or Close and Quit App?";

    [alert addButtonWithTitle:@"Disconnect from Stream"];
    [alert addButtonWithTitle:@"Close and Quit App"];
    [alert addButtonWithTitle:@"Cancel"];

    NSModalResponse response = [alert runModal];
    switch (response) {
        case NSAlertFirstButtonReturn:
            [self doCommandBySelector:@selector(performCloseStreamWindow:)];
            break;
            
        case NSAlertSecondButtonReturn:
            [self doCommandBySelector:@selector(performCloseAndQuitApp:)];
            break;

        default:
            break;
    }
}

- (IBAction)performCloseStreamWindow:(id)sender {
    [self.hidSupport releaseAllModifierKeys];
    [self.nextResponder doCommandBySelector:@selector(performClose:)];
}

- (IBAction)performCloseAndQuitApp:(id)sender {
    [self.delegate quitApp:self.app completion:nil];
}

- (IBAction)resizeWindowToActualResulution:(id)sender {
    CGFloat screenScale = [NSScreen mainScreen].backingScaleFactor;
    CGFloat width = (CGFloat)[self.class getResolution].width / screenScale;
    CGFloat height = (CGFloat)[self.class getResolution].height / screenScale;
    [self.view.window setContentSize:NSMakeSize(width, height)];
}


#pragma mark - Apollo

// Adds an "Apollo" menu to the menu bar for the duration of a stream from an Apollo host
- (void)installApolloMenu {
    if (self.apolloMenuItem != nil || !self.app.host.isApollo) {
        return;
    }

    NSMenu *apolloMenu = [[NSMenu alloc] initWithTitle:@"Apollo"];

    NSMenuItem *sendClipboardItem = [apolloMenu addItemWithTitle:@"Send Clipboard to Host" action:@selector(sendClipboardToHost:) keyEquivalent:@"v"];
    sendClipboardItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand;
    sendClipboardItem.target = self;

    NSMenuItem *getClipboardItem = [apolloMenu addItemWithTitle:@"Get Clipboard from Host" action:@selector(getClipboardFromHost:) keyEquivalent:@"c"];
    getClipboardItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand;
    getClipboardItem.target = self;

    [apolloMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *serverCommandsItem = [apolloMenu addItemWithTitle:@"Server Commands" action:nil keyEquivalent:@""];
    NSMenu *serverCommandsMenu = [[NSMenu alloc] initWithTitle:@"Server Commands"];
    NSArray<NSString *> *commands = self.apolloSession.serverCommands;
    if (commands.count == 0) {
        NSMenuItem *emptyItem = [serverCommandsMenu addItemWithTitle:@"No Commands Available" action:nil keyEquivalent:@""];
        emptyItem.enabled = NO;
        NSMenuItem *hintItem = [serverCommandsMenu addItemWithTitle:@"Add commands in Apollo and grant this Mac the Server Command permission" action:nil keyEquivalent:@""];
        hintItem.enabled = NO;
    } else {
        [commands enumerateObjectsUsingBlock:^(NSString *command, NSUInteger index, BOOL *stop) {
            NSMenuItem *commandItem = [serverCommandsMenu addItemWithTitle:command action:@selector(executeServerCommand:) keyEquivalent:@""];
            commandItem.tag = (NSInteger)index;
            commandItem.target = self;
        }];
    }
    serverCommandsItem.submenu = serverCommandsMenu;

    self.apolloMenuItem = [[NSMenuItem alloc] initWithTitle:@"Apollo" action:nil keyEquivalent:@""];
    self.apolloMenuItem.submenu = apolloMenu;

    // Sit just before the Window menu
    NSMenu *mainMenu = [NSApplication sharedApplication].mainMenu;
    NSInteger windowMenuIndex = [mainMenu indexOfItemWithTag:4000];
    [mainMenu insertItem:self.apolloMenuItem atIndex:windowMenuIndex >= 0 ? windowMenuIndex : mainMenu.numberOfItems];
}

- (void)removeApolloMenu {
    if (self.apolloMenuItem != nil) {
        [[NSApplication sharedApplication].mainMenu removeItem:self.apolloMenuItem];
        self.apolloMenuItem = nil;
    }
}

- (IBAction)sendClipboardToHost:(id)sender {
    [self.apolloSession sendClipboardWithCompletion:^(NSString *error) {
        [self showApolloError:error title:@"Couldn't Send Clipboard"];
    }];
}

- (IBAction)getClipboardFromHost:(id)sender {
    [self.apolloSession fetchClipboardWithCompletion:^(NSString *error) {
        [self showApolloError:error title:@"Couldn't Get Clipboard"];
    }];
}

- (IBAction)executeServerCommand:(NSMenuItem *)sender {
    if (![self.apolloSession executeServerCommandAtIndex:(NSUInteger)sender.tag]) {
        [self showApolloError:@"The stream isn't connected, or the command no longer exists on the host." title:@"Couldn't Run Server Command"];
    }
}

- (void)showApolloError:(NSString *)error title:(NSString *)title {
    if (error == nil) {
        return;
    }
    [self.hidSupport releaseAllModifierKeys];
    [self uncaptureMouse];
    [AlertPresenter displayAlert:NSAlertStyleWarning title:title message:error window:self.view.window completionHandler:nil];
}


#pragma mark - Stream activity

- (void)endStreamActivity {
    if (self.streamActivity != nil) {
        [NSProcessInfo.processInfo endActivity:self.streamActivity];
        self.streamActivity = nil;
    }
}


#pragma mark - Performance stats

static NSString *const kShowStatsDefaultsKey = @"showStreamStats";

- (void)startStatsTimer {
    if (self.statsTimer != nil) {
        return;
    }
    self.statsTicks = 0;
    [self setStatsOverlayVisible:[NSUserDefaults.standardUserDefaults boolForKey:kShowStatsDefaultsKey]];

    __weak typeof(self) weakSelf = self;
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf updateStats];
    }];
}

- (void)stopStatsTimer {
    [self.statsTimer invalidate];
    self.statsTimer = nil;
}

- (IBAction)toggleStatsOverlay:(id)sender {
    BOOL visible = !(self.statsOverlay != nil && !self.statsOverlay.hidden);
    [NSUserDefaults.standardUserDefaults setBool:visible forKey:kShowStatsDefaultsKey];
    [self setStatsOverlayVisible:visible];
    [self updateStats];
}

- (void)setStatsOverlayVisible:(BOOL)visible {
    if (visible && self.statsOverlay == nil) {
        NSTextField *overlay = [NSTextField wrappingLabelWithString:@""];
        overlay.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightMedium];
        overlay.textColor = NSColor.whiteColor;
        overlay.drawsBackground = YES;
        overlay.backgroundColor = [NSColor colorWithWhite:0 alpha:0.6];
        overlay.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
        [NSLayoutConstraint activateConstraints:@[
            [overlay.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
            [overlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        ]];
        self.statsOverlay = overlay;
    }
    self.statsOverlay.hidden = !visible;
}

- (void)updateStats {
    ArtemisVideoStatsSnapshot s;
    VideoStats *videoStats = self.streamMan.videoStats;
    if (videoStats == nil || ![videoStats lastWindow:&s]) {
        return;
    }
    ArtemisAudioStats audio;
    ArtemisAudioTakeStats(&audio);

    NSString *text = [NSString stringWithFormat:
        @"%@\n"
        @"RTT          %u ± %u ms\n"
        @"Host encode  %5.1f ms\n"
        @"Receive      %5.1f ms\n"
        @"Decode       %5.1f ms\n"
        @"Present      %5.1f ms (draw %.1f, display %.1f; drawable wait %.1f, max %.1f)\n"
        @"Client total %5.1f ms (max %.1f)\n"
        @"Audio queue  %5u ms (%u–%u), cushion target %u ms\n"
        @"Audio        %u underruns (%u ms), %u trimmed, %u dropped, pull ≤%u frames, gap ≤%.1f ms\n"
        @"Frames %u in, %u shown, %u lost, %u dropped, %u skipped, %u not displayed, %u keep-alive",
        videoStats.streamDescription ?: @"",
        s.rttMs, s.rttVarianceMs,
        s.hostLatencyMs, s.networkReceiveMs + s.queueDelayMs, s.decodeMs,
        s.renderMs, s.drawMs, s.displayMs, s.drawableWaitMs, s.maxDrawableWaitMs,
        s.clientTotalMs, s.maxClientTotalMs,
        ArtemisAudioQueuedMs(), audio.minQueuedMs, audio.maxQueuedMs, audio.targetCushionMs,
        audio.underruns, audio.underrunMs, audio.trimmedPackets, audio.overflowDrops, audio.maxCallbackFrames, audio.maxCallbackGapMs,
        s.framesReceived, s.framesPresented, s.framesLostInNetwork, s.framesDroppedByDecoder, s.framesSuperseded, s.framesNotDisplayed, s.keepAlivePresents];

    if (self.statsOverlay != nil && !self.statsOverlay.hidden) {
        self.statsOverlay.stringValue = text;
    }

    // Also log every few seconds, so latency can be checked with `log stream`
    if (self.statsTicks++ % 5 == 0) {
        Log(LOG_I, @"Stats: %@", [text stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]);
    }
}


#pragma mark - Helpers

- (void)enableMenuItems:(BOOL)enable {
    NSMenu *appMenu = [[NSApplication sharedApplication].mainMenu itemWithTag:1000].submenu;
    appMenu.autoenablesItems = enable;
    [self itemWithMenu:appMenu andAction:@selector(terminate:)].enabled = enable;
}

- (void)captureMouse {
    CGAssociateMouseAndMouseCursorPosition(NO);
    if (self.cursorHiddenCounter == 0) {
        [NSCursor hide];
        self.cursorHiddenCounter ++;
    }
    
    CGRect rectInWindow = [self.view convertRect:self.view.bounds toView:nil];
    CGRect rectInScreen = [self.view.window convertRectToScreen:rectInWindow];
    CGFloat screenHeight = self.view.window.screen.frame.size.height;
    CGPoint cursorPoint = CGPointMake(CGRectGetMidX(rectInScreen), screenHeight - CGRectGetMidY(rectInScreen));
    CGWarpMouseCursorPosition(cursorPoint);
    
    [self enableMenuItems:NO];
    
    [self disallowDisplaySleep];
    
    self.hidSupport.shouldSendInputEvents = YES;
    self.controllerSupport.shouldSendInputEvents = YES;
    self.view.window.acceptsMouseMovedEvents = YES;
}

- (void)uncaptureMouse {
    CGAssociateMouseAndMouseCursorPosition(YES);
    if (self.cursorHiddenCounter != 0) {
        [NSCursor unhide];
        self.cursorHiddenCounter --;
    }
    
    [self enableMenuItems:YES];
    
    [self allowDisplaySleep];
    
    self.hidSupport.shouldSendInputEvents = NO;
    self.controllerSupport.shouldSendInputEvents = NO;
    self.view.window.acceptsMouseMovedEvents = NO;
}

- (BOOL)isWindowInCurrentSpace {
    BOOL found = NO;
    CFArrayRef windowsInSpace = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for (NSDictionary *thisWindow in (__bridge NSArray *)windowsInSpace) {
        NSNumber *thisWindowNumber = (NSNumber *)thisWindow[(__bridge NSString *)kCGWindowNumber];
        if (self.view.window.windowNumber == thisWindowNumber.integerValue) {
            found = YES;
            break;
        }
    }
    if (windowsInSpace != NULL) {
        CFRelease(windowsInSpace);
    }
    return found;
}

- (BOOL)isWindowFullscreen {
    return [self.view.window styleMask] & NSWindowStyleMaskFullScreen;
}

- (BOOL)isOurWindowTheWindowInNotiifcation:(NSNotification *)note {
    return ((NSWindow *)note.object) == self.view.window;
}

- (NSMenuItem *)itemWithMenu:(NSMenu *)menu andAction:(SEL)action {
    return [menu itemAtIndex:[menu indexOfItemWithTarget:nil andAction:action]];
}


- (void)disallowDisplaySleep {
    if (self.powerAssertionID != 0) {
        return;
    }
    
    CFStringRef reasonForActivity= CFSTR("Artemis streaming");
    
    IOPMAssertionID assertionID;
    IOReturn success = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep, kIOPMAssertionLevelOn, reasonForActivity, &assertionID);
    
    if (success == kIOReturnSuccess) {
        self.powerAssertionID = assertionID;
    } else {
        self.powerAssertionID = 0;
    }
}

- (void)allowDisplaySleep {
    if (self.powerAssertionID != 0) {
        IOPMAssertionRelease(self.powerAssertionID);
        self.powerAssertionID = 0;
    }
}

- (void)closeWindowFromMainQueueWithMessage:(NSString *)message {
    [self.hidSupport releaseAllModifierKeys];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.apolloSession streamWillStop];
        [self stopStatsTimer];
        [self endStreamActivity];
        [self uncaptureMouse];

        [self.delegate appDidQuit:self.app];
        if (message != nil) {
            [AlertPresenter displayAlert:NSAlertStyleWarning title:@"Connection Failed" message:message window:self.view.window completionHandler:^(NSModalResponse returnCode) {
                [self.view.window close];
            }];
        } else {
            [self.view.window close];
        }
    });
}

- (StreamViewMac *)streamView {
    return (StreamViewMac *)self.view;
}


#pragma mark - Streaming Operations

- (void)prepareForStreaming {
    StreamConfiguration *streamConfig = [[StreamConfiguration alloc] init];
    
    streamConfig.host = self.app.host.activeAddress;
    streamConfig.hostUUID = self.app.host.uuid;
    streamConfig.appID = self.app.id;
    streamConfig.appUUID = self.app.uuid;
    streamConfig.appName = self.app.name;
    streamConfig.useVirtualDisplay = self.useVirtualDisplay;
    streamConfig.resolutionScaleFactor = (int)[SettingsClass resolutionScaleFor:self.app.host.uuid];
    streamConfig.serverCert = self.app.host.serverCert;
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];
    
    streamConfig.width = [self.class getResolution].width;
    streamConfig.height = [self.class getResolution].height;

    streamConfig.frameRate = [streamSettings.framerate intValue];
    streamConfig.frameRateMultiplier = (int)[SettingsClass frameRateMultiplierFor:self.app.host.uuid];
    streamConfig.bitRate = [streamSettings.bitrate intValue];
    streamConfig.optimizeGameSettings = streamSettings.optimizeGames;
    streamConfig.playAudioOnPC = streamSettings.playAudioOnPC;
    streamConfig.supportedVideoFormats = [self.class supportedVideoFormatsForCodec:[SettingsClass videoCodecFor:self.app.host.uuid]
                                                                              hdr:streamSettings.enableHdr];
    streamConfig.vsync = [SettingsClass vsyncFor:self.app.host.uuid];

    streamConfig.multiController = streamSettings.multiController;
    streamConfig.gamepadMask = self.useSystemControllerDriver ? [ControllerSupport getConnectedGamepadMask:streamConfig] : 1;
    
    streamConfig.audioConfiguration = AUDIO_CONFIGURATION_STEREO;

    if (self.useSystemControllerDriver) {
        if (@available(iOS 13, tvOS 13, macOS 10.15, *)) {
            self.controllerSupport = [[ControllerSupport alloc] initWithConfig:streamConfig presenceDelegate:self];
        }
    }
    self.hidSupport = [[HIDSupport alloc] init:self.app.host];
    self.apolloSession = [[ApolloSession alloc] initWithHost:self.app.host];

    self.streamMan =[[StreamManager alloc] initWithConfig:streamConfig renderView:self.view connectionCallbacks:self];
    NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
    [opQueue addOperation:self.streamMan];
}


#pragma mark - Codecs

// codec is an index into SettingsModel.videoCodecs: H.264, H.265, AV1, Automatic.
// H.264 is always offered as a fallback. When several codecs are offered,
// moonlight-common-c picks AV1 over HEVC over H.264 if the host supports them.
+ (int)supportedVideoFormatsForCodec:(NSInteger)codec hdr:(BOOL)hdr {
    BOOL automatic = codec == 3;
    int formats = VIDEO_FORMAT_H264;

    if ((codec == 1 || automatic) && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
        formats |= VIDEO_FORMAT_H265;
        if (hdr) {
            formats |= VIDEO_FORMAT_H265_MAIN10;
        }
    }
    // Apple Silicon decodes AV1 in hardware from M3 onwards
    if ((codec == 2 || automatic) && VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) {
        formats |= VIDEO_FORMAT_AV1_MAIN8;
        if (hdr) {
            formats |= VIDEO_FORMAT_AV1_MAIN10;
        }
    }
    return formats;
}


#pragma mark - Resolution

+ (struct Resolution)getResolution {
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];

    struct Resolution resolution;
    
    resolution.width = [streamSettings.width intValue];
    resolution.height = [streamSettings.height intValue];

    return resolution;
}


#pragma mark - ConnectionCallbacks

- (void)stageStarting:(const char *)stageName {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *lowerCase = [NSString stringWithFormat:@"%s in progress...", stageName];
        NSString *titleCase = [[[lowerCase substringToIndex:1] uppercaseString] stringByAppendingString:[lowerCase substringFromIndex:1]];
        self.streamView.statusText = titleCase;
    });
}

- (void)stageComplete:(const char *)stageName {
}

- (void)connectionStarted {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.streamView.statusText = nil;

        [self.apolloSession streamStarted];
        [self installApolloMenu];
        [self startStatsTimer];

        // Keep macOS from coalescing timers, napping the app or dimming the display
        // while streaming
        if (self.streamActivity == nil) {
            self.streamActivity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityLatencyCritical | NSActivityUserInitiated | NSActivityIdleDisplaySleepDisabled
                                                                               reason:@"Streaming"];
        }

        if ([SettingsClass autoFullscreenFor:self.app.host.uuid]) {
            if (!(self.view.window.styleMask & NSWindowStyleMaskFullScreen)) {
                [self.view.window toggleFullScreen:self];
            }
        } else {
            [self captureMouse];
        }
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %ld", errorCode);
    [self closeWindowFromMainQueueWithMessage:nil];
}

- (void)stageFailed:(const char *)stageName withError:(int)errorCode {
    Log(LOG_I, @"Stage %s failed: %ld", stageName, errorCode);
    [self closeWindowFromMainQueueWithMessage:[NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode]];
}

- (void)launchFailed:(NSString *)message {
    [self closeWindowFromMainQueueWithMessage:message];
}

- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    if ([SettingsClass rumbleFor:self.app.host.uuid]) {
        if (self.hidSupport.shouldSendInputEvents) {
            if (self.controllerSupport != nil) {
                [self.controllerSupport rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
            } else {
                [self.hidSupport rumbleLowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
            }
        }
    }
}

- (void)connectionStatusUpdate:(int)status {
}


#pragma mark - InputPresenceDelegate

- (void)gamepadPresenceChanged {
}

- (void)mousePresenceChanged {
}

@end
