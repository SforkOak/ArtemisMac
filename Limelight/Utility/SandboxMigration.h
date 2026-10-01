//
//  SandboxMigration.h
//  Artemis
//
//  Artemis used to run in the App Sandbox (inherited from Moonlight for macOS) as
//  com.sforkoak.artemis. It no longer does, so the AWDL helper can be registered, and it
//  has a new bundle ID (com.sforkoak.artemis.mac): macOS treats any bundle ID that ever
//  had a sandbox container as sandboxed when registering helpers. On first launch this
//  copies the paired-host database, the client certificate and key, and the preferences
//  over, so nothing has to be re-paired.
//

#import <Foundation/Foundation.h>

void ArtemisMigrateOutOfSandboxContainer(void);
