// Checks: any thread of a process can wait for a child another thread forked, as on Linux
// (children belong to the process); waitpid(-1) and waitpid(pid) both reap it.
// Observed: do_wait walked the process's threads but looked at the calling thread's children
// each time, so waitpid(-1) from another thread failed with ECHILD. Dart reaps children from
// a dedicated thread and aborted ("Wait for process exit failed: 10"): flutter could not run.
#define _GNU_SOURCE
#include <stdio.h>
#include <errno.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/wait.h>

static int failed;
static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
    failed |= !ok;
}

static void *spawn(void *arg) {
    pid_t pid = fork();
    if (pid == 0)
        _exit(*(int *) arg);
    return (void *) (long) pid;
}

int main(void) {
    int code = 7;
    pthread_t thread;
    void *ret;
    pthread_create(&thread, NULL, spawn, &code);
    pthread_join(thread, &ret);
    pid_t child = (pid_t) (long) ret;
    int status = 0;
    pid_t got = waitpid(-1, &status, 0);
    check(got == child && WIFEXITED(status) && WEXITSTATUS(status) == 7,
            "waitpid(-1) reaps a child another thread forked");

    code = 9;
    pthread_create(&thread, NULL, spawn, &code);
    pthread_join(thread, &ret);
    child = (pid_t) (long) ret;
    got = waitpid(child, &status, 0);
    check(got == child && WIFEXITED(status) && WEXITSTATUS(status) == 9, "so does waitpid(pid)");

    errno = 0;
    check(waitpid(-1, &status, WNOHANG) < 0 && errno == ECHILD, "with none left, ECHILD");
    return failed;
}
