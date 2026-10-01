//
//  DiscoveryWorker.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/2/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "DiscoveryWorker.h"
#import "Utils.h"
#import "HttpManager.h"
#import "ServerInfoResponse.h"
#import "HttpRequest.h"
#import "DataManager.h"
#import "NetworkRoute.h"
#import "TailscaleStatus.h"

@implementation DiscoveryWorker {
    TemporaryHost* _host;
    NSString* _uniqueId;
    NSString* _lastAddressSummary;
}

static const float POLL_RATE = 2.0f; // Poll every 2 seconds

- (id) initWithHost:(TemporaryHost*)host uniqueId:(NSString*)uniqueId {
    self = [super init];
    _host = host;
    _uniqueId = uniqueId;
    return self;
}

- (TemporaryHost*) getHost {
    return _host;
}

- (void)main {
    while (!self.cancelled) {
        [self discoverHost];
        if (!self.cancelled) {
            [NSThread sleepForTimeInterval:POLL_RATE];
        }
    }
}

// Picks up the host's Tailscale address, matching it by name or a known address
- (void) updateTailscaleAddress {
    TailscaleStatus *status = [TailscaleStatus currentStatusWithMaxAge:30];
    NSMutableArray<NSString*> *known = [NSMutableArray array];
    for (NSString *address in @[_host.address ?: @"", _host.localAddress ?: @"", _host.ipv6Address ?: @"", _host.tailscaleAddress ?: @""]) {
        if (address.length > 0) {
            [known addObject:address];
        }
    }
    TailscalePeer *peer = [status peerMatchingHostName:_host.name addresses:known];
    NSString *address = peer.ipv4Address ?: peer.addresses.firstObject;
    if (address != nil && ![address isEqualToString:_host.tailscaleAddress]) {
        Log(LOG_I, @"%@ is %@ on Tailscale (%@)", _host.name, address, peer.dnsName);
        _host.tailscaleAddress = address;
    }
}

static int routeRank(ArtemisRouteKind kind) {
    switch (kind) {
        case ArtemisRouteLAN:
        case ArtemisRouteLoopback:
            return 0;
        case ArtemisRouteTailscale:
            return 1;
        default:
            // A subnet route is an extra hop through the router
            return 2;
    }
}

- (NSArray*) getHostAddressList {
    [self updateTailscaleAddress];

    if (![NetworkRoute allowAnyNetwork]) {
        return [self getAllowedHostAddressList];
    }

    NSMutableArray *array = [[NSMutableArray alloc] initWithCapacity:3];

    if (_host.localAddress != nil) {
        [array addObject:_host.localAddress];
    }
    if (_host.address != nil) {
        [array addObject:_host.address];
    }
    if (_host.tailscaleAddress != nil) {
        [array addObject:_host.tailscaleAddress];
    }
    if (_host.externalAddress != nil) {
        [array addObject:_host.externalAddress];
    }
    if (_host.ipv6Address != nil) {
        [array addObject:_host.ipv6Address];
    }
    
    // Remove duplicate addresses from the list.
    // This is done using an array rather than a set
    // to preserve insertion order of addresses.
    for (int i = 0; i < [array count]; i++) {
        NSString *addr1 = [array objectAtIndex:i];
        
        for (int j = 1; j < [array count]; j++) {
            if (i == j) {
                continue;
            }
            
            NSString *addr2 = [array objectAtIndex:j];
            
            if ([addr1 isEqualToString:addr2]) {
                // Remove the last address
                [array removeObjectAtIndex:j];
                
                // Begin searching again from the start
                i = -1;
                break;
            }
        }
    }
    
    return array;
}

// The addresses the network policy allows right now, without contacting the others.
// Never the external address. The address the PC was added by goes first, so adding
// it by its Tailscale address or name uses Tailscale even at home; the rest go LAN,
// then Tailscale, then a Tailscale subnet route.
- (NSArray*) getAllowedHostAddressList {
    NSMutableArray<NetworkRoute*> *routes = [NSMutableArray array];
    NSMutableArray<NSString*> *skipped = [NSMutableArray array];
    for (NSString *address in @[_host.address ?: @"", _host.localAddress ?: @"", _host.tailscaleAddress ?: @"", _host.ipv6Address ?: @""]) {
        if (address.length == 0 || [[routes valueForKey:@"host"] containsObject:address] || [skipped containsObject:address]) {
            continue;
        }
        NetworkRoute *route = [NetworkRoute isUsableAddress:address] ? [NetworkRoute routeToHost:address] : nil;
        if (route.allowed) {
            [routes addObject:route];
        } else {
            [skipped addObject:address];
        }
    }

    NSString *manualAddress = _host.address;
    [routes sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NetworkRoute *a, NetworkRoute *b) {
        int rankA = [a.host isEqualToString:manualAddress] ? -1 : routeRank(a.kind);
        int rankB = [b.host isEqualToString:manualAddress] ? -1 : routeRank(b.kind);
        return rankA < rankB ? NSOrderedAscending : (rankA > rankB ? NSOrderedDescending : NSOrderedSame);
    }];

    NSMutableArray<NSString*> *descriptions = [NSMutableArray array];
    for (NetworkRoute *route in routes) {
        [descriptions addObject:[NSString stringWithFormat:@"%@ (%@)", route.host, route.kindDescription]];
    }
    NSString *summary = [NSString stringWithFormat:@"%@; not allowed: %@",
                         descriptions.count > 0 ? [descriptions componentsJoinedByString:@", "] : @"none",
                         skipped.count > 0 ? [skipped componentsJoinedByString:@", "] : @"none"];
    if (![summary isEqualToString:_lastAddressSummary]) {
        Log(LOG_I, @"%@ addresses: %@", _host.name, summary);
        _lastAddressSummary = summary;
    }
    return [routes valueForKey:@"host"];
}

- (void) discoverHost {
    BOOL receivedResponse = NO;
    NSArray *addresses = [self getHostAddressList];
    
    Log(LOG_D, @"%@ has %d unique addresses", _host.name, [addresses count]);
    
    // Give the PC 2 tries to respond before declaring it offline if we've seen it before.
    // If this is an unknown PC, update the status after 1 attempt to get the UI refreshed quickly.
    for (int i = 0; i < (_host.state == StateUnknown ? 1 : 2); i++) {
        for (NSString *address in addresses) {
            if (self.cancelled) {
                // Get out without updating the status because
                // it might not have finished checking the various
                // addresses
                return;
            }
            
            ServerInfoResponse* serverInfoResp = [self requestInfoAtAddress:address cert:_host.serverCert];
            receivedResponse = [self checkResponse:serverInfoResp];
            if (receivedResponse) {
                [serverInfoResp populateHost:_host];
                _host.activeAddress = address;
                
                // Update the database using the response
                DataManager *dataManager = [[DataManager alloc] init];
                [dataManager updateHost:_host];
                break;
            }
        }
        
        if (receivedResponse) {
            Log(LOG_D, @"Received serverinfo response on try %d", i);
            break;
        }
    }

    _host.state = receivedResponse ? StateOnline : StateOffline;
    if (receivedResponse) {
        Log(LOG_D, @"Received response from: %@\n{\n\t address:%@ \n\t localAddress:%@ \n\t externalAddress:%@ \n\t ipv6Address:%@ \n\t uuid:%@ \n\t mac:%@ \n\t pairState:%d \n\t online:%d \n\t activeAddress:%@ \n}", _host.name, _host.address, _host.localAddress, _host.externalAddress, _host.ipv6Address, _host.uuid, _host.mac, _host.pairState, _host.state, _host.activeAddress);
    }
}

- (ServerInfoResponse*) requestInfoAtAddress:(NSString*)address cert:(NSData*)cert {
    @autoreleasepool {
        HttpManager* hMan = [[HttpManager alloc] initWithHost:address
                                                     uniqueId:_uniqueId
                                                         serverCert:cert];
        ServerInfoResponse* response = [[ServerInfoResponse alloc] init];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:response
                                                           withUrlRequest:[hMan newServerInfoRequest:true]
                                           fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
        return response;
    }
}

- (BOOL) checkResponse:(ServerInfoResponse*)response {
    if ([response isStatusOk]) {
        // If the response is from a different host then do not update this host
        if ((_host.uuid == nil || [[response getStringTag:TAG_UNIQUE_ID] isEqualToString:_host.uuid])) {
            return YES;
        } else {
            Log(LOG_I, @"Received response from incorrect host: %@ expected: %@", [response getStringTag:TAG_UNIQUE_ID], _host.uuid);
        }
    }
    return NO;
}

@end
