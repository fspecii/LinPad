// Checks: a supplementary group grants its group permission bits, and a file or directory made
// in a set-group-ID directory takes that directory's group (a directory its setgid bit too), as
// on Linux. A user outside the group still only gets the "other" bits.
// Observed: only the effective gid was compared, so a member of a file's group through its
// supplementary groups was refused writing a group-writable file; and new files took the
// creator's gid. A Flutter SDK shared through a "flutter" group failed with Permission denied.
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>

#define GROUP 4242
#define DIR "/tmp/group-perm-test"

static int failed;
static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
    failed |= !ok;
}

// runs fn as uid 5000, gid 5000, with or without GROUP as a supplementary group
static int as_user(int (*fn)(void), int member) {
    pid_t pid = fork();
    if (pid == 0) {
        gid_t groups[] = {GROUP};
        if (setgroups(member ? 1 : 0, groups) < 0 || setgid(5000) < 0 || setuid(5000) < 0)
            _exit(100);
        _exit(fn());
    }
    int status;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 101;
}

static int write_shared(void) {
    int fd = open(DIR "/shared", O_WRONLY | O_APPEND);
    if (fd < 0)
        return errno == EACCES ? 1 : 2;
    return write(fd, "x", 1) == 1 ? 0 : 3;
}

static int make_files(void) {
    int fd = open(DIR "/new", O_WRONLY | O_CREAT | O_EXCL, 0664);
    if (fd < 0)
        return 1;
    close(fd);
    return mkdir(DIR "/sub", 0775) < 0 ? 2 : 0;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (getuid() != 0) {
        printf("SKIP: needs root\n");
        return 0;
    }
    unlink(DIR "/shared");
    unlink(DIR "/new");
    rmdir(DIR "/sub");
    rmdir(DIR);
    if (mkdir(DIR, 0775) < 0 || chown(DIR, 0, GROUP) < 0 || chmod(DIR, 02775) < 0) {
        perror("setup");
        return 1;
    }
    int fd = open(DIR "/shared", O_WRONLY | O_CREAT, 0664);
    close(fd);
    chown(DIR "/shared", 0, GROUP);
    chmod(DIR "/shared", 0664);

    check(as_user(write_shared, 1) == 0, "a supplementary group grants the group write bit");
    check(as_user(write_shared, 0) == 1, "a user outside the group is refused (EACCES)");
    check(as_user(make_files, 1) == 0, "a group member creates a file and a directory in the shared directory");
    struct stat st;
    check(stat(DIR "/new", &st) == 0 && st.st_gid == GROUP && st.st_uid == 5000,
            "a new file takes the setgid directory's group");
    check(stat(DIR "/sub", &st) == 0 && st.st_gid == GROUP && (st.st_mode & S_ISGID),
            "a new directory takes its group and the setgid bit");

    unlink(DIR "/shared");
    unlink(DIR "/new");
    rmdir(DIR "/sub");
    rmdir(DIR);
    return failed;
}
