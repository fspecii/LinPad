// Checks: mkdir of a path that exists on a filesystem that makes no directories (devpts, proc),
// such as its mount point, fails with EEXIST as on Linux, so mkdir -p accepts it.
// Observed: such filesystems returned EPERM before looking, and `mkdir -p /dev/pts` (run again
// by a chroot setup script after devpts was mounted there) failed.
#include <stdio.h>
#include <errno.h>
#include <sys/stat.h>

static int failed;
static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
    failed |= !ok;
}

int main(void) {
    struct stat st;
    if (stat("/proc/self", &st) == 0) {
        errno = 0;
        check(mkdir("/proc/self", 0755) < 0 && errno == EEXIST, "mkdir of an existing /proc directory is EEXIST");
    }
    if (stat("/dev/pts", &st) == 0) {
        errno = 0;
        check(mkdir("/dev/pts", 0755) < 0 && errno == EEXIST, "mkdir of the devpts mount point is EEXIST");
    }
    errno = 0;
    check(mkdir("/proc/no-such-dir", 0755) < 0 && errno != EEXIST, "a new directory in /proc still fails");
    return failed;
}
