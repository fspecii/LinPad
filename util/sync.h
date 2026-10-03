#ifndef UTIL_SYNC_H
#define UTIL_SYNC_H

#include <stdatomic.h>
#include <pthread.h>
#include <stdbool.h>
#include <assert.h>
#include <setjmp.h>
#include <errno.h>
#include "misc.h"
#include "debug.h"

// locks, implemented using pthread

#define LOCK_DEBUG 0

typedef struct {
    pthread_mutex_t m;
    pthread_t owner;
#if LOCK_DEBUG
    struct lock_debug {
        const char *file; // doubles as locked
        int line;
        int pid;
        bool initialized;
    } debug;
#endif
} lock_t;

static inline void lock_init(lock_t *lock) {
    pthread_mutex_init(&lock->m, NULL);
#if LOCK_DEBUG
    lock->debug = (struct lock_debug) {
        .initialized = true,
    };
#endif
}

#if LOCK_DEBUG
#define LOCK_INITIALIZER {PTHREAD_MUTEX_INITIALIZER, 0, { .initialized = true }}
#else
#define LOCK_INITIALIZER {PTHREAD_MUTEX_INITIALIZER, 0}
#endif
static inline void __lock(lock_t *lock, __attribute__((unused)) const char *file, __attribute__((unused)) int line) {
    pthread_mutex_lock(&lock->m);
    lock->owner = pthread_self();
#if LOCK_DEBUG
    assert(lock->debug.initialized);
    assert(!lock->debug.file && "Attempting to recursively lock");
    lock->debug.file = file;
    lock->debug.line = line;
    extern int current_pid(void);
    lock->debug.pid = current_pid();
#endif
}
#define lock(lock) __lock(lock, __FILE__, __LINE__)
static inline void unlock(lock_t *lock) {
#if LOCK_DEBUG
    assert(lock->debug.initialized);
    assert(lock->debug.file && "Attempting to unlock an unlocked lock");
    lock->debug = (struct lock_debug) { .initialized = true };
#endif
    lock->owner = zero_init(pthread_t);
    pthread_mutex_unlock(&lock->m);
}

static inline int trylock(lock_t *lock, __attribute__((unused)) const char *file, __attribute__((unused)) int line) {
    int status = pthread_mutex_trylock(&lock->m);
#if LOCK_DEBUG
    if (!status) {
        lock->debug.file = file;
        lock->debug.line = line;
        extern int current_pid(void);
        lock->debug.pid = current_pid();
    }
#endif
    return status;
}
#define trylock(lock) trylock(lock, __FILE__, __LINE__)

// conditions, implemented using pthread conditions but hacked so you can also
// be woken by a signal

typedef struct {
    pthread_cond_t cond;
} cond_t;
#define COND_INITIALIZER ((cond_t) {PTHREAD_COND_INITIALIZER})

// Must call before using the condition
void cond_init(cond_t *cond);
// Must call when finished with the condition (currently doesn't do much but might do something important eventually I guess)
void cond_destroy(cond_t *cond);
// Releases the lock, waits for the condition, and reacquires the lock.
// Returns _EINTR if waiting stopped because the thread received a signal,
// _ETIMEDOUT if waiting stopped because the timout expired, 0 otherwise.
// Will never return _ETIMEDOUT if timeout is NULL.
int must_check wait_for(cond_t *cond, lock_t *lock, struct timespec *timeout);
// Same as wait_for, except it will never return _EINTR
int wait_for_ignore_signals(cond_t *cond, lock_t *lock, struct timespec *timeout);
// Wake up all waiters.
void notify(cond_t *cond);
// Wake up one waiter.
void notify_once(cond_t *cond);

// this is a read-write lock that prefers writers, i.e. if there are any
// writers waiting a read lock will block.
//
// It is built from atomics plus a mutex and two condition variables rather
// than pthread_rwlock_t: Darwin's rwlock can lose a wakeup when its waiters
// keep getting interrupted by signals (every guest signal is a pthread_kill
// SIGUSR1), leaving readers and a writer asleep on a lock nobody holds.
// Uncontended readers only touch the two counters; the mutex is for waiting.
typedef struct {
    atomic_int readers; // read-locked by this many, including ones backing out
    atomic_int writers; // waiting or holding the write lock
    bool writer_active; // protected by m
    pthread_mutex_t m;
    pthread_cond_t readers_cond;
    pthread_cond_t writers_cond;
    // 0: unlocked
    // -1: write-locked
    // >0: read-locked with this many readers
    atomic_int val;
    const char *file;
    int line;
    int pid;
} wrlock_t;
static inline void wrlock_init(wrlock_t *lock) {
    if (pthread_mutex_init(&lock->m, NULL)) __builtin_trap();
    if (pthread_cond_init(&lock->readers_cond, NULL)) __builtin_trap();
    if (pthread_cond_init(&lock->writers_cond, NULL)) __builtin_trap();
    lock->readers = lock->writers = 0;
    lock->writer_active = false;
    lock->val = lock->line = lock->pid = 0;
    lock->file = NULL;
}

extern int current_pid(void);
static inline void wrlock_destroy(wrlock_t *lock) {
    if (pthread_cond_destroy(&lock->readers_cond) != 0) __builtin_trap();
    if (pthread_cond_destroy(&lock->writers_cond) != 0) __builtin_trap();
    if (pthread_mutex_destroy(&lock->m) != 0) __builtin_trap();
}
static inline void __wrlock_reader_leave(wrlock_t *lock) {
    // The waiting writer checks readers under m before sleeping, so taking m
    // to signal it can't miss it.
    if (atomic_fetch_sub(&lock->readers, 1) == 1 && atomic_load(&lock->writers) > 0) {
        pthread_mutex_lock(&lock->m);
        pthread_cond_broadcast(&lock->writers_cond);
        pthread_mutex_unlock(&lock->m);
    }
}
// WRLOCK_DEBUG=1 (e.g. meson -Dc_args=-DWRLOCK_DEBUG=1) tracks who holds
// each wrlock: every thread keeps a list of the locks it holds and where it
// took them. Taking a lock the thread already holds is reported with both
// places, and a wait longer than 5 s prints every holder of that lock.
#ifndef WRLOCK_DEBUG
#define WRLOCK_DEBUG 0
#endif
#if WRLOCK_DEBUG
void wrlock_debug_check(wrlock_t *lock, bool write, const char *file, int line);
void wrlock_debug_acquired(wrlock_t *lock, bool write, const char *file, int line);
void wrlock_debug_released(wrlock_t *lock);
void wrlock_debug_wait(pthread_cond_t *cond, wrlock_t *lock, bool write, const char *file, int line);
#define WRLOCK_WAIT(cond, lock, write, file, line) wrlock_debug_wait(cond, lock, write, file, line)
#else
#define wrlock_debug_check(lock, write, file, line) ((void) 0)
#define wrlock_debug_acquired(lock, write, file, line) ((void) 0)
#define wrlock_debug_released(lock) ((void) 0)
#define WRLOCK_WAIT(cond, lock, write, file, line) pthread_cond_wait(cond, &(lock)->m)
#endif

static inline void __read_wrlock(wrlock_t *lock, __attribute__((unused)) const char *file, __attribute__((unused)) int line) {
    wrlock_debug_check(lock, false, file, line);
    for (;;) {
        if (atomic_load(&lock->writers) == 0) {
            atomic_fetch_add(&lock->readers, 1);
            if (atomic_load(&lock->writers) == 0)
                break;
            __wrlock_reader_leave(lock); // a writer came in: let it go first
        }
        pthread_mutex_lock(&lock->m);
        while (atomic_load(&lock->writers) > 0)
            WRLOCK_WAIT(&lock->readers_cond, lock, false, file, line);
        pthread_mutex_unlock(&lock->m);
    }
    assert(lock->val >= 0);
    lock->val++;
    wrlock_debug_acquired(lock, false, file, line);
}
#define read_wrlock(lock) __read_wrlock(lock, __FILE__, __LINE__)
static inline void read_wrunlock(wrlock_t *lock) {
    assert(lock->val > 0);
    wrlock_debug_released(lock);
    lock->val--;
    __wrlock_reader_leave(lock);
}
static inline void __write_wrlock(wrlock_t *lock, const char *file, int line) {
    wrlock_debug_check(lock, true, file, line);
    pthread_mutex_lock(&lock->m);
    atomic_fetch_add(&lock->writers, 1);
    while (lock->writer_active || atomic_load(&lock->readers) > 0)
        WRLOCK_WAIT(&lock->writers_cond, lock, true, file, line);
    lock->writer_active = true;
    pthread_mutex_unlock(&lock->m);
    wrlock_debug_acquired(lock, true, file, line);
    assert(lock->val == 0);
    lock->val = -1;
    lock->file = file;
    lock->line = line;
    lock->pid = current_pid();
}
#define write_wrlock(lock) __write_wrlock(lock, __FILE__, __LINE__)
// A reader lock only if no writer holds or waits for it; for monitors that must not
// queue behind a thread that holds the write lock for long (kernel/oom.c).
static inline bool read_wrtrylock(wrlock_t *lock) {
    if (atomic_load(&lock->writers) != 0)
        return false;
    atomic_fetch_add(&lock->readers, 1);
    if (atomic_load(&lock->writers) != 0) {
        __wrlock_reader_leave(lock);
        return false;
    }
    lock->val++;
    wrlock_debug_acquired(lock, false, "read_wrtrylock", 0);
    return true;
}
static inline bool write_wrtrylock(wrlock_t *lock) {
    pthread_mutex_lock(&lock->m);
    bool ok = false;
    if (!lock->writer_active) {
        atomic_fetch_add(&lock->writers, 1);
        if (atomic_load(&lock->readers) == 0) {
            lock->writer_active = true;
            ok = true;
        } else if (atomic_fetch_sub(&lock->writers, 1) == 1) {
            // readers that saw us may be waiting
            pthread_cond_broadcast(&lock->readers_cond);
        }
    }
    pthread_mutex_unlock(&lock->m);
    if (ok) {
        assert(lock->val == 0);
        lock->val = -1;
        wrlock_debug_acquired(lock, true, "write_wrtrylock", 0);
    }
    return ok;
}
static inline void write_wrunlock(wrlock_t *lock) {
    assert(lock->val == -1);
    wrlock_debug_released(lock);
    lock->val = lock->line = lock->pid = 0;
    lock->file = NULL;
    pthread_mutex_lock(&lock->m);
    lock->writer_active = false;
    if (atomic_fetch_sub(&lock->writers, 1) > 1)
        pthread_cond_broadcast(&lock->writers_cond);
    else
        pthread_cond_broadcast(&lock->readers_cond);
    pthread_mutex_unlock(&lock->m);
}

extern __thread sigjmp_buf unwind_buf;
extern __thread bool should_unwind;
static inline int sigunwind_start(void) {
    if (sigsetjmp(unwind_buf, 1)) {
        should_unwind = false;
        return 1;
    } else {
        should_unwind = true;
        return 0;
    }
}
static inline void sigunwind_end(void) {
    should_unwind = false;
}

#endif
