//
//  main.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>
#import "SandboxMigration.h"
#import "ArtemisAWDLHelperProtocol.h"

int main(int argc, const char * argv[]) {
    // `Artemis --unregister-awdl-helper` removes the privileged AWDL helper (for uninstalling)
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--unregister-awdl-helper") == 0) {
            NSError *error = nil;
            BOOL ok = [[SMAppService daemonServiceWithPlistName:@ARTEMIS_AWDL_HELPER_PLIST] unregisterAndReturnError:&error];
            fprintf(stderr, "%s\n", ok ? "Unregistered the AWDL helper" : error.localizedDescription.UTF8String);
            return ok ? 0 : 1;
        }
    }

    // Must run before anything opens the database, the client certificate or the defaults
    ArtemisMigrateOutOfSandboxContainer();
    return NSApplicationMain(argc, argv);
}
