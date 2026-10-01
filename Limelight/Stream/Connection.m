//
//  Connection.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Connection.h"
#import "AudioRenderer.h"
#import "Utils.h"
#import "NetworkRoute.h"

#import "Moonlight-Swift.h"

#import <AudioUnit/AudioUnit.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include "Limelight.h"
#include "opus_multistream.h"

@implementation Connection {
    SERVER_INFORMATION _serverInfo;
    STREAM_CONFIGURATION _streamConfig;
    CONNECTION_LISTENER_CALLBACKS _clCallbacks;
    DECODER_RENDERER_CALLBACKS _drCallbacks;
    AUDIO_RENDERER_CALLBACKS _arCallbacks;
    char _hostString[256];
    char _appVersionString[32];
    char _gfeVersionString[32];
    char _rtspSessionUrl[128];
}

static NSLock* initLock;
static id<ConnectionCallbacks> _callbacks;
static NSString *hostAddress;
static VideoDecoderRenderer* renderer;

int DrDecoderSetup(int videoFormat, int width, int height, int redrawRate, void* context, int drFlags)
{
    [renderer setupWithVideoFormat:videoFormat width:width height:height frameRate:redrawRate];
    return 0;
}

void DrStart(void)
{
    [renderer start];
}

void DrStop(void)
{
    // With direct submit, frames can still arrive until moonlight-common-c joins its
    // receive thread, so the renderer itself is released in DrCleanup()
    [renderer stop];

    _callbacks = nil;
}

void DrCleanup(void)
{
    [renderer cleanup];
    renderer = nil;
}

// Called on moonlight-common-c's receive thread the moment a frame is reassembled
int DrSubmitDecodeUnit(PDECODE_UNIT decodeUnit)
{
    return [renderer submitDecodeUnit:decodeUnit];
}

int ArInit(int audioConfiguration, POPUS_MULTISTREAM_CONFIGURATION opusConfig, void* context, int flags)
{
    return ArtemisAudioInit(opusConfig);
}

void ArCleanup(void)
{
    ArtemisAudioCleanup();
}

void ArDecodeAndPlaySample(char* sampleData, int sampleLength)
{
    ArtemisAudioDecodeAndPlay(sampleData, sampleLength);
}

- (void)updateVolume {
    if (hostAddress != nil) {
        NSString *uuid = [SettingsClass getHostUUIDFrom:hostAddress];
        ArtemisAudioSetVolume([SettingsClass volumeLevelFor:uuid]);
    }
}

void ClStageStarting(int stage)
{
    [_callbacks stageStarting:LiGetStageName(stage)];
}

void ClStageComplete(int stage)
{
    [_callbacks stageComplete:LiGetStageName(stage)];
}

void ClStageFailed(int stage, int errorCode)
{
    [_callbacks stageFailed:LiGetStageName(stage) withError:errorCode];
}

void ClConnectionStarted(void)
{
    [_callbacks connectionStarted];
}

void ClConnectionTerminated(int errorCode)
{
    [_callbacks connectionTerminated: errorCode];
}

void ClLogMessage(const char* format, ...)
{
    // Route moonlight-common-c's messages (codec negotiation, RFI, packet loss) into the unified log
    va_list va;
    va_start(va, format);
    NSString* message = [[NSString alloc] initWithFormat:[NSString stringWithUTF8String:format] arguments:va];
    va_end(va);
    LogTag(LOG_I, @"common-c", @"%@", [message stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]);
}

void ClRumble(unsigned short controllerNumber, unsigned short lowFreqMotor, unsigned short highFreqMotor)
{
    [_callbacks rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

void ClConnectionStatusUpdate(int status)
{
    [_callbacks connectionStatusUpdate:status];
}

void ClSetHdrMode(bool enabled)
{
    [renderer setHdrMode:enabled];
}

-(void) terminate
{
    // Interrupt any action blocking LiStartConnection(). This is
    // thread-safe and done outside initLock on purpose, since we
    // won't be able to acquire it if LiStartConnection is in
    // progress.
    LiInterruptConnection();
    
    // We dispatch this async to get out because this can be invoked
    // on a thread inside common and we don't want to deadlock. It also avoids
    // blocking on the caller's thread waiting to acquire initLock.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [initLock lock];
        LiStopConnection();
        [initLock unlock];
    });
}

-(id) initWithConfig:(StreamConfiguration*)config renderer:(VideoDecoderRenderer*)myRenderer connectionCallbacks:(id<ConnectionCallbacks>)callbacks
{
    self = [super init];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateVolume) name:@"volumeSettingChanged" object:nil];
    
    // Use a lock to ensure that only one thread is initializing
    // or deinitializing a connection at a time.
    if (initLock == nil) {
        initLock = [[NSLock alloc] init];
    }
    
    hostAddress = config.host;
    [self updateVolume];
    
    strncpy(_hostString,
            [config.host cStringUsingEncoding:NSUTF8StringEncoding],
            sizeof(_hostString) - 1);
    strncpy(_appVersionString,
            [config.appVersion cStringUsingEncoding:NSUTF8StringEncoding],
            sizeof(_appVersionString) - 1);
    if (config.gfeVersion != nil) {
        strncpy(_gfeVersionString,
                [config.gfeVersion cStringUsingEncoding:NSUTF8StringEncoding],
                sizeof(_gfeVersionString) - 1);
    }
    if (config.rtspSessionUrl != nil) {
        strncpy(_rtspSessionUrl,
                [config.rtspSessionUrl cStringUsingEncoding:NSUTF8StringEncoding],
                sizeof(_rtspSessionUrl) - 1);
    }

    LiInitializeServerInformation(&_serverInfo);
    _serverInfo.address = _hostString;
    _serverInfo.serverInfoAppVersion = _appVersionString;
    if (config.gfeVersion != nil) {
        _serverInfo.serverInfoGfeVersion = _gfeVersionString;
    }
    if (config.rtspSessionUrl != nil) {
        _serverInfo.rtspSessionUrl = _rtspSessionUrl;
    }
    _serverInfo.serverCodecModeSupport = config.serverCodecModeSupport;

    renderer = myRenderer;
    _callbacks = callbacks;

    LiInitializeStreamConfiguration(&_streamConfig);
    _streamConfig.width = config.width;
    _streamConfig.height = config.height;
    _streamConfig.fps = config.frameRate * MAX(1, config.frameRateMultiplier);
    _streamConfig.bitrate = config.bitRate;
    _streamConfig.supportedVideoFormats = config.supportedVideoFormats;
    _streamConfig.audioConfiguration = config.audioConfiguration;
    _streamConfig.colorSpace = COLORSPACE_REC_709;
    _streamConfig.colorRange = COLOR_RANGE_LIMITED;

    // Every Apple Silicon Mac has ARMv8 crypto instructions, so encrypting
    // the video and audio streams costs next to nothing.
    _streamConfig.encryptionFlags = ENCFLG_ALL;

    // Decide by the checked route rather than "is any VPN up", which Tailscale's
    // utun always is, and which made every LAN stream use small remote packets
    switch (config.networkRoute.kind) {
        case ArtemisRouteLAN:
        case ArtemisRouteLoopback:
            _streamConfig.streamingRemotely = STREAM_CFG_LOCAL;
            _streamConfig.packetSize = 1392;
            break;
        case ArtemisRouteTailscale:
        case ArtemisRouteTailscaleSubnet:
        default:
            // Tailscale's tunnel MTU is 1280, so keep packets from fragmenting.
            // The internet (with the policy off) gets the same cap.
            _streamConfig.streamingRemotely = STREAM_CFG_REMOTE;
            _streamConfig.packetSize = 1024;
            break;
    }

    memcpy(_streamConfig.remoteInputAesKey, [config.riKey bytes], [config.riKey length]);
    memset(_streamConfig.remoteInputAesIv, 0, 16);
    int riKeyId = htonl(config.riKeyId);
    memcpy(_streamConfig.remoteInputAesIv, &riKeyId, sizeof(riKeyId));

    LiInitializeVideoCallbacks(&_drCallbacks);
    _drCallbacks.setup = DrDecoderSetup;
    _drCallbacks.start = DrStart;
    _drCallbacks.stop = DrStop;
    _drCallbacks.cleanup = DrCleanup;
    _drCallbacks.submitDecodeUnit = DrSubmitDecodeUnit;

    // Lowest latency: frames go straight from the network thread to VideoToolbox's async
    // decoder, with no queue in between. Reference frame invalidation lets the host
    // repair packet loss (common on Wi-Fi) without a full keyframe for HEVC and AV1.
    _drCallbacks.capabilities = CAPABILITY_DIRECT_SUBMIT |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1;

    LiInitializeAudioCallbacks(&_arCallbacks);
    _arCallbacks.init = ArInit;
    _arCallbacks.cleanup = ArCleanup;
    _arCallbacks.decodeAndPlaySample = ArDecodeAndPlaySample;
    _arCallbacks.capabilities = CAPABILITY_DIRECT_SUBMIT |
                                CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION;

    LiInitializeConnectionCallbacks(&_clCallbacks);
    _clCallbacks.stageStarting = ClStageStarting;
    _clCallbacks.stageComplete = ClStageComplete;
    _clCallbacks.stageFailed = ClStageFailed;
    _clCallbacks.connectionStarted = ClConnectionStarted;
    _clCallbacks.connectionTerminated = ClConnectionTerminated;
    _clCallbacks.logMessage = ClLogMessage;
    _clCallbacks.rumble = ClRumble;
    _clCallbacks.connectionStatusUpdate = ClConnectionStatusUpdate;
    _clCallbacks.setHdrMode = ClSetHdrMode;

    return self;
}

-(void) main
{
    [initLock lock];
    LiStartConnection(&_serverInfo,
                      &_streamConfig,
                      &_clCallbacks,
                      &_drCallbacks,
                      &_arCallbacks,
                      NULL, 0,
                      NULL, 0);
    [initLock unlock];
}

@end
