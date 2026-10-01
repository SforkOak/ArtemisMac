//
//  AppsViewController.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 23/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "TemporaryApp.h"
#import "TemporaryHost.h"
#import "HostsViewController.h"
#import "CollectionView.h"

#define CUSTOM_PRIVATE_GFE_PORT (49999)

@interface AppsViewController : NSViewController
@property (nonatomic, strong) TemporaryHost *host;
@property (nonatomic, strong) HostsViewController *hostsVC;
@property (weak) IBOutlet CollectionView *collectionView;

// Launches the app with this Apollo UUID as soon as it's in the app list (art:// launch links)
- (void)launchAppWithUUID:(NSString *)appUUID name:(NSString *)appName;

@end

extern BOOL usesNewAppCoverArtAspectRatio(void);
