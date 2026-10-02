#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include "kernel/calls.h"

#define FUTEX_WAIT_ 0
#define FUTEX_WAKE_ 1
#define FUTEX_REQUEUE_ 3
#define FUTEX_CMP_REQUEUE_ 4
#define FUTEX_WAKE_OP_ 5
#define FUTEX_LOCK_PI_ 6
#define FUTEX_UNLOCK_PI_ 7
#define FUTEX_TRYLOCK_PI_ 8
#define FUTEX_WAIT_BITSET_ 9
#define FUTEX_WAKE_BITSET_ 10
#define FUTEX_WAIT_REQUEUE_PI_ 11
#define FUTEX_CMP_REQUEUE_PI_ 12
#define FUTEX_LOCK_PI2_ 13
#define FUTEX_BITSET_MATCH_ANY_ 0xffffffffu
// PI futex word layout
#define FUTEX_WAITERS_ 0x80000000u
#define FUTEX_OWNER_DIED_ 0x40000000u
#define FUTEX_TID_MASK_ 0x3fffffffu
#define FUTEX_PRIVATE_FLAG_ 128
#define FUTEX_CLOCK_REALTIME_ 256
#define FUTEX_CMD_MASK_ ~(FUTEX_PRIVATE_FLAG_ | FUTEX_CLOCK_REALTIME_)

// FUTEX_WAKE_OP val3 encoding (see Linux kernel futex.h)
#define FUTEX_OP_SET   0
#define FUTEX_OP_ADD   1
#define FUTEX_OP_OR    2
#define FUTEX_OP_ANDN  3
#define FUTEX_OP_XOR   4
#define FUTEX_OP_OPARG_SHIFT 8

#define FUTEX_OP_CMP_EQ 0
#define FUTEX_OP_CMP_NE 1
#define FUTEX_OP_CMP_LT 2
#define FUTEX_OP_CMP_LE 3
#define FUTEX_OP_CMP_GT 4
#define FUTEX_OP_CMP_GE 5

struct futex {
    atomic_uint refcount;
    struct mem *mem;
    addr_t addr;
    struct list queue;
    struct list chain; // locked by futex_hash_lock
};

struct futex_wait {
    cond_t cond;
    struct futex *futex; // will be changed by a requeue
    struct list queue;
    struct task *task;   // owning task (for per-thread futex_pipe wakeup)
    dword_t bitset;      // FUTEX_WAIT_BITSET mask, all ones for plain waits
};

#define FUTEX_HASH_BITS 12
#define FUTEX_HASH_SIZE (1 << FUTEX_HASH_BITS)
// Each hash bucket has its own lock, which covers its chain and the wait
// queues of the futexes in it (as on Linux), so unrelated futexes don't
// serialize. Operations on two futexes take both locks in index order.
static lock_t futex_locks[FUTEX_HASH_SIZE];
static struct list futex_hash[FUTEX_HASH_SIZE];

static void __attribute__((constructor)) init_futex_hash() {
    for (int i = 0; i < FUTEX_HASH_SIZE; i++) {
        list_init(&futex_hash[i]);
        lock_init(&futex_locks[i]);
    }
}

static unsigned futex_hash_of(struct mem *mem, addr_t addr) {
    return (addr ^ (unsigned long) mem) % FUTEX_HASH_SIZE;
}

static lock_t *futex_lock_of(struct mem *mem, addr_t addr) {
    return &futex_locks[futex_hash_of(mem, addr)];
}

static void futex_lock_pair(lock_t *a, lock_t *b) {
    if (a == b) {
        lock(a);
    } else if (a < b) {
        lock(a);
        lock(b);
    } else {
        lock(b);
        lock(a);
    }
}

static void futex_unlock_pair(lock_t *a, lock_t *b) {
    unlock(a);
    if (b != a)
        unlock(b);
}

// Caller holds the bucket lock for addr.
static struct futex *futex_get_unlocked(addr_t addr) {
    struct list *bucket = &futex_hash[futex_hash_of(current->mem, addr)];
    struct futex *futex;
    list_for_each_entry(bucket, futex, chain) {
        if (futex->addr == addr && futex->mem == current->mem) {
            futex->refcount++;
            return futex;
        }
    }

    futex = malloc(sizeof(struct futex));
    if (futex == NULL)
        return NULL;
    futex->refcount = 1;
    futex->mem = current->mem;
    futex->addr = addr;
    list_init(&futex->queue);
    list_add(bucket, &futex->chain);
    return futex;
}

// Returns the futex for the current process at the given addr, and locks it
// Unlocked variant is available for times when you need to get two futexes at once
// Returns the futex with its bucket locked, or NULL (unlocked).
static struct futex *futex_get(addr_t addr) {
    lock_t *l = futex_lock_of(current->mem, addr);
    lock(l);
    struct futex *futex = futex_get_unlocked(addr);
    if (futex == NULL)
        unlock(l);
    return futex;
}

static void futex_put_unlocked(struct futex *futex) {
    if (--futex->refcount == 0) {
        assert(list_empty(&futex->queue));
        list_remove(&futex->chain);
        free(futex);
    }
}

// Must be called on the result of futex_get when you're done with it
// Also has an unlocked version, for releasing the result of futex_get_unlocked
static void futex_put(struct futex *futex) {
    lock_t *l = futex_lock_of(futex->mem, futex->addr);
    futex_put_unlocked(futex);
    unlock(l);
}

static int futex_load(struct futex *futex, dword_t *out) {
    assert(futex->mem == current->mem);
    // read the word under the lock: another thread may unmap it right after
    read_wrlock(&current->mem->lock);
    dword_t *ptr = mem_ptr(current->mem, futex->addr, MEM_READ);
    if (ptr != NULL)
        *out = __atomic_load_n(ptr, __ATOMIC_SEQ_CST);
    read_wrunlock(&current->mem->lock);
    if (ptr == NULL)
        return 1;
    return 0;
}

static int futex_wait_bitset(addr_t uaddr, dword_t val, struct timespec *timeout, dword_t bitset) {
    struct futex *futex = futex_get(uaddr);
    if (futex == NULL)
        return _ENOMEM;
    int err = 0;
    dword_t tmp;
    if (futex_load(futex, &tmp))
        err = _EFAULT;
    else if (tmp != val)
        err = _EAGAIN;
    else {
        // Lazily create per-thread futex pipe (reused across all futex_wait calls)
        if (current->futex_pipe[0] == -1) {
            if (pipe(current->futex_pipe) < 0) {
                futex_put(futex);
                return _ENOMEM;
            }
            fcntl(current->futex_pipe[0], F_SETFL, O_NONBLOCK);
            fcntl(current->futex_pipe[1], F_SETFL, O_NONBLOCK);
        }
        // Drain any stale bytes from previous wakeups
        { char buf[16]; while (read(current->futex_pipe[0], buf, sizeof(buf)) > 0) {} }

        struct futex_wait wait;
        wait.cond = COND_INITIALIZER;
        wait.futex = futex;
        wait.task = current;
        wait.bitset = bitset;

        // Stay in queue so futex_wakelike can find us and write to our pipe
        list_add_tail(&futex->queue, &wait.queue);
        unlock(futex_lock_of(futex->mem, futex->addr));

        // Calculate deadline for timed waits
        int64_t deadline_ns = 0; // 0 = infinite
        if (timeout) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            deadline_ns = (int64_t)now.tv_sec * 1000000000LL + now.tv_nsec
                        + (int64_t)timeout->tv_sec * 1000000000LL + timeout->tv_nsec;
        }

        current->blocking = true;
        struct pollfd pfd = { .fd = current->futex_pipe[0], .events = POLLIN };
        for (;;) {
            // Compute poll timeout
            int poll_ms;
            if (deadline_ns) {
                struct timespec now;
                clock_gettime(CLOCK_MONOTONIC, &now);
                int64_t now_ns = (int64_t)now.tv_sec * 1000000000LL + now.tv_nsec;
                int64_t remain_ms = (deadline_ns - now_ns) / 1000000LL;
                if (remain_ms <= 0) { err = _ETIMEDOUT; break; }
                poll_ms = remain_ms > 1000 ? 1000 : (int)remain_ms;
            } else {
                // Wakeups and guest signals (SIGUSR1) interrupt the poll; the
                // timeout is only a safety net. At 100 ms, Firefox's ~60
                // idle threads cost ~600 host wakeups a second.
                poll_ms = 1000;
            }

            int ret = poll(&pfd, 1, poll_ms);
            if (ret > 0) {
                // Woken by pipe write — drain it
                char buf[16];
                while (read(current->futex_pipe[0], buf, sizeof(buf)) > 0) {}
                err = 0;
                break;
            }
            // ret == 0 (timeout) or ret < 0 (EINTR from signal) — check conditions
            if (current->group->doing_group_exit) {
                err = _EINTR; break;
            }
            if (current->sighand) {
                lock(&current->sighand->lock);
                bool sig_pending = !!(current->pending & ~current->blocked);
                unlock(&current->sighand->lock);
                if (sig_pending) { err = _EINTR; break; }
            }
            // Check value periodically (every ~100ms instead of every 10ms)
            read_wrlock(&current->mem->lock);
            dword_t *ptr = mem_ptr(current->mem, uaddr, MEM_READ);
            dword_t cur = ptr != NULL ? __atomic_load_n(ptr, __ATOMIC_SEQ_CST) : 0;
            read_wrunlock(&current->mem->lock);
            if (ptr == NULL) { err = _EFAULT; break; }
            if (cur != val) { err = 0; break; }
        }
        current->blocking = false;

        // Remove from queue (pipe stays open for reuse). A requeue may have
        // moved us to another futex (under both bucket locks), so lock the
        // bucket of the futex we're on now and check it didn't move again.
        struct futex *now;
        lock_t *l;
        for (;;) {
            now = __atomic_load_n(&wait.futex, __ATOMIC_ACQUIRE);
            l = futex_lock_of(now->mem, now->addr);
            lock(l);
            if (wait.futex == now)
                break;
            unlock(l);
        }
        list_remove_safe(&wait.queue);
        futex_put_unlocked(now);
        unlock(l);
        goto futex_wait_done;
    }
    futex_put(futex);
futex_wait_done:
    STRACE("%d end futex(FUTEX_WAIT)", current->pid);
    return err;
}

static int futex_wait(addr_t uaddr, dword_t val, struct timespec *timeout) {
    return futex_wait_bitset(uaddr, val, timeout, FUTEX_BITSET_MATCH_ANY_);
}

// Wake up to `max` waiters whose bitset intersects `bitset`. Caller must hold the futex's bucket lock.
static unsigned futex_wake_queue_bitset(struct futex *futex, dword_t max, dword_t bitset) {
    struct futex_wait *wait, *tmp;
    unsigned woken = 0;
    list_for_each_entry_safe(&futex->queue, wait, tmp, queue) {
        if (woken >= max)
            break;
        if (!(wait->bitset & bitset))
            continue;
        // Wake via per-thread pipe write — waiter is blocked on poll(futex_pipe[0])
        if (wait->task->futex_pipe[1] != -1) {
            char c = 1;
            write(wait->task->futex_pipe[1], &c, 1);
        }
        list_remove(&wait->queue);
        woken++;
    }
    return woken;
}

// Wake up to `max` waiters on the given futex. Caller must hold the futex's bucket lock.
static unsigned futex_wake_queue(struct futex *futex, dword_t max) {
    return futex_wake_queue_bitset(futex, max, FUTEX_BITSET_MATCH_ANY_);
}

static int futex_wakelike(int op, addr_t uaddr, dword_t wake_max, dword_t requeue_max, addr_t requeue_addr) {
    lock_t *l1 = futex_lock_of(current->mem, uaddr);
    lock_t *l2 = op == FUTEX_REQUEUE_ ? futex_lock_of(current->mem, requeue_addr) : l1;
    futex_lock_pair(l1, l2);
    struct futex *futex = futex_get_unlocked(uaddr);
    if (futex == NULL) {
        futex_unlock_pair(l1, l2);
        return _ENOMEM;
    }

    unsigned woken = futex_wake_queue(futex, wake_max);

    if (op == FUTEX_REQUEUE_) {
        struct futex *futex2 = futex_get_unlocked(requeue_addr);
        if (futex2 == NULL) {
            futex_put_unlocked(futex);
            futex_unlock_pair(l1, l2);
            return _ENOMEM;
        }
        struct futex_wait *wait, *tmp;
        unsigned requeued = 0;
        list_for_each_entry_safe(&futex->queue, wait, tmp, queue) {
            if (requeued >= requeue_max)
                break;
            // sketchy as hell
            list_remove(&wait->queue);
            list_add_tail(&futex2->queue, &wait->queue);
            assert(futex->refcount > 1); // should be true because this function keeps a reference
            futex->refcount--;
            futex2->refcount++;
            __atomic_store_n(&wait->futex, futex2, __ATOMIC_RELEASE);
            requeued++;
        }
        futex_put_unlocked(futex2);
        woken += requeued;
    }

    futex_put_unlocked(futex);
    futex_unlock_pair(l1, l2);
    return woken;
}

int futex_wake(addr_t uaddr, dword_t wake_max) {
    return futex_wakelike(FUTEX_WAKE_, uaddr, wake_max, 0, 0);
}

// FUTEX_CMP_REQUEUE: like FUTEX_REQUEUE, but first atomically check *uaddr == expected.
// Returns total woken+requeued, or _EAGAIN on mismatch, or _EFAULT on bad addr.
static int futex_cmp_requeue(addr_t uaddr, dword_t wake_max, dword_t requeue_max,
                             addr_t requeue_addr, dword_t expected) {
    lock_t *l1 = futex_lock_of(current->mem, uaddr);
    lock_t *l2 = futex_lock_of(current->mem, requeue_addr);
    futex_lock_pair(l1, l2);
    struct futex *futex = futex_get_unlocked(uaddr);
    if (futex == NULL) {
        futex_unlock_pair(l1, l2);
        return _ENOMEM;
    }

    dword_t cur;
    int err = 0;
    if (futex_load(futex, &cur))
        err = _EFAULT;
    else if (cur != expected)
        err = _EAGAIN;
    if (err < 0) {
        futex_put_unlocked(futex);
        futex_unlock_pair(l1, l2);
        return err;
    }

    unsigned woken = futex_wake_queue(futex, wake_max);

    struct futex *futex2 = futex_get_unlocked(requeue_addr);
    unsigned requeued = 0;
    if (futex2 != NULL) {
        struct futex_wait *wait, *tmp;
        list_for_each_entry_safe(&futex->queue, wait, tmp, queue) {
            if (requeued >= requeue_max)
                break;
            list_remove(&wait->queue);
            list_add_tail(&futex2->queue, &wait->queue);
            assert(futex->refcount > 1);
            futex->refcount--;
            futex2->refcount++;
            __atomic_store_n(&wait->futex, futex2, __ATOMIC_RELEASE);
            requeued++;
        }
        futex_put_unlocked(futex2);
    }

    futex_put_unlocked(futex);
    futex_unlock_pair(l1, l2);
    return woken + requeued;
}

// FUTEX_WAKE_OP: atomic RMW on *uaddr2, then wake up to val waiters on uaddr,
// and — if the old value of *uaddr2 satisfies the comparison — wake up to val2
// waiters on uaddr2. val3 encodes the op, oparg, cmp, and cmparg (see Linux).
static int futex_wake_op(addr_t uaddr, dword_t wake_max1, addr_t uaddr2,
                         dword_t wake_max2, dword_t val3) {
    int op_code = (val3 >> 28) & 0xf;
    int cmp_code = (val3 >> 24) & 0xf;
    // oparg/cmparg are 12-bit sign-extended.
    int32_t oparg  = (int32_t)((val3 << 8)) >> 20;  // bits [23:12] sign-extended
    int32_t cmparg = (int32_t)((val3 << 20)) >> 20; // bits [11:0] sign-extended

    bool shift = (op_code & FUTEX_OP_OPARG_SHIFT) != 0;
    op_code &= ~FUTEX_OP_OPARG_SHIFT;
    if (shift) {
        if (oparg < 0 || oparg > 31)
            return _EINVAL;
        oparg = 1 << oparg;
    }

    // Atomic RMW on *uaddr2.
    // We must hold mem->lock across mem_ptr+atomic op so the mapping can't vanish.
    read_wrlock(&current->mem->lock);
    uint32_t *ptr = mem_ptr(current->mem, uaddr2, MEM_WRITE);
    if (ptr == NULL) {
        read_wrunlock(&current->mem->lock);
        return _EFAULT;
    }
    uint32_t oldval;
    switch (op_code) {
        case FUTEX_OP_SET:
            oldval = __atomic_exchange_n(ptr, (uint32_t)oparg, __ATOMIC_SEQ_CST);
            break;
        case FUTEX_OP_ADD:
            oldval = __atomic_fetch_add(ptr, (uint32_t)oparg, __ATOMIC_SEQ_CST);
            break;
        case FUTEX_OP_OR:
            oldval = __atomic_fetch_or(ptr, (uint32_t)oparg, __ATOMIC_SEQ_CST);
            break;
        case FUTEX_OP_ANDN:
            oldval = __atomic_fetch_and(ptr, (uint32_t)~oparg, __ATOMIC_SEQ_CST);
            break;
        case FUTEX_OP_XOR:
            oldval = __atomic_fetch_xor(ptr, (uint32_t)oparg, __ATOMIC_SEQ_CST);
            break;
        default:
            read_wrunlock(&current->mem->lock);
            return _ENOSYS;
    }
    read_wrunlock(&current->mem->lock);

    int32_t sold = (int32_t)oldval;
    bool cmp_true;
    switch (cmp_code) {
        case FUTEX_OP_CMP_EQ: cmp_true = (sold == cmparg); break;
        case FUTEX_OP_CMP_NE: cmp_true = (sold != cmparg); break;
        case FUTEX_OP_CMP_LT: cmp_true = (sold <  cmparg); break;
        case FUTEX_OP_CMP_LE: cmp_true = (sold <= cmparg); break;
        case FUTEX_OP_CMP_GT: cmp_true = (sold >  cmparg); break;
        case FUTEX_OP_CMP_GE: cmp_true = (sold >= cmparg); break;
        default: return _ENOSYS;
    }

    // Wake waiters on both queues, holding both bucket locks.
    lock_t *l1 = futex_lock_of(current->mem, uaddr);
    lock_t *l2 = futex_lock_of(current->mem, uaddr2);
    futex_lock_pair(l1, l2);
    struct futex *f1 = futex_get_unlocked(uaddr);
    if (f1 == NULL) { futex_unlock_pair(l1, l2); return _ENOMEM; }
    unsigned total = futex_wake_queue(f1, wake_max1);
    if (cmp_true) {
        struct futex *f2 = futex_get_unlocked(uaddr2);
        if (f2 != NULL) {
            total += futex_wake_queue(f2, wake_max2);
            futex_put_unlocked(f2);
        }
    }
    futex_put_unlocked(f1);
    futex_unlock_pair(l1, l2);
    return total;
}

// Convert an absolute guest timeout on `clock` to the relative timeout
// futex_wait wants. Already-expired deadlines become zero.
static struct timespec futex_abs_to_rel(struct timespec_ abs, clockid_t clock) {
    struct timespec now, rel;
    clock_gettime(clock, &now);
    rel.tv_sec = abs.sec - now.tv_sec;
    rel.tv_nsec = abs.nsec - now.tv_nsec;
    if (rel.tv_nsec < 0) {
        rel.tv_sec--;
        rel.tv_nsec += 1000000000;
    }
    if (rel.tv_sec < 0)
        rel.tv_sec = rel.tv_nsec = 0;
    return rel;
}

// Atomic compare-and-swap on a guest futex word. Returns 0 on success, 1 if
// the word did not hold *expected (which is updated), or _EFAULT.
static int futex_cmpxchg(addr_t uaddr, dword_t *expected, dword_t desired) {
    read_wrlock(&current->mem->lock);
    dword_t *ptr = mem_ptr(current->mem, uaddr, MEM_WRITE);
    if (ptr == NULL) {
        read_wrunlock(&current->mem->lock);
        return _EFAULT;
    }
    bool ok = __atomic_compare_exchange_n(ptr, expected, desired, false,
                                          __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    read_wrunlock(&current->mem->lock);
    return ok ? 0 : 1;
}

static bool futex_owner_alive(pid_t_ tid) {
    lock(&pids_lock);
    struct task *task = pid_get_task(tid);
    bool alive = task != NULL && !task->zombie && !task->exiting;
    unlock(&pids_lock);
    return alive;
}

// PI futexes without priority inheritance: the word holds the owner's TID,
// FUTEX_WAITERS asks the owner to unlock through the kernel, and an owner
// that died leaves FUTEX_OWNER_DIED for the next owner. `deadline` is an
// absolute timeout on `clock`, or NULL.
static int futex_lock_pi(addr_t uaddr, struct timespec_ *deadline, clockid_t clock, bool trylock) {
    dword_t tid = current->pid;
    bool contended = false;
    for (;;) {
        // Take the lock under the bucket lock, so that whether anyone else is
        // queued (and so whether FUTEX_WAITERS must stay set) can't change.
        struct futex *futex = futex_get(uaddr);
        if (futex == NULL)
            return _ENOMEM;
        dword_t cur = 0;
        int r = futex_cmpxchg(uaddr, &cur, tid | (list_empty(&futex->queue) ? 0 : FUTEX_WAITERS_));
        if (r == 0 || r < 0) {
            futex_put(futex);
            return r;
        }
        if ((cur & FUTEX_TID_MASK_) == tid) {
            futex_put(futex);
            return _EDEADLK;
        }
        dword_t owner = cur & FUTEX_TID_MASK_;
        futex_put(futex);
        // (pids_lock must not be taken under a futex bucket lock)
        bool owner_dead = owner != 0 && !futex_owner_alive(owner);
        if (owner == 0 || owner_dead) {
            // Free (only flag bits left) or the owner died holding it
            futex = futex_get(uaddr);
            if (futex == NULL)
                return _ENOMEM;
            bool queued = !list_empty(&futex->queue);
            dword_t want = tid | (owner_dead ? FUTEX_OWNER_DIED_ : (cur & FUTEX_OWNER_DIED_)) |
                (queued || contended ? FUTEX_WAITERS_ : 0);
            r = futex_cmpxchg(uaddr, &cur, want);
            futex_put(futex);
            if (r <= 0)
                return r;
            continue;
        }
        if (trylock)
            return _EAGAIN;
        if (!(cur & FUTEX_WAITERS_)) {
            dword_t expected = cur;
            r = futex_cmpxchg(uaddr, &expected, cur | FUTEX_WAITERS_);
            if (r < 0)
                return r;
            if (r > 0)
                continue;
            cur |= FUTEX_WAITERS_;
        }
        contended = true;
        struct timespec rel;
        if (deadline != NULL)
            rel = futex_abs_to_rel(*deadline, clock);
        int err = futex_wait(uaddr, cur, deadline != NULL ? &rel : NULL);
        if (err == _ETIMEDOUT || err == _EINTR || err == _EFAULT)
            return err;
    }
}

static int futex_unlock_pi(addr_t uaddr) {
    dword_t tid = current->pid;
    for (;;) {
        dword_t cur;
        read_wrlock(&current->mem->lock);
        dword_t *ptr = mem_ptr(current->mem, uaddr, MEM_READ);
        if (ptr != NULL)
            cur = __atomic_load_n(ptr, __ATOMIC_SEQ_CST);
        read_wrunlock(&current->mem->lock);
        if (ptr == NULL)
            return _EFAULT;
        if ((cur & FUTEX_TID_MASK_) != tid)
            return _EPERM;
        int r = futex_cmpxchg(uaddr, &cur, 0);
        if (r < 0)
            return r;
        if (r > 0)
            continue;
        if (cur & FUTEX_WAITERS_)
            futex_wake(uaddr, 1);
        return 0;
    }
}

// The waiter half of a condvar on a PI mutex: wait on uaddr, then take the
// PI lock at uaddr2 before returning.
static int futex_wait_requeue_pi(addr_t uaddr, dword_t val, struct timespec_ *deadline,
                                 clockid_t clock, addr_t uaddr2) {
    struct timespec rel;
    if (deadline != NULL)
        rel = futex_abs_to_rel(*deadline, clock);
    int err = futex_wait(uaddr, val, deadline != NULL ? &rel : NULL);
    if (err < 0)
        return err;
    return futex_lock_pi(uaddr2, deadline, clock, false);
}

// The signaller half: wake the waiters, who then contend for the PI lock
// themselves (no real requeue is needed for correctness).
static int futex_cmp_requeue_pi(addr_t uaddr, dword_t nr_wake, dword_t nr_requeue, dword_t expected) {
    struct futex *futex = futex_get(uaddr);
    if (futex == NULL)
        return _ENOMEM;
    dword_t cur;
    if (futex_load(futex, &cur)) {
        futex_put(futex);
        return _EFAULT;
    }
    if (cur != expected) {
        futex_put(futex);
        return _EAGAIN;
    }
    unsigned woken = futex_wake_queue(futex, nr_wake + nr_requeue);
    futex_put(futex);
    return woken;
}

// Robust futex list: release the futexes a dying thread still holds.
void futex_exit_robust_list(void) {
    addr_t head = current->robust_list;
    if (head == 0 || current->mm == NULL)
        return;
    struct {
        uint64_t next;
        int64_t offset;
        uint64_t pending;
    } h;
    if (user_read(head, &h, sizeof(h)))
        return;
    dword_t tid = current->pid;
    addr_t entries[2048 + 1];
    int count = 0;
    for (addr_t entry = h.next & ~1ULL; entry != head && entry != 0 && count < 2048;) {
        entries[count++] = entry;
        uint64_t next;
        if (user_read(entry, &next, sizeof(next)))
            break;
        entry = next & ~1ULL;
    }
    if (h.pending != 0 && count <= 2048)
        entries[count++] = h.pending & ~1ULL;
    for (int i = 0; i < count; i++) {
        addr_t word = entries[i] + h.offset;
        for (;;) {
            dword_t cur;
            if (user_get(word, cur) || (cur & FUTEX_TID_MASK_) != tid)
                break;
            dword_t want = (cur & FUTEX_WAITERS_) | FUTEX_OWNER_DIED_;
            int r = futex_cmpxchg(word, &cur, want);
            if (r < 0)
                break;
            if (r == 0) {
                if (cur & FUTEX_WAITERS_)
                    futex_wake(word, 1);
                break;
            }
        }
    }
}

dword_t sys_futex(addr_t uaddr, dword_t op, dword_t val, addr_t timeout_or_val2, addr_t uaddr2, dword_t val3) {
    if (!(op & FUTEX_PRIVATE_FLAG_)) {
        STRACE("!FUTEX_PRIVATE ");
    }
    int cmd = op & FUTEX_CMD_MASK_;
    struct timespec timeout = {0};
    if ((cmd == FUTEX_WAIT_ || cmd == FUTEX_WAIT_BITSET_) && timeout_or_val2) {
        struct timespec_ timeout_;
        if (user_get(timeout_or_val2, timeout_))
            return _EFAULT;
        if (cmd == FUTEX_WAIT_BITSET_) {
            // FUTEX_WAIT_BITSET takes an absolute timeout on CLOCK_MONOTONIC,
            // or CLOCK_REALTIME with FUTEX_CLOCK_REALTIME.
            timeout = futex_abs_to_rel(timeout_, op & FUTEX_CLOCK_REALTIME_ ? CLOCK_REALTIME : CLOCK_MONOTONIC);
        } else {
            timeout.tv_sec = timeout_.sec;
            timeout.tv_nsec = timeout_.nsec;
        }
    }
    switch (cmd) {
        case FUTEX_WAIT_:
            STRACE("futex(FUTEX_WAIT, %#x, %d, 0x%x {%ds %dns}) = ...\n", uaddr, val, timeout_or_val2, timeout.tv_sec, timeout.tv_nsec);
            return futex_wait(uaddr, val, timeout_or_val2 ? &timeout : NULL);
        case FUTEX_WAIT_BITSET_:
            STRACE("futex(FUTEX_WAIT_BITSET, %#x, %d, mask=%#x) = ...\n", uaddr, val, val3);
            if (val3 == 0)
                return _EINVAL;
            return futex_wait_bitset(uaddr, val, timeout_or_val2 ? &timeout : NULL, val3);
        case FUTEX_WAKE_:
            STRACE("futex(FUTEX_WAKE, %#x, %d)", uaddr, val);
            return futex_wakelike(FUTEX_WAKE_, uaddr, val, 0, 0);
        case FUTEX_WAKE_BITSET_: {
            STRACE("futex(FUTEX_WAKE_BITSET, %#x, %d, mask=%#x)", uaddr, val, val3);
            if (val3 == 0)
                return _EINVAL;
            struct futex *futex = futex_get(uaddr);
            if (futex == NULL)
                return _ENOMEM;
            unsigned woken = futex_wake_queue_bitset(futex, val, val3);
            futex_put(futex);
            return woken;
        }
        case FUTEX_LOCK_PI_:
        case FUTEX_LOCK_PI2_:
        case FUTEX_TRYLOCK_PI_:
        case FUTEX_WAIT_REQUEUE_PI_: {
            // LOCK_PI always takes an absolute CLOCK_REALTIME timeout; the
            // others use CLOCK_MONOTONIC unless FUTEX_CLOCK_REALTIME is set.
            struct timespec_ deadline;
            bool has_deadline = cmd != FUTEX_TRYLOCK_PI_ && timeout_or_val2 != 0;
            if (has_deadline && user_get(timeout_or_val2, deadline))
                return _EFAULT;
            clockid_t clock = cmd == FUTEX_LOCK_PI_ || (op & FUTEX_CLOCK_REALTIME_) ?
                CLOCK_REALTIME : CLOCK_MONOTONIC;
            STRACE("futex(PI cmd=%d, %#x, %d)", cmd, uaddr, val);
            if (cmd == FUTEX_WAIT_REQUEUE_PI_)
                return futex_wait_requeue_pi(uaddr, val, has_deadline ? &deadline : NULL, clock, uaddr2);
            return futex_lock_pi(uaddr, has_deadline ? &deadline : NULL, clock, cmd == FUTEX_TRYLOCK_PI_);
        }
        case FUTEX_UNLOCK_PI_:
            STRACE("futex(FUTEX_UNLOCK_PI, %#x)", uaddr);
            return futex_unlock_pi(uaddr);
        case FUTEX_CMP_REQUEUE_PI_:
            STRACE("futex(FUTEX_CMP_REQUEUE_PI, %#x, %d, %#x, expected=%d)", uaddr, val, uaddr2, val3);
            return futex_cmp_requeue_pi(uaddr, val, timeout_or_val2, val3);
        case FUTEX_REQUEUE_:
            STRACE("futex(FUTEX_REQUEUE, %#x, %d, %#x)", uaddr, val, uaddr2);
            return futex_wakelike(FUTEX_REQUEUE_, uaddr, val, timeout_or_val2, uaddr2);
        case FUTEX_CMP_REQUEUE_:
            STRACE("futex(FUTEX_CMP_REQUEUE, %#x, %d, %#x, expected=%d)", uaddr, val, uaddr2, val3);
            return futex_cmp_requeue(uaddr, val, timeout_or_val2, uaddr2, val3);
        case FUTEX_WAKE_OP_:
            STRACE("futex(FUTEX_WAKE_OP, %#x, %d, %#x, %d, %#x)", uaddr, val, uaddr2, timeout_or_val2, val3);
            return futex_wake_op(uaddr, val, uaddr2, timeout_or_val2, val3);
    }
    STRACE("futex(%#x, %d, %d, timeout=%#x, %#x, %d) ", uaddr, op, val, timeout_or_val2, uaddr2, val3);
    // Loud diagnostic — these should be rare now that CMP_REQUEUE and WAKE_OP are implemented.
    // Returning _EINVAL instead of _ENOSYS lets most userspace libraries fall back to
    // FUTEX_WAKE/WAIT rather than treating it as "kernel too old" and aborting.
    printk("SYS_FUTEX: unsupported op=%d (cmd=%d) uaddr=%#x val=%d uaddr2=%#x val3=%#x pid=%d comm=%s\n",
           op, cmd, uaddr, val, uaddr2, val3, current->pid, current->comm);
    return _EINVAL;
}

struct robust_list_head_ {
    addr_t list;
    dword_t offset;
    addr_t list_op_pending;
};

int_t sys_set_robust_list(addr_t robust_list, dword_t len) {
    STRACE("set_robust_list(%#x, %d)", robust_list, len);
    if (len != sizeof(struct robust_list_head_))
        return _EINVAL;
    current->robust_list = robust_list;
    return 0;
}

int_t sys_get_robust_list(pid_t_ pid, addr_t robust_list_ptr, addr_t len_ptr) {
    STRACE("get_robust_list(%d, %#x, %#x)", pid, robust_list_ptr, len_ptr);

    // pid 0 means the calling thread (musl probes robust support this way)
    addr_t list;
    if (pid == 0) {
        list = current->robust_list;
    } else {
        lock(&pids_lock);
        struct task *task = pid_get_task(pid);
        if (task == NULL) {
            unlock(&pids_lock);
            return _ESRCH;
        }
        if (task->group != current->group) {
            unlock(&pids_lock);
            return _EPERM;
        }
        list = task->robust_list;
        unlock(&pids_lock);
    }

    if (user_put(robust_list_ptr, list))
        return _EFAULT;
    // len is a size_t
    addr_t len = sizeof(struct robust_list_head_);
    if (user_put(len_ptr, len))
        return _EFAULT;
    return 0;
}
