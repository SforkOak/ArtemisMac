//
//  SandboxMigration.m
//  Artemis
//

#import "SandboxMigration.h"
#import "DatabaseSingleton.h"

static NSString *const kMigratedMarker = @".migrated-from-sandbox";

static void CopyIfMissing(NSString *source, NSString *destination) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    if (![fileManager fileExistsAtPath:source] || [fileManager fileExistsAtPath:destination]) {
        return;
    }
    NSError *error = nil;
    if (![fileManager copyItemAtPath:source toPath:destination error:&error]) {
        Log(LOG_E, @"Sandbox migration: couldn't copy %@: %@", source.lastPathComponent, error);
    }
}

void ArtemisMigrateOutOfSandboxContainer(void) {
    @autoreleasepool {
        NSString *bundleId = NSBundle.mainBundle.bundleIdentifier;
        NSString *legacyBundleId = @"com.sforkoak.artemis";
        NSString *container = [NSHomeDirectory() stringByAppendingPathComponent:
                               [NSString stringWithFormat:@"Library/Containers/%@/Data", legacyBundleId]];
        NSString *destination = [DatabaseSingleton applicationSupportDirectory].path;
        NSString *marker = [destination stringByAppendingPathComponent:kMigratedMarker];

        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

        // Preferences: settings profiles, unique ID, window state. Later sources override
        // earlier ones: the legacy ID's sandbox container, then its unsandboxed domain, then
        // anything already set under the current ID.
        static NSString *const kDefaultsMigratedKey = @"migratedLegacyDefaults";
        if (![defaults boolForKey:kDefaultsMigratedKey]) {
            NSMutableDictionary *merged = [NSMutableDictionary dictionary];
            NSString *oldPreferences = [container stringByAppendingPathComponent:
                                        [NSString stringWithFormat:@"Library/Preferences/%@.plist", legacyBundleId]];
            [merged addEntriesFromDictionary:[NSDictionary dictionaryWithContentsOfFile:oldPreferences] ?: @{}];
            [merged addEntriesFromDictionary:[defaults persistentDomainForName:legacyBundleId] ?: @{}];
            [merged addEntriesFromDictionary:[defaults persistentDomainForName:bundleId] ?: @{}];
            merged[kDefaultsMigratedKey] = @YES;
            [defaults setPersistentDomain:merged forName:bundleId];
        }

        if ([fileManager fileExistsAtPath:marker] || ![fileManager fileExistsAtPath:container]) {
            return;
        }

        // Paired hosts and apps (Core Data, including its WAL files)
        NSString *oldDatabaseDirectory = [container stringByAppendingPathComponent:@"Library/Application Support/Moonlight"];
        for (NSString *suffix in @[@"", @"-wal", @"-shm"]) {
            NSString *name = [@"Moonlight_macOS.sqlite" stringByAppendingString:suffix];
            CopyIfMissing([oldDatabaseDirectory stringByAppendingPathComponent:name],
                          [destination stringByAppendingPathComponent:name]);
        }

        // The client identity the hosts paired with
        for (NSString *name in @[@"client.crt", @"client.key", @"client.p12"]) {
            NSString *target = [destination stringByAppendingPathComponent:name];
            CopyIfMissing([[container stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:name], target);
            [fileManager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:target error:nil];
        }

        [[NSData data] writeToFile:marker atomically:YES];
        Log(LOG_I, @"Migrated data out of the sandbox container");
    }
}
