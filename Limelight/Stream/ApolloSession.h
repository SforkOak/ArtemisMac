//
//  ApolloSession.h
//  Artemis
//
//  Apollo-only behaviour for one streaming session: the Wi-Fi keepalive,
//  clipboard sync and server commands.
//

#import <Foundation/Foundation.h>
#import "TemporaryHost.h"

NS_ASSUME_NONNULL_BEGIN

@interface ApolloSession : NSObject

// Settings are read from the host's settings profile when the session is created.
- (instancetype)initWithHost:(TemporaryHost *)host;

// Call once the stream is connected, and before disconnecting (LiStopConnection).
- (void)streamStarted;
- (void)streamWillStop;

// Automatic clipboard sync, driven by the stream window's key state
- (void)streamWindowDidBecomeKey;
- (void)streamWindowDidResignKey;

// Manual clipboard actions. The completion runs on the main queue with nil on
// success, or a message to show the user.
- (void)sendClipboardWithCompletion:(nullable void (^)(NSString *_Nullable error))completion;
- (void)fetchClipboardWithCompletion:(nullable void (^)(NSString *_Nullable error))completion;

- (NSArray<NSString *> *)serverCommands;
// Returns NO if the command couldn't be sent
- (BOOL)executeServerCommandAtIndex:(NSUInteger)index;

@end

NS_ASSUME_NONNULL_END
