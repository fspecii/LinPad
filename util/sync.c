// before the iSH headers, which redefine words the system headers use
#include <execinfo.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include "kernel/task.h"
#include "util/sync.h"
#include "debug.h"
#include "kernel/errno.h"

void cond_init(cond_t *cond) {
    pthread_condattr_t attr;
    pthread_condattr_init(&attr);
#if __linux__
    pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
#endif
    pthread_cond_init(&cond->cond, &attr);
}
void cond_destroy(cond_t *cond) {
    pthread_cond_destroy(&cond->cond);
}

static bool is_signal_pending(lock_t *lock) {
    if (!current)
        return false;
    if (lock != &current->sighand->lock)
        lock(&current->sighand->lock);
    bool pending = !!(current->pending & ~current->blocked);
    if (lock != &current->sighand->lock)
        unlock(&current->sighand->lock);
    return pending;
}

int wait_for(cond_t *cond, lock_t *lock, struct timespec *timeout) {
    if (is_signal_pending(lock))
        return _EINTR;
    int err = wait_for_ignore_signals(cond, lock, timeout);
    if (err < 0)
        return _ETIMEDOUT;
    if (is_signal_pending(lock))
        return _EINTR;
    return 0;
}

int wait_for_ignore_signals(cond_t *cond, lock_t *lock, struct timespec *timeout) {
    if (current) {
        lock(&current->waiting_cond_lock);
        current->waiting_cond = cond;
        current->waiting_lock = lock;
        unlock(&current->waiting_cond_lock);
    }
    int rc = 0;
#if LOCK_DEBUG
    struct lock_debug lock_tmp = lock->debug;
    lock->debug = (struct lock_debug) { .initialized = lock->debug.initialized };
#endif
    if (!timeout) {
        pthread_cond_wait(&cond->cond, &lock->m);
    } else {
#if __linux__
        struct timespec abs_timeout;
        clock_gettime(CLOCK_MONOTONIC, &abs_timeout);
        abs_timeout.tv_sec += timeout->tv_sec;
        abs_timeout.tv_nsec += timeout->tv_nsec;
        if (abs_timeout.tv_nsec > 1000000000) {
            abs_timeout.tv_sec++;
            abs_timeout.tv_nsec -= 1000000000;
        }
        rc = pthread_cond_timedwait(&cond->cond, &lock->m, &abs_timeout);
#elif __APPLE__
        rc = pthread_cond_timedwait_relative_np(&cond->cond, &lock->m, timeout);
#else
#error Unimplemented pthread_cond_wait relative timeout.
#endif
    }
#if LOCK_DEBUG
    lock->debug = lock_tmp;
#endif

    if (current) {
        lock(&current->waiting_cond_lock);
        current->waiting_cond = NULL;
        current->waiting_lock = NULL;
        unlock(&current->waiting_cond_lock);
    }
    if (rc == ETIMEDOUT)
        return _ETIMEDOUT;
    return 0;
}

void notify(cond_t *cond) {
    pthread_cond_broadcast(&cond->cond);
}
void notify_once(cond_t *cond) {
    pthread_cond_signal(&cond->cond);
}

__thread sigjmp_buf unwind_buf;
__thread bool should_unwind = false;

void sigusr1_handler() {
    if (should_unwind) {
        should_unwind = false;
        siglongjmp(unwind_buf, 1);
    }
}

// This is how you would mitigate the unlock/wait race if the wait
// is async signal safe. wait_for *should* be safe from this race
// because of synchronization involving the waiting_cond_lock.
#if 0
    sigset_t sigusr1;
    sigemptyset(&sigusr1);
    sigaddset(&sigusr1, SIGUSR1);

    if (current) {
        if (sigsetjmp(unwind_buf, 1)) {
            return _EINTR;
        }
        should_unwind = true;
        sigprocmask(SIG_BLOCK, &sigusr1, NULL);
        if (lock != &current->sighand->lock)
            lock(&current->sighand->lock);
        bool pending = !!(current->pending & ~current->blocked);
        if (lock != &current->sighand->lock)
            unlock(&current->sighand->lock);
        sigprocmask(SIG_UNBLOCK, &sigusr1, NULL);
        if (pending) {
            should_unwind = false;
            return _EINTR;
        }
    }
#endif


#if WRLOCK_DEBUG

// Per-thread list of held wrlocks, linked into a global list so a waiter can
// print the holders of the lock it waits for.
#define WRLOCK_HELD_MAX 32
struct wrlock_held {
    wrlock_t *lock;
    bool write;
    const char *file;
    int line;
};
struct wrlock_thread {
    struct wrlock_thread *next;
    pthread_t thread;
    int pid;
    int count;
    struct wrlock_held held[WRLOCK_HELD_MAX];
};
static pthread_mutex_t wrlock_threads_lock = PTHREAD_MUTEX_INITIALIZER;
static struct wrlock_thread *wrlock_threads;
static __thread struct wrlock_thread *wrlock_self;

static struct wrlock_thread *wrlock_thread_self(void) {
    if (wrlock_self == NULL) {
        wrlock_self = calloc(1, sizeof(*wrlock_self));
        wrlock_self->thread = pthread_self();
        pthread_mutex_lock(&wrlock_threads_lock);
        wrlock_self->next = wrlock_threads;
        wrlock_threads = wrlock_self;
        pthread_mutex_unlock(&wrlock_threads_lock);
    }
    wrlock_self->pid = current_pid();
    return wrlock_self;
}

static void wrlock_debug_backtrace(void) {
    void *frames[32];
    int n = backtrace(frames, 32);
    backtrace_symbols_fd(frames, n, STDERR_FILENO);
}

void wrlock_debug_check(wrlock_t *lock, bool write, const char *file, int line) {
    struct wrlock_thread *self = wrlock_thread_self();
    for (int i = 0; i < self->count; i++) {
        struct wrlock_held *h = &self->held[i];
        if (h->lock == lock) {
            fprintf(stderr, "WRLOCK: pid %d takes %p for %s at %s:%d, but already holds it for %s since %s:%d\n",
                    self->pid, (void *) lock, write ? "write" : "read", file, line,
                    h->write ? "write" : "read", h->file, h->line);
            wrlock_debug_backtrace();
        }
    }
}

void wrlock_debug_acquired(wrlock_t *lock, bool write, const char *file, int line) {
    struct wrlock_thread *self = wrlock_thread_self();
    pthread_mutex_lock(&wrlock_threads_lock);
    if (self->count < WRLOCK_HELD_MAX)
        self->held[self->count] = (struct wrlock_held) {lock, write, file, line};
    self->count++;
    pthread_mutex_unlock(&wrlock_threads_lock);
}

void wrlock_debug_released(wrlock_t *lock) {
    struct wrlock_thread *self = wrlock_thread_self();
    pthread_mutex_lock(&wrlock_threads_lock);
    int n = self->count < WRLOCK_HELD_MAX ? self->count : WRLOCK_HELD_MAX;
    int i;
    for (i = n - 1; i >= 0; i--) {
        if (self->held[i].lock == lock)
            break;
    }
    if (i < 0) {
        fprintf(stderr, "WRLOCK: pid %d releases %p which it doesn't hold\n", self->pid, (void *) lock);
        wrlock_debug_backtrace();
    } else {
        memmove(&self->held[i], &self->held[i + 1], (n - i - 1) * sizeof(self->held[0]));
        self->count--;
    }
    pthread_mutex_unlock(&wrlock_threads_lock);
}

void wrlock_debug_wait(pthread_cond_t *cond, wrlock_t *lock, bool write, const char *file, int line) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 5;
    if (pthread_cond_timedwait(cond, &lock->m, &deadline) != ETIMEDOUT)
        return;
    pthread_mutex_lock(&wrlock_threads_lock);
    fprintf(stderr, "WRLOCK: pid %d waited 5 s for %s of %p at %s:%d (readers %d, writers %d, writer active %d); holders:\n",
            current_pid(), write ? "write" : "read", (void *) lock, file, line,
            atomic_load(&lock->readers), atomic_load(&lock->writers), lock->writer_active);
    for (struct wrlock_thread *t = wrlock_threads; t != NULL; t = t->next) {
        for (int i = 0; i < t->count && i < WRLOCK_HELD_MAX; i++) {
            if (t->held[i].lock == lock)
                fprintf(stderr, "WRLOCK:   pid %d holds it for %s since %s:%d\n", t->pid,
                        t->held[i].write ? "write" : "read", t->held[i].file, t->held[i].line);
        }
    }
    pthread_mutex_unlock(&wrlock_threads_lock);
}
#endif
