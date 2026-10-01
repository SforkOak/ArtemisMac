//
//  NetworkRoute.m
//  Artemis
//

#import "NetworkRoute.h"
#import "TailscaleStatus.h"

#include <net/if.h>
#include <netdb.h>

static NSString *const kAllowAnyNetworkKey = @"allowAnyNetwork";

@implementation NetworkRoute

+ (BOOL)allowAnyNetwork {
    return [NSUserDefaults.standardUserDefaults boolForKey:kAllowAnyNetworkKey];
}

+ (NSString *)openInternetMessage {
    return @"This connection would go over the open internet. Connect Tailscale or join your home network.";
}

+ (BOOL)isUsableAddress:(NSString *)address {
    if (address.length == 0) {
        return NO;
    }
    if ([self allowAnyNetwork]) {
        return YES;
    }
    ArtemisAddressClass addressClass = ArtemisClassifyHost(address.UTF8String);
    return addressClass == ArtemisAddrNotAddress || ArtemisAddressClassAllowed(addressClass);
}

+ (instancetype)routeToHost:(NSString *)host {
    NetworkRoute *route = [[NetworkRoute alloc] init];
    route->_host = host;
    route->_kind = ArtemisRouteRefused;
    route->_interfaceName = @"";

    NSString *lookup = host;
    if ([lookup hasPrefix:@"["] && [lookup hasSuffix:@"]"] && lookup.length > 2) {
        lookup = [lookup substringWithRange:NSMakeRange(1, lookup.length - 2)];
    }

    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *results = NULL;
    if (lookup.length == 0 || getaddrinfo(lookup.UTF8String, NULL, &hints, &results) != 0 || results == NULL) {
        route->_kindDescription = @"unresolved";
        route->_failureMessage = [NSString stringWithFormat:@"Couldn't find %@ on the network.", host];
        return route;
    }

    // An address family with no route (say, IPv6 on an IPv4-only network) can't be used,
    // so it doesn't count. Every one that can be used must be allowed.
    BOOL found = NO;
    BOOL allAllowed = YES;
    for (struct addrinfo *result = results; result != NULL; result = result->ai_next) {
        ArtemisRouteKind kind;
        char interfaceName[IF_NAMESIZE + 1];
        if (ArtemisCheckRoute(result->ai_addr, result->ai_addrlen, &kind, interfaceName, sizeof(interfaceName)) != 0) {
            continue;
        }
        BOOL allowed = kind != ArtemisRouteRefused;
        // Describe the first usable address, or the first refused one
        if (!found || (allAllowed && !allowed)) {
            char address[NI_MAXHOST];
            if (getnameinfo(result->ai_addr, result->ai_addrlen, address, sizeof(address), NULL, 0, NI_NUMERICHOST) == 0) {
                route->_address = @(address);
            }
            route->_kind = kind;
            route->_interfaceName = @(interfaceName);
        }
        found = YES;
        allAllowed = allAllowed && allowed;
    }
    freeaddrinfo(results);

    if (!found) {
        route->_kindDescription = @"no route";
        route->_failureMessage = [NSString stringWithFormat:@"There's no network route to %@.", host];
        return route;
    }

    switch (route->_kind) {
        case ArtemisRouteLAN:
            route->_kindDescription = @"LAN";
            break;
        case ArtemisRouteTailscale:
            route->_kindDescription = @"Tailscale";
            break;
        case ArtemisRouteTailscaleSubnet:
            route->_kindDescription = @"Tailscale subnet route";
            break;
        case ArtemisRouteLoopback:
            route->_kindDescription = @"this Mac";
            break;
        default:
            route->_kindDescription = @"Internet";
            break;
    }
    route->_allowed = allAllowed || [self allowAnyNetwork];
    if (!route->_allowed) {
        route->_failureMessage = [self openInternetMessage];
    }
    return route;
}

- (NSString *)pathDescription {
    switch (self.kind) {
        case ArtemisRouteLAN:
            return [NSString stringWithFormat:@"LAN (%@)", self.interfaceName];
        case ArtemisRouteLoopback:
            return @"this Mac";
        case ArtemisRouteTailscale:
        case ArtemisRouteTailscaleSubnet: {
            TailscaleStatus *status = [TailscaleStatus cachedStatusRefreshingAfter:10];
            TailscalePeer *peer = self.address != nil ? [status peerRoutingAddress:self.address] : nil;
            NSString *via = @"";
            if (self.kind == ArtemisRouteTailscaleSubnet) {
                via = [NSString stringWithFormat:@" via %@", peer.hostName ?: @"a subnet router"];
            }
            if (peer == nil) {
                return [NSString stringWithFormat:@"Tailscale%@", via];
            }
            return [NSString stringWithFormat:@"Tailscale%@ %@%@", via, peer.pathDescription,
                    peer.relayed ? @" ⚠ adds latency, limits bandwidth" : @""];
        }
        default:
            return self.allowed ? @"Internet (network policy off)" : @"Internet";
    }
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@ -> %@ via %@ (%@, %@)", self.host, self.address ?: @"?",
            self.interfaceName.length > 0 ? self.interfaceName : @"?", self.kindDescription,
            self.allowed ? @"allowed" : @"refused"];
}

@end
