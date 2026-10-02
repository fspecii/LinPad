//
//  ISHShellExecutor.m
//  iSH
//
//  Shell execution implementation with line-by-line output and process completion
//

#import "ISHShellExecutor.h"
#import "AppDelegate.h"
#import "LinuxInterop.h"

#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "fs/devices.h"
#include "fs/real.h"

#pragma mark - Result Implementation

@interface ISHShellExecutionResult ()
@property (nonatomic, readwrite) int exitCode;
@property (nonatomic, readwrite) int pid;
@property (nonatomic, readwrite) ISHShellExecutorError error;
@property (nonatomic, readwrite, copy) NSString *output;
@property (nonatomic, readwrite, copy) NSString *errorOutput;
@property (nonatomic, readwrite) NSTimeInterval duration;
@end

@implementation ISHShellExecutionResult
@end

#pragma mark - Execution Context

@interface ISHShellExecutionContext : NSObject {
    int _stdoutPipe[2];
    int _stderrPipe[2];
    int _stdinPipe[2];
}
@property (nonatomic) int guestPid;
@property (nonatomic) NSDate *startTime;
@property (nonatomic, copy) ISHShellLineCallback lineCallback;
@property (nonatomic, copy) ISHShellCompletionCallback completion;
@property (nonatomic) NSMutableString *stdoutBuffer;
@property (nonatomic) NSMutableString *stderrBuffer;
@property (nonatomic) dispatch_semaphore_t waitSemaphore;
@property (nonatomic) ISHShellExecutionResult *result;
@property (atomic) BOOL isCompleted;
@property (atomic) BOOL readersAbandoned;
@property (nonatomic) dispatch_group_t readersGroup;

- (int *)stdoutPipe;
- (int *)stderrPipe;
- (int *)stdinPipe;

@end

@implementation ISHShellExecutionContext

- (int *)stdoutPipe {
    return _stdoutPipe;
}

- (int *)stderrPipe {
    return _stderrPipe;
}

- (int *)stdinPipe {
    return _stdinPipe;
}

- (instancetype)init {
    if (self = [super init]) {
        _stdoutBuffer = [NSMutableString string];
        _stderrBuffer = [NSMutableString string];
        _stdoutPipe[0] = -1;
        _stdoutPipe[1] = -1;
        _stderrPipe[0] = -1;
        _stderrPipe[1] = -1;
        _stdinPipe[0] = -1;
        _stdinPipe[1] = -1;
        _readersGroup = dispatch_group_create();
        _result = [[ISHShellExecutionResult alloc] init];
        _result.error = ISHShellExecutorErrorNone;
    }
    return self;
}

- (void)cleanup {
    if (_stdoutPipe[0] >= 0) close(_stdoutPipe[0]);
    if (_stdoutPipe[1] >= 0) close(_stdoutPipe[1]);
    if (_stderrPipe[0] >= 0) close(_stderrPipe[0]);
    if (_stderrPipe[1] >= 0) close(_stderrPipe[1]);
    if (_stdinPipe[0] >= 0) close(_stdinPipe[0]);
    if (_stdinPipe[1] >= 0) close(_stdinPipe[1]);
    _stdoutPipe[0] = _stdoutPipe[1] = -1;
    _stderrPipe[0] = _stderrPipe[1] = -1;
    _stdinPipe[0] = _stdinPipe[1] = -1;
}

- (void)dealloc {
    [self cleanup];
}

@end

#pragma mark - Executor Implementation

@implementation ISHShellExecutor

static NSMutableDictionary<NSNumber *, ISHShellExecutionContext *> *_activeExecutions;
static dispatch_queue_t _readerQueue;
static dispatch_once_t _onceToken;

+ (void)initialize {
    if (self == [ISHShellExecutor class]) {
        _activeExecutions = [NSMutableDictionary dictionary];
        dispatch_once(&_onceToken, ^{
            _readerQueue = dispatch_queue_create("com.ish.shellexecutor.reader",
                                                 DISPATCH_QUEUE_CONCURRENT);
        });

        // Register for process exit notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(processDidExit:)
                                                     name:ProcessExitedNotification
                                                   object:nil];
    }
}

#pragma mark - Public API

+ (int)executeCommand:(NSString *)command
         lineCallback:(ISHShellLineCallback)lineCallback
           completion:(ISHShellCompletionCallback)completion {
    return [self executeCommand:command stdinData:nil lineCallback:lineCallback completion:completion];
}

+ (int)executeCommand:(NSString *)command
            stdinData:(NSData *)stdinData
         lineCallback:(ISHShellLineCallback)lineCallback
           completion:(ISHShellCompletionCallback)completion {
    return [self executeExecutable:@"/bin/sh"
                         arguments:@[@"-c", command]
                       environment:nil
                         stdinData:stdinData
                      lineCallback:lineCallback
                        completion:completion];
}

+ (int)executeExecutable:(NSString *)executable
               arguments:(NSArray<NSString *> *)arguments
             environment:(NSDictionary<NSString *, NSString *> *)environment
            lineCallback:(ISHShellLineCallback)lineCallback
              completion:(ISHShellCompletionCallback)completion {
    return [self executeExecutable:executable
                         arguments:arguments
                       environment:environment
                         stdinData:nil
                      lineCallback:lineCallback
                        completion:completion];
}

+ (int)executeExecutable:(NSString *)executable
               arguments:(NSArray<NSString *> *)arguments
             environment:(NSDictionary<NSString *, NSString *> *)environment
               stdinData:(NSData *)stdinData
            lineCallback:(ISHShellLineCallback)lineCallback
              completion:(ISHShellCompletionCallback)completion {

    ISHShellExecutionContext *ctx = [[ISHShellExecutionContext alloc] init];
    ctx.lineCallback = lineCallback;
    ctx.completion = completion;
    ctx.startTime = [NSDate date];

    if (stdinData != nil) {
        if (pipe([ctx stdinPipe]) < 0) {
            NSLog(@"ISHShellExecutor: pipe() failed: %s", strerror(errno));
            [ctx cleanup];
            return ISHShellExecutorErrorProcessCreationFailed;
        }
        // The guest may exit without draining stdin; that must not SIGPIPE the app.
        fcntl([ctx stdinPipe][1], F_SETNOSIGPIPE, 1);
    }

    // Create pipes for stdout and stderr
    if (pipe([ctx stdoutPipe]) < 0 || pipe([ctx stderrPipe]) < 0) {
        NSLog(@"ISHShellExecutor: pipe() failed: %s", strerror(errno));
        [ctx cleanup];
        return ISHShellExecutorErrorProcessCreationFailed;
    }

    // Set read ends to non-blocking
    fcntl([ctx stdoutPipe][0], F_SETFL, O_NONBLOCK);
    fcntl([ctx stderrPipe][0], F_SETFL, O_NONBLOCK);

#if !ISH_LINUX
    struct task *saved_current = current;

    // Create new process
    int err = become_new_init_child();
    if (err < 0) {
        current = saved_current;
        [ctx cleanup];
        NSLog(@"ISHShellExecutor: become_new_init_child failed: %d", err);
        return ISHShellExecutorErrorProcessCreationFailed;
    }

    struct task *task = current;

    // Setup stdin as the stdin pipe, or /dev/null
    struct fd *stdin_fd = adhoc_fd_create(&realfs_fdops);
    if (stdin_fd) {
        stdin_fd->real_fd = stdinData != nil ? dup([ctx stdinPipe][0]) : open("/dev/null", O_RDONLY);
        task->files->files[0] = stdin_fd;
    }

    // Setup stdout to pipe
    struct fd *stdout_fd = adhoc_fd_create(&realfs_fdops);
    if (stdout_fd) {
        stdout_fd->real_fd = dup([ctx stdoutPipe][1]);
        task->files->files[1] = stdout_fd;
    }

    // Setup stderr to pipe
    struct fd *stderr_fd = adhoc_fd_create(&realfs_fdops);
    if (stderr_fd) {
        stderr_fd->real_fd = dup([ctx stderrPipe][1]);
        task->files->files[2] = stderr_fd;
    }

    // Close write ends in parent
    close([ctx stdoutPipe][1]);
    close([ctx stderrPipe][1]);
    [ctx stdoutPipe][1] = -1;
    [ctx stderrPipe][1] = -1;

    // Build argv (NUL-separated string)
    NSMutableArray<NSString *> *fullArgs = [NSMutableArray arrayWithObject:executable];
    if (arguments) {
        [fullArgs addObjectsFromArray:arguments];
    }

    // Same limit as the kernel's ARGV_MAX (32 pages) for guest-initiated execve.
    const size_t argv_max = 32 * 4096;
    size_t argv_size = 1;
    for (NSString *arg in fullArgs)
        argv_size += strlen(arg.UTF8String) + 1;
    if (argv_size > argv_max) {
        current = saved_current;
        [ctx cleanup];
        NSLog(@"ISHShellExecutor: argv too long");
        return ISHShellExecutorErrorExecFailed;
    }
    NSMutableData *argv_data = [NSMutableData dataWithLength:argv_size];
    char *argv_buf = argv_data.mutableBytes;
    size_t pos = 0;
    for (NSString *arg in fullArgs) {
        const char *str = arg.UTF8String;
        size_t len = strlen(str) + 1;
        memcpy(argv_buf + pos, str, len);
        pos += len;
    }
    // Add final NUL terminator for double-NUL ending
    argv_buf[pos] = '\0';

    // Build envp
    NSMutableString *envp_str = [NSMutableString string];

    // Default environment
    [envp_str appendString:@"TERM=xterm-256color\0"];
    [envp_str appendString:@"HOME=/root\0"];
    [envp_str appendString:@"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"];
#if defined(GUEST_ARM64)
    [envp_str appendString:@"PYTHONMALLOC=malloc\0"];
#endif

    // Custom environment
    if (environment) {
        for (NSString *key in environment) {
            [envp_str appendFormat:@"%@=%@\0", key, environment[key]];
        }
    }

    // Add final NUL terminator for double-NUL ending
    [envp_str appendString:@"\0"];

    const char *envp = envp_str.UTF8String;

    // Execute
    err = do_execve(executable.UTF8String, fullArgs.count, argv_buf, envp);
    if (err < 0) {
        current = saved_current;
        [ctx cleanup];
        NSLog(@"ISHShellExecutor: do_execve failed: %d", err);
        return ISHShellExecutorErrorExecFailed;
    }

    // Get guest PID and start task
    ctx.guestPid = task->pid;
    ctx.result.pid = ctx.guestPid;
    task_start(task);
    current = saved_current;

    // Register context
    @synchronized(_activeExecutions) {
        _activeExecutions[@(ctx.guestPid)] = ctx;
    }

    if (stdinData != nil) {
        close([ctx stdinPipe][0]);
        [ctx stdinPipe][0] = -1;
        int writeEnd = [ctx stdinPipe][1];
        [ctx stdinPipe][1] = -1;
        dispatch_async(_readerQueue, ^{
            const char *bytes = stdinData.bytes;
            size_t remaining = stdinData.length;
            while (remaining > 0) {
                ssize_t written = write(writeEnd, bytes, remaining);
                if (written < 0) {
                    if (errno == EINTR)
                        continue;
                    break;
                }
                bytes += written;
                remaining -= (size_t) written;
            }
            close(writeEnd);
        });
    }

    // Start reader threads
    [self startReaderForPipe:[ctx stdoutPipe][0] context:ctx isStdErr:NO];
    [self startReaderForPipe:[ctx stderrPipe][0] context:ctx isStdErr:YES];

    return ctx.guestPid;
#else
    // TODO: Linux implementation using linux_start_session
    [ctx cleanup];
    return ISHShellExecutorErrorProcessCreationFailed;
#endif
}

+ (ISHShellExecutionResult *)executeCommandSync:(NSString *)command
                                        timeout:(NSTimeInterval)timeout
                                   lineCallback:(ISHShellLineCallback)lineCallback {

    ISHShellExecutionContext *ctx = [[ISHShellExecutionContext alloc] init];
    ctx.lineCallback = lineCallback;
    ctx.waitSemaphore = dispatch_semaphore_create(0);
    ctx.startTime = [NSDate date];

    __block ISHShellExecutionResult *result = nil;

    int pid = [self executeCommand:command
                      lineCallback:lineCallback
                        completion:^(ISHShellExecutionResult *execResult) {
        result = execResult;
        dispatch_semaphore_signal(ctx.waitSemaphore);
    }];

    if (pid < 0) {
        // Execution failed
        result = [[ISHShellExecutionResult alloc] init];
        result.error = (ISHShellExecutorError)pid;
        result.exitCode = -1;
        return result;
    }

    // Wait for completion or timeout
    dispatch_time_t waitTime = timeout > 0
        ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))
        : DISPATCH_TIME_FOREVER;

    long waitResult = dispatch_semaphore_wait(ctx.waitSemaphore, waitTime);

    if (waitResult != 0) {
        // Timeout - kill the process
        [self killProcess:pid withSignal:SIGKILL_];
        result = [[ISHShellExecutionResult alloc] init];
        result.error = ISHShellExecutorErrorTimeout;
        result.pid = pid;
        result.exitCode = -1;
        result.output = @"";
        result.errorOutput = @"";
    }

    return result;
}

+ (BOOL)killProcess:(int)pid withSignal:(int)signal {
    struct siginfo_ info = SIGINFO_NIL;
    lock(&pids_lock);
    struct task *task = pid_get_task((dword_t)pid);
    if (task) {
        send_signal(task, signal, info);
    }
    unlock(&pids_lock);
    return task != NULL;
}

#pragma mark - Process Exit Handling

+ (void)processDidExit:(NSNotification *)notification {
    int pid = [notification.userInfo[@"pid"] intValue];
    int exitCode = [notification.userInfo[@"code"] intValue];

    ISHShellExecutionContext *ctx;
    @synchronized(_activeExecutions) {
        ctx = _activeExecutions[@(pid)];
        if (!ctx) return;
        [_activeExecutions removeObjectForKey:@(pid)];
    }

    if (ctx.isCompleted) return;
    ctx.isCompleted = YES;
    ctx.result.exitCode = exitCode;
    ctx.result.duration = -[ctx.startTime timeIntervalSinceNow];

    // Output written just before exit may still be in the pipes. Wait for EOF, but
    // not forever: a background child that inherited stdout keeps the pipe open.
    dispatch_async(_readerQueue, ^{
        if (dispatch_group_wait(ctx.readersGroup, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0) {
            ctx.readersAbandoned = YES;
            dispatch_group_wait(ctx.readersGroup, DISPATCH_TIME_FOREVER);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishExecution:ctx];
        });
    });
}

+ (void)finishExecution:(ISHShellExecutionContext *)ctx {
    @synchronized(ctx.stdoutBuffer) {
        ctx.result.output = [ctx.stdoutBuffer copy];
    }
    @synchronized(ctx.stderrBuffer) {
        ctx.result.errorOutput = [ctx.stderrBuffer copy];
    }
    [ctx cleanup];

    if (ctx.completion)
        ctx.completion(ctx.result);

    // Signal semaphore for sync execution
    if (ctx.waitSemaphore)
        dispatch_semaphore_signal(ctx.waitSemaphore);
}

#pragma mark - Pipe Reading

+ (void)startReaderForPipe:(int)fd context:(ISHShellExecutionContext *)ctx isStdErr:(BOOL)isStdErr {
    dispatch_group_enter(ctx.readersGroup);
    dispatch_async(_readerQueue, ^{
        [self readPipe:fd context:ctx isStdErr:isStdErr];
        dispatch_group_leave(ctx.readersGroup);
    });
}

static NSString *DecodeOutput(NSData *data) {
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    // Fallback to Latin1 for binary data
    return string ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
}

+ (void)readPipe:(int)fd context:(ISHShellExecutionContext *)ctx isStdErr:(BOOL)isStdErr {
    char buffer[4096];
    // Bytes, not characters: a UTF-8 sequence can straddle two reads.
    NSMutableData *pending = [NSMutableData data];

    for (;;) {
        ssize_t bytesRead = read(fd, buffer, sizeof(buffer));
        if (bytesRead > 0) {
            [pending appendBytes:buffer length:bytesRead];
            [self emitCompleteLines:pending context:ctx isStdErr:isStdErr];
        } else if (bytesRead == 0) {
            break;
        } else if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            if (ctx.readersAbandoned)
                break;
            usleep(10000); // 10ms
        } else {
            break;
        }
    }

    // Process any remaining partial line
    if (pending.length > 0)
        [self emitLine:DecodeOutput(pending) newline:NO context:ctx isStdErr:isStdErr];
}

+ (void)emitCompleteLines:(NSMutableData *)pending
                  context:(ISHShellExecutionContext *)ctx
                 isStdErr:(BOOL)isStdErr {
    for (;;) {
        const char *bytes = pending.bytes;
        const char *newline = memchr(bytes, '\n', pending.length);
        if (newline == NULL)
            return;
        NSUInteger lineLength = (NSUInteger) (newline - bytes);
        NSString *line = DecodeOutput([NSData dataWithBytes:bytes length:lineLength]);
        [pending replaceBytesInRange:NSMakeRange(0, lineLength + 1) withBytes:NULL length:0];
        [self emitLine:line newline:YES context:ctx isStdErr:isStdErr];
    }
}

+ (void)emitLine:(NSString *)line
         newline:(BOOL)newline
         context:(ISHShellExecutionContext *)ctx
        isStdErr:(BOOL)isStdErr {
    NSMutableString *outputBuffer = isStdErr ? ctx.stderrBuffer : ctx.stdoutBuffer;
    @synchronized(outputBuffer) {
        [outputBuffer appendString:line];
        if (newline)
            [outputBuffer appendString:@"\n"];
    }
    if (ctx.lineCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ctx.lineCallback(line, isStdErr);
        });
    }
}

@end
