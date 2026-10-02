// tm CMD...: run CMD and print wall-clock seconds to stderr
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>
int main(int argc, char **argv) {
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    pid_t p = fork();
    if (p == 0) { execvp(argv[1], argv + 1); _exit(127); }
    int st; while (waitpid(p, &st, 0) < 0) {}
    clock_gettime(CLOCK_MONOTONIC, &b);
    fprintf(stderr, "tm: %.3f s\n", (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9);
    return WEXITSTATUS(st);
}
