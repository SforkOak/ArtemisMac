//
//  DeepLinkRouter.h
//  Artemis
//
//  Handles the art:// links Apollo's web UI produces:
//    art://HOST:PORT?pin=1234&passphrase=...&name=...       pair with OTP
//    art://launch?host_uuid=...&app_uuid=...&app_name=...   launch an app
//  The link is held until the host list is ready to act on it, so links that
//  launch Artemis work too.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const ArtemisDeepLinkNotification;

@interface DeepLinkRouter : NSObject

+ (instancetype)shared;

// Called by the app delegate. Posts ArtemisDeepLinkNotification on the main queue.
- (void)handleURL:(NSURL *)url;

// Returns the waiting link, if any, and clears it
- (nullable NSURL *)takePendingURL;

@end

NS_ASSUME_NONNULL_END
