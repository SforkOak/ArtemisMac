//
//  AWDLController.h
//  Artemis
//
//  The "Disable AWDL while Artemis is open" feature. AWDL (interface awdl0) powers
//  AirDrop, Handoff, Universal Control, Sidecar and AirPlay to this Mac. It makes the
//  Wi-Fi radio hop channels, which causes periodic latency spikes while streaming.
//  Turning it off needs root, so Artemis registers a small privileged helper with
//  SMAppService. The user approves it once in System Settings > Login Items. The
//  helper restores AWDL as soon as Artemis quits or crashes.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ArtemisAWDLState) {
    ArtemisAWDLStateActive,          // awdl0 is up
    ArtemisAWDLStateDisabled,        // awdl0 is down
    ArtemisAWDLStateNeedsApproval,   // the helper is waiting for approval in System Settings
    ArtemisAWDLStateUnavailable,     // the helper couldn't be registered or reached
};

@interface AWDLController : NSObject

+ (instancetype)shared;

// The user's choice, remembered across launches
@property (nonatomic, readonly) BOOL suppressionEnabled;
@property (nonatomic, readonly) ArtemisAWDLState state;
// Short description of the state for the UI
@property (nonatomic, readonly) NSString *statusText;

// Called on the main queue whenever state or statusText changes
@property (nonatomic, copy, nullable) void (^stateChangedHandler)(void);

// Main thread only
- (void)setSuppressionEnabled:(BOOL)enabled;
// Re-applies the saved choice; call once at launch
- (void)start;

@end

NS_ASSUME_NONNULL_END
