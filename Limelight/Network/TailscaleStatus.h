//
//  TailscaleStatus.h
//  Artemis
//
//  Reads `tailscale status --json`, to find a host's Tailscale address and whether the
//  path to it is direct or relayed. Everything returns nil when Tailscale isn't
//  installed, connected or running; nothing fails because of it.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TailscalePeer : NSObject

@property (nonatomic, readonly) NSString *hostName;
// MagicDNS name without the trailing dot, e.g. "wall-desktop.tail397a88.ts.net"
@property (nonatomic, readonly) NSString *dnsName;
@property (nonatomic, readonly) NSArray<NSString *> *addresses;
// Subnets this peer routes for the tailnet (its primary subnet routes)
@property (nonatomic, readonly) NSArray<NSString *> *subnetRoutes;
@property (nonatomic, readonly, nullable) NSString *ipv4Address;
// The peer's direct UDP endpoint; empty while relayed or idle
@property (nonatomic, readonly) NSString *currentAddress;
// The DERP region it falls back to, e.g. "sfo"
@property (nonatomic, readonly) NSString *relay;
@property (nonatomic, readonly) NSString *peerRelay;
@property (nonatomic, readonly) BOOL online;
@property (nonatomic, readonly) BOOL active;
// Traffic goes through a relay rather than straight to the peer
@property (nonatomic, readonly) BOOL relayed;
// "direct (192.168.19.130:41641)", "relayed (DERP sfo)", "peer relay (…)" or "idle"
@property (nonatomic, readonly) NSString *pathDescription;

@end

@interface TailscaleStatus : NSObject

@property (nonatomic, readonly) NSArray<NSString *> *selfAddresses;
@property (nonatomic, readonly) NSArray<TailscalePeer *> *peers;

// Parses `tailscale status --json`. nil unless Tailscale is running.
+ (nullable instancetype)statusFromJSON:(NSData *)json;

// The status, fetched first if the last one is older than maxAge. Runs the Tailscale
// CLI (tens of ms), so call it off the main thread.
+ (nullable instancetype)currentStatusWithMaxAge:(NSTimeInterval)maxAge;

// Never blocks: returns the last status and refreshes it in the background if it's
// older than maxAge
+ (nullable instancetype)cachedStatusRefreshingAfter:(NSTimeInterval)maxAge;

// The peer with one of these addresses, or else the one whose host name (or first
// MagicDNS label) matches hostName
- (nullable TailscalePeer *)peerMatchingHostName:(nullable NSString *)hostName addresses:(NSArray<NSString *> *)addresses;

// The peer that owns address, or else the subnet router that routes it
- (nullable TailscalePeer *)peerRoutingAddress:(NSString *)address;

@end

NS_ASSUME_NONNULL_END
