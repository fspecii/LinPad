// Checks: epoll takes two descriptors of one open file (dup) as separate entries.
// Expected (Linux, epoll(7) "Q1"/"Q2"): an entry is keyed by file and descriptor number, so
// adding a dup of a descriptor already in the set succeeds, each entry keeps its own
// events and data, and only the same number again gives EEXIST.
// Observed: iSH keyed entries by the open file only and returned EEXIST. Bun (the native
// Claude Code TUI) adds a dup of stdout for writing and stdin for reading, both one
// terminal, and died with "EEXIST: file already exists, epoll_ctl".
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/epoll.h>
#include <sys/socket.h>

static int failed;
static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
    failed |= !ok;
}

static int add(int ep, int fd, unsigned events, unsigned long data) {
    struct epoll_event ev = { .events = events, .data.u64 = data };
    return epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev);
}

// The events reported for data, after waiting up to timeout ms
static unsigned events_for(int ep, unsigned long data, int timeout) {
    struct epoll_event out[8];
    int n = epoll_wait(ep, out, 8, timeout);
    unsigned events = 0;
    for (int i = 0; i < n; i++)
        if (out[i].data.u64 == data)
            events |= out[i].events;
    return events;
}

// in, out: one open file (in for reading, out its dup for writing); peer writes to it
static void run(const char *kind, int in, int peer) {
    char what[128];
    int out = dup(in);
    int ep = epoll_create1(0);
    int a = add(ep, out, EPOLLOUT, 2);
    int b = add(ep, in, EPOLLIN, 1);
    snprintf(what, sizeof(what), "%s: ADD a dup of a descriptor in the set = %d, %d errno %d (want 0, 0)",
            kind, a, b, b ? errno : 0);
    check(a == 0 && b == 0, what);
    int c = add(ep, in, EPOLLIN, 1), ce = errno;
    snprintf(what, sizeof(what), "%s: ADD the same number again = %d errno %d (want -1 EEXIST)", kind, c, ce);
    check(c == -1 && ce == EEXIST, what);
    unsigned e = events_for(ep, 1, 0);
    snprintf(what, sizeof(what), "%s: reading entry idle (events %#x)", kind, e);
    check(e == 0, what);
    e = events_for(ep, 2, 1000);
    snprintf(what, sizeof(what), "%s: writing entry reports EPOLLOUT with its own data (events %#x)", kind, e);
    check(e & EPOLLOUT, what);
    write(peer, "x\n", 2);
    e = events_for(ep, 1, 1000);
    snprintf(what, sizeof(what), "%s: reading entry reports EPOLLIN with its own data (events %#x)", kind, e);
    check(e & EPOLLIN, what);
    int d = epoll_ctl(ep, EPOLL_CTL_DEL, out, NULL);
    e = events_for(ep, 1, 1000);
    unsigned e2 = events_for(ep, 2, 0);
    snprintf(what, sizeof(what), "%s: DEL the dup = %d, the other entry still reports (%#x, dup %#x)", kind, d, e, e2);
    check(d == 0 && (e & EPOLLIN) && !(e2 & EPOLLOUT), what);
    close(ep);
    close(out);
}

int main(void) {
    // A terminal: what tmux and ssh give a shell as stdin, stdout and stderr
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0 || grantpt(master) < 0 || unlockpt(master) < 0) {
        perror("posix_openpt");
        return 1;
    }
    int tty = open(ptsname(master), O_RDWR | O_NOCTTY);
    run("pty", tty, master);
    // A socket, polled through its host descriptor
    int sv[2];
    socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
    run("socket", sv[0], sv[1]);
    return failed;
}
