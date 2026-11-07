// Checks: copy_file_range copies only between regular files, as on Linux: a tty or a pipe on
// either side fails at once with EINVAL (a directory with EISDIR), and regular files still
// copy, with and without offsets. A thread blocked reading a tty also leaves promptly when its
// process exits.
// Observed: copy_file_range read a tty or pipe through its generic loop, blocking in the read
// and retrying EINTR there. Go's io.Copy into a file tries copy_file_range first, so a Go TUI
// (agent-deck) kept a thread in it on its terminal. When the TUI was killed, the exit's SIGKILL
// made the read return EINTR, the loop called it again at once, forever; after a second the
// exit safety valve gave up on the thread and released its signal state, and the spinning
// thread's next check dereferenced it: the whole app crashed.
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <signal.h>
#include <time.h>
#include <sys/syscall.h>
#include <sys/wait.h>

#define DEADLINE_MS 3000
#define EXIT_MS 400     // well under do_exit_group's 500 ms wait before the safety valve

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

// waitpid with a deadline, so a child that will not go away fails the test instead of hanging it
static pid_t wait_bounded(pid_t pid, int *status, int ms) {
    long long start = now_ms();
    pid_t r;
    while ((r = waitpid(pid, status, WNOHANG)) == 0 && now_ms() - start < ms)
        usleep(5000);
    return r;
}

static long cfr(int in, long long *in_off, int out, long long *out_off, size_t len) {
    return syscall(SYS_copy_file_range, in, in_off, out, out_off, len, 0);
}

static int open_pty(int *master) {
    *master = posix_openpt(O_RDWR | O_NOCTTY);
    if (*master < 0 || grantpt(*master) < 0 || unlockpt(*master) < 0)
        return -1;
    return open(ptsname(*master), O_RDWR | O_NOCTTY);
}

// Runs copy_file_range(in, out) in a child, which reports errno, so a call that blocks can be
// told apart (and ended) instead of hanging the test.
static void expect_error(int in, int out, int want, const char *what) {
    pid_t pid = fork();
    if (pid == 0) {
        long n = cfr(in, NULL, out, NULL, 64);
        _exit(n < 0 ? errno : 200);
    }
    long long start = now_ms();
    int status = 0;
    while (waitpid(pid, &status, WNOHANG) == 0) {
        if (now_ms() - start > DEADLINE_MS) {
            printf("     %s: still blocked after %d ms\n", what, DEADLINE_MS);
            kill(pid, SIGKILL);
            if (wait_bounded(pid, &status, DEADLINE_MS) != pid)
                printf("     %s: and still there %d ms after SIGKILL\n", what, DEADLINE_MS);
            check(0, what);
            return;
        }
        usleep(10000);
    }
    int got = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    if (got != want)
        printf("     %s: got %s\n", what, got == 200 ? "success" : got < 0 ? "a crash" : strerror(got));
    check(got == want, what);
}

static void *read_tty(void *arg) {
    char c;
    read(*(int *) arg, &c, 1);
    return NULL;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    char path_a[] = "/tmp/cfr-a-XXXXXX", path_b[] = "/tmp/cfr-b-XXXXXX";
    int a = mkstemp(path_a), b = mkstemp(path_b);
    if (a < 0 || b < 0) {
        perror("mkstemp");
        return 1;
    }
    char data[10000];
    for (size_t i = 0; i < sizeof(data); i++)
        data[i] = (char) (i * 7 + 3);
    if (write(a, data, sizeof(data)) != (ssize_t) sizeof(data)) {
        perror("write");
        return 1;
    }

    // regular to regular: the whole file through the file offsets, then a slice by offset
    lseek(a, 0, SEEK_SET);
    long n = cfr(a, NULL, b, NULL, sizeof(data));
    char back[sizeof(data)];
    check(n == (long) sizeof(data) && pread(b, back, sizeof(back), 0) == (ssize_t) sizeof(back) &&
            memcmp(back, data, sizeof(data)) == 0, "regular files copy through the file offsets");
    long long in_off = 1000, out_off = 0;
    off_t a_pos = lseek(a, 0, SEEK_CUR);
    n = cfr(a, &in_off, b, &out_off, 500);
    check(n == 500 && in_off == 1500 && out_off == 500 && lseek(a, 0, SEEK_CUR) == a_pos &&
            pread(b, back, 500, 0) == 500 && memcmp(back, data + 1000, 500) == 0,
            "regular files copy by offset, leaving the file offset alone");

    int master, slave = open_pty(&master);
    int pipefd[2];
    int dir = open("/", O_RDONLY | O_DIRECTORY);
    if (slave < 0 || pipe(pipefd) < 0 || dir < 0) {
        perror("setup");
        return 1;
    }
    expect_error(slave, b, EINVAL, "from a tty with no input: EINVAL, not a blocking read");
    expect_error(pipefd[0], b, EINVAL, "from an empty pipe: EINVAL, not a blocking read");
    expect_error(a, slave, EINVAL, "to a tty: EINVAL");
    expect_error(a, pipefd[1], EINVAL, "to a pipe: EINVAL");
    expect_error(dir, b, EISDIR, "from a directory: EISDIR");

    // A process exits while one of its threads waits for terminal input.
    pid_t pid = fork();
    if (pid == 0) {
        pthread_t thread;
        pthread_create(&thread, NULL, read_tty, &slave);
        usleep(100000);
        _exit(0);
    }
    usleep(50000);
    long long start = now_ms();
    int status = 0;
    pid_t reaped = wait_bounded(pid, &status, DEADLINE_MS);
    long long took = now_ms() - start;
    if (took > EXIT_MS)
        printf("     exit took %lld ms%s\n", took, reaped == pid ? "" : ", and has not finished");
    check(reaped == pid && WIFEXITED(status) && took <= EXIT_MS,
            "a thread blocked reading a tty does not hold up its process's exit");

    unlink(path_a);
    unlink(path_b);
    return failed;
}
