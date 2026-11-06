// Checks: pselect6 with a NULL sixth argument (no signal mask) works, as on Linux.
// Observed: iSH read the mask descriptor without checking for NULL and failed with EFAULT.
// glibc's select() makes exactly this call (musl always passes a descriptor), so apt, waiting
// for its download methods, reported "Method ... did not start correctly".
#define _GNU_SOURCE
#include <stdio.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <sys/select.h>
#include <sys/syscall.h>

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
    write(p[1], "x", 1);
    fd_set readable;
    FD_ZERO(&readable);
    FD_SET(p[0], &readable);
    struct timespec timeout = {1, 0};
    long n = syscall(SYS_pselect6, p[0] + 1, &readable, NULL, NULL, &timeout, NULL);
    check(n == 1 && FD_ISSET(p[0], &readable), "pselect6 with no mask descriptor reports a readable pipe");

    FD_ZERO(&readable);
    FD_SET(p[1], &readable);
    struct timespec zero = {0, 0};
    errno = 0;
    n = syscall(SYS_pselect6, p[1] + 1, &readable, NULL, NULL, &zero, NULL);
    check(n == 0, "and times out when nothing is ready");
    return failed;
}
