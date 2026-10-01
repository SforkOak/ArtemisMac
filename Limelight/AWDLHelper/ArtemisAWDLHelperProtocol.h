//
//  ArtemisAWDLHelperProtocol.h
//  Artemis
//
//  XPC interface between Artemis and its privileged AWDL helper. The helper can do
//  exactly two things: keep awdl0 down while a connected Artemis asks it to, and
//  report the interface's state. Shared by the app and the helper.
//

#import <Foundation/Foundation.h>

#define ARTEMIS_AWDL_HELPER_MACH_SERVICE "com.sforkoak.artemis.awdl-helper"
#define ARTEMIS_AWDL_HELPER_PLIST "com.sforkoak.artemis.awdl-helper.plist"

NS_ASSUME_NONNULL_BEGIN

@protocol ArtemisAWDLHelperProtocol

// While suppressed, the helper keeps awdl0 down, putting it back down whenever macOS
// brings it up. Suppression ends, and awdl0 is restored, when the caller asks or
// when its connection goes away (Artemis quits or crashes).
- (void)setAWDLSuppressed:(BOOL)suppressed reply:(void (^)(BOOL success))reply;

- (void)statusWithReply:(void (^)(BOOL awdlUp, BOOL suppressed))reply;

@end

NS_ASSUME_NONNULL_END
