//
//  StreamViewController.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 25/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "TemporaryApp.h"
#import "AppsViewControllerDelegate.h"

@protocol KeyboardNotifiableDelegate <NSObject>

- (BOOL)onKeyboardEquivalent:(NSEvent *)event;

@end

struct Resolution {
   int width;
   int height;
};

@interface StreamViewController : NSViewController
@property (nonatomic, strong) TemporaryApp *app;
@property (nonatomic, weak) id<AppsViewControllerDelegate> delegate;
// Ask Apollo to stream from a virtual display sized to this client
@property (nonatomic) BOOL useVirtualDisplay;

+ (struct Resolution)getResolution;
@end
