#include <stdio.h>
#include <fcntl.h>
#include <stdarg.h>
#include <string.h>
#include <sys/uio.h>
#include <syslog.h>
#include <signal.h>
#include <unistd.h>
#if LOG_HANDLER_NSLOG
#include <CoreFoundation/CoreFoundation.h>
#endif
#if LOG_HANDLER_OS_LOG
#include <os/log.h>
#endif
#include "kernel/calls.h"
#include "util/sync.h"
#include "util/fifo.h"
#include "kernel/task.h"
#include "kernel/log_tail.h"
#include "misc.h"

#define LOG_BUF_SHIFT 20
static char log_buffer[1 << LOG_BUF_SHIFT];
static struct fifo log_buf = FIFO_INIT(log_buffer);
static size_t log_max_since_clear = 0;
static lock_t log_lock = LOCK_INITIALIZER;

#define SYSLOG_ACTION_CLOSE_ 0
#define SYSLOG_ACTION_OPEN_ 1
#define SYSLOG_ACTION_READ_ 2
#define SYSLOG_ACTION_READ_ALL_ 3
#define SYSLOG_ACTION_READ_CLEAR_ 4
#define SYSLOG_ACTION_CLEAR_ 5
#define SYSLOG_ACTION_CONSOLE_OFF_ 6
#define SYSLOG_ACTION_CONSOLE_ON_ 7
#define SYSLOG_ACTION_CONSOLE_LEVEL_ 8
#define SYSLOG_ACTION_SIZE_UNREAD_ 9
#define SYSLOG_ACTION_SIZE_BUFFER_ 10

static int syslog_read(addr_t buf_addr, int_t len, int flags) {
    if (len < 0)
        return _EINVAL;
    if (flags & FIFO_LAST) {
        if ((size_t) len > log_max_since_clear)
            len = log_max_since_clear;
    } else {
        if ((size_t) len > fifo_capacity(&log_buf))
            len = fifo_capacity(&log_buf);
    }
    // never more than the ring holds: fifo_read would fail and leave buf unset
    if ((size_t) len > fifo_size(&log_buf))
        len = fifo_size(&log_buf);
    char *buf = malloc(len);
    fifo_read(&log_buf, buf, len, flags);
    int fail = user_write(buf_addr, buf, len);
    free(buf);
    if (fail)
        return _EFAULT;
    return len;
}

static int do_syslog(int type, addr_t buf_addr, int_t len) {
    int res;
    switch (type) {
        case SYSLOG_ACTION_READ_:
            return syslog_read(buf_addr, len, 0);
        case SYSLOG_ACTION_READ_ALL_:
            return syslog_read(buf_addr, len, FIFO_LAST | FIFO_PEEK);

        case SYSLOG_ACTION_READ_CLEAR_:
            res = syslog_read(buf_addr, len, FIFO_LAST | FIFO_PEEK);
            if (res < 0)
                return res;
            fallthrough;
        case SYSLOG_ACTION_CLEAR_:
            log_max_since_clear = 0;
            return 0;

        case SYSLOG_ACTION_SIZE_UNREAD_:
            return fifo_size(&log_buf);
        case SYSLOG_ACTION_SIZE_BUFFER_:
            return fifo_capacity(&log_buf);

        case SYSLOG_ACTION_CLOSE_:
        case SYSLOG_ACTION_OPEN_:
        case SYSLOG_ACTION_CONSOLE_OFF_:
        case SYSLOG_ACTION_CONSOLE_ON_:
        case SYSLOG_ACTION_CONSOLE_LEVEL_:
            return 0;
        default:
            return _EINVAL;
    }
}
int_t sys_syslog(int_t type, addr_t buf_addr, int_t len) {
    lock(&log_lock);
    int retval = do_syslog(type, buf_addr, len);
    unlock(&log_lock);
    return retval;
}

static uint64_t log_buf_total = 0;

#define DIAG_BUF_SHIFT 18
static char diag_buffer[1 << DIAG_BUF_SHIFT];
static struct fifo diag_buf = FIFO_INIT(diag_buffer);
static uint64_t diag_buf_total = 0;

static void log_buf_append(const char *msg) {
    log_buf_total += strlen(msg);
    fifo_write(&log_buf, msg, strlen(msg), FIFO_OVERWRITE);
    log_max_since_clear += strlen(msg);
    if (log_max_since_clear > fifo_capacity(&log_buf))
        log_max_since_clear = fifo_capacity(&log_buf);
}
static void log_line(const char *line);
static void output_line(const char *line) {
    // send it to stdout or wherever
    log_line(line);
    // add it to the circular buffer
    log_buf_append(line);
    log_buf_append("\n");
}

void ish_vprintk(const char *msg, va_list args) {
    // format the message
    // I'm trusting you to not pass an absurdly long message
    static __thread char buf[16384] = "";
    static __thread size_t buf_size = 0;
    buf_size += vsprintf(buf + buf_size, msg, args);

    // output up to the last newline, leave the rest in the buffer
    lock(&log_lock);
    char *b = buf;
    char *p;
    while ((p = strchr(b, '\n')) != NULL) {
        *p = '\0';
        output_line(b);
        *p = '\n';
        buf_size -= p + 1 - b;
        b = p + 1;
    }
    unlock(&log_lock);
    memmove(buf, b, strlen(b) + 1);
}
bool ish_log_enabled(void) {
    static int enabled = -1;
    if (enabled < 0) {
        const char *env = getenv("ISH_LOG");
        enabled = env != NULL && *env != '\0' && strcmp(env, "0") != 0;
    }
    return enabled;
}

void ish_printk(const char *msg, ...) {
    va_list args;
    va_start(args, msg);
    ish_vprintk(msg, args);
    va_end(args);
}

void ish_printk_diag(const char *msg, ...) {
    va_list args;
    va_start(args, msg);
    if (ish_log_enabled()) {
        ish_vprintk(msg, args);
    } else {
        char line[1024];
        int length = vsnprintf(line, sizeof(line), msg, args);
        if (length > 0) {
            size_t size = (size_t) length < sizeof(line) ? (size_t) length : sizeof(line) - 1;
            lock(&log_lock);
            fifo_write(&diag_buf, line, size, FIFO_OVERWRITE);
            diag_buf_total += size;
            unlock(&log_lock);
        }
    }
    va_end(args);
}

// Copies the newest `max` bytes of a ring; the caller holds log_lock, or is
// crashing and cannot take it.
static size_t ring_tail(struct fifo *ring, char *out, size_t max) {
    size_t size = ring->size < max ? ring->size : max;
    size_t start = (ring->start + ring->size - size) % ring->capacity;
    size_t first = ring->capacity - start < size ? ring->capacity - start : size;
    memcpy(out, ring->buf + start, first);
    memcpy(out + first, ring->buf, size - first);
    return size;
}

size_t ish_log_copy_tail(int ring, char *out, size_t max, uint64_t *total) {
    lock(&log_lock);
    struct fifo *fifo = ring == ISH_LOG_RING_DIAGNOSTIC ? &diag_buf : &log_buf;
    size_t copied = ring_tail(fifo, out, max);
    if (total)
        *total = ring == ISH_LOG_RING_DIAGNOSTIC ? diag_buf_total : log_buf_total;
    unlock(&log_lock);
    return copied;
}

static char crash_path[1024];
static struct sigaction previous_abort_action;
static volatile sig_atomic_t crash_written = 0;

static void write_all(int fd, const char *data, size_t size) {
    while (size > 0) {
        ssize_t written = write(fd, data, size);
        if (written <= 0)
            return;
        data += written;
        size -= (size_t) written;
    }
}

static void write_ring(int fd, const char *title, struct fifo *ring) {
    size_t size = ring->size < (64 << 10) ? ring->size : (64 << 10);
    size_t start = (ring->start + ring->size - size) % ring->capacity;
    size_t first = ring->capacity - start < size ? ring->capacity - start : size;
    write_all(fd, title, strlen(title));
    write_all(fd, ring->buf + start, first);
    write_all(fd, ring->buf, size - first);
    write_all(fd, "\n", 1);
}

void ish_log_write_crash(const char *reason) {
    if (crash_path[0] == '\0' || crash_written)
        return;
    crash_written = 1;
    int fd = open(crash_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0)
        return;
    write_all(fd, "reason: ", 8);
    write_all(fd, reason, strlen(reason));
    write_all(fd, "\n", 1);
    write_ring(fd, "\n--- kernel log (newest 64 KB) ---\n", &log_buf);
    write_ring(fd, "\n--- diagnostic log (newest 64 KB) ---\n", &diag_buf);
    close(fd);
}

static void crash_on_abort(int sig) {
    ish_log_write_crash("SIGABRT (abort)");
    sigaction(SIGABRT, &previous_abort_action, NULL);
    raise(sig);
}

void ish_log_set_crash_path(const char *path) {
    if (path == NULL || strlen(path) >= sizeof(crash_path))
        return;
    bool first = crash_path[0] == '\0';
    strcpy(crash_path, path);
    if (!first)
        return;
    struct sigaction action = {0};
    action.sa_handler = crash_on_abort;
    sigemptyset(&action.sa_mask);
    sigaction(SIGABRT, &action, &previous_abort_action);
}

#if LOG_HANDLER_DPRINTF
#define NEWLINE "\r\n"
static void log_line(const char *line) {
    struct iovec output[2] = {{(void *) line, strlen(line)}, {"\n", 1}};
    writev(666, output, 2);
}
#elif LOG_HANDLER_NSLOG
static void log_line(const char *line) {
    extern void NSLog(CFStringRef msg, ...);
    NSLog(CFSTR("%s"), line);
}
#elif LOG_HANDLER_SYSLOG
static void log_line(const char *line) {
    syslog(LOG_DEBUG, "%s", line);
}
#elif LOG_HANDLER_OS_LOG
static void log_line(const char *line) {
    os_log_fault(OS_LOG_DEFAULT, "%s", line);
}
#elif LOG_HANDLER_STDERR
static void log_line(const char *line) {
    fprintf(stderr, "%s\n", line);
}
#endif

static void default_die_handler(const char *msg) {
    printk("%s\n", msg);
}
void (*die_handler)(const char *msg) = default_die_handler;
_Noreturn void die(const char *msg, ...);
void die(const char *msg, ...) {
    va_list args;
    va_start(args, msg);
    char buf[4096];
    vsprintf(buf, msg, args);
    ish_log_write_crash(buf);
    die_handler(buf);
    abort();
    va_end(args);
}

// fun little utility function
int current_pid() {
    if (current)
        return current->pid;
    return -1;
}
