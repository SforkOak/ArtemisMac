//
//  StreamManager.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamManager.h"
#import "CryptoManager.h"
#import "HttpManager.h"
#import "Utils.h"

#import "StreamView.h"
#import "ServerInfoResponse.h"
#import "HttpResponse.h"
#import "HttpRequest.h"
#import "IdManager.h"

@implementation StreamManager {
    StreamConfiguration* _config;

    OSView* _renderView;
    id<ConnectionCallbacks> _callbacks;
    Connection* _connection;
    VideoDecoderRenderer* _renderer;
}

- (id) initWithConfig:(StreamConfiguration*)config renderView:(OSView*)view connectionCallbacks:(id<ConnectionCallbacks>)callbacks {
    self = [super init];
    _config = config;
    _renderView = view;
    _callbacks = callbacks;
    _config.riKey = [Utils randomBytes:16];
    _config.riKeyId = arc4random();
    return self;
}

- (void)main {
    [CryptoManager generateKeyPairUsingSSL];
    NSString* uniqueId = [IdManager getUniqueId];
    
    HttpManager* hMan = [[HttpManager alloc] initWithHost:_config.host
                                                 uniqueId:uniqueId
                                                     serverCert:_config.serverCert];
    
    ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:false]
                                       fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
    NSString* pairStatus = [serverInfoResp getStringTag:@"PairStatus"];
    NSString* appversion = [serverInfoResp getStringTag:@"appversion"];
    NSString* gfeVersion = [serverInfoResp getStringTag:@"GfeVersion"];
    NSString* serverState = [serverInfoResp getStringTag:@"state"];
    NSString* codecSupport = [serverInfoResp getStringTag:@"ServerCodecModeSupport"];
    if (![serverInfoResp isStatusOk]) {
        [_callbacks launchFailed:serverInfoResp.statusMessage];
        return;
    }
    else if (pairStatus == NULL || appversion == NULL || serverState == NULL) {
        [_callbacks launchFailed:@"Failed to connect to PC"];
        return;
    }
    
    if (![pairStatus isEqualToString:@"1"]) {
        // Not paired
        [_callbacks launchFailed:@"Device not paired to PC"];
        return;
    }
    
    // Populate the config's version fields from serverinfo. The launch
    // request needs appVersion to tell GFE and Sunshine apart.
    _config.appVersion = appversion;
    _config.gfeVersion = gfeVersion;
    _config.serverCodecModeSupport = [codecSupport intValue];

    // resumeApp and launchApp handle calling launchFailed
    NSString* sessionUrl;
    if ([serverState hasSuffix:@"_SERVER_BUSY"]) {
        // App already running, resume it
        if (![self resumeApp:hMan receiveSessionUrl:&sessionUrl]) {
            return;
        }
    } else {
        // Start app
        if (![self launchApp:hMan receiveSessionUrl:&sessionUrl]) {
            return;
        }
    }

    // Populate RTSP session URL from launch/resume response
    _config.rtspSessionUrl = sessionUrl;

    if (![serverState hasSuffix:@"_SERVER_BUSY"] && _config.hostUUID != nil) {
        [StreamManager recordLaunchedSession:_config];
    }

#if TARGET_OS_IPHONE
    // Set mouse delta factors from the screen resolution and stream size
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    CGRect screenBounds = [[UIScreen mainScreen] bounds];
    CGSize screenSize = CGSizeMake(screenBounds.size.width * screenScale, screenBounds.size.height * screenScale);
    [((StreamView*)_renderView) setMouseDeltaFactors:_config.width / screenSize.width
                                                   y:_config.height / screenSize.height];
#endif

    // Initializing the renderer must be done on the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        VideoDecoderRenderer* renderer = [[VideoDecoderRenderer alloc] initWithView:self->_renderView vsync:self->_config.vsync];
        if (renderer == nil) {
            [self->_callbacks launchFailed:@"Couldn't start the Metal video renderer."];
            return;
        }
        self->_videoStats = renderer.stats;
        self->_renderer = renderer;
        self->_connection = [[Connection alloc] initWithConfig:self->_config renderer:renderer connectionCallbacks:self->_callbacks];
        NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
        [opQueue addOperation:self->_connection];
    });
}

static NSString *const kLaunchedSessionsKey = @"launchedSessions";

+ (void) recordLaunchedSession:(StreamConfiguration*)config {
    NSMutableDictionary *sessions = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kLaunchedSessionsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    sessions[config.hostUUID] = @{
        @"width": @(config.width),
        @"height": @(config.height),
        @"fps": @(config.frameRate),
        @"virtualDisplay": @(config.useVirtualDisplay),
        @"appId": config.appID ?: @"",
    };
    [NSUserDefaults.standardUserDefaults setObject:sessions forKey:kLaunchedSessionsKey];
}

+ (NSDictionary *) launchedSessionForHost:(NSString *)hostUUID {
    return [NSUserDefaults.standardUserDefaults dictionaryForKey:kLaunchedSessionsKey][hostUUID];
}

+ (void) forgetLaunchedSessionForHost:(NSString *)hostUUID {
    NSMutableDictionary *sessions = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kLaunchedSessionsKey] mutableCopy];
    if (sessions[hostUUID] != nil) {
        [sessions removeObjectForKey:hostUUID];
        [NSUserDefaults.standardUserDefaults setObject:sessions forKey:kLaunchedSessionsKey];
    }
}

- (void) stopStream
{
    [_connection terminate];
    _callbacks = nil;
}

- (void) setStatsOverlayText:(NSString *)text
{
    [_renderer setOverlayText:text];
}

- (BOOL) launchApp:(HttpManager*)hMan receiveSessionUrl:(NSString**)sessionUrl {
    HttpResponse* launchResp = [[HttpResponse alloc] init];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:launchResp withUrlRequest:[hMan newLaunchRequest:_config]]];
    NSString *gameSession = [launchResp getStringTag:@"gamesession"];
    *sessionUrl = [launchResp getStringTag:@"sessionUrl0"];
    if (launchResp.statusCode == 403) {
        [_callbacks launchFailed:@"The host denied permission to launch apps from this Mac. In Apollo's web UI, give this client the Launch Apps permission."];
        return FALSE;
    } else if (![launchResp isStatusOk]) {
        [_callbacks launchFailed:launchResp.statusMessage];
        Log(LOG_E, @"Failed Launch Response: %@", launchResp.statusMessage);
        return FALSE;
    } else if (gameSession == NULL || [gameSession isEqualToString:@"0"]) {
        [_callbacks launchFailed:@"Failed to launch app"];
        Log(LOG_E, @"Failed to parse game session");
        return FALSE;
    }
    
    return TRUE;
}

- (BOOL) resumeApp:(HttpManager*)hMan receiveSessionUrl:(NSString**)sessionUrl {
    HttpResponse* resumeResp = [[HttpResponse alloc] init];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:resumeResp withUrlRequest:[hMan newResumeRequest:_config]]];
    NSString* resume = [resumeResp getStringTag:@"resume"];
    *sessionUrl = [resumeResp getStringTag:@"sessionUrl0"];
    if (resumeResp.statusCode == 403) {
        [_callbacks launchFailed:@"The host denied permission to view this stream from this Mac. In Apollo's web UI, give this client the View Streams permission."];
        return FALSE;
    } else if (![resumeResp isStatusOk]) {
        [_callbacks launchFailed:resumeResp.statusMessage];
        Log(LOG_E, @"Failed Resume Response: %@", resumeResp.statusMessage);
        return FALSE;
    } else if (resume == NULL || [resume isEqualToString:@"0"]) {
        [_callbacks launchFailed:@"Failed to resume app"];
        Log(LOG_E, @"Failed to parse resume response");
        return FALSE;
    }
    
    return TRUE;
}

@end
