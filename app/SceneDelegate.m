//
//  SceneDelegate.m
//  iSH
//
//  Created by Theodore Dubois on 10/26/19.
//

#import "SceneDelegate.h"
#import "AboutViewController.h"
#import "AppDelegate.h"

TerminalViewController *currentTerminalViewController = NULL;

@interface SceneDelegate ()

@property NSString *terminalUUID;
// The scene went away; a session start still waiting for Linux to boot is dropped.
@property BOOL disconnected;

@end

static NSString *const TerminalUUID = @"TerminalUUID";

// Implemented in Swift (app/Desktop/DesktopBridge.swift) and looked up at runtime,
// because this file is also compiled into targets that don't link DesktopKit.
@protocol ISHDesktopBridge
+ (BOOL)isEnabled;
+ (UIViewController *)makeRootViewController;
@optional
+ (BOOL)openURL:(NSURL *)url;
@end

static Class<ISHDesktopBridge> DesktopBridgeIfEnabled(void) {
    Class bridge = NSClassFromString(@"DesktopBridge");
    if (![bridge respondsToSelector:@selector(isEnabled)] || ![bridge respondsToSelector:@selector(makeRootViewController)])
        return nil;
    Class<ISHDesktopBridge> desktop = bridge;
    return [desktop isEnabled] ? desktop : nil;
}

/// Runs block on the main queue once Linux runs (or failed to boot). Fast mode boots it only
/// after StikDebug has enabled the JIT, after the scene connects.
static void WhenBooted(void (^block)(void)) {
    ISHBootPhase phase = AppDelegate.bootPhase;
    if (phase == ISHBootPhaseRunning || phase == ISHBootPhaseFailed) {
        block();
        return;
    }
    __block BOOL done = NO;
    [AppDelegate observeBoot:^(ISHBootPhase phase, double fraction, NSString *title, NSString *detail) {
        if (done || (phase != ISHBootPhaseRunning && phase != ISHBootPhaseFailed))
            return;
        done = YES;
        dispatch_async(dispatch_get_main_queue(), block);
    }];
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
        [self openURLContexts:connectionOptions.URLContexts];
        return;
    }

    TerminalViewController *vc = (TerminalViewController *) self.window.rootViewController;
    if (![vc isKindOfClass:TerminalViewController.class])
        return;
    vc.sceneSession = session;
    NSUserActivity *restored = session.stateRestorationActivity;
    // Boot observers are never removed, so hold the scene weakly: one that disconnects while
    // fast mode waits for StikDebug is released, and starts no shell nobody can see.
    __weak SceneDelegate *weakSelf = self;
    __weak TerminalViewController *weakTerminal = vc;
    WhenBooted(^{
        SceneDelegate *scene = weakSelf;
        TerminalViewController *terminal = weakTerminal;
        if (scene == nil || terminal == nil || scene.disconnected)
            return;
        if (restored == nil) {
            [terminal startNewSession];
        } else {
            scene.terminalUUID = restored.userInfo[TerminalUUID];
            [terminal reconnectSessionFromTerminalUUID:
             [[NSUUID alloc] initWithUUIDString:scene.terminalUUID]];
        }
    });
}

/// linpad:// links go to the desktop, which asks before acting on them.
- (void)openURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    Class<ISHDesktopBridge> desktop = DesktopBridgeIfEnabled();
    if (desktop == nil || ![(Class) desktop respondsToSelector:@selector(openURL:)])
        return;
    for (UIOpenURLContext *context in contexts)
        [desktop openURL:context.URL];
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    [self openURLContexts:URLContexts];
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

- (void)sceneDidDisconnect:(UIScene *)scene {
    self.disconnected = YES;
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
