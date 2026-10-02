//
//  TailscaleStatus.m
//  Artemis
//

#import "TailscaleStatus.h"
#import "Logger.h"

#include "NetworkPolicy.h"

#include <netdb.h>

static NSString *stringValue(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSArray<NSString *> *stringArray(id value) {
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    if ([value isKindOfClass:[NSArray class]]) {
        for (id item in value) {
            if ([item isKindOfClass:[NSString class]]) {
                [strings addObject:item];
            }
        }
    }
    return strings;
}

@implementation TailscalePeer

- (instancetype)initWithJSON:(NSDictionary *)json {
    self = [super init];
    _hostName = stringValue(json[@"HostName"]);
    NSString *dnsName = stringValue(json[@"DNSName"]);
    _dnsName = [dnsName hasSuffix:@"."] ? [dnsName substringToIndex:dnsName.length - 1] : dnsName;
    _addresses = stringArray(json[@"TailscaleIPs"]);
    _subnetRoutes = stringArray(json[@"PrimaryRoutes"]);
    _currentAddress = stringValue(json[@"CurAddr"]);
    _relay = stringValue(json[@"Relay"]);
    _peerRelay = stringValue(json[@"PeerRelay"]);
    _online = [json[@"Online"] respondsToSelector:@selector(boolValue)] && [json[@"Online"] boolValue];
    _active = [json[@"Active"] respondsToSelector:@selector(boolValue)] && [json[@"Active"] boolValue];
    for (NSString *address in _addresses) {
        if (![address containsString:@":"]) {
            _ipv4Address = address;
            break;
        }
    }
    return self;
}

- (BOOL)relayed {
    // An idle peer has no path yet, relayed or not
    return self.active && self.currentAddress.length == 0 && (self.peerRelay.length > 0 || self.relay.length > 0);
}

- (NSString *)pathDescription {
    // Relay is the peer's home DERP region, set even when the path is direct
    if (self.currentAddress.length > 0) {
        return [NSString stringWithFormat:@"direct (%@)", self.currentAddress];
    }
    if (!self.active) {
        return @"idle";
    }
    if (self.peerRelay.length > 0) {
        return [NSString stringWithFormat:@"peer relay (%@)", self.peerRelay];
    }
    if (self.relay.length > 0) {
        return [NSString stringWithFormat:@"relayed (DERP %@)", self.relay];
    }
    return @"connecting";
}

@end

@implementation TailscaleStatus

static TailscaleStatus *cachedStatus;
static NSDate *cachedAt;
static BOOL cachedInterfaceUp;
static BOOL refreshing;

+ (instancetype)statusFromJSON:(NSData *)json {
    NSDictionary *root = json.length > 0 ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    if (![root isKindOfClass:[NSDictionary class]] || ![stringValue(root[@"BackendState"]) isEqualToString:@"Running"]) {
        return nil;
    }

    TailscaleStatus *status = [[TailscaleStatus alloc] init];
    status->_selfAddresses = stringArray(root[@"TailscaleIPs"]);
    NSMutableArray<TailscalePeer *> *peers = [NSMutableArray array];
    NSDictionary *peerMap = root[@"Peer"];
    if ([peerMap isKindOfClass:[NSDictionary class]]) {
        for (id peer in peerMap.allValues) {
            if ([peer isKindOfClass:[NSDictionary class]]) {
                [peers addObject:[[TailscalePeer alloc] initWithJSON:peer]];
            }
        }
    }
    status->_peers = peers;
    return status;
}

+ (NSString *)cliPath {
    for (NSString *path in @[@"/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                             @"/opt/homebrew/bin/tailscale",
                             @"/usr/local/bin/tailscale"]) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

+ (instancetype)fetch {
    NSString *cli = [self cliPath];
    if (cli == nil) {
        return nil;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:cli];
    task.arguments = @[@"status", @"--json"];
    task.qualityOfService = NSQualityOfServiceUtility;
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    NSError *error;
    if (![task launchAndReturnError:&error]) {
        Log(LOG_W, @"Couldn't run %@: %@", cli, error);
        return nil;
    }

    // Don't let a stuck CLI hold up discovery
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (task.running) {
            Log(LOG_W, @"tailscale status timed out");
            [task terminate];
        }
    });
    NSData *json = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationReason != NSTaskTerminationReasonExit || task.terminationStatus != 0) {
        return nil;
    }
    return [self statusFromJSON:json];
}

+ (dispatch_queue_t)fetchQueue {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.sforkoak.artemis.tailscale-status",
                                      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

// Call with @synchronized(self) held
+ (BOOL)isStale:(NSTimeInterval)maxAge interfaceUp:(BOOL)interfaceUp {
    return cachedAt == nil || -cachedAt.timeIntervalSinceNow > maxAge || interfaceUp != cachedInterfaceUp;
}

// Runs on the fetch queue
+ (void)refreshIfStale:(NSTimeInterval)maxAge {
    // Skip the CLI entirely while Tailscale isn't connected
    BOOL interfaceUp = ArtemisTailscaleInterfaceUp();
    @synchronized (self) {
        if (![self isStale:maxAge interfaceUp:interfaceUp]) {
            return;
        }
    }
    TailscaleStatus *status = interfaceUp ? [self fetch] : nil;
    @synchronized (self) {
        cachedStatus = status;
        cachedAt = [NSDate date];
        cachedInterfaceUp = interfaceUp;
    }
}

+ (instancetype)currentStatusWithMaxAge:(NSTimeInterval)maxAge {
    dispatch_sync([self fetchQueue], ^{
        [self refreshIfStale:maxAge];
    });
    @synchronized (self) {
        return cachedStatus;
    }
}

+ (instancetype)cachedStatusRefreshingAfter:(NSTimeInterval)maxAge {
    @synchronized (self) {
        if (!refreshing && (cachedAt == nil || -cachedAt.timeIntervalSinceNow > maxAge)) {
            refreshing = YES;
            dispatch_async([self fetchQueue], ^{
                [self refreshIfStale:maxAge];
                @synchronized (self) {
                    refreshing = NO;
                }
            });
        }
        return cachedStatus;
    }
}

- (TailscalePeer *)peerMatchingHostName:(NSString *)hostName addresses:(NSArray<NSString *> *)addresses {
    for (TailscalePeer *peer in self.peers) {
        for (NSString *address in addresses) {
            if ([peer.addresses containsObject:address]) {
                return peer;
            }
        }
    }
    if (hostName.length == 0) {
        return nil;
    }
    NSString *label = [[hostName.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                       componentsJoinedByString:@"-"];
    for (TailscalePeer *peer in self.peers) {
        NSString *firstLabel = [peer.dnsName componentsSeparatedByString:@"."].firstObject;
        if ([peer.hostName caseInsensitiveCompare:hostName] == NSOrderedSame ||
            [firstLabel caseInsensitiveCompare:label] == NSOrderedSame) {
            return peer;
        }
    }
    return nil;
}

- (TailscalePeer *)peerRoutingAddress:(NSString *)address {
    for (TailscalePeer *peer in self.peers) {
        if ([peer.addresses containsObject:address]) {
            return peer;
        }
    }

    struct addrinfo hints = {0};
    hints.ai_flags = AI_NUMERICHOST;
    struct addrinfo *result = NULL;
    if (getaddrinfo(address.UTF8String, NULL, &hints, &result) != 0 || result == NULL) {
        return nil;
    }
    TailscalePeer *router = nil;
    for (TailscalePeer *peer in self.peers) {
        for (NSString *route in peer.subnetRoutes) {
            // Exit node routes aren't subnet routes
            if (![route hasSuffix:@"/0"] && ArtemisAddressInPrefix(result->ai_addr, route.UTF8String)) {
                router = peer;
                break;
            }
        }
        if (router != nil) {
            break;
        }
    }
    freeaddrinfo(result);
    return router;
}

@end
