//
//  HttpManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/16/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "HttpResponse.h"
#import "HttpRequest.h"
#import "StreamConfiguration.h"

@interface HttpManager : NSObject <NSURLSessionDelegate>

- (id) initWithHost:(NSString*) host uniqueId:(NSString*) uniqueId serverCert:(NSData*) serverCert;
- (void) setServerCert:(NSData*) serverCert;
// otpAuth is Apollo's OTP hash, or nil for regular PIN pairing
- (NSURLRequest*) newPairRequest:(NSData*)salt clientCert:(NSData*)clientCert otpAuth:(NSString*)otpAuth;
- (NSURLRequest*) newUnpairRequest;
- (NSURLRequest*) newChallengeRequest:(NSData*)challenge;
- (NSURLRequest*) newChallengeRespRequest:(NSData*)challengeResp;
- (NSURLRequest*) newClientSecretRespRequest:(NSString*)clientPairSecret;
- (NSURLRequest*) newPairChallenge;
- (NSURLRequest*) newAppListRequest;
- (NSURLRequest*) newServerInfoRequest:(bool)fastFail;
- (NSURLRequest*) newHttpServerInfoRequest:(bool)fastFail;
- (NSURLRequest*) newHttpServerInfoRequest;
- (NSURLRequest*) newLaunchRequest:(StreamConfiguration*)config;
- (NSURLRequest*) newResumeRequest:(StreamConfiguration*)config;
- (NSURLRequest*) newQuitAppRequest;
- (NSURLRequest*) newAppAssetRequestWithAppId:(NSString*)appId;
// Apollo text clipboard. Only allowed while this client is streaming.
- (NSURLRequest*) newGetClipboardRequest;
- (NSURLRequest*) newSetClipboardRequest:(NSString*)text;
- (void) executeRequestSynchronously:(HttpRequest*)request;
// For responses that aren't XML: returns the body and sets *httpStatus to the HTTP
// status code (or the NSURLError code if the request failed).
- (NSData*) executeRawRequestSynchronously:(NSURLRequest*)request httpStatus:(NSInteger*)httpStatus;

@end


