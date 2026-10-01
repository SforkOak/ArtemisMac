//
//  NetworkPolicy.c
//  Artemis
//

#include "NetworkPolicy.h"

#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

static bool prefixMatches(const uint8_t *address, const uint8_t *prefix, int bits) {
    int bytes = bits / 8;
    int remainder = bits % 8;
    if (memcmp(address, prefix, bytes) != 0) {
        return false;
    }
    if (remainder == 0) {
        return true;
    }
    uint8_t mask = (uint8_t)(0xFF << (8 - remainder));
    return (address[bytes] & mask) == (prefix[bytes] & mask);
}

static ArtemisAddressClass classifyV4(uint32_t address) {
    if ((address & 0xFF000000) == 0x7F000000) {
        return ArtemisAddrLoopback;
    }
    if ((address & 0xFF000000) == 0x0A000000 ||  // 10.0.0.0/8
        (address & 0xFFF00000) == 0xAC100000 ||  // 172.16.0.0/12
        (address & 0xFFFF0000) == 0xC0A80000) {  // 192.168.0.0/16
        return ArtemisAddrPrivate;
    }
    if ((address & 0xFFFF0000) == 0xA9FE0000) {  // 169.254.0.0/16
        return ArtemisAddrLinkLocal;
    }
    if ((address & 0xFFC00000) == 0x64400000) {  // 100.64.0.0/10
        return ArtemisAddrTailscale;
    }
    return ArtemisAddrInternet;
}

static ArtemisAddressClass classifyV6(const uint8_t *bytes) {
    static const uint8_t loopback[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    static const uint8_t v4Mapped[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF};
    static const uint8_t tailscale[6] = {0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0};
    static const uint8_t linkLocal[2] = {0xFE, 0x80};
    static const uint8_t uniqueLocal[1] = {0xFC};

    if (memcmp(bytes, loopback, sizeof(loopback)) == 0) {
        return ArtemisAddrLoopback;
    }
    if (memcmp(bytes, v4Mapped, sizeof(v4Mapped)) == 0) {
        uint32_t v4;
        memcpy(&v4, bytes + 12, sizeof(v4));
        return classifyV4(ntohl(v4));
    }
    if (prefixMatches(bytes, tailscale, 48)) {
        return ArtemisAddrTailscale;
    }
    if (prefixMatches(bytes, linkLocal, 10)) {
        return ArtemisAddrLinkLocal;
    }
    if (prefixMatches(bytes, uniqueLocal, 7)) {
        return ArtemisAddrUniqueLocal;
    }
    return ArtemisAddrInternet;
}

ArtemisAddressClass ArtemisClassifySockaddr(const struct sockaddr *addr) {
    if (addr == NULL) {
        return ArtemisAddrNotAddress;
    }
    if (addr->sa_family == AF_INET) {
        return classifyV4(ntohl(((const struct sockaddr_in *)addr)->sin_addr.s_addr));
    }
    if (addr->sa_family == AF_INET6) {
        return classifyV6(((const struct sockaddr_in6 *)addr)->sin6_addr.s6_addr);
    }
    return ArtemisAddrNotAddress;
}

ArtemisAddressClass ArtemisClassifyHost(const char *host) {
    char buffer[INET6_ADDRSTRLEN + IF_NAMESIZE + 4];
    if (host == NULL || strlen(host) >= sizeof(buffer)) {
        return ArtemisAddrNotAddress;
    }

    // Accept "[v6]" and drop a "%scope"
    const char *start = host;
    size_t length = strlen(host);
    if (length >= 2 && host[0] == '[' && host[length - 1] == ']') {
        start = host + 1;
        length -= 2;
    }
    memcpy(buffer, start, length);
    buffer[length] = '\0';
    char *scope = strchr(buffer, '%');
    if (scope != NULL) {
        *scope = '\0';
    }

    struct in_addr v4;
    if (inet_pton(AF_INET, buffer, &v4) == 1) {
        return classifyV4(ntohl(v4.s_addr));
    }
    struct in6_addr v6;
    if (inet_pton(AF_INET6, buffer, &v6) == 1) {
        return classifyV6(v6.s6_addr);
    }
    return ArtemisAddrNotAddress;
}

bool ArtemisAddressClassAllowed(ArtemisAddressClass addressClass) {
    switch (addressClass) {
        case ArtemisAddrLoopback:
        case ArtemisAddrPrivate:
        case ArtemisAddrLinkLocal:
        case ArtemisAddrUniqueLocal:
        case ArtemisAddrTailscale:
            return true;
        default:
            return false;
    }
}

bool ArtemisIsTailscaleName(const char *host) {
    static const char suffix[] = ".ts.net";
    if (host == NULL) {
        return false;
    }
    size_t length = strlen(host);
    if (length > 0 && host[length - 1] == '.') {
        length--;
    }
    size_t suffixLength = sizeof(suffix) - 1;
    return length > suffixLength && strncasecmp(host + length - suffixLength, suffix, suffixLength) == 0;
}

// Copies an address's bytes (4 or 16) with any KAME embedded scope cleared, and
// returns its scope ID (0 if none). getifaddrs() reports IPv6 link-local addresses
// with the interface index in bytes 2-3 (fe80:4::1), but getsockname() doesn't.
static int addressBytes(const struct sockaddr *addr, uint8_t bytes[16], uint32_t *scope) {
    *scope = 0;
    if (addr->sa_family == AF_INET) {
        memcpy(bytes, &((const struct sockaddr_in *)addr)->sin_addr, 4);
        return 4;
    }
    if (addr->sa_family == AF_INET6) {
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
        memcpy(bytes, sin6->sin6_addr.s6_addr, 16);
        *scope = sin6->sin6_scope_id;
        if (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80) {
            uint32_t embedded = ((uint32_t)bytes[2] << 8) | bytes[3];
            if (*scope == 0) {
                *scope = embedded;
            }
            bytes[2] = bytes[3] = 0;
        }
        return 16;
    }
    return 0;
}

static bool sameAddress(const struct sockaddr *a, const struct sockaddr *b) {
    uint8_t bytesA[16], bytesB[16];
    uint32_t scopeA, scopeB;
    if (a->sa_family != b->sa_family) {
        return false;
    }
    int length = addressBytes(a, bytesA, &scopeA);
    if (length == 0 || length != addressBytes(b, bytesB, &scopeB)) {
        return false;
    }
    if (scopeA != 0 && scopeB != 0 && scopeA != scopeB) {
        return false;
    }
    return memcmp(bytesA, bytesB, length) == 0;
}

static bool inSubnet(const struct sockaddr *addr, const struct sockaddr *interfaceAddr, const struct sockaddr *netmask) {
    uint8_t a[16], b[16], mask[16];
    uint32_t scope;
    if (netmask == NULL || addr->sa_family != interfaceAddr->sa_family) {
        return false;
    }
    int length = addressBytes(addr, a, &scope);
    if (length == 0 || length != addressBytes(interfaceAddr, b, &scope)) {
        return false;
    }
    // A netmask's sa_family isn't always set, so take its bytes by the address's family
    if (length == 4) {
        memcpy(mask, &((const struct sockaddr_in *)netmask)->sin_addr, 4);
    } else {
        memcpy(mask, ((const struct sockaddr_in6 *)netmask)->sin6_addr.s6_addr, 16);
    }
    for (int i = 0; i < length; i++) {
        if ((a[i] & mask[i]) != (b[i] & mask[i])) {
            return false;
        }
    }
    return true;
}

bool ArtemisAddressInPrefix(const struct sockaddr *addr, const char *cidr) {
    char buffer[INET6_ADDRSTRLEN + 8];
    if (addr == NULL || cidr == NULL || strlen(cidr) >= sizeof(buffer)) {
        return false;
    }
    strcpy(buffer, cidr);
    char *slash = strchr(buffer, '/');
    if (slash == NULL) {
        return false;
    }
    *slash = '\0';
    char *end;
    long bits = strtol(slash + 1, &end, 10);
    if (*end != '\0' || bits < 0) {
        return false;
    }

    uint8_t prefix[16], bytes[16];
    uint32_t scope;
    int length = addressBytes(addr, bytes, &scope);
    if (length == 4 && inet_pton(AF_INET, buffer, prefix) == 1 && bits <= 32) {
        return prefixMatches(bytes, prefix, (int)bits);
    }
    if (length == 16 && inet_pton(AF_INET6, buffer, prefix) == 1 && bits <= 128) {
        return prefixMatches(bytes, prefix, (int)bits);
    }
    return false;
}

static bool isTunnelInterface(const char *name) {
    static const char *const prefixes[] = {"utun", "ipsec", "ppp", "tun", "tap", "gif", "stf", "wg"};
    for (size_t i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); i++) {
        if (strncmp(name, prefixes[i], strlen(prefixes[i])) == 0) {
            return true;
        }
    }
    return false;
}

ArtemisRouteKind ArtemisDecideRoute(const struct sockaddr *dest, const struct sockaddr *local,
                                    const ArtemisInterfaceAddress *ifaces, size_t count,
                                    const char **interfaceName) {
    if (interfaceName != NULL) {
        *interfaceName = NULL;
    }

    ArtemisAddressClass destClass = ArtemisClassifySockaddr(dest);
    if (destClass == ArtemisAddrLoopback) {
        if (interfaceName != NULL) {
            *interfaceName = "lo0";
        }
        return ArtemisRouteLoopback;
    }

    const ArtemisInterfaceAddress *owner = NULL;
    for (size_t i = 0; i < count; i++) {
        if (ifaces[i].addr != NULL && sameAddress(ifaces[i].addr, local)) {
            owner = &ifaces[i];
            break;
        }
    }
    if (owner == NULL) {
        return ArtemisRouteRefused;
    }
    if (interfaceName != NULL) {
        *interfaceName = owner->name;
    }

    if (strncmp(owner->name, "utun", 4) == 0 && ArtemisClassifySockaddr(local) == ArtemisAddrTailscale) {
        switch (destClass) {
            case ArtemisAddrTailscale:
                return ArtemisRouteTailscale;
            case ArtemisAddrPrivate:
            case ArtemisAddrLinkLocal:
            case ArtemisAddrUniqueLocal:
                return ArtemisRouteTailscaleSubnet;
            default:
                // An exit node, which forwards to the internet
                return ArtemisRouteRefused;
        }
    }
    if (isTunnelInterface(owner->name)) {
        return ArtemisRouteRefused;
    }

    // The source interface may have several addresses (IPv4, and IPv6 ones with different prefixes)
    for (size_t i = 0; i < count; i++) {
        if (ifaces[i].addr != NULL && strcmp(ifaces[i].name, owner->name) == 0 &&
            inSubnet(dest, ifaces[i].addr, ifaces[i].netmask)) {
            return ArtemisRouteLAN;
        }
    }
    return ArtemisRouteRefused;
}

int ArtemisCheckRoute(const struct sockaddr *dest, socklen_t destLength, ArtemisRouteKind *kind,
                      char *interfaceName, size_t interfaceNameSize) {
    struct sockaddr_storage target;
    if (destLength > sizeof(target) || (dest->sa_family != AF_INET && dest->sa_family != AF_INET6)) {
        return EAFNOSUPPORT;
    }
    memcpy(&target, dest, destLength);
    // connect() needs a port; any will do since nothing is sent
    if (dest->sa_family == AF_INET) {
        ((struct sockaddr_in *)&target)->sin_port = htons(47984);
    } else {
        ((struct sockaddr_in6 *)&target)->sin6_port = htons(47984);
    }

    // Connecting a UDP socket only picks the route and source address
    int fd = socket(dest->sa_family, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        return errno;
    }
    struct sockaddr_storage local;
    socklen_t localLength = sizeof(local);
    if (connect(fd, (struct sockaddr *)&target, destLength) != 0 ||
        getsockname(fd, (struct sockaddr *)&local, &localLength) != 0) {
        int err = errno;
        close(fd);
        return err;
    }
    close(fd);

    struct ifaddrs *list;
    if (getifaddrs(&list) != 0) {
        return errno;
    }
    size_t count = 0;
    for (struct ifaddrs *ifa = list; ifa != NULL; ifa = ifa->ifa_next) {
        count++;
    }
    ArtemisInterfaceAddress *ifaces = calloc(count > 0 ? count : 1, sizeof(*ifaces));
    if (ifaces == NULL) {
        freeifaddrs(list);
        return ENOMEM;
    }
    size_t used = 0;
    for (struct ifaddrs *ifa = list; ifa != NULL; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == NULL || (ifa->ifa_flags & IFF_UP) == 0 ||
            (ifa->ifa_addr->sa_family != AF_INET && ifa->ifa_addr->sa_family != AF_INET6)) {
            continue;
        }
        ifaces[used].name = ifa->ifa_name;
        ifaces[used].addr = ifa->ifa_addr;
        ifaces[used].netmask = ifa->ifa_netmask;
        used++;
    }

    const char *name = NULL;
    *kind = ArtemisDecideRoute((struct sockaddr *)&target, (struct sockaddr *)&local, ifaces, used, &name);
    if (interfaceName != NULL && interfaceNameSize > 0) {
        snprintf(interfaceName, interfaceNameSize, "%s", name != NULL ? name : "");
    }

    free(ifaces);
    freeifaddrs(list);
    return 0;
}

bool ArtemisTailscaleInterfaceUp(void) {
    struct ifaddrs *list;
    if (getifaddrs(&list) != 0) {
        return false;
    }
    bool up = false;
    for (struct ifaddrs *ifa = list; ifa != NULL && !up; ifa = ifa->ifa_next) {
        up = ifa->ifa_addr != NULL && (ifa->ifa_flags & IFF_UP) != 0 &&
             strncmp(ifa->ifa_name, "utun", 4) == 0 &&
             ArtemisClassifySockaddr(ifa->ifa_addr) == ArtemisAddrTailscale;
    }
    freeifaddrs(list);
    return up;
}
