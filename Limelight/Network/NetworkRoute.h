//
//  NetworkRoute.h
//  Artemis
//
//  How ArtemisMac would reach a host, and whether the network policy allows it. By
//  default only the local network and Tailscale are allowed, never the open internet.
//  The "Allow Connections Over Any Network" setting turns the policy off.
//

#import <Foundation/Foundation.h>

#include "NetworkPolicy.h"

NS_ASSUME_NONNULL_BEGIN

@interface NetworkRoute : NSObject

@property (nonatomic, readonly) NSString *host;
// The numeric address that was checked (with any %scope), or nil if the host didn't resolve
@property (nonatomic, readonly, nullable) NSString *address;
@property (nonatomic, readonly) ArtemisRouteKind kind;
@property (nonatomic, readonly) NSString *interfaceName;
@property (nonatomic, readonly) BOOL allowed;
// "LAN", "Tailscale", "Tailscale subnet route", "this Mac", "Internet" or "no route"
@property (nonatomic, readonly) NSString *kindDescription;
// Why it isn't allowed, for an alert
@property (nonatomic, readonly, nullable) NSString *failureMessage;

// Asks the kernel how it would route to host, without sending anything. Resolving a
// host name can block. A name is only allowed if every address it resolves to (that
// has a route) is.
+ (instancetype)routeToHost:(NSString *)host;

// The policy's off switch (NSUserDefaults "allowAnyNetwork", off by default)
+ (BOOL)allowAnyNetwork;

// Whether a stored address may be used at all, without a route lookup: numeric
// addresses must be local or Tailscale ones. Names pass, and are checked when used.
+ (BOOL)isUsableAddress:(nullable NSString *)address;

+ (NSString *)openInternetMessage;

@end

NS_ASSUME_NONNULL_END
