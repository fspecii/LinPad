#include <stdlib.h>
#include <signal.h>
#include <time.h>
#include "util/timer.h"
#include "misc.h"

struct timer *timer_new(clockid_t clockid, timer_callback_t callback, void *data) {
//    assert(clockid == CLOCK_MONOTONIC || clockid == CLOCK_REALTIME);
    struct timer *timer = malloc(sizeof(struct timer));
    timer->clockid = clockid;
    timer->callback = callback;
    timer->data = data;
    timer->active = false;
    timer->thread_running = false;
    lock_init(&timer->lock);
    cond_init(&timer->cond);
    timer->dead = false;
    timer->overrun = 0;
    return timer;
}

void timer_free(struct timer *timer) {
    lock(&timer->lock);
    timer->active = false;
    if (timer->thread_running) {
        timer->dead = true;
        notify(&timer->cond);
        unlock(&timer->lock);
    } else {
        unlock(&timer->lock);
        cond_destroy(&timer->cond);
        free(timer);
    }
}

// The relative condvar wait runs on a clock that stops while the iPad sleeps, but
// timers are measured against CLOCK_MONOTONIC/REALTIME, which keep going. Waiting in
// slices of at most this long makes a timer that came due during sleep fire within a
// second of waking instead of a whole sleep's length late.
static const struct timespec max_wait_slice = {.tv_sec = 1};

static inline int64_t timespec_to_ns(struct timespec ts) {
    return (int64_t) ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static inline struct timespec timespec_from_ns(int64_t ns) {
    return (struct timespec) {.tv_sec = ns / 1000000000, .tv_nsec = ns % 1000000000};
}

// Periods of an interval timer that are already over when it fires: after the app was
// suspended for an hour, a 10 ms timer is a few hundred thousand periods behind. Those
// are counted (timer->overrun) instead of each running the callback.
static uint64_t timer_skip_missed_periods(struct timer *timer, struct timespec now) {
    int64_t interval = timespec_to_ns(timer->interval);
    int64_t late = timespec_to_ns(timespec_subtract(now, timer->end));
    if (interval <= 0 || late < interval)
        return 0;
    uint64_t missed = (uint64_t) (late / interval);
    timer->end = timespec_add(timer->end, timespec_from_ns((int64_t) missed * interval));
    return missed;
}

static void *timer_thread(void *param) {
    struct timer *timer = param;
    lock(&timer->lock);
    while (true) {
        struct timespec remaining = timespec_subtract(timer->end, timespec_now(timer->clockid));
        // Sleep on the condvar rather than in nanosleep, so a timer_set that
        // lands between dropping the lock and going to sleep is not lost.
        while (timer->active && !timer->dead && timespec_positive(remaining)) {
            struct timespec slice = remaining;
            if (timespec_positive(timespec_subtract(slice, max_wait_slice)))
                slice = max_wait_slice;
            wait_for_ignore_signals(&timer->cond, &timer->lock, &slice);
            remaining = timespec_subtract(timer->end, timespec_now(timer->clockid));
        }
        if (timer->active) {
            timer->overrun = timer_skip_missed_periods(timer, timespec_now(timer->clockid));
            timer->callback(timer->data);
            timer->overrun = 0;
        }
        if (timer->active && timespec_positive(timer->interval)) {
            timer->start = timer->end;
            timer->end = timespec_add(timer->start, timer->interval);
        } else {
            break;
        }
    }
    timer->thread_running = false;
    if (timer->dead) {
        unlock(&timer->lock);
        cond_destroy(&timer->cond);
        free(timer);
    } else {
        unlock(&timer->lock);
    }
    return NULL;
}

int timer_set(struct timer *timer, struct timer_spec spec, struct timer_spec *oldspec) {
    lock(&timer->lock);
    struct timespec now = timespec_now(timer->clockid);
    if (oldspec != NULL) {
        oldspec->value = timespec_subtract(timer->end, now);
        oldspec->interval = timer->interval;
    }

    timer->start = now;
    timer->end = timespec_add(timer->start, spec.value);
    timer->interval = spec.interval;
    timer->active = !timespec_is_zero(spec.value);
    if (timer->thread_running) {
        notify(&timer->cond);
    } else if (timer->active) {
        timer->thread_running = true;
        pthread_create(&timer->thread, NULL, timer_thread, timer);
        pthread_detach(timer->thread);
    }
    unlock(&timer->lock);
    return 0;
}
