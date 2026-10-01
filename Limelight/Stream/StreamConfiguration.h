//
//  StreamConfiguration.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@interface StreamConfiguration : NSObject

@property NSString* host;
@property NSString* appVersion;
@property NSString* gfeVersion;
@property NSString* appID;
@property NSString* appUUID;
@property NSString* appName;
// Apollo: stream to a virtual display, and scale the virtual display's
// size by this percentage (20-200; 100 = native).
@property BOOL useVirtualDisplay;
@property int resolutionScaleFactor;
@property NSString* rtspSessionUrl;
@property int serverCodecModeSupport;
@property int width;
@property int height;
@property int frameRate;
@property int bitRate;
@property int riKeyId;
@property BOOL streamingRemotely;
@property NSData* riKey;
@property int gamepadMask;
@property BOOL optimizeGameSettings;
@property BOOL playAudioOnPC;
@property int audioConfiguration;
@property int supportedVideoFormats;
@property BOOL multiController;
// NO: show each frame the moment it's decoded (lowest latency, may tear).
// YES: present on the display's refresh (smoother).
@property BOOL vsync;
@property NSData* serverCert;

@end
