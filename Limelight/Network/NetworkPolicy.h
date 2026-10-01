//
//  NetworkPolicy.h
//  Artemis
//
//  Which networks ArtemisMac may reach a host over. By default a stream may only use
//  the local network or Tailscale, never the open internet. Kept free of Objective-C
//  so it can be unit tested (see Tests/run-tests.sh).
//

#ifndef ArtemisNetworkPolicy_h
#define ArtemisNetworkPolicy_h

#include <stdbool.h>
#include <stddef.h>
#include <sys/socket.h>

typedef enum {
    ArtemisAddrNotAddress = 0, // not a numeric IP address (a host name)
    ArtemisAddrLoopback,       // 127.0.0.0/8, ::1
    ArtemisAddrPrivate,        // RFC 1918: 10/8, 172.16/12, 192.168/16
    ArtemisAddrLinkLocal,      // 169.254/16, fe80::/10
    ArtemisAddrUniqueLocal,    // fc00::/7, except Tailscale's
    // 100.64.0.0/10 and fd7a:115c:a1e0::/48. 100.64/10 is also carrier-grade NAT space,
    // so only the route check (ArtemisDecideRoute) can tell Tailscale from an ISP's CGNAT.
    ArtemisAddrTailscale,
    ArtemisAddrInternet,       // everything else
} ArtemisAddressClass;

ArtemisAddressClass ArtemisClassifySockaddr(const struct sockaddr *addr);

// Classifies a numeric IPv4 or IPv6 address (an IPv6 one may carry a %scope).
// Returns ArtemisAddrNotAddress for host names.
ArtemisAddressClass ArtemisClassifyHost(const char *host);

// Local network and Tailscale classes
bool ArtemisAddressClassAllowed(ArtemisAddressClass addressClass);

// A Tailscale MagicDNS name (*.ts.net, with or without a trailing dot)
bool ArtemisIsTailscaleName(const char *host);

// Whether addr is inside a CIDR prefix such as "192.168.19.0/24" or "fd7a:115c:a1e0::/48"
bool ArtemisAddressInPrefix(const struct sockaddr *addr, const char *cidr);

typedef enum {
    ArtemisRouteRefused = 0,     // through a gateway or another VPN: the open internet
    ArtemisRouteLAN,             // on-link: in the subnet of a non-tunnel interface
    ArtemisRouteTailscale,       // through Tailscale to a tailnet address
    ArtemisRouteTailscaleSubnet, // through Tailscale to a LAN address behind a subnet router
    ArtemisRouteLoopback,        // this Mac
} ArtemisRouteKind;

typedef struct {
    const char *name;               // e.g. "en0", "utun7"
    const struct sockaddr *addr;
    const struct sockaddr *netmask; // may be NULL
} ArtemisInterfaceAddress;

// Decides how traffic to dest would leave this Mac. local is the source address the
// kernel picked for dest (getsockname() on a connected UDP socket) and ifaces lists
// the interface addresses (getifaddrs()). Tailscale needs both a Tailscale source
// address and a utun interface; a LAN route needs dest inside the subnet of the
// (non-tunnel) interface that owns the source address. Sets *interfaceName to the
// owning interface's name when found.
ArtemisRouteKind ArtemisDecideRoute(const struct sockaddr *dest, const struct sockaddr *local,
                                    const ArtemisInterfaceAddress *ifaces, size_t count,
                                    const char **interfaceName);

// Asks the kernel how it would route to dest, without sending anything, and decides
// with ArtemisDecideRoute. Returns 0, or an errno such as ENETUNREACH when there's no route.
int ArtemisCheckRoute(const struct sockaddr *dest, socklen_t destLength, ArtemisRouteKind *kind,
                      char *interfaceName, size_t interfaceNameSize);

// Whether a Tailscale interface (a utun with a Tailscale address) is up
bool ArtemisTailscaleInterfaceUp(void);

#endif
