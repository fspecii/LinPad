// Checks: /proc/<tid>/syscall names the syscall a blocked thread is in, also a small read of a
// pipe (which the ARM64 dispatcher serves on its fast path), and is readable by its owner only.
// Expected (Linux, proc(5)): "<nr> <six args> <sp> <pc>" while blocked, mode 0400.
// Observed before: a thread blocked on the fast path read "running", and the file was 0444.
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/syscall.h>

static int failed;
static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
    failed |= !ok;
}

static int pipefd[2];
static volatile pid_t reader_tid;

static void *reader(void *arg) {
    (void) arg;
    reader_tid = gettid();
    char c;
    read(pipefd[0], &c, 1);
    return NULL;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (pipe(pipefd) < 0) {
        perror("pipe");
        return 1;
    }
    pthread_t thread;
    pthread_create(&thread, NULL, reader, NULL);
    char path[64], line[256] = "";
    int want = SYS_read, nr = -1;
    for (int tries = 0; tries < 100 && nr != want; tries++) {
        usleep(20000);
        if (reader_tid == 0)
            continue;
        snprintf(path, sizeof(path), "/proc/self/task/%d/syscall", reader_tid);
        FILE *f = fopen(path, "r");
        if (f == NULL)
            continue;
        if (fgets(line, sizeof(line), f) == NULL || sscanf(line, "%d", &nr) != 1)
            nr = -1;
        fclose(f);
    }
    line[strcspn(line, "\n")] = '\0';
    printf("     %s: %s\n", path, line);
    check(nr == want, "a thread blocked reading a pipe is in read");
    unsigned long fd = ~0ul;
    sscanf(line, "%*d %lx", &fd);
    check(fd == (unsigned long) pipefd[0], "its first argument is the pipe");

    struct stat st;
    check(stat(path, &st) == 0 && (st.st_mode & 0777) == 0400, "the file is the owner's alone (0400)");

    write(pipefd[1], "x", 1);
    pthread_join(thread, NULL);
    snprintf(path, sizeof(path), "/proc/self/task/%d/syscall", gettid());
    FILE *f = fopen(path, "r");
    line[0] = '\0';
    if (f != NULL) {
        fgets(line, sizeof(line), f);
        fclose(f);
    }
    // the reading thread is in read() itself
    check(sscanf(line, "%d", &nr) == 1 && nr == want, "a thread reading its own file sees read");
    return failed;
}
