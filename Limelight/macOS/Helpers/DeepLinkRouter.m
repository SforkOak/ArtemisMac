//
//  DeepLinkRouter.m
//  Artemis
//

#import "DeepLinkRouter.h"

NSNotificationName const ArtemisDeepLinkNotification = @"ArtemisDeepLinkNotification";

@implementation DeepLinkRouter {
    NSURL *_pendingURL;
}

+ (instancetype)shared {
    static DeepLinkRouter *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[DeepLinkRouter alloc] init];
    });
    return shared;
}

- (void)handleURL:(NSURL *)url {
    if (![url.scheme.lowercaseString isEqualToString:@"art"]) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_pendingURL = url;
        [[NSNotificationCenter defaultCenter] postNotificationName:ArtemisDeepLinkNotification object:self];
    });
}

- (NSURL *)takePendingURL {
    NSURL *url = _pendingURL;
    _pendingURL = nil;
    return url;
}

@end
