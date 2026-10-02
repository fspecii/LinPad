//
//  ViewController.h
//  iSH
//
//  Created by Theodore Dubois on 10/17/17.
//

#import <UIKit/UIKit.h>
#import "Terminal.h"

@interface TerminalViewController : UIViewController

@property (nonatomic) Terminal *terminal;

- (void)startNewSession;
- (void)reconnectSessionFromTerminalUUID:(NSUUID *)uuid;
@property (readonly) NSUUID *sessionTerminalUUID; // 0 means invalid
@property UISceneSession *sceneSession API_AVAILABLE(ios(13.0));

// Hosted inside a desktop window instead of being a scene's root view controller.
@property (nonatomic) BOOL embedded;
// Replaces UserPreferences.launchCommand for the next session started by this controller.
@property (nonatomic, copy) NSArray<NSString *> *launchCommandOverride;

@end

extern struct tty_driver ios_tty_driver;
