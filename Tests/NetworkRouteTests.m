//
//  NetworkRouteTests.m
//  Artemis
//
//  Unit tests for TailscaleStatus parsing and NetworkRoute. Run Tests/run-tests.sh.
//

#import <Foundation/Foundation.h>

#import "Logger.h"
#import "NetworkRoute.h"
#import "TailscaleStatus.h"

void Log(LogLevel level, NSString *fmt, ...) {
    (void)level;
    (void)fmt;
}

static int failures;

#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// Shaped like `tailscale status --json`, with made-up peers
static NSString *const kStatusJSON = @"{"
    @"\"BackendState\": \"Running\","
    @"\"TailscaleIPs\": [\"100.88.0.1\", \"fd7a:115c:a1e0::1\"],"
    @"\"Peer\": {"
    @"  \"nodekey:a\": {\"HostName\": \"Gaming-PC\", \"DNSName\": \"gaming-pc.tailnet-example.ts.net.\","
    @"    \"TailscaleIPs\": [\"100.93.0.2\", \"fd7a:115c:a1e0::2\"], \"PrimaryRoutes\": null,"
    @"    \"CurAddr\": \"\", \"Relay\": \"sfo\", \"PeerRelay\": \"\", \"Online\": true, \"Active\": true},"
    @"  \"nodekey:b\": {\"HostName\": \"nas\", \"DNSName\": \"nas.tailnet-example.ts.net.\","
    @"    \"TailscaleIPs\": [\"100.76.0.3\"], \"PrimaryRoutes\": [\"192.168.50.0/24\"],"
    @"    \"CurAddr\": \"192.168.50.25:41641\", \"Relay\": \"sfo\", \"Online\": true, \"Active\": true},"
    @"  \"nodekey:c\": {\"HostName\": \"localhost\", \"DNSName\": \"living-room.tailnet-example.ts.net.\","
    @"    \"TailscaleIPs\": [\"100.72.0.4\"], \"CurAddr\": \"\", \"Relay\": \"ord\", \"Online\": false, \"Active\": false}"
    @"}}";

static void testStatus(void) {
    TailscaleStatus *status = [TailscaleStatus statusFromJSON:[kStatusJSON dataUsingEncoding:NSUTF8StringEncoding]];
    CHECK(status != nil, "status didn't parse");
    CHECK(status.peers.count == 3, "%lu peers", (unsigned long)status.peers.count);
    CHECK([status.selfAddresses containsObject:@"100.88.0.1"], "self address");

    TailscalePeer *pc = [status peerMatchingHostName:@"Gaming-PC" addresses:@[]];
    CHECK([pc.ipv4Address isEqualToString:@"100.93.0.2"], "match by host name: %s", pc.ipv4Address.UTF8String);
    CHECK([pc.dnsName isEqualToString:@"gaming-pc.tailnet-example.ts.net"], "trailing dot dropped");
    CHECK(pc.relayed, "no CurAddr and a DERP region is relayed");
    CHECK([pc.pathDescription isEqualToString:@"relayed (DERP sfo)"], "%s", pc.pathDescription.UTF8String);

    CHECK([status peerMatchingHostName:@"gaming pc" addresses:@[]] == pc, "match by MagicDNS label");
    CHECK([status peerMatchingHostName:@"Living-Room" addresses:@[]] != nil, "match by DNS label when HostName is generic");
    NSArray<NSString *> *known = @[@"192.168.1.9", @"100.93.0.2"];
    CHECK([status peerMatchingHostName:@"Other" addresses:known] == pc, "match by address");
    CHECK([status peerMatchingHostName:@"Other" addresses:@[@"192.168.1.9"]] == nil, "no match");
    CHECK([status peerMatchingHostName:nil addresses:@[]] == nil, "nil name");

    TailscalePeer *nas = [status peerRoutingAddress:@"192.168.50.130"];
    CHECK([nas.hostName isEqualToString:@"nas"], "subnet router");
    CHECK(!nas.relayed, "direct path isn't relayed");
    CHECK([nas.pathDescription isEqualToString:@"direct (192.168.50.25:41641)"], "%s", nas.pathDescription.UTF8String);
    CHECK([status peerRoutingAddress:@"fd7a:115c:a1e0::2"] == pc, "peer by IPv6 address");
    CHECK([status peerRoutingAddress:@"192.168.51.1"] == nil, "unrouted address");

    TailscalePeer *idle = [status peerMatchingHostName:@"living-room" addresses:@[]];
    CHECK([idle.pathDescription isEqualToString:@"idle"], "%s", idle.pathDescription.UTF8String);

    CHECK([TailscaleStatus statusFromJSON:[@"{\"BackendState\": \"Stopped\"}" dataUsingEncoding:NSUTF8StringEncoding]] == nil, "stopped");
    CHECK([TailscaleStatus statusFromJSON:[@"not json" dataUsingEncoding:NSUTF8StringEncoding]] == nil, "garbage");
    CHECK([TailscaleStatus statusFromJSON:[NSData data]] == nil, "empty");
}

static void testRoutes(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    // The registration domain is in memory only
    [defaults registerDefaults:@{@"allowAnyNetwork": @NO}];

    NetworkRoute *loopback = [NetworkRoute routeToHost:@"127.0.0.1"];
    CHECK(loopback.allowed && loopback.kind == ArtemisRouteLoopback, "%s", loopback.description.UTF8String);
    CHECK([loopback.address isEqualToString:@"127.0.0.1"], "address");

    // TEST-NET-3 is never on-link
    NetworkRoute *internet = [NetworkRoute routeToHost:@"203.0.113.1"];
    CHECK(!internet.allowed, "%s", internet.description.UTF8String);
    CHECK(internet.failureMessage != nil, "failure message");

    NetworkRoute *unresolved = [NetworkRoute routeToHost:@"no-such-host.invalid"];
    CHECK(!unresolved.allowed && unresolved.address == nil, "%s", unresolved.description.UTF8String);
    CHECK(![NetworkRoute routeToHost:@""].allowed, "empty host");

    CHECK([NetworkRoute isUsableAddress:@"192.168.19.130"], "LAN address usable");
    CHECK([NetworkRoute isUsableAddress:@"100.93.0.2"], "Tailscale address usable");
    CHECK([NetworkRoute isUsableAddress:@"pc.tailnet-example.ts.net"], "names are checked later");
    CHECK(![NetworkRoute isUsableAddress:@"203.0.113.1"], "public IPv4 not usable");
    CHECK(![NetworkRoute isUsableAddress:@"2600:1700::1"], "global IPv6 not usable");
    CHECK(![NetworkRoute isUsableAddress:nil], "nil not usable");

    [defaults registerDefaults:@{@"allowAnyNetwork": @YES}];
    CHECK([NetworkRoute allowAnyNetwork], "setting on");
    CHECK([NetworkRoute isUsableAddress:@"203.0.113.1"], "public usable with the policy off");
    NetworkRoute *anyNetwork = [NetworkRoute routeToHost:@"203.0.113.1"];
    // With no network at all there's no route either way
    CHECK(anyNetwork.allowed || anyNetwork.address == nil || [anyNetwork.kindDescription isEqualToString:@"no route"],
          "%s", anyNetwork.description.UTF8String);
    [defaults registerDefaults:@{@"allowAnyNetwork": @NO}];
}

int main(void) {
    @autoreleasepool {
        testStatus();
        testRoutes();
    }
    if (failures > 0) {
        printf("%d network route check(s) failed\n", failures);
        return 1;
    }
    printf("Network route tests passed\n");
    return 0;
}
