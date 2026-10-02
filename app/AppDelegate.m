//
//  AppDelegate.m
//  iSH
//
//  Created by Theodore Dubois on 10/17/17.
//

#include <dlfcn.h>
#include <sys/stat.h>
#include <resolv.h>
#include <arpa/inet.h>
#include <netdb.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import "AboutViewController.h"
#import "AppDelegate.h"
#import "AppGroup.h"
#import "CurrentRoot.h"
#import "ExceptionExfiltrator.h"
#import "iOSFS.h"
#import "SceneDelegate.h"
#import "PasteboardDevice.h"
#import "LocationDevice.h"
#import "NSObject+SaneKVO.h"
#import "Roots.h"
#import "TerminalViewController.h"
#import "UserPreferences.h"
#import "UIApplication+OpenURL.h"
#include "kernel/init.h"
#include "kernel/calls.h"
#include "fs/dyndev.h"
#include "fs/devices.h"
#include "fs/path.h"
#if defined(GUEST_ARM64) && defined(DEBUG)
#include "DebugServer.h"
#endif
#include "kernel/native_offload.h"
#ifdef ISH_FFMPEG_TEST
extern void native_builtins_init(void);
#endif

#if ISH_LINUX
#import "LinuxInterop.h"
#endif

@interface AppDelegate ()

@property BOOL exiting;
@property SCNetworkReachabilityRef reachability;

@end

#if !ISH_LINUX
static void ios_handle_exit(struct task *task, int code) {
    // we are interested in init and in children of init
    // this is called with pids_lock as an implementation side effect, please do not cite as an example of good API design
    if (task->parent != NULL && task->parent->parent != NULL)
        return;
    // pid should be saved now since task would be freed
    pid_t pid = task->pid;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ProcessExitedNotification
                                                            object:nil
                                                          userInfo:@{@"pid": @(pid),
                                                                     @"code": @(code)}];
    });
}

static void ios_handle_die(const char *msg) {
    NSString *message = [NSString stringWithFormat:@"%s: %s", __func__, msg];
    iSHExceptionHandler([[NSException alloc] initWithName:NSGenericException reason:message userInfo:nil]);
}
#elif ISH_LINUX
void ReportPanic(const char *message) {
    [NSNotificationCenter.defaultCenter postNotificationName:KernelPanicNotification object:nil userInfo:@{@"message":@(message)}];
}
#endif

static int bootError;
static NSString *const kSkipStartupMessage = @"Skip Startup Message";

#if !ISH_LINUX
#pragma mark - Boot phases

static ISHBootPhase bootPhase = ISHBootPhaseRunning;
static double bootFraction;
static NSString *bootTitle = @"";
static NSString *bootDetail = @"";
static NSString *bootFailure;
static NSMutableArray *bootObservers;

typedef void (^BootObserver)(ISHBootPhase, double, NSString *, NSString *);

// Main thread only.
static void SetBootState(ISHBootPhase phase, double fraction, NSString *title, NSString *detail) {
    bootPhase = phase;
    bootFraction = fraction;
    bootTitle = title ?: bootTitle;
    bootDetail = detail ?: bootDetail;
    for (BootObserver observer in bootObservers.copy)
        observer(bootPhase, bootFraction, bootTitle, bootDetail);
}

/// Measurements for release testing, readable from outside the app (simctl get_app_container,
/// or a device's app container): first-launch import time, boot time, and whether the app
/// container's filesystem is case-sensitive (it decides whether Thunar/thunar collide).
static void RecordBootStat(NSString *key, NSString *value) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"boot-stats.txt"];
    NSString *line = [NSString stringWithFormat:@"%@=%@\n", key, value];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (file == nil) {
        [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [file seekToEndOfFile];
    [file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [file closeFile];
    NSLog(@"[boot] %@=%@", key, value);
}

static BOOL ContainerIsCaseSensitive(void) {
    // Probed next to the roots, on the volume the fakefs lives on.
    NSURL *dir = Roots.instance.defaultRootUrl.URLByDeletingLastPathComponent;
    __attribute__((objc_precise_lifetime)) NSString *upperPath = [dir URLByAppendingPathComponent:@".CaseProbe"].path;
    __attribute__((objc_precise_lifetime)) NSString *lowerPath = [dir URLByAppendingPathComponent:@".caseprobe"].path;
    char upper[PATH_MAX], lower[PATH_MAX];
    strlcpy(upper, upperPath.fileSystemRepresentation, sizeof(upper));
    strlcpy(lower, lowerPath.fileSystemRepresentation, sizeof(lower));
    unlink(upper);
    unlink(lower);
    int fd = open(upper, O_CREAT | O_WRONLY | O_EXCL, 0600);
    if (fd < 0)
        return NO;
    close(fd);
    struct stat a, b;
    BOOL sensitive = !(stat(upper, &a) == 0 && stat(lower, &b) == 0 && a.st_ino == b.st_ino);
    unlink(upper);
    return sensitive;
}

#pragma mark - Fast mode (native JIT via StikDebug)

// The app never debugs itself: it asks the user-installed StikDebug app, through its
// documented URL scheme, to attach to this process (StikJIT INTEGRATION.md, "Configure the
// JIT methods"). StikDebug then runs universal.js where TXM is present, and the JIT's
// handshake (jit/codemem.c) prepares the code region and detaches.

NSString *const ISHFastModeSettingKey = @"fastMode.setting";
static NSString *const kFastModeForceAttemptKey = @"fastMode.debugForceAttempt"; // testing: try without StikDebug installed
static const int kFastModeWaitTicks = 200; // x 100 ms of the app running: ~20 s

static ISHFastModeState fastModeState = ISHFastModeStateIdle;
static NSString *fastModeMessage;
static BOOL fastModeNewProgramsOnly;
static BOOL fastModeBusy;
static NSMutableArray *fastModeObservers;

static NSString *const kFastModeCodeCacheKey = @"fastMode.codeCacheMB"; // 0 = automatic

// The JIT reads ISH_JIT_CACHE_MB when it starts (jit/codemem.c): the code cache size from
// Settings › Fast Mode, if the user picked one.
static void ApplyJITSettings(void) {
    NSInteger mb = [NSUserDefaults.standardUserDefaults integerForKey:kFastModeCodeCacheKey];
    if (mb >= 32 && mb <= 1024)
        setenv("ISH_JIT_CACHE_MB", [NSString stringWithFormat:@"%ld", (long) mb].UTF8String, 1);
}

static void *JITSymbol(const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

// Main thread only.
static void SetFastModeState(ISHFastModeState state, NSString *message) {
    fastModeState = state;
    fastModeMessage = message;
    for (void (^observer)(void) in fastModeObservers.copy)
        observer();
}

static BOOL FastModeAutomatic(void) {
    NSString *setting = [NSUserDefaults.standardUserDefaults stringForKey:ISHFastModeSettingKey];
    return setting == nil || ![setting isEqualToString:@"off"];
}

// get-task-allow is what lets StikDebug attach at all (development-signed installs).
static BOOL HasGetTaskAllow(void) {
    static BOOL result;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
        void *(*createFromSelf)(CFAllocatorRef) = security ? dlsym(security, "SecTaskCreateFromSelf") : NULL;
        CFTypeRef (*copyValue)(void *, CFStringRef, CFErrorRef *) =
            security ? dlsym(security, "SecTaskCopyValueForEntitlement") : NULL;
        if (createFromSelf == NULL || copyValue == NULL)
            return;
        void *task = createFromSelf(NULL);
        if (task == NULL)
            return;
        CFTypeRef value = copyValue(task, CFSTR("get-task-allow"), NULL);
        result = value == kCFBooleanTrue;
        if (value != NULL)
            CFRelease(value);
        CFRelease(task);
    });
    return result;
}

static BOOL StikDebugInstalled(void) {
    return [UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"stikdebug://"]];
}

static BOOL JITDebugReady(void) {
    bool (*ready)(void) = JITSymbol("ish_jit_debug_ready");
    return ready != NULL && ready();
}

static NSString *FastModeUnavailableReason(void) {
    if (JITSymbol("ish_jit_try_enable") == NULL)
        return @"This build does not include the native JIT.";
    if (JITDebugReady())
        return nil; // launched from StikDebug already
    if ([NSUserDefaults.standardUserDefaults boolForKey:kFastModeForceAttemptKey])
        return nil;
#if TARGET_OS_SIMULATOR
    return @"The simulator has no StikDebug; fast mode needs an iPad.";
#else
    if (!HasGetTaskAllow())
        return @"This installation lacks the get-task-allow entitlement, so no debugger can attach. Install a development-signed build (Xcode, SideStore or iloader).";
    if (!StikDebugInstalled())
        return @"StikDebug is not installed.";
    return nil;
#endif
}

static NSURL *StikDebugURL(void) {
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"stikdebug";
    components.host = @"enable-jit";
    NSMutableArray *items = [NSMutableArray arrayWithObjects:
        [NSURLQueryItem queryItemWithName:@"bundle-id" value:NSBundle.mainBundle.bundleIdentifier ?: @""],
        [NSURLQueryItem queryItemWithName:@"pid" value:[NSString stringWithFormat:@"%d", getpid()]], nil];
    bool (*txm)(void) = JITSymbol("ish_jit_txm_present");
    if (txm != NULL && txm())
        [items addObject:[NSURLQueryItem queryItemWithName:@"script-name" value:@"universal.js"]];
    components.queryItems = items;
    return components.URL;
}

/// Asks StikDebug for the JIT and waits for it; `done` runs on the main queue with whether
/// the JIT is on. Never touches the breakpoint protocol before the debugger is ready
/// (ish_jit_try_enable checks it again).
static void RequestFastMode(BOOL afterBoot, void (^done)(BOOL on)) {
    bool (*tryEnable)(void) = JITSymbol("ish_jit_try_enable");
    NSString *reason = FastModeUnavailableReason();
    if (reason != nil || tryEnable == NULL || fastModeBusy) {
        done(NO);
        return;
    }
    fastModeBusy = YES;
    void (^finish)(BOOL, NSString *) = ^(BOOL on, NSString *failure) {
        fastModeBusy = NO;
        fastModeNewProgramsOnly = on && afterBoot;
        SetFastModeState(on ? ISHFastModeStateOn : ISHFastModeStateFailed, failure);
        done(on);
    };
    if (JITDebugReady()) {
        SetFastModeState(ISHFastModeStateEnabling, nil);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL on = tryEnable();
            dispatch_async(dispatch_get_main_queue(), ^{
                finish(on, on ? nil : @"The JIT could not get executable memory.");
            });
        });
        return;
    }
    SetFastModeState(ISHFastModeStateEnabling, nil);
    void (^open)(void) = ^{
        NSURL *url = StikDebugURL();
        NSLog(@"[fast mode] opening %@", url);
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL opened) {
            if (!opened) {
                finish(NO, @"StikDebug did not open.");
                return;
            }
            // Count only time this app runs: while StikDebug is in front we are suspended.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                BOOL ready = NO;
                for (int tick = 0; tick < kFastModeWaitTicks && !(ready = JITDebugReady()); tick++)
                    usleep(100000);
                BOOL on = ready && tryEnable();
                dispatch_async(dispatch_get_main_queue(), ^{
                    finish(on, on ? nil : ready ? @"StikDebug attached, but the JIT could not get executable memory."
                                                : @"StikDebug did not enable the JIT in time. Is LocalDevVPN connected?");
                });
            });
        }];
    };
    // A URL opens only once this app is in the foreground.
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        open();
    } else {
        __block id token = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                           object:nil
                                                                            queue:NSOperationQueue.mainQueue
                                                                       usingBlock:^(NSNotification *note) {
            [NSNotificationCenter.defaultCenter removeObserver:token];
            open();
        }];
    }
}

/// Feeds fakefs_import's per-entry callback (fraction of the compressed archive read, and
/// the entry's path) into the boot phase, at most 20 times a second.
@interface RootImportProgress : NSObject <ProgressReporter>
- (instancetype)initWithArchive:(NSURL *)archive title:(NSString *)title;
@end

@implementation RootImportProgress {
    NSString *_title;
    double _archiveMB;
    NSUInteger _entries;
    CFAbsoluteTime _lastReport;
    NSNumberFormatter *_formatter;
}

- (instancetype)initWithArchive:(NSURL *)archive title:(NSString *)title {
    if (self = [super init]) {
        _title = title;
        NSNumber *size = [archive resourceValuesForKeys:@[NSURLFileSizeKey] error:nil][NSURLFileSizeKey];
        _archiveMB = size.doubleValue / 1048576.0;
        _formatter = [NSNumberFormatter new];
        _formatter.numberStyle = NSNumberFormatterDecimalStyle;
    }
    return self;
}

- (void)updateProgress:(double)fraction message:(NSString *)message {
    _entries++;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _lastReport < 0.05 && fraction < 1)
        return;
    _lastReport = now;
    NSString *detail = [NSString stringWithFormat:@"%.0f of %.0f MB · %@ files",
                        fraction * _archiveMB, _archiveMB, [_formatter stringFromNumber:@(_entries)]];
    NSString *title = _title;
    dispatch_async(dispatch_get_main_queue(), ^{
        SetBootState(ISHBootPhaseUnpacking, fraction, title, detail);
    });
}

- (BOOL)shouldCancel {
    return NO;
}

@end
#endif

@implementation AppDelegate

- (int)boot {
    if (Roots.instance.needsDefaultRoot) {
        // Classic UI (or no desktop): import synchronously; the launch screen stays up.
        NSError *error;
        if (![Roots.instance importBundledRootWithProgress:nil error:&error]) {
            NSLog(@"failed to import default root: %@", error);
            return _EIO;
        }
    }
#if !ISH_LINUX
    NSURL *root = Roots.instance.defaultRootUrl;

    int err = mount_root(&fakefs, [root URLByAppendingPathComponent:@"data"].fileSystemRepresentation);
    if (err < 0)
        return err;

    fs_register(&iosfs);
    fs_register(&iosfs_unsafe);

    // need to do this first so that we can have a valid current for the generic_mknod calls
    err = become_first_process();
    if (err < 0)
        return err;

#ifdef ISH_FFMPEG_TEST
    // Register built-in native handlers (fake_ffmpeg) for the ffmpeg test target.
    // This is NOT called in the standard iSH ARM64 target.
    native_builtins_init();
#endif

    FsInitialize();

    // create some device nodes
    // this will do nothing if they already exist
    // (some rootfs tarballs omit the empty /dev and /proc directories)
    generic_mkdirat(AT_PWD, "/dev", 0755);
    generic_mkdirat(AT_PWD, "/proc", 0555);
    generic_mknodat(AT_PWD, "/dev/tty1", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 1));
    generic_mknodat(AT_PWD, "/dev/tty2", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 2));
    generic_mknodat(AT_PWD, "/dev/tty3", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 3));
    generic_mknodat(AT_PWD, "/dev/tty4", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 4));
    generic_mknodat(AT_PWD, "/dev/tty5", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 5));
    generic_mknodat(AT_PWD, "/dev/tty6", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 6));
    generic_mknodat(AT_PWD, "/dev/tty7", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 7));

    generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/console", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));

    generic_mknodat(AT_PWD, "/dev/null", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
    
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
    generic_mkdirat(AT_PWD, "/dev/shm", 01777);
    
    // Permissions on / have been broken for a while, let's fix them
    generic_setattrat(AT_PWD, "/", (struct attr) {.type = attr_mode, .mode = 0755}, false);
    
    // Register clipboard device driver and create device node for it
    err = dyn_dev_register(&clipboard_dev, DEV_CHAR, DYN_DEV_MAJOR, DEV_CLIPBOARD_MINOR);
    if (err != 0) {
        return err;
    }
    generic_mknodat(AT_PWD, "/dev/clipboard", S_IFCHR|0666, dev_make(DYN_DEV_MAJOR, DEV_CLIPBOARD_MINOR));
    
    err = dyn_dev_register(&location_dev, DEV_CHAR, DYN_DEV_MAJOR, DEV_LOCATION_MINOR);
    if (err != 0)
        return err;
    generic_mknodat(AT_PWD, "/dev/location", S_IFCHR|0666, dev_make(DYN_DEV_MAJOR, DEV_LOCATION_MINOR));

    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);

    iosfs_init(); // let it mount any filesystems from user defaults

    [self configureDns];
    
    exit_hook = ios_handle_exit;
    die_handler = ios_handle_die;
#if !TARGET_OS_SIMULATOR
    NSString *sockTmp = [NSTemporaryDirectory() stringByAppendingString:@"ishsock"];
    sock_tmp_prefix = strdup(sockTmp.UTF8String);
#endif
    
    tty_drivers[TTY_CONSOLE_MAJOR] = &ios_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    if (err < 0)
        return err;

#if defined(GUEST_ARM64) && defined(DEBUG)
    debug_server_start(1234);
#endif

    NSArray<NSString *> *command;
    command = UserPreferences.shared.bootCommand;
    char argv[4096];
    [Terminal convertCommand:command toArgs:argv limitSize:sizeof(argv)];
    const char *envp =
        "TERM=xterm-256color\0"
        "HOME=/root\0"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"
#if defined(GUEST_ARM64)
        "PYTHONMALLOC=malloc\0"
#endif
        ;
    err = do_execve(command[0].UTF8String, command.count, argv, envp);
    if (err < 0)
        return err;
    task_start(current);

#else
    // The default root is imported above, before entering the kernel: the import runs something on the main thread, and that would deadlock.
    NSArray<NSString *> *args = @[];
    actuate_kernel([args componentsJoinedByString:@" "].UTF8String);
#endif
    
    return 0;
}

#if ISH_LINUX
const char *DefaultRootPath() {
    return [Roots.instance rootUrl:Roots.instance.defaultRoot].fileSystemRepresentation;
}

void SyncHostname(void) {
    async_do_in_workqueue(^{
        char hostname[256];
        if (gethostname(hostname, sizeof(hostname)) < 0)
            return;
        linux_sethostname(hostname);
    });
}
#endif

- (void)configureDns {
#if !ISH_LINUX
    struct __res_state res;
    if (EXIT_SUCCESS != res_ninit(&res)) {
        exit(2);
    }
    NSMutableString *resolvConf = [NSMutableString new];
    if (res.dnsrch[0] != NULL) {
        [resolvConf appendString:@"search"];
        for (int i = 0; res.dnsrch[i] != NULL; i++) {
            [resolvConf appendFormat:@" %s", res.dnsrch[i]];
        }
        [resolvConf appendString:@"\n"];
    }
    union res_sockaddr_union servers[NI_MAXSERV];
    int serversFound = res_getservers(&res, servers, NI_MAXSERV);
    char address[NI_MAXHOST];
    for (int i = 0; i < serversFound; i ++) {
        union res_sockaddr_union s = servers[i];
        if (s.sin.sin_len == 0)
            continue;
        getnameinfo((struct sockaddr *) &s.sin, s.sin.sin_len,
                    address, sizeof(address),
                    NULL, 0, NI_NUMERICHOST);
        [resolvConf appendFormat:@"nameserver %s\n", address];
    }
    
    current = pid_get_task(1);
    struct fd *fd = generic_open("/etc/resolv.conf", O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0666);
    if (!IS_ERR(fd)) {
        fd->ops->write(fd, resolvConf.UTF8String, [resolvConf lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
        fd_close(fd);
    }
#endif
}

+ (int)bootError {
    return bootError;
}

#if !ISH_LINUX
+ (ISHBootPhase)bootPhase {
    return bootPhase;
}

+ (NSInteger)jitStatus {
    // Looked up at run time: jit_enabled() exists only in ISH_JIT_BUILD=enabled builds,
    // and the Objective-C side is compiled the same way either way.
    static bool (*jitEnabled)(void);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        jitEnabled = (bool (*)(void)) dlsym(RTLD_DEFAULT, "jit_enabled");
    });
    if (jitEnabled == NULL)
        return -1;
    return jitEnabled() ? 1 : 0;
}

+ (NSString *)bootFailureMessage {
    return bootFailure;
}

/// Runs `boot` now, or, when fast mode is automatic and possible, after asking StikDebug for
/// the JIT first: the engine is chosen when the first address space is created. Boot
/// continues in Compatibility mode if that fails.
- (void)afterFastMode:(void (^)(void))boot {
    NSString *reason = FastModeAutomatic() ? FastModeUnavailableReason() : @"setting is off";
    if (reason != nil) {
        NSLog(@"[fast mode] not requested: %@", reason);
        boot();
        return;
    }
    SetBootState(ISHBootPhaseConfiguring, 1, @"Enabling fast mode via StikDebug…", @"");
    RequestFastMode(NO, ^(BOOL on) {
        RecordBootStat(@"fast_mode", on ? @"on" : (fastModeMessage ?: @"off"));
        SetBootState(ISHBootPhaseConfiguring, 1, @"Configuring…", @"");
        boot();
    });
}

+ (ISHFastModeState)fastModeState {
    return fastModeState;
}

+ (NSString *)fastModeMessage {
    return fastModeMessage;
}

+ (BOOL)fastModeNewProgramsOnly {
    return fastModeNewProgramsOnly;
}

+ (NSString *)fastModeUnavailableReason {
    return FastModeUnavailableReason();
}

+ (void)retryFastMode {
    if (fastModeBusy)
        return;
    BOOL booted = bootPhase == ISHBootPhaseRunning;
    RequestFastMode(booted, ^(BOOL on) {
        if (!on && fastModeState != ISHFastModeStateFailed)
            SetFastModeState(ISHFastModeStateFailed, FastModeUnavailableReason() ?: @"Fast mode is not available.");
    });
}

+ (void)observeFastMode:(void (^)(void))observer {
    if (fastModeObservers == nil)
        fastModeObservers = [NSMutableArray new];
    [fastModeObservers addObject:[observer copy]];
    observer();
}

+ (void)observeBoot:(void (^)(ISHBootPhase, double, NSString *, NSString *))observer {
    if (bootObservers == nil)
        bootObservers = [NSMutableArray new];
    [bootObservers addObject:[observer copy]];
    observer(bootPhase, bootFraction, bootTitle, bootDetail);
}

static BOOL DesktopEnabled(void) {
    id enabled = [NSUserDefaults.standardUserDefaults objectForKey:@"desktop.enabled"];
    return enabled == nil || [enabled boolValue];
}

/// Boots now, or (desktop, first launch or scheduled update) prepares the root on a
/// background thread and boots when it is done, so the desktop's splash can show progress.
/// If the app is suspended meanwhile the import thread just pauses; if it is killed, the
/// staging directory is discarded at the next launch and the import starts over.
- (void)startBoot {
    RecordBootStat(@"case_sensitive_container", ContainerIsCaseSensitive() ? @"yes" : @"no");
    Roots *roots = Roots.instance;
    BOOL import = roots.needsDefaultRoot;
    NSString *update = roots.pendingUpdate;
    if (update != nil && ![update isEqualToString:roots.availableUpdate ?: @""]) {
        roots.pendingUpdate = nil; // superseded or already installed
        update = nil;
    }
    if (!DesktopEnabled() || (!import && update == nil)) {
        void (^boot)(void) = ^{
            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            bootError = [self boot];
            SetBootState(bootError < 0 ? ISHBootPhaseFailed : ISHBootPhaseRunning, 1, nil, nil);
            RecordBootStat(@"boot_seconds", [NSString stringWithFormat:@"%.2f", CFAbsoluteTimeGetCurrent() - start]);
        };
        // The classic terminal UI expects a booted kernel when launching finishes.
        if (DesktopEnabled())
            [self afterFastMode:boot];
        else
            boot();
        return;
    }

    NSString *title = import ? @"Unpacking Linux…" : @"Updating Linux…";
    SetBootState(ISHBootPhaseUnpacking, 0, title, @"");
    UIApplication *app = UIApplication.sharedApplication;
    __block UIBackgroundTaskIdentifier task = [app beginBackgroundTaskWithName:@"Unpack Linux" expirationHandler:^{
        [app endBackgroundTask:task];
        task = UIBackgroundTaskInvalid;
    }];
    RootImportProgress *progress = [[RootImportProgress alloc] initWithArchive:import ? roots.bundledRootArchive : roots.updateRootArchive title:title];
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error;
        BOOL ok = import ? [roots importBundledRootWithProgress:progress error:&error]
                         : [roots updateDefaultRootWithProgress:progress error:&error];
        CFAbsoluteTime unpacked = CFAbsoluteTimeGetCurrent();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (task != UIBackgroundTaskInvalid) {
                [app endBackgroundTask:task];
                task = UIBackgroundTaskInvalid;
            }
            RecordBootStat(import ? @"import_seconds" : @"update_seconds",
                           [NSString stringWithFormat:@"%.2f%@", unpacked - start, ok ? @"" : @" (failed)"]);
            if (!import)
                roots.pendingUpdate = nil; // a failed update boots the old system and is offered again
            if (!ok && import) {
                bootError = _EIO;
                bootFailure = error.localizedDescription ?: @"unpacking failed";
                NSLog(@"failed to import default root: %@", error);
                SetBootState(ISHBootPhaseFailed, 0, nil, bootFailure);
                return;
            }
            if (!ok)
                NSLog(@"system update failed, booting the previous system: %@", error);
            SetBootState(ISHBootPhaseConfiguring, 1, @"Configuring…", @"");
            // One run-loop turn so the splash shows "Configuring…" before the kernel starts.
            dispatch_async(dispatch_get_main_queue(), ^{
                [self afterFastMode:^{
                    CFAbsoluteTime bootStart = CFAbsoluteTimeGetCurrent();
                    bootError = [self boot];
                    if (bootError < 0)
                        bootFailure = [NSString stringWithFormat:@"error %d", bootError];
                    SetBootState(bootError < 0 ? ISHBootPhaseFailed : ISHBootPhaseRunning, 1, nil, nil);
                    RecordBootStat(@"boot_seconds", [NSString stringWithFormat:@"%.2f", CFAbsoluteTimeGetCurrent() - bootStart]);
                }];
            });
        });
    });
}
#endif

+ (void)maybePresentStartupMessageOnViewController:(UIViewController *)vc {
    if ([NSUserDefaults.standardUserDefaults integerForKey:kSkipStartupMessage] >= 1)
        return;
    if (!FsIsManaged()) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Install iSH’s built-in APK?"
                                                                       message:@"iSH now includes the APK package manager, but it must be manually activated."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Show me how"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [UIApplication openURL:@"https://go.ish.app/get-apk"];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Don't show again"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    }
    [NSUserDefaults.standardUserDefaults setInteger:1 forKey:kSkipStartupMessage];
}

static void (^backgroundURLSessionCompletion)(void);

- (void)application:(UIApplication *)application handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler {
    backgroundURLSessionCompletion = completionHandler;
}

+ (void)finishBackgroundURLSessionEvents {
    void (^completion)(void) = backgroundURLSessionCompletion;
    backgroundURLSessionCompletion = nil;
    if (completion)
        completion();
}

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey,id> *)launchOptions {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:@"hail mary"]) {
        [defaults removeObjectForKey:kPreferenceBootCommandKey];
        [defaults removeObjectForKey:kPreferenceLaunchCommandKey];
        [defaults setBool:NO forKey:@"hail mary"];
    }
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"recovery"])
        return YES;

#if !ISH_LINUX
    ApplyJITSettings();
    [self startBoot];
#else
    bootError = [self boot];
#endif

#if ISH_LINUX
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification object:UIApplication.sharedApplication queue:nil usingBlock:^(NSNotification * _Nonnull note) {
        SyncHostname();
    }];
    SyncHostname();
#endif

    return YES;
}

void NetworkReachabilityCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
    AppDelegate *self = (__bridge AppDelegate *) info;
#if !ISH_LINUX
    if (bootPhase != ISHBootPhaseRunning)
        return; // boot writes /etc/resolv.conf itself
#endif
    [self configureDns];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // get the network permissions popup to appear on chinese devices
    [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:@"http://captive.apple.com"]] resume];

    if ([NSUserDefaults.standardUserDefaults boolForKey:@"FASTLANE_SNAPSHOT"])
        [UIView setAnimationsEnabled:NO];

#if !ISH_LINUX
    NSString *ishVersion = [NSString stringWithFormat:@"iSH %@ (%@)",
                         [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
                         [NSBundle.mainBundle objectForInfoDictionaryKey:(NSString *) kCFBundleVersionKey]];
    extern const char *proc_ish_version;
    proc_ish_version = strdup(ishVersion.UTF8String);
    // this defaults key is set when taking app store screenshots
    extern const char *uname_hostname_override;
    NSString *hostnameOverride = UserPreferences.shared._hostnameOverride;
    if (@available(iOS 16.0, *)) { // Hostname obfuscation is in effect
        hostnameOverride = hostnameOverride ? hostnameOverride : UserPreferences.shared.hostnameOverride;
    }
    if (hostnameOverride) {
        uname_hostname_override = strdup(hostnameOverride.UTF8String);
    }
#endif
    
    [UserPreferences.shared observe:@[@"shouldDisableDimming"] options:NSKeyValueObservingOptionInitial
                              owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIApplication.sharedApplication.idleTimerDisabled = UserPreferences.shared.shouldDisableDimming;
        });
    }];
    
    // This code is IPv4 and IPv6 aware: see https://developer.apple.com/library/archive/samplecode/Reachability/Listings/ReadMe_md.html
    struct sockaddr_in address = {
        .sin_len = sizeof(address),
        .sin_family = AF_INET,
    };
    self.reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (struct sockaddr *) &address);
    SCNetworkReachabilityContext context = {
        .info = (__bridge void *) self,
    };
    SCNetworkReachabilitySetCallback(self.reachability, NetworkReachabilityCallback, &context);
    SCNetworkReachabilityScheduleWithRunLoop(self.reachability, CFRunLoopGetMain(), kCFRunLoopCommonModes);

    if (self.window != nil) {
        // For iOS <13, where the app delegate owns the window instead of the scene
        if ([NSUserDefaults.standardUserDefaults boolForKey:@"recovery"]) {
            UINavigationController *vc = [[UIStoryboard storyboardWithName:@"About" bundle:nil] instantiateInitialViewController];
            AboutViewController *avc = (AboutViewController *) vc.topViewController;
            avc.recoveryMode = YES;
            self.window.rootViewController = vc;
            return YES;
        }
        TerminalViewController *vc = (TerminalViewController *) self.window.rootViewController;
        if ([vc isKindOfClass:TerminalViewController.class]) {
            currentTerminalViewController = vc;
            [vc startNewSession];
        }
    }
    return YES;
}

- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions API_AVAILABLE(ios(13.0)) {
    for (UISceneSession *sceneSession in sceneSessions) {
        NSString *terminalUUID = sceneSession.stateRestorationActivity.userInfo[@"TerminalUUID"];
        [[Terminal terminalWithUUID:[[NSUUID alloc] initWithUUIDString:terminalUUID]] destroy];
    }
}

- (void)dealloc {
    if (self.reachability != NULL) {
        SCNetworkReachabilityUnscheduleFromRunLoop(self.reachability, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFRelease(self.reachability);
    }
}

- (void)exitApp {
    self.exiting = YES;
    id app = [UIApplication sharedApplication];
    [app suspend];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    if (self.exiting)
        exit(0);
}

@end

#if !ISH_LINUX
NSString *const ProcessExitedNotification = @"ProcessExitedNotification";
#else
NSString *const KernelPanicNotification = @"KernelPanicNotification";
#endif
