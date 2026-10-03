// Guest file-lock semantics (tests/lifecycle/locks.sh): flock(), fcntl() record locks,
// open file description (OFD) locks and lockf(), as Linux defines them. Prints one line
// per check and "bad=N" at the end.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef F_OFD_GETLK
#define F_OFD_GETLK 36
#define F_OFD_SETLK 37
#define F_OFD_SETLKW 38
#endif

static int bad;
static const char *path = "/tmp/locktest.file";

static void check(const char *what, int ok) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) bad++;
    fflush(stdout);
}

static int open_file(void) {
    int fd = open(path, O_RDWR | O_CREAT, 0644);
    if (fd < 0) { perror("open"); exit(1); }
    return fd;
}

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

// Runs fn in a child and returns its exit status.
static int in_child(int (*fn)(void *), void *arg) {
    pid_t pid = fork();
    if (pid == 0) _exit(fn(arg));
    int status;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 99;
}

static int child_flock_nb(void *arg) {
    int fd = open_file();
    int op = *(int *) arg;
    return flock(fd, op | LOCK_NB) == 0 ? 0 : (errno == EWOULDBLOCK ? 1 : 2);
}

static int setlk(int fd, int cmd, short type, off_t start, off_t len) {
    struct flock fl = {.l_type = type, .l_whence = SEEK_SET, .l_start = start, .l_len = len};
    return fcntl(fd, cmd, &fl);
}

static int child_setlk(void *arg) {
    int fd = open_file();
    off_t *range = arg;
    return setlk(fd, F_SETLK, F_WRLCK, range[0], range[1]) == 0 ? 0 : (errno == EAGAIN || errno == EACCES ? 1 : 2);
}

static int child_getlk_pid(void *arg) {
    int fd = open_file();
    struct flock fl = {.l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 10};
    if (fcntl(fd, F_GETLK, &fl) < 0) return 2;
    pid_t expected = *(pid_t *) arg;
    return fl.l_type == F_WRLCK && fl.l_pid == expected && fl.l_start == 0 && fl.l_len == 100 ? 0 : 1;
}

static void on_alarm(int sig) { (void) sig; }

int main(void) {
    unlink(path);
    int ex = LOCK_EX, sh = LOCK_SH;

    // --- flock ---
    int a = open_file();
    check("flock: LOCK_EX on a free file", flock(a, LOCK_EX) == 0);
    check("flock: another process can't take LOCK_EX (EWOULDBLOCK)", in_child(child_flock_nb, &ex) == 1);
    check("flock: another process can't take LOCK_SH", in_child(child_flock_nb, &sh) == 1);
    int b = open_file();
    check("flock: a second open file description in the same process conflicts",
          flock(b, LOCK_EX | LOCK_NB) < 0 && errno == EWOULDBLOCK);
    int d = dup(a);
    check("flock: a dup shares the lock (no conflict)", flock(d, LOCK_EX | LOCK_NB) == 0);
    close(a);
    check("flock: still held while a dup is open", in_child(child_flock_nb, &ex) == 1);
    close(d);
    check("flock: released when the last descriptor closes", in_child(child_flock_nb, &ex) == 0);
    check("flock: LOCK_SH by two descriptions", flock(b, LOCK_SH) == 0 && in_child(child_flock_nb, &sh) == 0);
    check("flock: LOCK_EX refused while another holds LOCK_SH", in_child(child_flock_nb, &ex) == 1);
    check("flock: convert SH to EX", flock(b, LOCK_EX) == 0 && in_child(child_flock_nb, &sh) == 1);
    check("flock: LOCK_UN", flock(b, LOCK_UN) == 0 && in_child(child_flock_nb, &ex) == 0);

    // fork: the child shares the parent's open file description, so the lock is shared.
    a = open_file();
    flock(a, LOCK_EX);
    pid_t pid = fork();
    if (pid == 0) {
        int again = flock(a, LOCK_EX | LOCK_NB);  // same description: fine
        flock(a, LOCK_UN);                         // releases it for the parent too
        _exit(again == 0 ? 0 : 1);
    }
    int status;
    waitpid(pid, &status, 0);
    check("flock: a forked child holds the same lock", WIFEXITED(status) && WEXITSTATUS(status) == 0);
    check("flock: the child's LOCK_UN released it", in_child(child_flock_nb, &ex) == 0);
    close(a);

    // Blocking flock waits for the holder and is interrupted by a signal.
    a = open_file();
    flock(a, LOCK_EX);
    pid = fork();
    if (pid == 0) {
        usleep(300000);
        flock(a, LOCK_UN);
        _exit(0);
    }
    b = open_file();
    double t0 = now();
    int r = flock(b, LOCK_EX);
    double waited = now() - t0;
    waitpid(pid, &status, 0);
    check("flock: blocking LOCK_EX waits for the holder", r == 0 && waited > 0.2 && waited < 5);
    close(a);
    a = open_file();
    signal(SIGALRM, on_alarm);
    siginterrupt(SIGALRM, 1);
    alarm(1);
    t0 = now();
    r = flock(a, LOCK_EX);
    check("flock: a blocked LOCK_EX is interrupted by a signal (EINTR)", r < 0 && errno == EINTR && now() - t0 < 5);
    close(a);
    close(b);

    // --- fcntl record locks ---
    a = open_file();
    off_t range[2];
    check("fcntl: F_SETLK write lock 0..99", setlk(a, F_SETLK, F_WRLCK, 0, 100) == 0);
    range[0] = 50; range[1] = 10;
    check("fcntl: another process's overlapping lock is refused", in_child(child_setlk, range) == 1);
    range[0] = 100; range[1] = 10;
    check("fcntl: a non-overlapping lock is granted", in_child(child_setlk, range) == 0);
    pid_t me = getpid();
    check("fcntl: F_GETLK reports the holder's pid and range", in_child(child_getlk_pid, &me) == 0);
    check("fcntl: flock and fcntl locks are independent", flock(a, LOCK_EX | LOCK_NB) == 0);
    flock(a, LOCK_UN);
    b = open_file();
    close(b);
    range[0] = 0; range[1] = 10;
    check("fcntl: closing any descriptor of the file drops the process's locks", in_child(child_setlk, range) == 0);

    // F_SETLKW blocks until the holder unlocks.
    setlk(a, F_SETLK, F_WRLCK, 0, 0);
    pid = fork();
    if (pid == 0) {
        usleep(300000);
        setlk(a, F_SETLK, F_UNLCK, 0, 0);  // the child does not own it: no effect
        _exit(0);
    }
    waitpid(pid, &status, 0);
    range[0] = 0; range[1] = 1;
    check("fcntl: locks are not inherited by fork", in_child(child_setlk, range) == 1);
    pid = fork();
    if (pid == 0) {
        int fd = open_file();
        double s = now();
        int got = setlk(fd, F_SETLKW, F_WRLCK, 0, 1);
        _exit(got == 0 && now() - s > 0.2 ? 0 : 1);
    }
    usleep(400000);
    setlk(a, F_SETLK, F_UNLCK, 0, 0);
    waitpid(pid, &status, 0);
    check("fcntl: F_SETLKW waits for the unlock", WIFEXITED(status) && WEXITSTATUS(status) == 0);
    close(a);

    // lockf (musl implements it with F_SETLK/F_SETLKW/F_GETLK)
    a = open_file();
    lseek(a, 0, SEEK_SET);
    check("lockf: F_LOCK", lockf(a, F_LOCK, 10) == 0);
    pid = fork();
    if (pid == 0) {
        int fd = open_file();
        _exit(lockf(fd, F_TEST, 10) < 0 && (errno == EACCES || errno == EAGAIN) ? 0 : 1);
    }
    waitpid(pid, &status, 0);
    check("lockf: F_TEST in another process sees it", WIFEXITED(status) && WEXITSTATUS(status) == 0);
    close(a);

    // --- OFD locks: owned by the open file description ---
    a = open_file();
    b = open_file();
    check("ofd: F_OFD_SETLK write lock", setlk(a, F_OFD_SETLK, F_WRLCK, 0, 10) == 0);
    check("ofd: another description in the same process conflicts",
          setlk(b, F_OFD_SETLK, F_WRLCK, 5, 1) < 0 && errno == EAGAIN);
    struct flock fl = {.l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 1};
    check("ofd: F_OFD_GETLK reports it with pid -1",
          fcntl(b, F_OFD_GETLK, &fl) == 0 && fl.l_type == F_WRLCK && fl.l_pid == -1);
    d = dup(a);
    close(a);
    check("ofd: survives closing one of its descriptors",
          setlk(b, F_OFD_SETLK, F_WRLCK, 0, 1) < 0 && errno == EAGAIN);
    close(d);
    check("ofd: released when the description closes", setlk(b, F_OFD_SETLK, F_WRLCK, 0, 1) == 0);
    close(b);

    printf("bad=%d\n", bad);
    unlink(path);
    return 0;
}
