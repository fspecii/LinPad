// Checks: a pty write larger than the tty buffer (4096 bytes) reaches a reader on the other
// side that waits in poll, select or epoll_wait (level or edge triggered), or in read().
// Expected (Linux): the writer fills the buffer, the reader is woken for that data and
// drains it, and the writer goes on; a 16 KiB frame arrives within milliseconds.
// Observed: tty_input filled the buffer and slept until it was consumed, but woke readers
// and pollers only after the whole write was in. A poller (dropbear, a Python pty driver,
// a TUI's epoll_wait on stdin) saw the data only at poll_wait's 1 s re-check: a Bubble Tea
// TUI (agent-deck) behind dropbear redrew seconds after a keystroke, while its input reader
// sat in epoll_wait with the key long read. An EPOLLET waiter, whose edge only a wakeup
// re-arms, and a reader blocked in read() were never woken: writer and reader deadlocked.
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <signal.h>
#include <termios.h>
#include <time.h>
#include <poll.h>
#include <sys/epoll.h>
#include <sys/select.h>
#include <sys/wait.h>

#define FRAME 16384
#define ROUNDS 4
#define SLOW_MS 300     // a missed wakeup costs at least poll_wait's 1 s re-check
#define HUNG_MS 15000

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

// canon: the slave stays in canonical mode (without echo), else it is made raw
static int open_pty(int *master, int *slave, int canon) {
    *master = posix_openpt(O_RDWR | O_NOCTTY);
    if (*master < 0 || grantpt(*master) < 0 || unlockpt(*master) < 0)
        return -1;
    *slave = open(ptsname(*master), O_RDWR | O_NOCTTY);
    if (*slave < 0)
        return -1;
    struct termios t;
    tcgetattr(*slave, &t);
    if (canon)
        t.c_lflag &= ~(ECHO | ECHOE | ECHOK | ECHONL);
    else
        cfmakeraw(&t);
    tcsetattr(*slave, TCSANOW, &t);
    return 0;
}

static void write_all(int fd, const char *data, size_t size) {
    for (size_t done = 0; done < size;) {
        ssize_t n = write(fd, data + done, size - done);
        if (n <= 0)
            _exit(3);
        done += n;
    }
}

enum wait_kind { WAIT_POLL, WAIT_SELECT, WAIT_EPOLL, WAIT_EPOLL_ET, WAIT_READ };
static const char *kind_name[] = {"poll", "select", "epoll", "epoll EPOLLET", "read"};

// Wait until fd is readable the way kind does.
static int wait_readable(enum wait_kind kind, int fd, int ep) {
    switch (kind) {
    case WAIT_POLL: {
        struct pollfd p = {.fd = fd, .events = POLLIN};
        return poll(&p, 1, -1);
    }
    case WAIT_SELECT: {
        fd_set r;
        FD_ZERO(&r);
        FD_SET(fd, &r);
        return select(fd + 1, &r, NULL, NULL, NULL);
    }
    case WAIT_EPOLL:
    case WAIT_EPOLL_ET: {
        struct epoll_event ev;
        return epoll_wait(ep, &ev, 1, -1);
    }
    case WAIT_READ:
        return 1;
    }
    return -1;
}

struct writer {
    int fd;
    int go[2];   // a byte per round: write a frame
};

static void *writer_thread(void *arg) {
    struct writer *w = arg;
    static char frame[FRAME];
    memset(frame, 'x', sizeof(frame));
    for (size_t i = 63; i < sizeof(frame); i += 64)
        frame[i] = '\n';   // lines, for a canonical reader
    char c;
    while (read(w->go[0], &c, 1) == 1)
        write_all(w->fd, frame, sizeof(frame));
    return NULL;
}

// One end gets FRAME bytes written per round; the other waits the way kind does and reads
// until it has them all. Returns the slowest round in ms.
static long long transfer(enum wait_kind kind, int to_slave, int canon) {
    int master, slave;
    if (open_pty(&master, &slave, canon) < 0)
        _exit(4);
    int wfd = to_slave ? master : slave;   // a paste, or a TUI's output
    int rfd = to_slave ? slave : master;
    if (kind != WAIT_READ)
        fcntl(rfd, F_SETFL, fcntl(rfd, F_GETFL) | O_NONBLOCK);
    int ep = epoll_create1(0);
    struct epoll_event ev = {.events = EPOLLIN | (kind == WAIT_EPOLL_ET ? EPOLLET : 0)};
    epoll_ctl(ep, EPOLL_CTL_ADD, rfd, &ev);

    struct writer w = {.fd = wfd};
    pipe(w.go);
    pthread_t thread;
    pthread_create(&thread, NULL, writer_thread, &w);

    long long worst = 0;
    static char buf[FRAME];
    for (int r = 0; r < ROUNDS; r++) {
        if (kind == WAIT_READ) {
            // be in read() before the writer starts, like a reader thread is
            write(w.go[1], "g", 1);
            usleep(1000);
        }
        long long t0 = now_ms();
        if (kind != WAIT_READ)
            write(w.go[1], "g", 1);
        size_t got = 0;
        while (got < FRAME) {
            if (wait_readable(kind, rfd, ep) <= 0)
                continue;
            // drain it, as an edge-triggered reader must
            ssize_t n;
            while (got < FRAME && (n = read(rfd, buf, FRAME - got)) > 0) {
                got += n;
                if (kind == WAIT_READ)
                    break;
            }
        }
        long long ms = now_ms() - t0;
        if (ms > worst)
            worst = ms;
    }
    return worst;
}

// A keystroke written to the master is answered by a redraw larger than the buffer: the
// process on the slave waits in epoll_wait, reads the key and writes the frame, while the
// master's holder polls the master (dropbear, a pty.fork() driver).
static long long keystroke_redraw(void) {
    int master, slave;
    if (open_pty(&master, &slave, 0) < 0)
        _exit(4);
    pid_t pid = fork();
    if (pid == 0) {
        close(master);
        int ep = epoll_create1(0);
        struct epoll_event ev = {.events = EPOLLIN};
        epoll_ctl(ep, EPOLL_CTL_ADD, slave, &ev);
        static char frame[FRAME];
        memset(frame, 'y', sizeof(frame));
        for (;;) {
            struct epoll_event out;
            if (epoll_wait(ep, &out, 1, -1) != 1)
                continue;
            char key;
            if (read(slave, &key, 1) != 1 || key == 'q')
                _exit(0);
            write_all(slave, frame, sizeof(frame));
        }
    }
    fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);
    long long worst = 0;
    static char buf[FRAME];
    for (int i = 0; i < ROUNDS; i++) {
        long long t0 = now_ms();
        write(master, "j", 1);
        size_t got = 0;
        while (got < FRAME) {
            struct pollfd p = {.fd = master, .events = POLLIN};
            if (poll(&p, 1, -1) <= 0)
                continue;
            ssize_t n;
            while (got < FRAME && (n = read(master, buf, FRAME - got)) > 0)
                got += n;
        }
        long long ms = now_ms() - t0;
        if (ms > worst)
            worst = ms;
    }
    write(master, "q", 1);
    waitpid(pid, NULL, 0);
    return worst;
}

// Runs a case in a child, so that a deadlocked one can be killed. -1 if it hung.
static long long run_case(enum wait_kind kind, int to_slave, int canon, int keystroke) {
    int result[2];
    pipe(result);
    pid_t pid = fork();
    if (pid == 0) {
        close(result[0]);
        long long worst = keystroke ? keystroke_redraw() : transfer(kind, to_slave, canon);
        write(result[1], &worst, sizeof(worst));
        _exit(0);
    }
    close(result[1]);
    long long worst = -1;
    struct pollfd p = {.fd = result[0], .events = POLLIN};
    if (poll(&p, 1, HUNG_MS) != 1 || read(result[0], &worst, sizeof(worst)) != sizeof(worst))
        worst = -1;
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);
    close(result[0]);
    return worst;
}

static void report(long long worst, const char *what) {
    char line[256];
    if (worst < 0)
        snprintf(line, sizeof(line), "%s: hung (no data for %d ms)", what, HUNG_MS);
    else
        snprintf(line, sizeof(line), "%s: slowest of %d rounds %lld ms (want < %d)",
                what, ROUNDS, worst, SLOW_MS);
    check(worst >= 0 && worst < SLOW_MS, line);
}

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    char what[160];
    for (int to_slave = 0; to_slave <= 1; to_slave++) {
        for (enum wait_kind kind = WAIT_POLL; kind <= WAIT_READ; kind++) {
            snprintf(what, sizeof(what), "%d bytes %s, reader in %s", FRAME,
                    to_slave ? "master -> slave (paste)" : "slave -> master (TUI output)",
                    kind_name[kind]);
            report(run_case(kind, to_slave, 0, 0), what);
        }
    }
    // a canonical reader gets the complete lines in a full buffer
    static const enum wait_kind canon_kinds[] = {WAIT_POLL, WAIT_READ};
    for (size_t i = 0; i < sizeof(canon_kinds) / sizeof(canon_kinds[0]); i++) {
        snprintf(what, sizeof(what), "%d bytes of lines master -> canonical slave, reader in %s",
                FRAME, kind_name[canon_kinds[i]]);
        report(run_case(canon_kinds[i], 1, 1, 0), what);
    }
    snprintf(what, sizeof(what), "key to epoll_wait on the slave, %d-byte redraw to poll on the master", FRAME);
    report(run_case(0, 0, 0, 1), what);
    return failed;
}
