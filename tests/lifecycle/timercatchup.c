// Guest side of tests/lifecycle/suspend.sh: periodic timers across a suspension.
// A 1 ms timerfd and a 1 ms ITIMER_REAL run while the host stops the emulator (SIGSTOP,
// as iPadOS suspends the app) and resumes it. Prints one line per second:
//   t=SECONDS gap=LONGEST_MS_BETWEEN_WAKEUPS expirations=TIMERFD_COUNT alarms=SIGALRMS
// and "bad=N" at the end: N counts seconds after the resume in which the loop was not
// woken at least every 50 ms (the timers did not keep running normally).
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t alarms;
static void on_alarm(int sig) { (void) sig; alarms++; }

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

int main(int argc, char **argv) {
    int seconds = argc > 1 ? atoi(argv[1]) : 30;
    signal(SIGALRM, on_alarm);
    struct itimerval it = {{0, 1000}, {0, 1000}};
    setitimer(ITIMER_REAL, &it, NULL);
    int tfd = timerfd_create(CLOCK_MONOTONIC, 0);
    struct itimerspec spec = {{0, 1000000}, {0, 1000000}};
    timerfd_settime(tfd, 0, &spec, NULL);

    double start = now_ms(), last = start, second_start = start, longest = 0, overall_longest = 0;
    uint64_t total = 0;
    int bad = 0, after_resume = 0, resumed = 0;
    for (;;) {
        uint64_t n;
        ssize_t r = read(tfd, &n, sizeof(n));
        double t = now_ms();
        if (r == sizeof(n))
            total += n;
        else if (errno != EINTR)
            break;
        double gap = t - last;
        last = t;
        if (gap > longest)
            longest = gap;
        if (gap > 1000)
            resumed = 1; // the emulator was stopped
        if (t - second_start >= 1000) {
            printf("t=%.0f gap=%.0f expirations=%llu alarms=%d\n", (t - start) / 1000, longest,
                   (unsigned long long) total, (int) alarms);
            fflush(stdout);
            if (resumed && after_resume++ > 0 && longest > 50)
                bad++;
            if (longest > overall_longest && !(resumed && after_resume <= 1))
                overall_longest = longest;
            second_start = t;
            longest = 0;
        }
        if (t - start > seconds * 1000.0)
            break;
    }
    printf("resumed=%d bad=%d\n", resumed, bad);
    return 0;
}
