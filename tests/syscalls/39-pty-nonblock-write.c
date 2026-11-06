// Checks: a non-blocking write into a full pty, either way round, reports only what was stored
// (then EAGAIN), so everything reported arrives on the other side; with ONLCR a newline counts
// once its \r\n is in. A full pty does not poll writable, and a writer waiting in poll or in
// edge-triggered epoll_wait is woken when the reader makes room.
// Observed: tty_write returned the full size whatever the buffer took, so a non-blocking writer
// (dropbear writing keystrokes, a TUI writing a redraw) silently lost the rest, and tty_poll
// always said writable, so pollers spun on writes that stored nothing.
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <poll.h>
#include <termios.h>
#include <time.h>
#include <sys/epoll.h>

#define CAP (1 << 20)   // stop counting here: before the fix writes never failed
#define WAKE_MS 600     // poll_wait re-checks every second; a missed wakeup costs that

static int failed;
static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
    failed |= !ok;
}

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000;
}

static void open_pair(int *master, int *slave, int slave_oflag) {
    *master = posix_openpt(O_RDWR | O_NOCTTY);
    grantpt(*master);
    unlockpt(*master);
    *slave = open(ptsname(*master), O_RDWR | O_NOCTTY);
    struct termios t;
    tcgetattr(*slave, &t);
    cfmakeraw(&t);
    t.c_oflag |= slave_oflag;
    tcsetattr(*slave, TCSANOW, &t);
    fcntl(*master, F_SETFL, O_NONBLOCK);
    fcntl(*slave, F_SETFL, O_NONBLOCK);
}

// Writes `chunk` bytes at a time until EAGAIN; returns the total reported.
static long fill(int fd, const char *data, size_t chunk) {
    long total = 0;
    while (total < CAP) {
        ssize_t n = write(fd, data, chunk);
        if (n < 0)
            break;
        total += n;
    }
    return total;
}

static long drain(int fd, long *newlines, long *crs) {
    char buf[4096];
    long total = 0;
    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n <= 0)
            break;
        for (ssize_t i = 0; i < n; i++) {
            if (newlines && buf[i] == '\n') (*newlines)++;
            if (crs && buf[i] == '\r') (*crs)++;
        }
        total += n;
    }
    return total;
}

static int writable(int fd) {
    struct pollfd p = {.fd = fd, .events = POLLOUT};
    return poll(&p, 1, 0) == 1 && (p.revents & POLLOUT);
}

static void direction(const char *what, int writer, int reader) {
    char data[1000], msg[160];
    memset(data, 'x', sizeof(data));
    long sent = fill(writer, data, sizeof(data));
    int eagain = errno == EAGAIN;
    snprintf(msg, sizeof(msg), "%s: a full pty fails with EAGAIN (reported %ld)", what, sent);
    check(sent < CAP && eagain, msg);
    snprintf(msg, sizeof(msg), "%s: a full pty does not poll writable", what);
    check(!writable(writer), msg);
    long got = drain(reader, NULL, NULL);
    snprintf(msg, sizeof(msg), "%s: every byte reported written arrives (%ld of %ld)", what, got, sent);
    check(got == sent, msg);
    snprintf(msg, sizeof(msg), "%s: writable again once drained", what);
    check(writable(writer), msg);
}

struct delayed_read { int fd; int ms; };
static void *read_later(void *arg) {
    struct delayed_read *d = arg;
    usleep(d->ms * 1000);
    char buf[2048];
    read(d->fd, buf, sizeof(buf));
    return NULL;
}

static void wakeup(const char *what, int use_epoll) {
    int master, slave;
    open_pair(&master, &slave, 0);
    char data[1000];
    memset(data, 'y', sizeof(data));
    fill(master, data, sizeof(data));
    int ep = -1;
    if (use_epoll) {
        ep = epoll_create1(0);
        struct epoll_event ev = {.events = EPOLLOUT | EPOLLET};
        epoll_ctl(ep, EPOLL_CTL_ADD, master, &ev);
        struct epoll_event out;
        epoll_wait(ep, &out, 1, 0);   // take any initial edge
    }
    struct delayed_read d = {slave, 200};
    pthread_t thread;
    pthread_create(&thread, NULL, read_later, &d);
    long long start = now_ms();
    int ready;
    if (use_epoll) {
        struct epoll_event out;
        ready = epoll_wait(ep, &out, 1, 3000) == 1 && (out.events & EPOLLOUT);
    } else {
        struct pollfd p = {.fd = master, .events = POLLOUT};
        ready = poll(&p, 1, 3000) == 1 && (p.revents & POLLOUT);
    }
    long long took = now_ms() - start;
    pthread_join(thread, NULL);
    char msg[160];
    snprintf(msg, sizeof(msg), "%s: woken when the reader makes room (%lld ms, reader at 200)", what, took);
    check(ready && took >= 150 && took < 200 + WAKE_MS, msg);
    if (ep >= 0)
        close(ep);
    close(master);
    close(slave);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    int master, slave;
    open_pair(&master, &slave, 0);
    direction("master to slave", master, slave);
    direction("slave to master", slave, master);
    close(master);
    close(slave);

    // ONLCR: each newline goes out as \r\n
    open_pair(&master, &slave, OPOST | ONLCR);
    char lines[1000];
    memset(lines, '\n', sizeof(lines));
    long sent = fill(slave, lines, sizeof(lines));
    long newlines = 0, crs = 0;
    drain(master, &newlines, &crs);
    char msg[160];
    snprintf(msg, sizeof(msg), "ONLCR: newlines reported %ld, arrived %ld (with %ld \\r)", sent, newlines, crs);
    check(sent < CAP && newlines == sent && (crs == sent || crs == sent + 1), msg);
    close(master);
    close(slave);

    wakeup("poll POLLOUT", 0);
    wakeup("epoll EPOLLOUT|EPOLLET", 1);
    return failed;
}
