// Native host regression for fs/poll.c and fs/real.c. The fixtures supply the
// task/socket-restart context; readiness, host registration and waits are the
// production implementations. Run with tests/unit/poll-test.sh.
#include <stdarg.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#ifdef __APPLE__
#include <sys/event.h>
#endif
#include "kernel/task.h"
#include "fs/fd.h"
#include "fs/poll.h"
#include "fs/real.h"

__thread struct task *current;

int errno_map(void) { return -errno; }
bool is_adhoc_fd(struct fd *fd) { (void) fd; return false; }
void sockrestart_begin_listen_wait(struct fd *fd) { (void) fd; }
void sockrestart_end_listen_wait(struct fd *fd) { (void) fd; }
bool sockrestart_should_restart_listen_wait(void) { return false; }
void ish_printk(const char *format, ...) {
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
}

#define CHECK(test) do { \
    if (!(test)) { \
        fprintf(stderr, "poll-test:%d: %s (errno %d)\n", __LINE__, #test, errno); \
        exit(1); \
    } \
} while (0)

static const struct fd_ops native_ops = {.poll = realfs_poll};
static const struct fd_ops epoll_ops = {.poll = epoll_fd_poll};

static void fd_init(struct fd *fd, int host_fd, mode_t_ type, const struct fd_ops *ops) {
    memset(fd, 0, sizeof(*fd));
    fd->real_fd = host_fd;
    fd->type = type;
    fd->ops = ops;
    list_init(&fd->poll_fds);
    lock_init(&fd->poll_lock);
}

static struct poll *new_poll(void) {
    struct poll *poll = poll_create();
    CHECK(!IS_ERR(poll));
    return poll;
}

static int count_event(void *context, int types, union poll_fd_info info) {
    int *events = context;
    (void) info;
    *events |= types;
    return 1;
}

static int wait_now(struct poll *poll, int *events) {
    struct timespec zero = {0};
    *events = 0;
    return poll_wait(poll, count_event, events, &zero);
}

static void nested_level_test(void) {
    struct poll *inner = new_poll(), *outer = new_poll();
    struct fd members[20], inner_fd, outer_fd;
    int peers[20];
    for (unsigned i = 0; i < array_size(members); i++) {
        int pair[2];
        CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
        fd_init(&members[i], pair[0], S_IFSOCK, &native_ops);
        peers[i] = pair[1];
        CHECK(poll_add_fd(inner, &members[i], POLL_WRITE,
                    (union poll_fd_info) {.fd = i}) == 0);
    }
    fd_init(&inner_fd, inner->real.fd, 0, &epoll_ops);
    inner_fd.epollfd.poll = inner;
    CHECK(poll_add_fd(outer, &inner_fd, POLL_READ, (union poll_fd_info) {0}) == 0);
    fd_init(&outer_fd, outer->real.fd, 0, &epoll_ops);
    outer_fd.epollfd.poll = outer;
    for (int i = 0; i < 4; i++)
        CHECK(epoll_fd_poll(&outer_fd) == POLL_READ);
    poll_destroy(outer);
    poll_destroy(inner);
    for (unsigned i = 0; i < array_size(members); i++) {
        close(members[i].real_fd);
        close(peers[i]);
    }
    puts("nested level: 20 writable sockets return promptly");
}

static void nested_edge_test(void) {
    struct poll *poll = new_poll();
    struct fd members[20], epoll_fd;
    int peers[20], events;
    for (unsigned i = 0; i < array_size(members); i++) {
        int pair[2];
        CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
        fd_init(&members[i], pair[0], S_IFSOCK, &native_ops);
        peers[i] = pair[1];
        CHECK(poll_add_fd(poll, &members[i], POLL_READ | POLL_EDGETRIGGERED,
                    (union poll_fd_info) {.fd = i}) == 0);
    }
    fd_init(&epoll_fd, poll->real.fd, 0, &epoll_ops);
    epoll_fd.epollfd.poll = poll;
    for (int round = 0; round < 2; round++) {
        for (unsigned i = 0; i < array_size(members); i++)
            CHECK(write(peers[i], "x", 1) == 1);
        CHECK(epoll_fd_poll(&epoll_fd) == POLL_READ);
        CHECK(wait_now(poll, &events) == (int) array_size(members));
        CHECK(events == POLL_READ);
        CHECK(epoll_fd_poll(&epoll_fd) == 0);
        CHECK(wait_now(poll, &events) == 0);
        for (unsigned i = 0; i < array_size(members); i++) {
            char byte;
            CHECK(read(members[i].real_fd, &byte, 1) == 1);
        }
        CHECK(epoll_fd_poll(&epoll_fd) == 0);
    }
    // A queued host event must not make the set readable after its data was
    // consumed elsewhere, before epoll collected it.
    CHECK(write(peers[0], "x", 1) == 1);
    char byte;
    CHECK(read(members[0].real_fd, &byte, 1) == 1);
    CHECK(epoll_fd_poll(&epoll_fd) == 0);
    poll_destroy(poll);
    for (unsigned i = 0; i < array_size(members); i++) {
        close(members[i].real_fd);
        close(peers[i]);
    }
    puts("nested edge: 20 edges rearm without duplicates or stale readiness");
}

static double monotonic_time(void) {
    struct timespec time;
    CHECK(clock_gettime(CLOCK_MONOTONIC, &time) == 0);
    return time.tv_sec + time.tv_nsec / 1e9;
}

static double cpu_time(void) {
    struct rusage usage;
    CHECK(getrusage(RUSAGE_SELF, &usage) == 0);
    return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
        usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
}

static void check_level_read_filter(struct poll *poll, int fd) {
#ifdef __APPLE__
    struct timespec zero = {0};
    for (int i = 0; i < 2; i++) {
        struct kevent event;
        CHECK(kevent(poll->real.fd, NULL, 0, &event, 1, &zero) == 1);
        CHECK(event.ident == (uintptr_t) fd && event.filter == EVFILT_READ);
        CHECK(!(event.flags & EV_CLEAR));
    }
#else
    (void) poll;
    (void) fd;
#endif
}

static void fifo_idle_test(void) {
    char dir[] = "/tmp/linpad-poll-test-XXXXXX";
    CHECK(mkdtemp(dir) != NULL);
    char path[128];
    CHECK(snprintf(path, sizeof(path), "%s/fifo", dir) > 0);
    CHECK(mkfifo(path, 0600) == 0);
    int reader = open(path, O_RDONLY | O_NONBLOCK);
    CHECK(reader >= 0);
    int writer = open(path, O_WRONLY | O_NONBLOCK);
    CHECK(writer >= 0);
    CHECK(unlink(path) == 0);
    CHECK(rmdir(dir) == 0);
    char buffered[960] = {0};
    CHECK(write(writer, buffered, sizeof(buffered)) == sizeof(buffered));
    struct fd member;
    fd_init(&member, reader, S_IFIFO, &native_ops);
    struct poll *poll = new_poll();
    int always = POLL_HUP | POLL_ERR | POLL_NVAL;
    CHECK(poll_add_fd(poll, &member, POLL_READ | always, (union poll_fd_info) {0}) == 0);
    int events;
    CHECK(wait_now(poll, &events) == 1 && (events & POLL_READ));
    check_level_read_filter(poll, reader);
    // A suspended audio source keeps a descriptor in poll(events=0) with
    // buffered FIFO bytes. It must sleep while the writer is still alive.
    CHECK(poll_mod_fd(poll, &member, always, (union poll_fd_info) {0}) == 0);
    struct timespec timeout = {.tv_nsec = 200000000};
    double start = monotonic_time(), cpu_start = cpu_time();
    events = 0;
    CHECK(poll_wait(poll, count_event, &events, &timeout) == 0);
    double elapsed = monotonic_time() - start, cpu = cpu_time() - cpu_start;
    CHECK(elapsed >= 0.15 && elapsed < 1.5);
    CHECK(cpu < elapsed / 2);
    CHECK(events == 0);
    CHECK(poll_mod_fd(poll, &member, POLL_READ | always, (union poll_fd_info) {0}) == 0);
    CHECK(wait_now(poll, &events) == 1 && (events & POLL_READ));
    check_level_read_filter(poll, reader);
    poll_destroy(poll);
    close(reader);
    close(writer);
    printf("fifo idle: %.3fs wall, %.6fs CPU; read interest restores readiness\n", elapsed, cpu);
}

struct close_context { int fd; };
static void *close_later(void *context) {
    struct close_context *close_context = context;
    struct timespec delay = {.tv_nsec = 50000000};
    nanosleep(&delay, NULL);
    CHECK(close(close_context->fd) == 0);
    return NULL;
}

static void pipe_hup_test(void) {
    for (int buffered = 0; buffered < 2; buffered++) {
        int pair[2];
        CHECK(pipe(pair) == 0);
        if (buffered)
            CHECK(write(pair[1], "x", 1) == 1);
        struct fd member;
        fd_init(&member, pair[0], S_IFIFO, &native_ops);
        struct poll *poll = new_poll();
        CHECK(poll_add_fd(poll, &member, POLL_HUP | POLL_ERR | POLL_NVAL,
                    (union poll_fd_info) {0}) == 0);
        struct close_context context = {.fd = pair[1]};
        pthread_t thread;
        CHECK(pthread_create(&thread, NULL, close_later, &context) == 0);
        int events = 0;
        struct timespec timeout = {.tv_nsec = 500000000};
        double start = monotonic_time();
        CHECK(poll_wait(poll, count_event, &events, &timeout) == 1);
        CHECK(events & POLL_HUP);
        CHECK(monotonic_time() - start < 0.4);
        CHECK(pthread_join(thread, NULL) == 0);
        poll_destroy(poll);
        close(pair[0]);
    }
    puts("pipe HUP: closing empty and buffered writers wakes promptly");
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    struct tgroup group = {0};
    struct task task = {.group = &group};
    current = &task;
    alarm(5);
    if (argc == 1 || strcmp(argv[1], "nested") == 0) {
        nested_level_test();
        nested_edge_test();
    }
    if (argc == 1 || strcmp(argv[1], "fifo") == 0) {
        fifo_idle_test();
        pipe_hup_test();
    }
    alarm(0);
    return 0;
}
