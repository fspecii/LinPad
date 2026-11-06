// Checks: fstatat(fd, "", AT_EMPTY_PATH) describes fd itself (AT_FDCWD: the working directory),
// as on Linux; without AT_EMPTY_PATH an empty path is still ENOENT.
// Observed: the flag was ignored and the empty path failed with ENOENT. glibc 2.33 and later
// implement fstat this way, so its dynamic loader could not stat any library ("cannot stat
// shared object") and no Debian or Ubuntu program ran at all.
#define _GNU_SOURCE
#include <stdio.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/syscall.h>

static int failed;
static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
    failed |= !ok;
}

// the raw syscall, as glibc makes it (musl's fstatat may not pass AT_EMPTY_PATH through)
static long raw_fstatat(int dirfd, const char *path, struct stat *st, int flags) {
    return syscall(SYS_newfstatat, dirfd, path, st, flags);
}

int main(void) {
    int fd = open("/bin/sh", O_RDONLY);
    struct stat byfd, empty;
    if (fd < 0 || fstat(fd, &byfd) < 0) {
        perror("setup");
        return 1;
    }
    check(raw_fstatat(fd, "", &empty, AT_EMPTY_PATH) == 0 && empty.st_ino == byfd.st_ino &&
            empty.st_size == byfd.st_size && empty.st_mode == byfd.st_mode,
            "fstatat(fd, \"\", AT_EMPTY_PATH) is fstat(fd)");

    struct stat cwd, dot;
    check(raw_fstatat(AT_FDCWD, "", &cwd, AT_EMPTY_PATH) == 0 && stat(".", &dot) == 0 &&
            cwd.st_ino == dot.st_ino && S_ISDIR(cwd.st_mode),
            "fstatat(AT_FDCWD, \"\", AT_EMPTY_PATH) is the working directory");

    errno = 0;
    check(raw_fstatat(fd, "", &empty, 0) < 0 && errno == ENOENT, "an empty path without AT_EMPTY_PATH is ENOENT");
    return failed;
}
