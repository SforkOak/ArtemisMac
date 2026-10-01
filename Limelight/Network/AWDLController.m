//
//  AWDLController.m
//  Artemis
//

#import "AWDLController.h"
#import "ArtemisAWDLHelperProtocol.h"

#import <ServiceManagement/ServiceManagement.h>
#include <ifaddrs.h>
#include <net/if.h>

static NSString *const kSuppressAWDLDefaultsKey = @"suppressAWDL";
// Make sure we're talking to our own helper, signed by the same team
static NSString *const kHelperRequirement =
    @"identifier \"com.sforkoak.artemis.awdl-helper\" and anchor apple generic and certificate leaf[subject.OU] = \"CHD882B8G5\"";

@interface AWDLController ()
@property (nonatomic, readwrite) ArtemisAWDLState state;
@property (nonatomic, readwrite, copy) NSString *statusText;
@end

@implementation AWDLController {
    NSXPCConnection *_connection;
    NSTimer *_pollTimer;
    BOOL _helperSuppressing;
    NSString *_lastError;
}

+ (instancetype)shared {
    static AWDLController *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[AWDLController alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _statusText = @"";
        _state = ArtemisAWDLStateActive;
    }
    return self;
}

- (BOOL)suppressionEnabled {
    return [NSUserDefaults.standardUserDefaults boolForKey:kSuppressAWDLDefaultsKey];
}

- (SMAppService *)helperService {
    return [SMAppService daemonServiceWithPlistName:@ARTEMIS_AWDL_HELPER_PLIST];
}

- (void)start {
    if (_pollTimer != nil) {
        return;
    }
    // Picks up approval in System Settings, and macOS turning AWDL back on
    __weak typeof(self) weakSelf = self;
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refresh];
    }];
    if (self.suppressionEnabled) {
        [self registerHelperOpeningSettingsIfNeeded:NO];
    }
    [self refresh];
}

// Returns NO if registration failed outright
- (BOOL)registerHelperOpeningSettingsIfNeeded:(BOOL)openSettings {
    SMAppService *service = [self helperService];
    if (service.status == SMAppServiceStatusEnabled) {
        return YES;
    }

    NSError *error = nil;
    if (![service registerAndReturnError:&error] && service.status != SMAppServiceStatusRequiresApproval) {
        Log(LOG_E, @"Couldn't register the AWDL helper: %@", error);
        _lastError = error.localizedDescription;
        return NO;
    }
    if (service.status == SMAppServiceStatusRequiresApproval && openSettings) {
        [SMAppService openSystemSettingsLoginItems];
    }
    return YES;
}

- (void)setSuppressionEnabled:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kSuppressAWDLDefaultsKey];
    _lastError = nil;

    if (enabled) {
        [self registerHelperOpeningSettingsIfNeeded:YES];
    } else {
        [self tellHelperToSuppress:NO];
    }
    [self refresh];
}

- (void)refresh {
    if (self.suppressionEnabled && !_helperSuppressing && [self helperService].status == SMAppServiceStatusEnabled) {
        [self tellHelperToSuppress:YES];
    }
    [self updateState];
}


#pragma mark - Helper connection

- (NSXPCConnection *)connection {
    if (_connection == nil) {
        _connection = [[NSXPCConnection alloc] initWithMachServiceName:@ARTEMIS_AWDL_HELPER_MACH_SERVICE options:NSXPCConnectionPrivileged];
        _connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(ArtemisAWDLHelperProtocol)];
        [_connection setCodeSigningRequirement:kHelperRequirement];

        __weak typeof(self) weakSelf = self;
        _connection.invalidationHandler = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (strongSelf != nil) {
                    strongSelf->_connection = nil;
                    strongSelf->_helperSuppressing = NO;
                }
            });
        };
        // The helper exited and restored AWDL; the next refresh asks again if still wanted
        _connection.interruptionHandler = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (strongSelf != nil) {
                    strongSelf->_helperSuppressing = NO;
                }
            });
        };
        [_connection resume];
    }
    return _connection;
}

- (void)tellHelperToSuppress:(BOOL)suppress {
    if (!suppress && _connection == nil) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    id<ArtemisAWDLHelperProtocol> helper = [[self connection] remoteObjectProxyWithErrorHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf != nil) {
                Log(LOG_W, @"AWDL helper error: %@", error);
                strongSelf->_helperSuppressing = NO;
                strongSelf->_lastError = error.localizedDescription;
                [strongSelf updateState];
            }
        });
    }];

    // Set first so the poll timer doesn't ask again while the reply is in flight
    _helperSuppressing = suppress;
    [helper setAWDLSuppressed:suppress reply:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf->_lastError = nil;
            if (!suppress) {
                // Dropping the connection also tells the helper we're done
                [strongSelf->_connection invalidate];
                strongSelf->_connection = nil;
            }
            [strongSelf updateState];
        });
    }];
}


#pragma mark - State

static BOOL IsAWDLUp(void) {
    struct ifaddrs *addresses = NULL;
    if (getifaddrs(&addresses) != 0) {
        return NO;
    }
    BOOL up = NO;
    for (struct ifaddrs *address = addresses; address != NULL; address = address->ifa_next) {
        if (strcmp(address->ifa_name, "awdl0") == 0 && (address->ifa_flags & IFF_UP)) {
            up = YES;
            break;
        }
    }
    freeifaddrs(addresses);
    return up;
}

- (void)updateState {
    BOOL wanted = self.suppressionEnabled;
    SMAppServiceStatus status = [self helperService].status;
    BOOL up = IsAWDLUp();

    ArtemisAWDLState state;
    NSString *text;
    if (wanted && status == SMAppServiceStatusRequiresApproval) {
        state = ArtemisAWDLStateNeedsApproval;
        text = @"Allow Artemis in System Settings › Login Items";
    } else if (wanted && _lastError != nil) {
        state = ArtemisAWDLStateUnavailable;
        text = [NSString stringWithFormat:@"Helper unavailable: %@", _lastError];
    } else if (!up) {
        state = ArtemisAWDLStateDisabled;
        text = @"AWDL is off";
    } else {
        state = ArtemisAWDLStateActive;
        text = wanted ? @"Turning AWDL off…" : @"AWDL is on (can cause Wi-Fi lag spikes)";
    }

    if (state != self.state || ![text isEqualToString:self.statusText]) {
        self.state = state;
        self.statusText = text;
        if (self.stateChangedHandler != nil) {
            self.stateChangedHandler();
        }
    }
}

@end
