// Checks: opening /proc/self/fd/N, /proc/<pid>/fd/N or /dev/fd/N gives the file fd N refers to,
// as Linux's magic links do, also for a pipe, which has no path: reading and writing through
// them reach the pipe. A regular file still opens through its link; a closed fd is ENOENT.
// Observed: these were plain symlinks, and a pipe's target ("pipe:[...]") was looked up as a
// path: ENOENT. bash's process substitution, cat <(...), reads /dev/fd/63 and failed.
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

static int failed;
static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
    failed |= !ok;
}

int main(void) {
    int p[2];
    if (pipe(p) < 0) {
        perror("pipe");
        return 1;
    }
    char path[64], buf[16] = {0};

    snprintf(path, sizeof(path), "/proc/self/fd/%d", p[1]);
    int w = open(path, O_WRONLY);
    check(w >= 0 && write(w, "hello", 5) == 5, "a pipe's write end opens through /proc/self/fd");
    snprintf(path, sizeof(path), "/proc/self/fd/%d", p[0]);
    int r = open(path, O_RDONLY);
    check(r >= 0 && read(r, buf, sizeof(buf)) == 5 && memcmp(buf, "hello", 5) == 0,
            "its read end opens there too and reads what was written");

    snprintf(path, sizeof(path), "/proc/%d/fd/%d", getpid(), p[1]);
    int w2 = open(path, O_WRONLY);
    check(w2 >= 0 && write(w2, "x", 1) == 1 && read(p[0], buf, 1) == 1 && buf[0] == 'x',
            "/proc/<own pid>/fd works the same");

    if (access("/dev/fd", F_OK) == 0) {
        snprintf(path, sizeof(path), "/dev/fd/%d", p[0]);
        write(p[1], "y", 1);
        int r2 = open(path, O_RDONLY);
        check(r2 >= 0 && read(r2, buf, 1) == 1 && buf[0] == 'y', "/dev/fd/N opens the pipe");
    }

    int file = open("/bin/sh", O_RDONLY);
    snprintf(path, sizeof(path), "/proc/self/fd/%d", file);
    int again = open(path, O_RDONLY);
    char magic[4];
    check(again >= 0 && read(again, magic, 4) == 4 && memcmp(magic, "\x7f" "ELF", 4) == 0,
            "a regular file still opens through its link");

    close(r);
    snprintf(path, sizeof(path), "/proc/self/fd/%d", r);
    errno = 0;
    check(open(path, O_RDONLY) < 0 && errno == ENOENT, "a closed fd's link is ENOENT");
    return failed;
}
