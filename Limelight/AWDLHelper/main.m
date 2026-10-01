//
//  main.m
//  ArtemisAWDLHelper
//
//  Privileged LaunchDaemon (registered by Artemis with SMAppService) that keeps the
//  AWDL interface (awdl0, used by AirDrop/Continuity) down while Artemis asks it to.
//  AWDL makes the Wi-Fi radio hop channels, which shows up as periodic latency spikes
//  while streaming. macOS brings awdl0 back up on its own, so the helper watches the
//  routing socket and puts it back down. When the last Artemis connection that asked
//  for suppression goes away, awdl0 is brought back up.
//

#import <Foundation/Foundation.h>
#import <os/log.h>

#include <fcntl.h>
#include <net/if.h>
#include <net/route.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#import "ArtemisAWDLHelperProtocol.h"

static const char *kInterfaceName = "awdl0";
// Only Artemis, signed by its developer team, may talk to the helper
static NSString *const kClientRequirement =
    @"identifier \"com.sforkoak.artemis.mac\" and anchor apple generic and certificate leaf[subject.OU] = \"CHD882B8G5\"";

static os_log_t sLog;
static dispatch_queue_t sQueue;

#pragma mark - awdl0

static BOOL GetInterfaceFlags(short *flags) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        return NO;
    }
    struct ifreq ifr = {0};
    strlcpy(ifr.ifr_name, kInterfaceName, sizeof(ifr.ifr_name));
    BOOL ok = ioctl(fd, SIOCGIFFLAGS, &ifr) == 0;
    if (ok) {
        *flags = ifr.ifr_flags;
    }
    close(fd);
    return ok;
}

static BOOL SetInterfaceUp(BOOL up) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        return NO;
    }
    struct ifreq ifr = {0};
    strlcpy(ifr.ifr_name, kInterfaceName, sizeof(ifr.ifr_name));
    BOOL ok = ioctl(fd, SIOCGIFFLAGS, &ifr) == 0;
    if (ok) {
        ifr.ifr_flags = up ? (ifr.ifr_flags | IFF_UP) : (ifr.ifr_flags & ~IFF_UP);
        ok = ioctl(fd, SIOCSIFFLAGS, &ifr) == 0;
    }
    if (!ok) {
        os_log_error(sLog, "Failed to bring %{public}s %{public}s: %{public}s", kInterfaceName, up ? "up" : "down", strerror(errno));
    }
    close(fd);
    return ok;
}

static BOOL IsInterfaceUp(void) {
    short flags = 0;
    return GetInterfaceFlags(&flags) && (flags & IFF_UP) != 0;
}

#pragma mark - Suppression (all state lives on sQueue)

static NSMutableSet<NSXPCConnection *> *sSuppressingClients;
static BOOL sWasUpBeforeSuppression;
static int sRouteSocket = -1;
static dispatch_source_t sRouteSource;
static dispatch_source_t sRecheckTimer;
static dispatch_source_t sIdleExitTimer;

static void PushDownIfUp(const char *reason) {
    if (IsInterfaceUp()) {
        os_log(sLog, "%{public}s came back up (%{public}s); taking it down", kInterfaceName, reason);
        SetInterfaceUp(NO);
    }
}

static void StartSuppressing(void) {
    sWasUpBeforeSuppression = IsInterfaceUp();
    SetInterfaceUp(NO);
    os_log(sLog, "Suppressing %{public}s (was %{public}s)", kInterfaceName, sWasUpBeforeSuppression ? "up" : "down");

    // Interface flag changes arrive as RTM_IFINFO messages on a routing socket
    unsigned int interfaceIndex = if_nametoindex(kInterfaceName);
    sRouteSocket = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC);
    if (sRouteSocket >= 0) {
        fcntl(sRouteSocket, F_SETFL, O_NONBLOCK);
        sRouteSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)sRouteSocket, 0, sQueue);
        int fd = sRouteSocket;
        dispatch_source_set_event_handler(sRouteSource, ^{
            char buffer[4096];
            ssize_t length;
            while ((length = read(fd, buffer, sizeof(buffer))) > 0) {
                for (char *next = buffer; next + sizeof(struct if_msghdr) <= buffer + length;) {
                    struct if_msghdr *message = (struct if_msghdr *)next;
                    if (message->ifm_msglen == 0) {
                        break;
                    }
                    if (message->ifm_type == RTM_IFINFO && message->ifm_index == interfaceIndex && (message->ifm_flags & IFF_UP)) {
                        PushDownIfUp("routing message");
                    }
                    next += message->ifm_msglen;
                }
            }
        });
        dispatch_source_set_cancel_handler(sRouteSource, ^{
            close(fd);
        });
        dispatch_resume(sRouteSource);
    }

    // Backstop in case a routing message is missed
    sRecheckTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sQueue);
    dispatch_source_set_timer(sRecheckTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(sRecheckTimer, ^{
        PushDownIfUp("periodic check");
    });
    dispatch_resume(sRecheckTimer);
}

static void StopSuppressing(void) {
    if (sRouteSource != nil) {
        dispatch_source_cancel(sRouteSource);
        sRouteSource = nil;
        sRouteSocket = -1;
    }
    if (sRecheckTimer != nil) {
        dispatch_source_cancel(sRecheckTimer);
        sRecheckTimer = nil;
    }
    if (sWasUpBeforeSuppression) {
        SetInterfaceUp(YES);
    }
    os_log(sLog, "Stopped suppressing %{public}s; restored it %{public}s", kInterfaceName, sWasUpBeforeSuppression ? "up" : "down");
}

static void ScheduleIdleExit(void) {
    if (sIdleExitTimer != nil) {
        dispatch_source_cancel(sIdleExitTimer);
    }
    // launchd starts the helper again on demand
    sIdleExitTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sQueue);
    dispatch_source_set_timer(sIdleExitTimer, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, NSEC_PER_SEC);
    dispatch_source_set_event_handler(sIdleExitTimer, ^{
        if (sSuppressingClients.count == 0) {
            os_log(sLog, "Idle; exiting");
            exit(0);
        }
    });
    dispatch_resume(sIdleExitTimer);
}

static void SetClientSuppressing(NSXPCConnection *client, BOOL suppressing) {
    BOOL wasSuppressing = sSuppressingClients.count > 0;
    if (suppressing) {
        [sSuppressingClients addObject:client];
    } else {
        [sSuppressingClients removeObject:client];
    }
    BOOL isSuppressing = sSuppressingClients.count > 0;

    if (isSuppressing && !wasSuppressing) {
        StartSuppressing();
    } else if (!isSuppressing && wasSuppressing) {
        StopSuppressing();
        ScheduleIdleExit();
    }
}

#pragma mark - XPC

@interface AWDLHelper : NSObject <NSXPCListenerDelegate, ArtemisAWDLHelperProtocol>
@end

@implementation AWDLHelper

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    [connection setCodeSigningRequirement:kClientRequirement];
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(ArtemisAWDLHelperProtocol)];
    connection.exportedObject = self;

    // A suppressing connection is retained by sSuppressingClients, so the weak reference
    // is only nil for connections that never asked for suppression
    __weak NSXPCConnection *weakConnection = connection;
    connection.invalidationHandler = ^{
        // Artemis quit or crashed: stop suppressing on its behalf
        dispatch_async(sQueue, ^{
            NSXPCConnection *strongConnection = weakConnection;
            if (strongConnection != nil) {
                SetClientSuppressing(strongConnection, NO);
            }
            if (sSuppressingClients.count == 0) {
                ScheduleIdleExit();
            }
        });
    };

    [connection resume];
    return YES;
}

- (void)setAWDLSuppressed:(BOOL)suppressed reply:(void (^)(BOOL))reply {
    NSXPCConnection *client = NSXPCConnection.currentConnection;
    dispatch_async(sQueue, ^{
        SetClientSuppressing(client, suppressed);
        reply(suppressed ? !IsInterfaceUp() : YES);
    });
}

- (void)statusWithReply:(void (^)(BOOL, BOOL))reply {
    dispatch_async(sQueue, ^{
        reply(IsInterfaceUp(), sSuppressingClients.count > 0);
    });
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        sLog = os_log_create("com.sforkoak.artemis", "awdl-helper");
        sQueue = dispatch_queue_create("com.sforkoak.artemis.awdl-helper", DISPATCH_QUEUE_SERIAL);
        sSuppressingClients = [NSMutableSet set];

        AWDLHelper *helper = [[AWDLHelper alloc] init];
        NSXPCListener *listener = [[NSXPCListener alloc] initWithMachServiceName:@ARTEMIS_AWDL_HELPER_MACH_SERVICE];
        listener.delegate = helper;
        [listener resume];

        dispatch_async(sQueue, ^{
            ScheduleIdleExit();
        });
        dispatch_main();
    }
}
