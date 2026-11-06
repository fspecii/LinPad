// Checks: inside a chroot, a symlink with an absolute target resolves against the chroot's
// root, as on Linux, while relative targets keep working.
// Observed: an absolute target restarted the lookup at the real root, so every such symlink
// in a chroot pointed outside it. In a Debian chroot dpkg could not stat the .debs apt links
// to under /tmp ("cannot stat pathname ...: No such file or directory").
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>

static int failed;
static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
    failed |= !ok;
}

static int read_is(const char *path, const char *want) {
    char buf[32] = {0};
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return 0;
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    return n == (ssize_t) strlen(want) && memcmp(buf, want, n) == 0;
}

static void write_file(const char *path, const char *text) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    write(fd, text, strlen(text));
    close(fd);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *jail = "/tmp/chroot-symlink-test";
    char path[256];
    mkdir(jail, 0755);
    snprintf(path, sizeof(path), "%s/data", jail);
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/data/file", jail);
    write_file(path, "inside");
    // the same absolute path outside the jail holds something else
    mkdir("/data", 0755);
    write_file("/data/file", "outside");
    snprintf(path, sizeof(path), "%s/abs", jail);
    unlink(path);
    symlink("/data/file", path);
    snprintf(path, sizeof(path), "%s/rel", jail);
    unlink(path);
    symlink("data/file", path);

    pid_t child = fork();
    if (child == 0) {
        if (chroot(jail) < 0 || chdir("/") < 0)
            _exit(2);
        int ok = read_is("/abs", "inside") ? 0 : 1;
        ok |= read_is("/rel", "inside") ? 0 : 4;
        struct stat st;
        ok |= stat("/abs", &st) == 0 && S_ISREG(st.st_mode) ? 0 : 8;
        _exit(ok);
    }
    int status = -1;
    waitpid(child, &status, 0);
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    if (code == 2)
        printf("SKIP: chroot not permitted\n");
    else {
        check(code >= 0 && !(code & 1), "an absolute symlink resolves inside the chroot");
        check(code >= 0 && !(code & 4), "a relative symlink still resolves");
        check(code >= 0 && !(code & 8), "stat follows the absolute symlink inside the chroot");
    }
    unlink("/data/file");
    rmdir("/data");
    return failed;
}
