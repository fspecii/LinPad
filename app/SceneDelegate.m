//
//  SceneDelegate.m
//  iSH
//
//  Created by Theodore Dubois on 10/26/19.
//

#import "SceneDelegate.h"
#import "AboutViewController.h"

TerminalViewController *currentTerminalViewController = NULL;

@interface SceneDelegate ()

@property NSString *terminalUUID;

@end

static NSString *const TerminalUUID = @"TerminalUUID";

// Implemented in Swift (app/Desktop/DesktopBridge.swift) and looked up at runtime,
// because this file is also compiled into targets that don't link DesktopKit.
@protocol ISHDesktopBridge
+ (BOOL)isEnabled;
+ (UIViewController *)makeRootViewController;
@end

static Class<ISHDesktopBridge> DesktopBridgeIfEnabled(void) {
    Class bridge = NSClassFromString(@"DesktopBridge");
    if (![bridge respondsToSelector:@selector(isEnabled)] || ![bridge respondsToSelector:@selector(makeRootViewController)])
        return nil;
    Class<ISHDesktopBridge> desktop = bridge;
    return [desktop isEnabled] ? desktop : nil;
}

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"recovery"]) {
        UINavigationController *vc = [[UIStoryboard storyboardWithName:@"About" bundle:nil] instantiateInitialViewController];
        AboutViewController *avc = (AboutViewController *) vc.topViewController;
        avc.recoveryMode = YES;
        self.window.rootViewController = vc;
        return;
    }

    Class<ISHDesktopBridge> desktop = DesktopBridgeIfEnabled();
    if (desktop != nil) {
        self.window.rootViewController = [desktop makeRootViewController];
        return;
    }

    TerminalViewController *vc = (TerminalViewController *) self.window.rootViewController;
    if (![vc isKindOfClass:TerminalViewController.class])
        return;
    vc.sceneSession = session;
    if (session.stateRestorationActivity == nil) {
        [vc startNewSession];
    } else {
        self.terminalUUID = session.stateRestorationActivity.userInfo[TerminalUUID];
        [vc reconnectSessionFromTerminalUUID:
         [[NSUUID alloc] initWithUUIDString:self.terminalUUID]];
    }
}

- (NSUserActivity *)stateRestorationActivityForScene:(UIScene *)scene {
    NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:@"app.ish.scene"];
    TerminalViewController *vc = (TerminalViewController *) self.window.rootViewController;
    if ([vc isKindOfClass:TerminalViewController.class]) {
        self.terminalUUID = vc.sessionTerminalUUID.UUIDString;
        if (self.terminalUUID != nil) {
            [activity addUserInfoEntriesFromDictionary:@{TerminalUUID: self.terminalUUID}];
        }
    }
    return activity;
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    TerminalViewController *terminalViewController = (TerminalViewController *) self.window.rootViewController;
    if (![terminalViewController isKindOfClass:TerminalViewController.class])
        return;
    currentTerminalViewController = terminalViewController;
}

- (void)sceneWillResignActive:(UIScene *)scene {
    TerminalViewController *terminalViewController = (TerminalViewController *) self.window.rootViewController;
    if (![terminalViewController isKindOfClass:TerminalViewController.class])
        return;

    if (currentTerminalViewController == terminalViewController) {
        currentTerminalViewController = NULL;
    }
}

@end
