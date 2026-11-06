// Checks: fchmodat2 (Linux 6.6) changes a mode like fchmodat; with AT_SYMLINK_NOFOLLOW it
// works on a regular file and refuses a symlink with EOPNOTSUPP (leaving its target alone);
// AT_EMPTY_PATH with "" changes the fd itself; unknown flags are EINVAL.
// Observed: the syscall was missing (ENOSYS); Alpine's apk tries it first and logged
// "missing syscall 452" before falling back.
#define _GNU_SOURCE
#include <stdio.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/syscall.h>

#ifndef SYS_fchmodat2
#define SYS_fchmodat2 452
#endif

static int failed;
static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
    failed |= !ok;
}

static int mode_of(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 ? (int) (st.st_mode & 07777) : -1;
}

int main(void) {
    const char *file = "/tmp/fchmodat2-file", *link = "/tmp/fchmodat2-link";
    unlink(file);
    unlink(link);
    int fd = open(file, O_RDWR | O_CREAT, 0644);
    symlink(file, link);

    check(syscall(SYS_fchmodat2, AT_FDCWD, file, 0600, 0) == 0 && mode_of(file) == 0600, "changes a file's mode");
    check(syscall(SYS_fchmodat2, AT_FDCWD, file, 0640, AT_SYMLINK_NOFOLLOW) == 0 && mode_of(file) == 0640,
            "AT_SYMLINK_NOFOLLOW still changes a regular file");
    errno = 0;
    check(syscall(SYS_fchmodat2, AT_FDCWD, link, 0777, AT_SYMLINK_NOFOLLOW) < 0 && errno == EOPNOTSUPP &&
            mode_of(file) == 0640, "AT_SYMLINK_NOFOLLOW on a symlink is EOPNOTSUPP, target untouched");
    check(syscall(SYS_fchmodat2, fd, "", 0604, AT_EMPTY_PATH) == 0 && mode_of(file) == 0604,
            "AT_EMPTY_PATH changes the fd itself");
    errno = 0;
    check(syscall(SYS_fchmodat2, AT_FDCWD, file, 0600, 0x4) < 0 && errno == EINVAL, "an unknown flag is EINVAL");

    close(fd);
    unlink(link);
    unlink(file);
    return failed;
}
