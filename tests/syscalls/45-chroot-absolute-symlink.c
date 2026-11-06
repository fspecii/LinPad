// Checks: inside a chroot, a symlink with an absolute target resolves against the chroot's
// root, as on Linux, while relative targets keep working; and getcwd, /proc/self/cwd and
// /proc/self/fd/N give paths inside the chroot.
// Observed: an absolute target restarted the lookup at the real root, so every such symlink
// in a chroot pointed outside it. In a Debian chroot dpkg could not stat the .debs apt links
// to under /tmp ("cannot stat pathname ...: No such file or directory"). getcwd and the
// /proc links gave the full outside path, so git refused its own directory ("Invalid path").
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/mount.h>
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

    snprintf(path, sizeof(path), "%s/proc", jail);
    mkdir(path, 0555);
    int proc_mounted = mount("proc", path, "proc", 0, NULL) == 0;
    pid_t child = fork();
    if (child == 0) {
        if (chroot(jail) < 0 || chdir("/") < 0)
            _exit(2);
        int ok = read_is("/abs", "inside") ? 0 : 1;
        ok |= read_is("/rel", "inside") ? 0 : 4;
        struct stat st;
        ok |= stat("/abs", &st) == 0 && S_ISREG(st.st_mode) ? 0 : 8;
        char cwd[256] = "", link[256] = "", fdlink[256] = "", fdpath[64];
        ok |= chdir("/data") == 0 && getcwd(cwd, sizeof(cwd)) != NULL && strcmp(cwd, "/data") == 0 ? 0 : 16;
        ssize_t n = readlink("/proc/self/cwd", link, sizeof(link) - 1);
        ok |= n == 5 && strcmp(link, "/data") == 0 ? 0 : 32;
        int fd = open("/data/file", O_RDONLY);
        snprintf(fdpath, sizeof(fdpath), "/proc/self/fd/%d", fd);
        n = readlink(fdpath, fdlink, sizeof(fdlink) - 1);
        ok |= n == 10 && strcmp(fdlink, "/data/file") == 0 ? 0 : 64;
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
        check(code >= 0 && !(code & 16), "getcwd gives the path inside the chroot");
        if (proc_mounted) {
            check(code >= 0 && !(code & 32), "so does /proc/self/cwd");
            check(code >= 0 && !(code & 64), "and /proc/self/fd/N of an open file");
        }
    }
    if (proc_mounted) {
        snprintf(path, sizeof(path), "%s/proc", jail);
        umount(path);
    }
    unlink("/data/file");
    rmdir("/data");
    return failed;
}
