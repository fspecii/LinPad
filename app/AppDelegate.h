//
//  AppDelegate.h
//  iSH
//
//  Created by Theodore Dubois on 10/17/17.
//

#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>

@property (strong, nonatomic) UIWindow *window;
- (void)exitApp;

#if !ISH_LINUX
+ (int)bootError;

/// Where the guest is in starting up. With the desktop, the first launch unpacks the bundled
/// rootfs (and a scheduled system update installs) on a background thread while the
/// desktop's boot splash shows progress; until the phase is Running nothing may touch the
/// kernel (no guest processes, no guest file access).
typedef NS_ENUM(NSInteger, ISHBootPhase) {
    ISHBootPhaseUnpacking,
    ISHBootPhaseConfiguring,
    ISHBootPhaseRunning,
    ISHBootPhaseFailed,
};
+ (ISHBootPhase)bootPhase;
/// The CPU engine after boot: 1 native JIT, 0 gadget engine (JIT compiled in but off: on a
/// device no debugger is attached), -1 this build has no JIT.
+ (NSInteger)jitStatus;
+ (NSString *)bootFailureMessage;
/// Called on the main queue now and on every change. `fraction` is within Unpacking;
/// `title` is e.g. "Unpacking Linux…", `detail` e.g. "312 of 690 MB · 41,230 files".
+ (void)observeBoot:(void (^)(ISHBootPhase phase, double fraction, NSString *title, NSString *detail))observer;

/// Fast mode: the native JIT, enabled by handing off to the user-installed StikDebug app
/// (stikdebug://enable-jit URL scheme, universal.js on TXM devices). With the setting on
/// "automatic" (default), boot waits for it (up to ~20 s), then continues either way.
typedef NS_ENUM(NSInteger, ISHFastModeState) {
    ISHFastModeStateIdle,       ///< not tried (setting off, unavailable, or not yet)
    ISHFastModeStateEnabling,   ///< waiting for StikDebug
    ISHFastModeStateOn,         ///< the JIT runs (fastModeNewProgramsOnly: enabled after boot)
    ISHFastModeStateFailed,     ///< the last attempt failed: fastModeMessage says why
};
extern NSString *const ISHFastModeSettingKey; ///< NSUserDefaults: @"automatic" or @"off"
+ (ISHFastModeState)fastModeState;
+ (NSString *)fastModeMessage;
+ (BOOL)fastModeNewProgramsOnly;
/// nil if fast mode can be requested; otherwise why not (no JIT in this build, no
/// get-task-allow, StikDebug not installed).
+ (NSString *)fastModeUnavailableReason;
/// Whether this installation's signature has get-task-allow, so a debugger can attach.
+ (BOOL)fastModeHasGetTaskAllow;
/// Asks StikDebug again. After boot, only programs started afterwards use the JIT.
+ (void)retryFastMode;
/// Called on the main queue now and on every fast mode change.
+ (void)observeFastMode:(void (^)(void))observer;
#endif

+ (void)maybePresentStartupMessageOnViewController:(UIViewController *)vc;
/// Calls the completion handler iOS passed when it relaunched the app for a background
/// download (the Linux system update), once the session has delivered every event.
+ (void)finishBackgroundURLSessionEvents;

@end

#if !ISH_LINUX
extern NSString *const ProcessExitedNotification;
#else
extern NSString *const KernelPanicNotification;
#endif

