//
//  HostsViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "HostsViewController.h"
#import "HostCell.h"
#import "HostCellView.h"
#import "HostsViewControllerDelegate.h"
#import "AppsViewController.h"
#import "AlertPresenter.h"
#import "NSWindow+Moonlight.h"
#import "NSCollectionView+Moonlight.h"
#import "Helpers.h"
#import "NavigatableAlertView.h"

#import "Moonlight-Swift.h"

#import "CryptoManager.h"
#import "IdManager.h"
#import "DiscoveryManager.h"
#import "TemporaryHost.h"
#import "DataManager.h"
#import "PairManager.h"
#import "AWDLController.h"
#import "DeepLinkRouter.h"
#import "WakeOnLanManager.h"
#import "NetworkRoute.h"

@interface HostsViewController () <NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate, NSControlTextEditingDelegate, HostsViewControllerDelegate, DiscoveryCallback, PairCallback, NSMenuItemValidation>
@property (nonatomic, strong) NSArray<TemporaryHost *> *hosts;
@property (nonatomic, strong) TemporaryHost *selectedHost;
@property (nonatomic, strong) NSAlert *pairAlert;
@property (nonatomic) BOOL pairingWithOTP;
@property (nonatomic, strong) NSAlert *addHostManuallyAlert;

@property (nonatomic, strong) NSArray *hostList;
@property (nonatomic) NSSearchField *getSearchField;

@property (nonatomic, strong) NSOperationQueue *opQueue;
@property (nonatomic, strong) DiscoveryManager *discMan;

@property (nonatomic, strong) id deepLinkObserver;
@property (nonatomic, strong) NSSwitch *awdlSwitch;
@property (nonatomic, strong) NSView *awdlStatusDot;
@property (nonatomic, strong) NSTextField *awdlStatusLabel;

@end

@implementation HostsViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    [self.collectionView registerNib:[[NSNib alloc] initWithNibNamed:@"HostCell" bundle:nil] forItemWithIdentifier:@"HostCell"];

    self.hosts = [NSArray array];
    
    [self prepareDiscovery];
    [self installAWDLBar];

    __weak typeof(self) weakSelf = self;
    self.deepLinkObserver = [[NSNotificationCenter defaultCenter] addObserverForName:ArtemisDeepLinkNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [weakSelf handlePendingDeepLink];
    }];
    // A link that launched Artemis arrived before this view existed
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf handlePendingDeepLink];
    });
}


#pragma mark - art:// links

- (void)handlePendingDeepLink {
    NSURL *url = [[DeepLinkRouter shared] takePendingURL];
    if (url == nil) {
        return;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableDictionary<NSString *, NSString *> *query = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) {
        if (item.value != nil) {
            query[item.name] = item.value;
        }
    }

    if ([components.host.lowercaseString isEqualToString:@"launch"]) {
        [self handleLaunchLink:query];
    } else {
        [self handlePairLinkToAddress:components.host port:components.port query:query];
    }
}

- (void)showDeepLinkError:(NSString *)message {
    [AlertPresenter displayAlert:NSAlertStyleWarning title:@"Couldn't Open Link" message:message window:self.view.window completionHandler:nil];
}

// art://HOST:PORT?pin=1234&passphrase=...&name=... from Apollo's OTP pairing page
- (void)handlePairLinkToAddress:(NSString *)address port:(NSNumber *)port query:(NSDictionary<NSString *, NSString *> *)query {
    NSString *pin = query[@"pin"];
    NSString *passphrase = query[@"passphrase"];
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if (address.length == 0 || pin.length != 4 || [pin rangeOfCharacterFromSet:nonDigits].location != NSNotFound || passphrase.length == 0) {
        [self showDeepLinkError:@"This pairing link is incomplete. Generate a new one on Apollo's PIN pairing page."];
        return;
    }
    if (port != nil && port.integerValue != 47989) {
        [self showDeepLinkError:[NSString stringWithFormat:@"ArtemisMac only supports hosts on the default port (47989), but this link uses %@.", port]];
        return;
    }

    void (^pair)(TemporaryHost *) = ^(TemporaryHost *host) {
        if (host.pairState == PairStatePaired) {
            [AlertPresenter displayAlert:NSAlertStyleInformational title:[NSString stringWithFormat:@"Already paired with %@", host.name] message:nil window:self.view.window completionHandler:nil];
            return;
        }
        self.selectedHost = host;
        [self setupPairing:host otpPin:pin passphrase:passphrase];
    };

    TemporaryHost *existing = [self hostWithAddress:address];
    if (existing != nil) {
        pair(existing);
    } else {
        [self addHostWithAddress:address completion:pair];
    }
}

// art://launch?host_uuid=...&app_uuid=...&app_name=... from Apollo's app list
- (void)handleLaunchLink:(NSDictionary<NSString *, NSString *> *)query {
    NSString *hostUUID = query[@"host_uuid"];
    NSString *appUUID = query[@"app_uuid"];
    NSString *hostName = query[@"host_name"] ?: @"this host";
    if (hostUUID.length == 0 || appUUID.length == 0) {
        [self showDeepLinkError:@"This launch link is incomplete."];
        return;
    }

    TemporaryHost *host = nil;
    for (TemporaryHost *candidate in self.hostList ?: self.hosts) {
        if ([candidate.uuid caseInsensitiveCompare:hostUUID] == NSOrderedSame) {
            host = candidate;
            break;
        }
    }
    if (host == nil || host.pairState != PairStatePaired) {
        [self showDeepLinkError:[NSString stringWithFormat:@"Pair with %@ first, then try the link again.", hostName]];
        return;
    }

    for (NSViewController *child in self.parentViewController.childViewControllers) {
        if ([child isKindOfClass:[AppsViewController class]] && child.view.superview != nil) {
            AppsViewController *appsVC = (AppsViewController *)child;
            if (appsVC.host == host) {
                [appsVC launchAppWithUUID:appUUID name:query[@"app_name"]];
            } else {
                [self showDeepLinkError:[NSString stringWithFormat:@"Go back to the host list, then try the link for %@ again.", hostName]];
            }
            return;
        }
    }

    [self transitionToAppsVCWithHost:host launchingAppUUID:appUUID name:query[@"app_name"]];
}

- (TemporaryHost *)hostWithAddress:(NSString *)address {
    for (TemporaryHost *host in self.hostList ?: self.hosts) {
        for (NSString *candidate in @[host.activeAddress ?: @"", host.address ?: @"", host.localAddress ?: @"", host.externalAddress ?: @"", host.ipv6Address ?: @"", host.tailscaleAddress ?: @""]) {
            if ([candidate caseInsensitiveCompare:address] == NSOrderedSame) {
                return host;
            }
        }
    }
    return nil;
}


#pragma mark - AWDL toggle

static NSString *const kAWDLExplainedDefaultsKey = @"awdlTradeoffExplained";

// A bar along the bottom of the host picker with the "Disable AWDL" switch and live status
- (void)installAWDLBar {
    NSVisualEffectView *bar = [[NSVisualEffectView alloc] init];
    bar.material = NSVisualEffectMaterialTitlebar;
    bar.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    NSString *explanation = @"AWDL is the peer-to-peer Wi-Fi link behind AirDrop, Handoff, Universal Control, Sidecar and AirPlay to this Mac. "
                            @"It makes the Wi-Fi radio hop channels, which causes lag spikes while streaming over Wi-Fi. "
                            @"While it's off, those features don't work. AWDL comes back as soon as ArtemisMac quits.";

    self.awdlSwitch = [[NSSwitch alloc] init];
    self.awdlSwitch.controlSize = NSControlSizeSmall;
    self.awdlSwitch.target = self;
    self.awdlSwitch.action = @selector(awdlSwitchChanged:);
    self.awdlSwitch.toolTip = explanation;

    NSTextField *label = [NSTextField labelWithString:@"Disable AWDL while ArtemisMac is open"];
    label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    label.toolTip = explanation;

    self.awdlStatusDot = [[NSView alloc] init];
    self.awdlStatusDot.wantsLayer = YES;
    self.awdlStatusDot.layer.cornerRadius = 4;
    self.awdlStatusDot.translatesAutoresizingMaskIntoConstraints = NO;

    self.awdlStatusLabel = [NSTextField labelWithString:@""];
    self.awdlStatusLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    self.awdlStatusLabel.textColor = NSColor.secondaryLabelColor;
    self.awdlStatusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.awdlStatusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *row = [NSStackView stackViewWithViews:@[self.awdlSwitch, label, self.awdlStatusDot, self.awdlStatusLabel]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    [row setCustomSpacing:16 afterView:label];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:row];
    [self.view addSubview:bar positioned:NSWindowAbove relativeTo:nil];

    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [bar.heightAnchor constraintEqualToConstant:34],
        [row.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:14],
        [row.trailingAnchor constraintLessThanOrEqualToAnchor:bar.trailingAnchor constant:-14],
        [row.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [self.awdlStatusDot.widthAnchor constraintEqualToConstant:8],
        [self.awdlStatusDot.heightAnchor constraintEqualToConstant:8],
    ]];

    __weak typeof(self) weakSelf = self;
    [AWDLController shared].stateChangedHandler = ^{
        [weakSelf updateAWDLBar];
    };
    [self updateAWDLBar];
}

- (void)updateAWDLBar {
    AWDLController *awdl = [AWDLController shared];
    self.awdlSwitch.state = awdl.suppressionEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.awdlStatusLabel.stringValue = awdl.statusText;

    NSColor *color;
    switch (awdl.state) {
        case ArtemisAWDLStateDisabled:
            color = NSColor.systemGreenColor;
            break;
        case ArtemisAWDLStateNeedsApproval:
        case ArtemisAWDLStateUnavailable:
            color = NSColor.systemOrangeColor;
            break;
        case ArtemisAWDLStateActive:
        default:
            color = awdl.suppressionEnabled ? NSColor.systemOrangeColor : NSColor.tertiaryLabelColor;
            break;
    }
    self.awdlStatusDot.layer.backgroundColor = color.CGColor;
}

- (IBAction)awdlSwitchChanged:(NSSwitch *)sender {
    BOOL enable = sender.state == NSControlStateValueOn;

    if (enable && ![NSUserDefaults.standardUserDefaults boolForKey:kAWDLExplainedDefaultsKey]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleInformational;
        alert.messageText = @"Disable AWDL while ArtemisMac is open?";
        alert.informativeText = @"This removes a common cause of Wi-Fi lag spikes. While ArtemisMac is open, AirDrop, Handoff, Universal Control, Sidecar, AirPlay to this Mac and Apple Watch unlock won't work. Everything comes back when ArtemisMac quits.\n\n"
                                @"Turning AWDL off needs a small helper that runs with administrator rights. The first time, macOS asks you to allow it in System Settings › General › Login Items.";
        [alert addButtonWithTitle:@"Disable AWDL"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] != NSAlertFirstButtonReturn) {
            sender.state = NSControlStateValueOff;
            return;
        }
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:kAWDLExplainedDefaultsKey];
    }

    [[AWDLController shared] setSuppressionEnabled:enable];
    [self updateAWDLBar];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    
    self.parentViewController.title = @"ArtemisMac";
    self.parentViewController.view.window.subtitle = [Helpers versionNumberString];

    [self.parentViewController.view.window moonlight_toolbarItemForAction:@selector(addHostButtonClicked:)].enabled = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    [self.parentViewController.view.window moonlight_toolbarItemForAction:@selector(backButtonClicked:)].enabled = NO;
#pragma clang diagnostic pop
    
    self.getSearchField.delegate = self;
    self.getSearchField.placeholderString = @"Search Hosts";
}

- (void)viewDidAppear {
    [super viewDidAppear];
    
    [self.discMan startDiscovery];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    
    [self.discMan stopDiscovery];
}

- (BOOL)becomeFirstResponder {
    [self.view.window makeFirstResponder:self.collectionView];
    return [super becomeFirstResponder];
}

- (void)transitionToAppsVCWithHost:(TemporaryHost *)host {
    [self transitionToAppsVCWithHost:host launchingAppUUID:nil name:nil];
}

- (void)transitionToAppsVCWithHost:(TemporaryHost *)host launchingAppUUID:(NSString *)appUUID name:(NSString *)appName {
    AppsViewController *appsVC = [self.storyboard instantiateControllerWithIdentifier:@"appsVC"];
    appsVC.host = host;
    appsVC.hostsVC = self;
    if (appUUID != nil) {
        [appsVC launchAppWithUUID:appUUID name:appName];
    }
    
    [self.parentViewController addChildViewController:appsVC];
    [self.parentViewController.view addSubview:appsVC.view];
    
    appsVC.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    appsVC.view.frame = self.view.bounds;
    
    [SettingsClass loadMoonlightSettingsFor:host.uuid];
    
    [self.parentViewController.view.window makeFirstResponder:nil];

    [self.parentViewController transitionFromViewController:self toViewController:appsVC options:NSViewControllerTransitionSlideLeft completionHandler:^{
        [self.parentViewController.view.window makeFirstResponder:appsVC];
    }];
}


#pragma mark - NSResponder

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    // Forward validate to collectionView, because for some reason it doesn't get called
    // automatically by the system when expected (even though it's firstResponder).
    return [self.collectionView validateMenuItem:menuItem];
}


#pragma mark - Actions

- (IBAction)wakeMenuItemClicked:(NSMenuItem *)sender {
    TemporaryHost *host = [self getHostFromMenuItem:sender];
    if (host != nil) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [WakeOnLanManager wakeHost:host];
        });
    }
}

- (IBAction)removeHostMenuItemClicked:(NSMenuItem *)sender {
    TemporaryHost *host = [self getHostFromMenuItem:sender];
    if (host != nil) {
        [self.discMan removeHostFromDiscovery:host];
        DataManager* dataMan = [[DataManager alloc] init];
        [dataMan removeHost:host];
        self.hosts = [self.hosts filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id  _Nullable evaluatedObject, NSDictionary<NSString *,id> * _Nullable bindings) {
            return evaluatedObject != host;
        }]];
        [self updateHosts];
    }
}

- (IBAction)showHiddenAppsMenuItemClicked:(NSMenuItem *)sender {
    TemporaryHost *host = [self getHostFromMenuItem:sender];
    if (host != nil) {
        if (sender.state == NSControlStateValueOn) {
            sender.state = NSControlStateValueOff;
            host.showHiddenApps = NO;
        } else {
            sender.state = NSControlStateValueOn;
            host.showHiddenApps = YES;
        }
    }
}

- (IBAction)open:(NSMenuItem *)sender {
    TemporaryHost *host = [self getHostFromMenuItem:sender];
    if (host == nil) {
        if (self.collectionView.selectionIndexes.count != 0) {
            host = self.hosts[self.collectionView.selectionIndexes.firstIndex];
        }
    }
    [self openHost:host];
}

- (IBAction)addHostButtonClicked:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = @"Add Host Manually";
    alert.informativeText = @"If Moonlight doesn't find your local gaming PC automatically,\nenter the IP address of your PC";

    NSTextField *inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    inputField.identifier = @"addHostField";
    inputField.placeholderString = @"IP address";
    inputField.delegate = self;
    [alert setAccessoryView:inputField];

    [alert addButtonWithTitle:@"Add"];
    [alert addButtonWithTitle:@"Cancel"];
    
    alert.buttons.firstObject.enabled = NO;
    
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSAlertFirstButtonReturn) {
            [self addHostManuallyHandlerWithInputValue:inputField.stringValue];
        }
        self.addHostManuallyAlert = nil;
        [self.view.window endSheet:alert.window];
    }];
    [alert.accessoryView becomeFirstResponder];
    
    self.addHostManuallyAlert = alert;
}

- (void)addHostManuallyHandlerWithInputValue:(NSString *)inputValue {
    [self addHostWithAddress:inputValue completion:nil];
}

// Adds a host by address. The completion runs on the main queue with the new host.
- (void)addHostWithAddress:(NSString *)hostAddress completion:(void (^)(TemporaryHost *host))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self.discMan discoverHost:hostAddress withCallback:^(TemporaryHost* host, NSString* error){
            if (host != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    DataManager* dataMan = [[DataManager alloc] init];
                    [dataMan updateHost:host];
                    self.hosts = [self.hosts arrayByAddingObject:host];
                    [self updateHosts];
                    if (completion != nil) {
                        completion(host);
                    }
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [AlertPresenter displayAlert:NSAlertStyleWarning title:@"Add Host Manually" message:error window:self.view.window completionHandler:nil];
                });
            }
        }];
    });
}


#pragma mark - NSCollectionViewDataSource

- (nonnull NSCollectionViewItem *)collectionView:(nonnull NSCollectionView *)collectionView itemForRepresentedObjectAtIndexPath:(nonnull NSIndexPath *)indexPath {
    HostCell *item = [collectionView makeItemWithIdentifier:@"HostCell" forIndexPath:indexPath];
    
    TemporaryHost *host = self.hosts[indexPath.item];
    item.hostName.stringValue = host.name;
    item.host = host;
    item.delegate = self;
    
    return item;
}

- (NSInteger)collectionView:(nonnull NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.hosts.count;
}


#pragma mark - NSCollectionViewDelegate

- (void)collectionView:(NSCollectionView *)collectionView didSelectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths {
}


#pragma mark - NSSearchFieldDelegate, NSControlTextEditingDelegate

- (void)controlTextDidChange:(NSNotification *)obj {
    NSControl *control = (NSControl *)(obj.object);
    if ([control.identifier isEqualToString:@"addHostField"]) {
        self.addHostManuallyAlert.buttons.firstObject.enabled = control.stringValue.length != 0;
    } else {
        [self filterHostsByString:((NSTextField *)obj.object).stringValue];
    }
}


#pragma mark - HostsViewControllerDelegate

- (void)openHost:(TemporaryHost *)host {
    self.selectedHost = host;
    
    if (host.state == StateOnline) {
        if (host.pairState == PairStatePaired) {
            [self transitionToAppsVCWithHost:host];
        } else {
            [self setupPairing:host];
        }
    } else {
        [self handleOfflineHost:host];
    }
}

- (void)didOpenContextMenu:(NSMenu *)menu forHost:(TemporaryHost *)host {
    NSMenuItem *wakeMenuItem = [HostsViewController getMenuItemForIdentifier:@"wakeMenuItem" inMenu:menu];
    NSMenuItem *showHiddenAppsMenuItem = [HostsViewController getMenuItemForIdentifier:@"showHiddenAppsMenuItem" inMenu:menu];
    if (wakeMenuItem != nil) {
        if (host.state == StateOnline) {
            wakeMenuItem.enabled = NO;
        }
    }
    showHiddenAppsMenuItem.state = host.showHiddenApps ? NSControlStateValueOn : NSControlStateValueOff;

    NSMenuItem *otpPairMenuItem = [HostsViewController getMenuItemForIdentifier:@"otpPairMenuItem" inMenu:menu];
    if (otpPairMenuItem == nil) {
        otpPairMenuItem = [[NSMenuItem alloc] initWithTitle:@"Pair with OTP…" action:@selector(otpPairMenuItemClicked:) keyEquivalent:@""];
        otpPairMenuItem.identifier = @"otpPairMenuItem";
        otpPairMenuItem.target = self;
        otpPairMenuItem.image = [NSImage imageWithSystemSymbolName:@"key" accessibilityDescription:nil];
        [menu insertItem:otpPairMenuItem atIndex:0];
    }
    otpPairMenuItem.representedObject = host;
    otpPairMenuItem.hidden = host.pairState == PairStatePaired;
    otpPairMenuItem.enabled = host.state == StateOnline;

    NSMenuItem *permissionsMenuItem = [HostsViewController getMenuItemForIdentifier:@"apolloPermissionsMenuItem" inMenu:menu];
    if (permissionsMenuItem == nil) {
        permissionsMenuItem = [[NSMenuItem alloc] initWithTitle:@"Apollo Permissions…" action:@selector(apolloPermissionsMenuItemClicked:) keyEquivalent:@""];
        permissionsMenuItem.identifier = @"apolloPermissionsMenuItem";
        permissionsMenuItem.target = self;
        permissionsMenuItem.image = [NSImage imageWithSystemSymbolName:@"checkmark.shield" accessibilityDescription:nil];
        [menu addItem:permissionsMenuItem];
    }
    permissionsMenuItem.representedObject = host;
    permissionsMenuItem.hidden = !(host.pairState == PairStatePaired && host.permission >= 0);
}

- (IBAction)apolloPermissionsMenuItemClicked:(NSMenuItem *)item {
    TemporaryHost *host = item.representedObject;
    if (host == nil || host.permission < 0) {
        return;
    }

    uint32_t permission = (uint32_t)host.permission;
    NSArray<NSArray *> *entries = @[
        @[@"Controller input", @(ApolloPermissionInputController)],
        @[@"Touch input", @(ApolloPermissionInputTouch)],
        @[@"Pen input", @(ApolloPermissionInputPen)],
        @[@"Mouse input", @(ApolloPermissionInputMouse)],
        @[@"Keyboard input", @(ApolloPermissionInputKeyboard)],
        @[@"Send clipboard to host", @(ApolloPermissionClipboardSet)],
        @[@"Read host clipboard", @(ApolloPermissionClipboardRead)],
        @[@"Server commands", @(ApolloPermissionServerCommand)],
        @[@"List apps", @(ApolloPermissionListApps)],
        // Launching implies viewing, and viewing implies listing
        @[@"View streams", @(ApolloPermissionViewStreams | ApolloPermissionLaunchApps)],
        @[@"Launch apps", @(ApolloPermissionLaunchApps)],
    ];

    NSMutableString *details = [NSMutableString string];
    for (NSArray *entry in entries) {
        BOOL granted = (permission & [entry[1] unsignedIntValue]) != 0;
        [details appendFormat:@"%@  %@\n", granted ? @"✓" : @"✗", entry[0]];
    }
    [details appendString:@"\nChange these in Apollo's web UI under Clients."];

    [AlertPresenter displayAlert:NSAlertStyleInformational title:[NSString stringWithFormat:@"%@ grants this Mac:", host.name] message:details window:self.view.window completionHandler:nil];
}

- (IBAction)otpPairMenuItemClicked:(NSMenuItem *)item {
    TemporaryHost *host = item.representedObject;
    if (host == nil) {
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = [NSString stringWithFormat:@"Pair with %@ using OTP", host.name];
    alert.informativeText = @"In Apollo's web UI, open the PIN pairing page and choose OTP. Enter the PIN and passphrase it shows.";

    NSTextField *pinField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    pinField.placeholderString = @"4-digit PIN";
    NSSecureTextField *passphraseField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    passphraseField.placeholderString = @"Passphrase";

    NSStackView *fields = [NSStackView stackViewWithViews:@[pinField, passphraseField]];
    fields.orientation = NSUserInterfaceLayoutOrientationVertical;
    fields.spacing = 8;
    fields.frame = NSMakeRect(0, 0, 240, 56);
    alert.accessoryView = fields;

    [alert addButtonWithTitle:@"Pair"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.window.initialFirstResponder = pinField;

    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode != NSAlertFirstButtonReturn) {
            return;
        }

        NSString *pin = [pinField.stringValue trim];
        NSString *passphrase = passphraseField.stringValue;
        NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        if (pin.length != 4 || [pin rangeOfCharacterFromSet:nonDigits].location != NSNotFound || passphrase.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [AlertPresenter displayAlert:NSAlertStyleWarning title:@"Pairing Failed" message:@"Enter the 4-digit PIN and the passphrase shown in Apollo." window:self.view.window completionHandler:nil];
            });
            return;
        }

        self.selectedHost = host;
        [self setupPairing:host otpPin:pin passphrase:passphrase];
    }];
}


#pragma mark - Helpers

- (NSSearchField *)getSearchField {
    return [self.parentViewController.view.window moonlight_searchFieldInToolbar];
}

- (TemporaryHost *)getHostFromMenuItem:(NSMenuItem *)item {
    HostCellView *hostCellView = (HostCellView *)(item.menu.delegate);
    HostCell *hostCell = (HostCell *)(hostCellView.delegate);
    
    return hostCell.host;
}

+ (NSMenuItem *)getMenuItemForIdentifier:(NSString *)id inMenu:(NSMenu *)menu {
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.identifier isEqualToString:id]) {
            return item;
        }
    }
    
    return nil;
}


#pragma mark - Host Discovery

- (void)prepareDiscovery {
    // Set up crypto
    [CryptoManager generateKeyPairUsingSSL];
    
    self.opQueue = [[NSOperationQueue alloc] init];
    
    [self retrieveSavedHosts];
    self.discMan = [[DiscoveryManager alloc] initWithHosts:self.hosts andCallback:self];
}

- (void)retrieveSavedHosts {
    DataManager* dataMan = [[DataManager alloc] init];
    NSArray* hosts = [dataMan getHosts];
    @synchronized(self.hosts) {
        // Sort the host list in alphabetical order
        self.hosts = [hosts sortedArrayUsingSelector:@selector(compareName:)];
        
        // Initialize the non-persistent host state
        for (TemporaryHost* host in self.hosts) {
            // Discovery replaces this with the best allowed address within seconds
            for (NSString *address in @[host.localAddress ?: @"", host.externalAddress ?: @"", host.address ?: @""]) {
                if (host.activeAddress == nil && [NetworkRoute isUsableAddress:address]) {
                    host.activeAddress = address;
                }
            }
        }
    }
}

- (void)updateHosts {
    Log(LOG_I, @"Updating hosts...");
    @synchronized (self.hosts) {
        // Sort the host list in alphabetical order
        self.hosts = [self.hosts sortedArrayUsingSelector:@selector(compareName:)];
        self.hostList = self.hosts;
        [self.collectionView moonlight_reloadDataKeepingSelection];
    }
}

- (void)filterHostsByString:(NSString *)filterString {
    NSPredicate *predicate;
    if (filterString.length != 0) {
        predicate = [NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@", filterString];
    } else {
        predicate = [NSPredicate predicateWithValue:YES];
    }
    NSArray<TemporaryHost *> *filteredHosts = [self.hostList filteredArrayUsingPredicate:predicate];
    self.hosts = [filteredHosts sortedArrayUsingSelector:@selector(compareName:)];

    [self.collectionView reloadData];
}


#pragma mark - Host Operations

- (void)setupPairing:(TemporaryHost *)host {
    [self setupPairing:host otpPin:nil passphrase:nil];
}

- (void)setupPairing:(TemporaryHost *)host otpPin:(NSString *)otpPin passphrase:(NSString *)passphrase {
    // Polling the server while pairing causes the server to screw up
    [self.discMan stopDiscoveryBlocking];

    NSString *uniqueId = [IdManager getUniqueId];
    NSData *cert = [CryptoManager readCertFromFile];

    HttpManager* hMan = [[HttpManager alloc] initWithHost:host.activeAddress uniqueId:uniqueId serverCert:host.serverCert];
    PairManager* pMan;
    if (otpPin != nil && passphrase != nil) {
        self.pairingWithOTP = YES;
        pMan = [[PairManager alloc] initWithManager:hMan clientCert:cert otpPin:otpPin passphrase:passphrase callback:self];
    } else {
        self.pairingWithOTP = NO;
        pMan = [[PairManager alloc] initWithManager:hMan clientCert:cert callback:self];
    }
    [self.opQueue addOperation:pMan];
}

- (void)handleOfflineHost:(TemporaryHost *)host {
    NSAlert *alert = [[NSAlert alloc] init];

    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = [NSString stringWithFormat:@"%@ is offline, do you want to try and wake it?", host.name];
    [alert addButtonWithTitle:@"Wake"];
    [alert addButtonWithTitle:@"Cancel"];

    NavigatableAlertView *alertView = [[NavigatableAlertView alloc] init];
    alertView.responder = alert.window;
    [self.view addSubview:alertView];
    [self.view.window makeFirstResponder:alertView];
    
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
        switch (returnCode) {
            case NSAlertFirstButtonReturn:
                [WakeOnLanManager wakeHost:host];
    
                [alertView removeFromSuperview];
                [self.view.window makeFirstResponder:self];
                break;
            case NSAlertSecondButtonReturn:
                [self.view.window endSheet:alert.window];

                [alertView removeFromSuperview];
                [self.view.window makeFirstResponder:self];
                break;
        }
    }];
}


#pragma mark - DiscoveryCallback

- (void)updateAllHosts:(NSArray<TemporaryHost *> *)hosts {
    dispatch_async(dispatch_get_main_queue(), ^{
        Log(LOG_D, @"New host list:");
        for (TemporaryHost* host in hosts) {
            Log(LOG_D, @"Host: \n{\n\t name:%@ \n\t address:%@ \n\t localAddress:%@ \n\t externalAddress:%@ \n\t uuid:%@ \n\t mac:%@ \n\t pairState:%d \n\t online:%d \n\t activeAddress:%@ \n}", host.name, host.address, host.localAddress, host.externalAddress, host.uuid, host.mac, host.pairState, host.state, host.activeAddress);
        }
        @synchronized(self.hosts) {
            self.hosts = hosts;
        }
        
        [self updateHosts];
    });
}


#pragma mark - PairCallback

- (void)startPairing:(NSString *)PIN {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *title = self.pairingWithOTP
            ? [NSString stringWithFormat:@"Pairing with %@…", self.selectedHost.name]
            : [NSString stringWithFormat:@"Enter the following PIN on %@: %@", self.selectedHost.name, PIN];
        self.pairAlert = [AlertPresenter displayAlert:NSAlertStyleInformational title:title message:nil window:self.view.window completionHandler:nil];
    });
}

- (void)pairSuccessful:(NSData *)serverCert {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.selectedHost.serverCert = serverCert;
        
        [self.view.window endSheet:self.pairAlert.window];
        [self.discMan startDiscovery];
        [self alreadyPaired];
    });
}

- (void)pairFailed:(NSString*)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pairAlert != nil) {
            [self.view.window endSheet:self.pairAlert.window];
            self.pairAlert = nil;
        }
        [AlertPresenter displayAlert:NSAlertStyleWarning title:[NSString stringWithFormat:@"Pairing Failed"] message:message window:self.view.window completionHandler:nil];
        [self->_discMan startDiscovery];
    });
}

- (void)alreadyPaired {
    [self transitionToAppsVCWithHost:self.selectedHost];
}

@end
