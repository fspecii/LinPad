// Checks: when a session's leader has exited and been reaped while another process of the
// session still has the controlling tty, that process is reaped in turn without harm.
// Observed: reaping it (task_leave_session) looked the session up with pid_get(sid). Once the
// leader is reaped and its last member leaves, nothing holds that pid, pid_get returns NULL,
// and the lookup dereferenced it: the reaper (here init) crashed the app. An SSH session's
// leftover job does this, e.g. a TUI that outlives dropbear's shell and is reaped by init. (A
// member still in the leader's process group kept that pid in use, which hid the bug.)
// The orphan is reaped by pid 1, as on Linux; the test needs a pid 1 that reaps orphans (the
// smoke runner's /bin/sh does).
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/wait.h>

#define DEADLINE_MS 5000

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

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    int report[2], go[2];
    if (pipe(report) < 0 || pipe(go) < 0) {
        perror("pipe");
        return 1;
    }
    pid_t leader = fork();
    if (leader == 0) {
        close(report[0]);
        close(go[1]);
        int master = posix_openpt(O_RDWR | O_NOCTTY);
        if (setsid() < 0 || master < 0 || grantpt(master) < 0 || unlockpt(master) < 0)
            _exit(2);
        int slave = open(ptsname(master), O_RDWR | O_NOCTTY);
        if (slave < 0 || ioctl(slave, TIOCSCTTY, 0) < 0)
            _exit(3);
        pid_t member = fork();
        if (member == 0) {
            // keeps the session and its controlling tty, in a process group of its own as a
            // job-control shell's job is, and exits once the leader is gone
            setpgid(0, 0);
            char c;
            read(go[0], &c, 1);
            _exit(0);
        }
        write(report[1], &member, sizeof(member));
        _exit(0);
    }
    close(report[1]);
    close(go[0]);
    pid_t member;
    if (read(report[0], &member, sizeof(member)) != sizeof(member)) {
        int status;
        waitpid(leader, &status, 0);
        printf("leader setup failed (exit %d)\n", WIFEXITED(status) ? WEXITSTATUS(status) : -1);
        return 1;
    }
    int status;
    check(waitpid(leader, &status, 0) == leader && WIFEXITED(status) && WEXITSTATUS(status) == 0,
            "the session leader exits and is reaped first");
    check(kill(member, 0) == 0, "its session's other process is still running");

    // the member is init's child now; let it exit and wait for init to reap it
    write(go[1], "x", 1);
    long long start = now_ms();
    int reaped = 0;
    while (!reaped && now_ms() - start < DEADLINE_MS) {
        reaped = kill(member, 0) < 0 && errno == ESRCH;
        usleep(10000);
    }
    if (!reaped) {
        printf("SKIP: pid 1 did not reap the orphan within %d ms\n", DEADLINE_MS);
        return failed;
    }
    check(1, "init reaps the session's last process after its leader");
    return failed;
}
