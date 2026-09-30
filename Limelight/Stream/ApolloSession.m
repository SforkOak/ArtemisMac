//
//  ApolloSession.m
//  Artemis
//

#import "ApolloSession.h"
#import "HttpManager.h"
#import "IdManager.h"

#import "Moonlight-Swift.h"

#import <AppKit/AppKit.h>

#include "Limelight.h"

// Artemis Android uses the same interval: frequent enough that the Wi-Fi radio
// never drops into power save between video frames.
static const uint64_t kKeepaliveIntervalNs = 20 * NSEC_PER_MSEC;

@implementation ApolloSession {
    TemporaryHost *_host;
    BOOL _keepaliveEnabled;
    BOOL _clipboardSyncEnabled;
    BOOL _streaming;

    dispatch_queue_t _keepaliveQueue;
    dispatch_source_t _keepaliveTimer;
    dispatch_queue_t _clipboardQueue;

    // Pasteboard changeCount after our last sync in either direction, so text we just
    // received isn't sent straight back and unchanged text isn't sent again
    NSInteger _lastSyncedChangeCount;
}

- (instancetype)initWithHost:(TemporaryHost *)host {
    self = [super init];
    if (self) {
        _host = host;
        _keepaliveEnabled = host.isApollo && [SettingsClass wifiKeepaliveFor:host.uuid];
        _clipboardSyncEnabled = host.isApollo && [SettingsClass clipboardSyncFor:host.uuid];
        _keepaliveQueue = dispatch_queue_create("com.sforkoak.artemis.keepalive",
                                                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
        _clipboardQueue = dispatch_queue_create("com.sforkoak.artemis.clipboard", DISPATCH_QUEUE_SERIAL);
        _lastSyncedChangeCount = -1;
    }
    return self;
}

- (void)dealloc {
    [self stopKeepalive];
}


#pragma mark - Session lifecycle

- (void)streamStarted {
    NSAssert(NSThread.isMainThread, @"ApolloSession must be driven from the main thread");
    _streaming = YES;

    if (_keepaliveEnabled) {
        [self startKeepalive];
    }
    if (_clipboardSyncEnabled) {
        [self sendClipboardIfChanged];
    }
}

- (void)streamWillStop {
    NSAssert(NSThread.isMainThread, @"ApolloSession must be driven from the main thread");
    [self stopKeepalive];

    // Best effort: grab the host's clipboard while Apollo still considers us connected
    if (_streaming && _clipboardSyncEnabled) {
        [self fetchClipboardWithCompletion:nil];
    }
    _streaming = NO;
}


#pragma mark - Keepalive

- (void)startKeepalive {
    if (_keepaliveTimer != nil) {
        return;
    }

    _keepaliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, _keepaliveQueue);
    dispatch_source_set_timer(_keepaliveTimer, dispatch_time(DISPATCH_TIME_NOW, kKeepaliveIntervalNs), kKeepaliveIntervalNs, 2 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_keepaliveTimer, ^{
        LiSendEmptyPayload();
    });
    dispatch_resume(_keepaliveTimer);
}

- (void)stopKeepalive {
    if (_keepaliveTimer == nil) {
        return;
    }

    dispatch_source_cancel(_keepaliveTimer);
    _keepaliveTimer = nil;

    // Wait out a tick that may already be running, so nothing is sent after we return
    dispatch_sync(_keepaliveQueue, ^{});
}


#pragma mark - Clipboard

- (void)streamWindowDidBecomeKey {
    if (_streaming && _clipboardSyncEnabled) {
        [self sendClipboardIfChanged];
    }
}

- (void)streamWindowDidResignKey {
    if (_streaming && _clipboardSyncEnabled) {
        [self fetchClipboardWithCompletion:nil];
    }
}

- (void)sendClipboardIfChanged {
    if (NSPasteboard.generalPasteboard.changeCount != _lastSyncedChangeCount) {
        [self sendClipboardWithCompletion:nil];
    }
}

- (void)sendClipboardWithCompletion:(void (^)(NSString *))completion {
    NSAssert(NSThread.isMainThread, @"ApolloSession must be driven from the main thread");
    if (![self hasPermission:ApolloPermissionClipboardSet]) {
        [self complete:completion error:@"Apollo hasn't given this Mac the Clipboard Set permission."];
        return;
    }

    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    NSString *text = [pasteboard stringForType:NSPasteboardTypeString];
    NSInteger changeCount = pasteboard.changeCount;
    if (text.length == 0) {
        _lastSyncedChangeCount = changeCount;
        [self complete:completion error:@"The clipboard doesn't contain any text."];
        return;
    }

    HttpManager *hMan = [self newHttpManager];
    dispatch_async(_clipboardQueue, ^{
        NSInteger status = 0;
        [hMan executeRawRequestSynchronously:[hMan newSetClipboardRequest:text] httpStatus:&status];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status == 200) {
                self->_lastSyncedChangeCount = changeCount;
                [self complete:completion error:nil];
            } else {
                [self complete:completion error:[self messageForClipboardStatus:status]];
            }
        });
    });
}

- (void)fetchClipboardWithCompletion:(void (^)(NSString *))completion {
    NSAssert(NSThread.isMainThread, @"ApolloSession must be driven from the main thread");
    if (![self hasPermission:ApolloPermissionClipboardRead]) {
        [self complete:completion error:@"Apollo hasn't given this Mac the Clipboard Read permission."];
        return;
    }

    HttpManager *hMan = [self newHttpManager];
    dispatch_async(_clipboardQueue, ^{
        NSInteger status = 0;
        NSData *body = [hMan executeRawRequestSynchronously:[hMan newGetClipboardRequest] httpStatus:&status];
        NSString *text = (status == 200 && body != nil) ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != 200) {
                [self complete:completion error:[self messageForClipboardStatus:status]];
                return;
            }

            if (text.length > 0) {
                NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
                if (![[pasteboard stringForType:NSPasteboardTypeString] isEqualToString:text]) {
                    [pasteboard clearContents];
                    [pasteboard setString:text forType:NSPasteboardTypeString];
                }
                self->_lastSyncedChangeCount = pasteboard.changeCount;
            }
            [self complete:completion error:nil];
        });
    });
}

- (NSString *)messageForClipboardStatus:(NSInteger)status {
    switch (status) {
        case 401:
            return @"Apollo denied clipboard access for this Mac. Check its permissions in Apollo's web UI.";
        case 403:
            return @"Apollo only allows clipboard sync while this Mac is streaming.";
        case 404:
            return @"This host doesn't support clipboard sync. It requires Apollo.";
        default:
            return [NSString stringWithFormat:@"Clipboard sync failed (error %ld).", (long)status];
    }
}


#pragma mark - Server commands

- (NSArray<NSString *> *)serverCommands {
    return _host.serverCommands;
}

- (BOOL)executeServerCommandAtIndex:(NSUInteger)index {
    if (index >= _host.serverCommands.count || index > UINT8_MAX) {
        return NO;
    }
    return LiSendExecServerCmd((uint8_t)index) == 0;
}


#pragma mark - Helpers

- (BOOL)hasPermission:(ApolloPermission)permission {
    return _host.permission >= 0 && (((uint32_t)_host.permission) & permission) != 0;
}

- (HttpManager *)newHttpManager {
    return [[HttpManager alloc] initWithHost:_host.activeAddress uniqueId:[IdManager getUniqueId] serverCert:_host.serverCert];
}

- (void)complete:(void (^)(NSString *))completion error:(NSString *)error {
    if (error != nil) {
        Log(LOG_W, @"Apollo: %@", error);
    }
    if (completion != nil) {
        completion(error);
    }
}

@end
