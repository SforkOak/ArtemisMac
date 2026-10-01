//
//  NetworkPolicyTests.c
//  Artemis
//
//  Unit tests for the address classifier and route check. Run Tests/run-tests.sh.
//

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "NetworkPolicy.h"

static int failures;

#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// "a.b.c.d" or "v6" with an optional numeric "%scope"
static struct sockaddr_storage addr(const char *text) {
    struct sockaddr_storage storage;
    memset(&storage, 0, sizeof(storage));
    char buffer[64];
    snprintf(buffer, sizeof(buffer), "%s", text);
    char *scope = strchr(buffer, '%');
    if (scope != NULL) {
        *scope++ = '\0';
    }
    struct sockaddr_in *sin = (struct sockaddr_in *)&storage;
    struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)&storage;
    if (inet_pton(AF_INET, buffer, &sin->sin_addr) == 1) {
        sin->sin_family = AF_INET;
        sin->sin_len = sizeof(*sin);
    } else if (inet_pton(AF_INET6, buffer, &sin6->sin6_addr) == 1) {
        sin6->sin6_family = AF_INET6;
        sin6->sin6_len = sizeof(*sin6);
        sin6->sin6_scope_id = scope != NULL ? (uint32_t)atoi(scope) : 0;
    } else {
        printf("bad test address %s\n", text);
        exit(2);
    }
    return storage;
}

static struct sockaddr_storage mask(int family, int bits) {
    struct sockaddr_storage storage;
    memset(&storage, 0, sizeof(storage));
    uint8_t *bytes;
    int length;
    if (family == AF_INET) {
        bytes = (uint8_t *)&((struct sockaddr_in *)&storage)->sin_addr;
        length = 4;
    } else {
        bytes = ((struct sockaddr_in6 *)&storage)->sin6_addr.s6_addr;
        length = 16;
    }
    // Leave sa_family unset, as the kernel sometimes does for netmasks
    for (int i = 0; i < length; i++) {
        int take = bits >= 8 ? 8 : (bits > 0 ? bits : 0);
        bytes[i] = (uint8_t)(0xFF << (8 - take));
        if (take == 0) {
            bytes[i] = 0;
        }
        bits -= take;
    }
    return storage;
}

static const char *className(ArtemisAddressClass c) {
    static const char *const names[] = {"NotAddress", "Loopback", "Private", "LinkLocal", "UniqueLocal", "Tailscale", "Internet"};
    return names[c];
}

static void expectClass(const char *host, ArtemisAddressClass expected) {
    ArtemisAddressClass got = ArtemisClassifyHost(host);
    CHECK(got == expected, "%s: %s, expected %s", host ? host : "NULL", className(got), className(expected));
}

static void testClassifier(void) {
    expectClass("192.168.19.130", ArtemisAddrPrivate);
    expectClass("10.1.2.3", ArtemisAddrPrivate);
    expectClass("172.16.0.1", ArtemisAddrPrivate);
    expectClass("172.31.255.255", ArtemisAddrPrivate);
    expectClass("172.32.0.1", ArtemisAddrInternet);
    expectClass("169.254.10.20", ArtemisAddrLinkLocal);
    expectClass("127.0.0.1", ArtemisAddrLoopback);
    expectClass("100.64.0.1", ArtemisAddrTailscale);
    expectClass("100.93.195.63", ArtemisAddrTailscale);
    expectClass("100.127.255.255", ArtemisAddrTailscale);
    expectClass("100.128.0.1", ArtemisAddrInternet);
    expectClass("100.63.255.255", ArtemisAddrInternet);
    expectClass("203.0.113.1", ArtemisAddrInternet);
    expectClass("8.8.8.8", ArtemisAddrInternet);

    expectClass("fe80::1%en0", ArtemisAddrLinkLocal);
    expectClass("[fe80::1]", ArtemisAddrLinkLocal);
    expectClass("febf::1", ArtemisAddrLinkLocal);
    expectClass("fec0::1", ArtemisAddrInternet);
    expectClass("fdf0:1190:9a97:4514:daf1:989:6449:9c87", ArtemisAddrUniqueLocal);
    expectClass("fc00::1", ArtemisAddrUniqueLocal);
    expectClass("fd7a:115c:a1e0::6a32:c340", ArtemisAddrTailscale);
    expectClass("fd7a:115c:a1e1::1", ArtemisAddrUniqueLocal);
    expectClass("2001:db8::1", ArtemisAddrInternet);
    expectClass("2600:1700::1", ArtemisAddrInternet);
    expectClass("::1", ArtemisAddrLoopback);
    expectClass("::ffff:192.168.1.1", ArtemisAddrPrivate);
    expectClass("::ffff:8.8.8.8", ArtemisAddrInternet);
    expectClass("64:ff9b::808:808", ArtemisAddrInternet);

    expectClass("wall-desktop.tail397a88.ts.net", ArtemisAddrNotAddress);
    expectClass("192.168.1", ArtemisAddrNotAddress);
    expectClass("", ArtemisAddrNotAddress);
    expectClass(NULL, ArtemisAddrNotAddress);

    CHECK(!ArtemisAddressClassAllowed(ArtemisAddrInternet), "Internet allowed");
    CHECK(!ArtemisAddressClassAllowed(ArtemisAddrNotAddress), "NotAddress allowed");
    CHECK(ArtemisAddressClassAllowed(ArtemisAddrPrivate), "Private refused");
    CHECK(ArtemisAddressClassAllowed(ArtemisAddrLinkLocal), "LinkLocal refused");
    CHECK(ArtemisAddressClassAllowed(ArtemisAddrUniqueLocal), "UniqueLocal refused");
    CHECK(ArtemisAddressClassAllowed(ArtemisAddrTailscale), "Tailscale refused");

    CHECK(ArtemisIsTailscaleName("wall-desktop.tail397a88.ts.net"), "ts.net name");
    CHECK(ArtemisIsTailscaleName("wall-desktop.tail397a88.ts.net."), "ts.net name with trailing dot");
    CHECK(ArtemisIsTailscaleName("WALL.TS.NET"), "upper-case ts.net name");
    CHECK(!ArtemisIsTailscaleName("ts.net"), "bare ts.net");
    CHECK(!ArtemisIsTailscaleName(".ts.net"), "empty label");
    CHECK(!ArtemisIsTailscaleName("evil-ts.net"), "evil-ts.net");
    CHECK(!ArtemisIsTailscaleName("x.ts.net.evil.com"), "ts.net inside another domain");
    CHECK(!ArtemisIsTailscaleName("x.ts.network"), "ts.network");
    CHECK(!ArtemisIsTailscaleName(NULL), "NULL name");

    struct sockaddr_storage a = addr("192.168.19.130");
    CHECK(ArtemisAddressInPrefix((struct sockaddr *)&a, "192.168.19.0/24"), "in /24");
    CHECK(!ArtemisAddressInPrefix((struct sockaddr *)&a, "192.168.20.0/24"), "not in other /24");
    CHECK(ArtemisAddressInPrefix((struct sockaddr *)&a, "0.0.0.0/0"), "in /0");
    CHECK(!ArtemisAddressInPrefix((struct sockaddr *)&a, "::/0"), "v4 in v6 prefix");
    CHECK(!ArtemisAddressInPrefix((struct sockaddr *)&a, "192.168.19.0/33"), "bad prefix length");
    CHECK(!ArtemisAddressInPrefix((struct sockaddr *)&a, "bogus"), "no slash");
    struct sockaddr_storage b = addr("fd7a:115c:a1e0::6a32:c340");
    CHECK(ArtemisAddressInPrefix((struct sockaddr *)&b, "fd7a:115c:a1e0::/48"), "in tailnet /48");
    CHECK(!ArtemisAddressInPrefix((struct sockaddr *)&b, "fd7a:115c:a1e1::/48"), "not in other /48");
}

// Interface addresses modeled on this Mac: Wi-Fi on the home LAN, Tailscale, and another VPN
static struct sockaddr_storage storage[32];
static ArtemisInterfaceAddress ifaces[16];
static size_t ifaceCount;

static void addInterface(const char *name, const char *address, int bits) {
    struct sockaddr_storage *a = &storage[ifaceCount * 2];
    *a = addr(address);
    struct sockaddr_storage *m = &storage[ifaceCount * 2 + 1];
    *m = mask(a->ss_family, bits);
    ifaces[ifaceCount].name = name;
    ifaces[ifaceCount].addr = (struct sockaddr *)a;
    ifaces[ifaceCount].netmask = (struct sockaddr *)m;
    ifaceCount++;
}

static const char *kindName(ArtemisRouteKind kind) {
    static const char *const names[] = {"Refused", "LAN", "Tailscale", "TailscaleSubnet", "Loopback"};
    return names[kind];
}

static void expectRoute(const char *dest, const char *local, ArtemisRouteKind expected, const char *expectedInterface) {
    struct sockaddr_storage d = addr(dest), l = addr(local);
    const char *name = NULL;
    ArtemisRouteKind got = ArtemisDecideRoute((struct sockaddr *)&d, (struct sockaddr *)&l, ifaces, ifaceCount, &name);
    CHECK(got == expected, "%s from %s: %s, expected %s", dest, local, kindName(got), kindName(expected));
    if (expectedInterface != NULL) {
        CHECK(name != NULL && strcmp(name, expectedInterface) == 0, "%s from %s: interface %s, expected %s",
              dest, local, name ? name : "NULL", expectedInterface);
    }
}

static void testRoutes(void) {
    ifaceCount = 0;
    addInterface("lo0", "127.0.0.1", 8);
    addInterface("lo0", "::1", 128);
    addInterface("en0", "192.168.19.50", 24);
    // getifaddrs() embeds the scope (interface 14 = 0x0e) in a link-local address
    addInterface("en0", "fe80:e::1c", 64);
    addInterface("en0", "fdf0:1190:9a97:4514::50", 64);
    addInterface("en0", "2600:1700:aaaa:bbbb::50", 64);
    addInterface("utun7", "100.88.134.121", 32);
    addInterface("utun7", "fd7a:115c:a1e0::3f32:867a", 48);
    addInterface("utun3", "10.8.0.2", 24);
    addInterface("en1", "100.70.0.2", 24);

    // At home
    expectRoute("192.168.19.130", "192.168.19.50", ArtemisRouteLAN, "en0");
    expectRoute("fdf0:1190:9a97:4514::130", "fdf0:1190:9a97:4514::50", ArtemisRouteLAN, "en0");
    expectRoute("fe80::99%14", "fe80::1c%14", ArtemisRouteLAN, "en0");
    // A global IPv6 address on the same link is on-link (the address policy refuses it separately)
    expectRoute("2600:1700:aaaa:bbbb::130", "2600:1700:aaaa:bbbb::50", ArtemisRouteLAN, "en0");
    expectRoute("2600:1700:cccc::1", "2600:1700:aaaa:bbbb::50", ArtemisRouteRefused, "en0");

    // Over Tailscale
    expectRoute("100.93.195.63", "100.88.134.121", ArtemisRouteTailscale, "utun7");
    expectRoute("fd7a:115c:a1e0::6a32:c340", "fd7a:115c:a1e0::3f32:867a", ArtemisRouteTailscale, "utun7");
    // Away from home, through a subnet router
    expectRoute("192.168.19.130", "100.88.134.121", ArtemisRouteTailscaleSubnet, "utun7");
    // Through an exit node: out to the internet
    expectRoute("203.0.113.1", "100.88.134.121", ArtemisRouteRefused, "utun7");

    // Out through the router
    expectRoute("203.0.113.1", "192.168.19.50", ArtemisRouteRefused, "en0");
    // Tailscale is down, so 100.64/10 would go to the ISP's carrier-grade NAT
    expectRoute("100.93.195.63", "192.168.19.50", ArtemisRouteRefused, "en0");
    // A network that itself uses 100.64/10: on-link is LAN, off-link isn't
    expectRoute("100.70.0.5", "100.70.0.2", ArtemisRouteLAN, "en1");
    expectRoute("100.80.0.1", "100.70.0.2", ArtemisRouteRefused, "en1");
    // Another VPN
    expectRoute("10.8.0.1", "10.8.0.2", ArtemisRouteRefused, "utun3");
    // Loopback
    expectRoute("127.0.0.1", "127.0.0.1", ArtemisRouteLoopback, "lo0");
    // A source address no interface owns
    expectRoute("192.168.19.130", "192.168.77.1", ArtemisRouteRefused, NULL);

    // Away from home on another 192.168.x network: the home address is off-link
    ifaceCount = 0;
    addInterface("en0", "192.168.1.20", 24);
    expectRoute("192.168.19.130", "192.168.1.20", ArtemisRouteRefused, "en0");
    expectRoute("192.168.1.30", "192.168.1.20", ArtemisRouteLAN, "en0");
    // An ISP that gives the Mac a 100.64/10 address directly: still not Tailscale
    ifaceCount = 0;
    addInterface("en0", "100.101.0.7", 16);
    expectRoute("100.93.195.63", "100.101.0.7", ArtemisRouteRefused, "en0");
}

static void testLiveRoute(void) {
    ArtemisRouteKind kind = ArtemisRouteRefused;
    char name[32];
    struct sockaddr_storage loopback = addr("127.0.0.1");
    int err = ArtemisCheckRoute((struct sockaddr *)&loopback, sizeof(struct sockaddr_in), &kind, name, sizeof(name));
    CHECK(err == 0 && kind == ArtemisRouteLoopback, "live loopback: err %d, %s", err, kindName(kind));

    // TEST-NET-3 is never on-link, so it's refused (or unreachable with no network)
    struct sockaddr_storage testNet = addr("203.0.113.1");
    err = ArtemisCheckRoute((struct sockaddr *)&testNet, sizeof(struct sockaddr_in), &kind, name, sizeof(name));
    CHECK(err != 0 || kind == ArtemisRouteRefused, "live 203.0.113.1: %s via %s", kindName(kind), name);
}

int main(void) {
    testClassifier();
    testRoutes();
    testLiveRoute();
    if (failures > 0) {
        printf("%d network policy check(s) failed\n", failures);
        return 1;
    }
    printf("Network policy tests passed\n");
    return 0;
}
