//
//  TemporaryHost.h
//  Moonlight
//
//  Created by Cameron Gutman on 12/1/15.
//  Copyright © 2015 Moonlight Stream. All rights reserved.
//

#import "Utils.h"
#import "Host+CoreDataClass.h"

// Apollo client permission bits (crypto::PERM in Apollo's src/crypto.h)
typedef NS_OPTIONS(uint32_t, ApolloPermission) {
    ApolloPermissionInputController = 1 << 8,
    ApolloPermissionInputTouch      = 1 << 9,
    ApolloPermissionInputPen        = 1 << 10,
    ApolloPermissionInputMouse      = 1 << 11,
    ApolloPermissionInputKeyboard   = 1 << 12,
    ApolloPermissionClipboardSet    = 1 << 16,
    ApolloPermissionClipboardRead   = 1 << 17,
    ApolloPermissionFileUpload      = 1 << 18,
    ApolloPermissionFileDownload    = 1 << 19,
    ApolloPermissionServerCommand   = 1 << 20,
    ApolloPermissionListApps        = 1 << 24,
    ApolloPermissionViewStreams     = 1 << 25,
    ApolloPermissionLaunchApps      = 1 << 26,
};

@interface TemporaryHost : NSObject

@property (atomic) State state;
@property (atomic) PairState pairState;
@property (atomic, nullable, retain) NSString * activeAddress;
@property (atomic, nullable, retain) NSString * currentGame;

@property (nonatomic) BOOL showHiddenApps;

@property (atomic, nullable, retain) NSData *serverCert;
@property (atomic, nullable, retain) NSString *address;
@property (atomic, nullable, retain) NSString *externalAddress;
@property (atomic, nullable, retain) NSString *localAddress;
@property (atomic, nullable, retain) NSString *ipv6Address;
@property (atomic, nullable, retain) NSString *mac;
@property (atomic)                   int serverCodecModeSupport;

// Apollo extensions reported in serverinfo. These are transient and refreshed on every poll.
// permission is the Apollo permission bitmask (see ApolloPermission), or -1 if the host didn't report one.
@property (atomic)                   int permission;
@property (atomic)                   BOOL virtualDisplayCapable;
@property (atomic)                   BOOL virtualDisplayDriverReady;
// Names of the host's server commands; a command's index here is its ID for LiSendExecServerCmd()
@property (atomic, nonnull, retain)  NSArray<NSString*> *serverCommands;
// YES when the host reports Apollo's extensions, so Apollo-only features can be offered
@property (atomic, readonly)         BOOL isApollo;

NS_ASSUME_NONNULL_BEGIN

@property (atomic, retain) NSString *name;
@property (atomic, retain) NSString *uuid;
@property (atomic, retain) NSSet *appList;

- (id) initFromHost:(Host*)host;

- (NSComparisonResult)compareName:(TemporaryHost *)other;

- (void) propagateChangesToParent:(Host*)host;

NS_ASSUME_NONNULL_END

@end
