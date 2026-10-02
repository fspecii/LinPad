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

static void *timer_thread(void *param) {
    struct timer *timer = param;
    lock(&timer->lock);
    while (true) {
        struct timespec remaining = timespec_subtract(timer->end, timespec_now(timer->clockid));
        // Sleep on the condvar rather than in nanosleep, so a timer_set that
        // lands between dropping the lock and going to sleep is not lost.
        while (timer->active && !timer->dead && timespec_positive(remaining)) {
            wait_for_ignore_signals(&timer->cond, &timer->lock, &remaining);
            remaining = timespec_subtract(timer->end, timespec_now(timer->clockid));
        }
        if (timer->active)
            timer->callback(timer->data);
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
