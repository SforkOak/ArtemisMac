//
//  PairManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "HttpManager.h"

@protocol PairCallback <NSObject>

- (void) startPairing:(NSString*)PIN;
- (void) pairSuccessful:(NSData*)serverCert;
- (void) pairFailed:(NSString*)message;
- (void) alreadyPaired;

@end

@interface PairManager : NSOperation
- (id) initWithManager:(HttpManager*)httpManager clientCert:(NSData*)clientCert callback:(id<PairCallback>)callback;
// Apollo OTP pairing: pair using the PIN and passphrase generated in Apollo's web UI,
// so nothing has to be typed on the host.
- (id) initWithManager:(HttpManager*)httpManager clientCert:(NSData*)clientCert otpPin:(NSString*)pin passphrase:(NSString*)passphrase callback:(id<PairCallback>)callback;
@end
