#include "debug.h"
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <stdio.h>
#include "kernel/calls.h"
#include "kernel/signal.h"
#include "kernel/task.h"
#include "kernel/native_offload.h"
#include "kernel/vdso.h"
#include "emu/interrupt.h"

#if is_gcc(9)
#pragma GCC diagnostic ignored "-Waddress-of-packed-member"
#endif


int xsave_extra = 0;
int fxsave_extra = 0;
static void sigmask_set(sigset_t_ set);
static void altstack_to_user(struct task *task, struct stack_t_ *user_stack);
static bool is_on_altstack(addr_t sp, struct task *task);

static int signal_is_blockable(int sig) {
    return sig != SIGKILL_ && sig != SIGSTOP_;
}

#define UNBLOCKABLE_MASK (sig_mask(SIGKILL_) | sig_mask(SIGSTOP_))

#define SIGNAL_IGNORE 0
#define SIGNAL_KILL 1
#define SIGNAL_CALL_HANDLER 2
#define SIGNAL_STOP 3

static int signal_action(struct sighand *sighand, int sig) {
    if (signal_is_blockable(sig)) {
        struct sigaction_ *action = &sighand->action[sig];
        if (action->handler == SIG_IGN_)
            return SIGNAL_IGNORE;
        if (action->handler != SIG_DFL_)
            return SIGNAL_CALL_HANDLER;
    }

    switch (sig) {
        case SIGURG_: case SIGCONT_: case SIGCHLD_:
        case SIGIO_: case SIGWINCH_:
            return SIGNAL_IGNORE;

        case SIGSTOP_: case SIGTSTP_: case SIGTTIN_: case SIGTTOU_:
            return SIGNAL_STOP;

        default:
            return SIGNAL_KILL;
    }
}

// ---- RLIMIT_SIGPENDING accounting ---------------------------------------------------
// Queued signal details are charged to the target's user, so one user cannot queue without bound.

struct sigpending_user {
    struct sigpending_user *next;
    uid_t_ uid;
    uint64_t count;
};
static lock_t sigpending_lock = LOCK_INITIALIZER;
static struct sigpending_user *sigpending_users;

static bool sigpending_charge(uid_t_ uid, uint64_t limit) {
    bool charged = false;
    lock(&sigpending_lock);
    struct sigpending_user *user = sigpending_users;
    while (user != NULL && user->uid != uid)
        user = user->next;
    if (user == NULL) {
        user = calloc(1, sizeof(*user));
        if (user != NULL) {
            user->uid = uid;
            user->next = sigpending_users;
            sigpending_users = user;
        }
    }
    if (user != NULL && user->count < limit) {
        user->count++;
        charged = true;
    }
    unlock(&sigpending_lock);
    return charged;
}

static void sigpending_uncharge(uid_t_ uid) {
    lock(&sigpending_lock);
    for (struct sigpending_user *user = sigpending_users; user != NULL; user = user->next) {
        if (user->uid == uid) {
            if (user->count > 0)
                user->count--;
            break;
        }
    }
    unlock(&sigpending_lock);
}

void sigqueue_free(struct sigqueue *sigqueue) {
    if (sigqueue->charged)
        sigpending_uncharge(sigqueue->charged_uid);
    free(sigqueue);
}

// Signals the kernel itself raises, and kill(), never fail for lack of room; sigqueue() and tgkill() do.
static bool signal_overrides_rlimit(const struct siginfo_ *info) {
    return info->code >= 0 || info->code == SI_TIMER_;
}

// ---- Queues -----------------------------------------------------------------------------
// A thread has a queue of its own for signals sent to it, and shares one with the rest of its
// process for signals sent to the process. Standard signals coalesce within a queue; each
// instance of a real-time signal is kept, with its siginfo.

// Queue `sig` on task's own queue, or on its process's when `shared`. Sighand lock held.
// *queued says whether an entry was added (a standard signal that is already pending is not).
static int enqueue_signal(struct task *task, int sig, struct siginfo_ info, bool shared, bool *queued) {
    sigset_t_ *pending = shared ? &task->group->shared_pending : &task->pending;
    struct list *queue = shared ? &task->group->shared_queue : &task->queue;
    *queued = false;
    // A timer has at most one signal pending; further expirations count as overruns of it.
    if (info.code == SI_TIMER_ && sigset_has(*pending, sig)) {
        struct sigqueue *entry;
        list_for_each_entry(queue, entry, queue) {
            if (entry->info.sig == sig && entry->info.code == SI_TIMER_ &&
                    entry->info.timer.timer == info.timer.timer) {
                int_t overrun = entry->info.timer.overrun;
                if (overrun < INT32_MAX - 1 - info.timer.overrun)
                    entry->info.timer.overrun = overrun + 1 + info.timer.overrun;
                else
                    entry->info.timer.overrun = INT32_MAX;
                return 0;
            }
        }
    }
    if (sig < SIGRTMIN_ && sigset_has(*pending, sig))
        return 0;

    struct sigqueue *sigqueue = malloc(sizeof(struct sigqueue));
    if (sigqueue == NULL)
        return _EAGAIN;
    sigqueue->charged = false;
    if (!signal_overrides_rlimit(&info)) {
        uid_t_ uid = task->uid;
        if (sigpending_charge(uid, task->group->limits[RLIMIT_SIGPENDING_].cur)) {
            sigqueue->charged = true;
            sigqueue->charged_uid = uid;
        } else if (sig >= SIGRTMIN_ && info.code != SI_USER_) {
            free(sigqueue);
            return _EAGAIN;
        } else {
            // the signal still arrives; only its details are lost
            info = (struct siginfo_) {.code = SI_USER_};
        }
    }
    sigqueue->info = info;
    sigqueue->info.sig = sig;
    list_add_tail(queue, &sigqueue->queue);
    sigset_add(pending, sig);
    *queued = true;
    return 0;
}

static struct sigqueue *dequeue_from(struct list *queue, sigset_t_ *pending, sigset_t_ mask) {
    sigset_t_ available = *pending & mask;
    if (available == 0)
        return NULL;
    int sig = __builtin_ctzll(available) + 1; // lowest number first
    struct sigqueue *found = NULL, *sigqueue;
    bool more = false;
    list_for_each_entry(queue, sigqueue, queue) {
        if (sigqueue->info.sig != sig)
            continue;
        if (found == NULL) {
            found = sigqueue;
        } else {
            more = true;
            break;
        }
    }
    if (found == NULL) {
        sigset_del(pending, sig);
        return NULL;
    }
    list_remove(&found->queue);
    if (!more)
        sigset_del(pending, sig);
    return found;
}

struct sigqueue *dequeue_signal(sigset_t_ mask) {
    struct sigqueue *sigqueue = dequeue_from(&current->queue, &current->pending, mask);
    if (sigqueue == NULL)
        sigqueue = dequeue_from(&current->group->shared_queue, &current->group->shared_pending, mask);
    if (sigqueue != NULL && sigqueue->info.code == SI_TIMER_) {
        int_t id = sigqueue->info.timer.timer;
        if (id >= 0 && id < TIMERS_MAX) {
            lock(&current->group->lock);
            current->group->posix_timers[id].overrun_last = sigqueue->info.timer.overrun;
            unlock(&current->group->lock);
        }
    }
    return sigqueue;
}

// Whether a thread would take a process-directed signal: it does not block it, or it is waiting
// for it in sigtimedwait.
static bool thread_wants_signal(struct task *thread, int sig) {
    if (thread->exiting || thread->zombie || thread->sighand == NULL)
        return false;
    if (!signal_is_blockable(sig))
        return true;
    return !sigset_has(thread->blocked, sig) || sigset_has(thread->waiting, sig);
}

// Call with pids_lock held, to walk the group's threads.
static struct task *pick_signal_thread(struct task *task, int sig) {
    if (thread_wants_signal(task, sig))
        return task;
    struct task *thread;
    list_for_each_entry(&task->group->threads, thread, group_links) {
        if (thread_wants_signal(thread, sig))
            return thread;
    }
    return NULL;
}

// Get `target` out of whatever it is blocked in so it looks at its signals. Sighand lock held;
// it is dropped and retaken around the wakeup.
static void kick_thread(struct sighand *sighand, struct task *target) {
    cpu_poke(&target->cpu);
    if (target == current)
        return;
    pthread_kill(target->thread, SIGUSR1);

    // wake up any pthread condition waiters
    // actual madness, I hope to god it's correct
    // must release the sighand lock while going insane, to avoid a deadlock
    unlock(&sighand->lock);
    // Wake up the target thread's condvar wait.
    // We don't acquire waiting_lock (the associated mutex) because:
    // 1. It may be held by the target thread inside pthread_cond_wait,
    //    and spinning on it blocks the condvar from returning.
    // 2. pthread_cond_broadcast() is safe without the mutex — worst case
    //    is a spurious wakeup, which wait_for() handles via re-checking.
    lock(&target->waiting_cond_lock);
    if (target->waiting_cond != NULL)
        notify(target->waiting_cond);
    unlock(&target->waiting_cond_lock);
    lock(&sighand->lock);
}

// Queue a signal and wake the thread that should take it. Sighand lock held. A shared
// (process-directed) signal needs pids_lock too, to find that thread.
static int deliver_signal_unlocked(struct task *task, int sig, struct siginfo_ info, bool shared) {
    bool queued;
    int err = enqueue_signal(task, sig, info, shared, &queued);
    if (err < 0 || !queued)
        return err;

    struct sighand *sighand = task->sighand;
    if (shared) {
        struct task *target = pick_signal_thread(task, sig);
        if (target != NULL)
            kick_thread(sighand, target);
        return 0;
    }
    if (sigset_has(task->blocked & ~task->waiting, sig) && signal_is_blockable(sig))
        return 0;
    kick_thread(sighand, task);
    return 0;
}

void deliver_signal(struct task *task, int sig, struct siginfo_ info) {
    if (task->sighand == NULL)
        return;
    lock(&task->sighand->lock);
    deliver_signal_unlocked(task, sig, info, false);
    unlock(&task->sighand->lock);
    cpu_poke(&task->cpu);
    signalfd_notify(task, sig);
}

static int send_signal_common(struct task *task, int sig, struct siginfo_ info, bool shared) {
    // signal zero is for testing whether a process exists
    if (sig == 0)
        return 0;
    if (task->zombie || task->exiting) {
        // a process's signal still has somewhere to go while another of its threads is running
        if (!shared || !signal_is_blockable(sig))
            return 0;
        struct task *alive = NULL, *thread;
        list_for_each_entry(&task->group->threads, thread, group_links) {
            if (!thread->exiting && !thread->zombie && thread->sighand != NULL) {
                alive = thread;
                break;
            }
        }
        if (alive == NULL)
            return 0;
        task = alive;
    }
#ifdef GUEST_ARM64
    if ((sig == SIGTRAP_ || sig == SIGABRT_ || sig == SIGILL_ || sig == SIGSEGV_ || sig == SIGBUS_)
        && ish_exec_trace())
        fprintf(stderr, "SIGNAL_TRACE: sig=%d pc=0x%llx pid=%d sp=0x%llx lr=0x%llx fault=0x%llx\n",
                sig, (unsigned long long)task->cpu.pc, task->pid,
                (unsigned long long)task->cpu.sp,
                (unsigned long long)task->cpu.regs[30],
                (unsigned long long)task->cpu.segfault_addr);
#endif

    // Native offload: forward signal to the host native process
    if (native_offload_forward_signal(task, sig))
        return 0;

    struct sighand *sighand = task->sighand;
    if (sighand == NULL)
        return 0;
    // SIGKILL and SIGSTOP act on the thread they are sent to
    if (!signal_is_blockable(sig))
        shared = false;
    lock(&sighand->lock);
    // Like Linux, a blocked signal is queued even if its action is to ignore
    // it, since the action may change before it is unblocked (and signalfd
    // readers depend on it, e.g. for SIGCHLD).
    bool queued = signal_action(sighand, sig) != SIGNAL_IGNORE ||
        (signal_is_blockable(sig) && sigset_has(task->blocked, sig));
    int err = 0;
    if (queued)
        err = deliver_signal_unlocked(task, sig, info, shared);
    unlock(&sighand->lock);
    if (queued)
        signalfd_notify(task, sig);

    if (sig == SIGCONT_ || sig == SIGKILL_) {
        lock(&task->group->lock);
        task->group->stopped = false;
        notify(&task->group->stopped_cond);
        unlock(&task->group->lock);
    }
    return err;
}

void send_signal(struct task *task, int sig, struct siginfo_ info) {
    send_signal_common(task, sig, info, false);
}

void send_process_signal(struct task *task, int sig, struct siginfo_ info) {
    send_signal_common(task, sig, info, true);
}

int send_signal_checked(struct task *task, int sig, struct siginfo_ info, bool thread_directed) {
    return send_signal_common(task, sig, info, !thread_directed);
}

bool try_self_signal(int sig) {
    assert(sig == SIGTTIN_ || sig == SIGTTOU_);

    struct sighand *sighand = current->sighand;
    lock(&sighand->lock);
    bool can_send = signal_action(sighand, sig) != SIGNAL_IGNORE &&
        !sigset_has(current->blocked, sig);
    if (can_send)
        deliver_signal_unlocked(current, sig, SIGINFO_NIL, false);
    unlock(&sighand->lock);
    return can_send;
}

int send_group_signal(dword_t pgid, int sig, struct siginfo_ info) {
    lock(&pids_lock);
    struct pid *pid = pid_get(pgid);
    if (pid == NULL) {
        unlock(&pids_lock);
        return _ESRCH;
    }
    struct tgroup *tgroup;
    list_for_each_entry(&pid->pgroup, tgroup, pgroup) {
        send_process_signal(tgroup->leader, sig, info);
    }
    unlock(&pids_lock);
    return 0;
}

static addr_t sigreturn_trampoline(const char *name) {
    addr_t sigreturn_addr = vdso_symbol(name);
    if (sigreturn_addr == 0) {
        die("sigreturn not found in vdso, this should never happen");
    }
    return current->mm->vdso + sigreturn_addr;
}

int sigset_size_valid(dword_t size) {
#if defined(GUEST_ARM64)
    return size >= sizeof(sigset_t_) && (size % sizeof(sigset_t_) == 0);
#else
    return size == sizeof(sigset_t_);
#endif
}

int user_get_sigset(addr_t addr, dword_t size, sigset_t_ *out) {
    if (!sigset_size_valid(size))
        return _EINVAL;
#if defined(GUEST_ARM64)
    uint64_t word = 0;
    if (user_read(addr, &word, sizeof(word)))
        return _EFAULT;
    *out = (sigset_t_) word;
    return 0;
#else
    if (user_get(addr, *out))
        return _EFAULT;
    return 0;
#endif
}

int user_put_sigset(addr_t addr, dword_t size, sigset_t_ set) {
    if (!sigset_size_valid(size))
        return _EINVAL;
#if defined(GUEST_ARM64)
    uint64_t word = (uint64_t) set;
    if (user_write(addr, &word, sizeof(word)))
        return _EFAULT;
    dword_t remaining = size - sizeof(word);
    addr_t pos = addr + sizeof(word);
    static const byte_t zeros[16] = {0};
    while (remaining > 0) {
        dword_t chunk = remaining > sizeof(zeros) ? sizeof(zeros) : remaining;
        if (user_write(pos, zeros, chunk))
            return _EFAULT;
        pos += chunk;
        remaining -= chunk;
    }
    return 0;
#else
    if (user_put(addr, set))
        return _EFAULT;
    return 0;
#endif
}

#if defined(GUEST_ARM64)
struct sigaction_arm64_kernel {
    uint64_t handler;
    uint64_t flags;
    uint64_t restorer;
    uint64_t mask[1];
};

static int user_get_sigaction_arm64(addr_t addr, dword_t sigset_size, struct sigaction_ *out) {
    uint64_t handler = 0;
    uint64_t flags = 0;
    uint64_t restorer = 0;
    if (user_read(addr + offsetof(struct sigaction_arm64_kernel, handler), &handler, sizeof(handler)))
        return _EFAULT;
    if (user_read(addr + offsetof(struct sigaction_arm64_kernel, flags), &flags, sizeof(flags)))
        return _EFAULT;
    if (user_read(addr + offsetof(struct sigaction_arm64_kernel, restorer), &restorer, sizeof(restorer)))
        return _EFAULT;
    sigset_t_ mask = 0;
    int err = user_get_sigset(addr + offsetof(struct sigaction_arm64_kernel, mask), sigset_size, &mask);
    if (err)
        return err;
    *out = (struct sigaction_) {
        .handler = (addr_t) handler,
        .flags = (dword_t) flags,
        .restorer = (addr_t) restorer,
        .mask = mask,
    };
    return 0;
}

static int user_put_sigaction_arm64(addr_t addr, dword_t sigset_size, const struct sigaction_ *in) {
    uint64_t handler = (uint64_t) in->handler;
    uint64_t flags = (uint64_t) in->flags;
    uint64_t restorer = (uint64_t) in->restorer;
    if (user_write(addr + offsetof(struct sigaction_arm64_kernel, handler), &handler, sizeof(handler)))
        return _EFAULT;
    if (user_write(addr + offsetof(struct sigaction_arm64_kernel, flags), &flags, sizeof(flags)))
        return _EFAULT;
    if (user_write(addr + offsetof(struct sigaction_arm64_kernel, restorer), &restorer, sizeof(restorer)))
        return _EFAULT;
    return user_put_sigset(addr + offsetof(struct sigaction_arm64_kernel, mask), sigset_size, in->mask);
}
#endif

#if defined(GUEST_ARM64)
// ARM64 signal handling - matches Linux kernel sigcontext layout

static void setup_sigcontext(struct sigcontext_ *sc, struct cpu_state *cpu) {
    // Store full ARM64 state needed for sigreturn
    // NOTE: Do NOT call arm64_sync_nzcv() here!
    // The JIT maintains cpu->nzcv directly (via mrs/str in store_flags).
    // The individual byte flags (nf/zf/cf/vf) are stale and must not
    // overwrite the correct nzcv value. See also: MEMORY.md NZCV lesson.

    // Clear the entire structure first
    memset(sc, 0, sizeof(*sc));

    sc->fault_address = cpu->segfault_addr;
    memcpy(sc->regs, cpu->regs, sizeof(cpu->regs));
    sc->sp = cpu->sp;
    sc->pc = cpu->pc;
    sc->pstate = cpu->nzcv;

    // Set up FPSIMD context in the extension area
    struct fpsimd_context_ *fpsimd = (struct fpsimd_context_ *)sc->__reserved;
    fpsimd->magic = FPSIMD_MAGIC;
    fpsimd->size = sizeof(struct fpsimd_context_);
    fpsimd->fpsr = cpu->fpsr;
    fpsimd->fpcr = cpu->fpcr;
    // Copy vector registers
    for (int i = 0; i < 32; i++) {
        fpsimd->vregs[i] = cpu->fp[i].q;
    }

    // Terminate the extension list with null entry
    uint32_t *term = (uint32_t *)(sc->__reserved + sizeof(struct fpsimd_context_));
    term[0] = 0;  // magic = 0 terminates
    term[1] = 0;  // size = 0
}
#else
static void setup_sigcontext(struct sigcontext_ *sc, struct cpu_state *cpu) {
    sc->ax = cpu->eax;
    sc->bx = cpu->ebx;
    sc->cx = cpu->ecx;
    sc->dx = cpu->edx;
    sc->di = cpu->edi;
    sc->si = cpu->esi;
    sc->bp = cpu->ebp;
    sc->sp = sc->sp_at_signal = cpu->esp;
    sc->ip = cpu->eip;
    collapse_flags(cpu);
    sc->flags = cpu->eflags;
    sc->trapno = cpu->trapno;
    if (cpu->trapno == INT_GPF)
        sc->cr2 = cpu->segfault_addr;
    // TODO more shit
    sc->oldmask = current->blocked & 0xffffffff;
}
#endif

static void setup_sigframe(struct siginfo_ *info, struct sigframe_ *frame) {
    frame->restorer = sigreturn_trampoline("__kernel_sigreturn");
    frame->sig = info->sig;
    setup_sigcontext(&frame->sc, &current->cpu);
    frame->extramask = current->blocked >> 32;

    static const struct {
        uint16_t popmov;
        uint32_t nr_sigreturn;
        uint16_t int80;
    } __attribute__((packed)) retcode = {
        .popmov = 0xb858,
        .nr_sigreturn = 113,
        .int80 = 0x80cd,
    };
    memcpy(frame->retcode, &retcode, sizeof(retcode));
}

static void setup_rt_sigframe(struct siginfo_ *info, struct rt_sigframe_ *frame) {
    frame->restorer = sigreturn_trampoline("__kernel_rt_sigreturn");
    frame->sig = info->sig;
    frame->info = *info;
    frame->uc.flags = 0;
    frame->uc.link = 0;
    altstack_to_user(current, &frame->uc.stack);
    setup_sigcontext(&frame->uc.mcontext, &current->cpu);
    frame->uc.sigmask = current->blocked;

    static const struct {
        uint8_t mov;
        uint32_t nr_rt_sigreturn;
        uint16_t int80;
        uint8_t pad;
    } __attribute__((packed)) rt_retcode = {
        .mov = 0xb8,
        .nr_rt_sigreturn = 173,
        .int80 = 0x80cd,
    };
    memcpy(frame->retcode, &rt_retcode, sizeof(rt_retcode));
}

// ISH_CRASHLOG=1 (or ISH_LOG): a process killed by a crash signal is logged on the
// host's stderr with where it was, the mapping (library + offset) of its pc and lr,
// and the thread's last syscalls, so a soak can tell which process died and why.
// ISH_CRASHLOG=2 also logs crash signals that go to a handler (a program's own
// crash handler may then _exit, which the plain log cannot see).
static int crashlog_level(void) {
    static int level = -1;
    if (level < 0) {
        const char *e = getenv("ISH_CRASHLOG");
        level = e != NULL && e[0] >= '1' && e[0] <= '9' ? e[0] - '0' : ish_log_enabled() ? 1 : 0;
    }
    return level;
}
static bool crashlog_enabled(void) {
    return crashlog_level() > 0;
}

static void describe_addr(addr_t addr, char *out, size_t size) {
    snprintf(out, size, "?");
    struct mem *mem = current->mem;
    if (mem == NULL)
        return;
    read_wrlock(&mem->lock);
    struct pt_entry *entry = mem_pt(mem, PAGE(addr));
    if (entry != NULL && entry->data != NULL) {
        char path[MAX_PATH] = "[anon]";
        if (entry->data->fd != NULL && generic_getpath(entry->data->fd, path) < 0)
            snprintf(path, sizeof(path), "[file]");
        // offset in the file: the mapping's file offset + the page's offset in it
        unsigned long long off = entry->data->file_offset + entry->offset - (entry->offset % PAGE_SIZE) +
                                 PGOFFSET(addr);
        snprintf(out, size, "%s+%#llx", path, entry->data->fd != NULL ? off : (unsigned long long) PGOFFSET(addr));
    }
    read_wrunlock(&mem->lock);
}

static void log_crash_line(const char *what, int sig, int code, addr_t fault_addr);

void log_crash(int sig, int code, addr_t fault_addr) {
    if (!crashlog_enabled() || current == NULL || current->crash_logged)
        return;
    current->crash_logged = true;
    log_crash_line("ish crash", sig, code, fault_addr);
}

static void log_crash_line(const char *what, int sig, int code, addr_t fault_addr) {
    struct cpu_state *cpu = &current->cpu;
    char pc_where[MAX_PATH + 32], lr_where[MAX_PATH + 32];
#ifdef GUEST_ARM64
    addr_t pc = cpu->pc, lr = cpu->regs[30], sp = cpu->sp;
#else
    addr_t pc = cpu->eip, lr = 0, sp = cpu->esp;
#endif
    describe_addr(pc, pc_where, sizeof(pc_where));
    describe_addr(lr, lr_where, sizeof(lr_where));
    char line[2048];
    int n = snprintf(line, sizeof(line),
            "%s: pid %d tgid %d (%s) signal %d code %d addr %#llx pc %#llx %s lr %#llx %s sp %#llx\n"
            "%s:   last syscalls (oldest first):",
            what, current->pid, current->tgid, current->comm, sig, code,
            (unsigned long long) fault_addr, (unsigned long long) pc, pc_where,
            (unsigned long long) lr, lr_where, (unsigned long long) sp, what);
    unsigned count = current->recent_syscall_pos < 16 ? current->recent_syscall_pos : 16;
    for (unsigned i = 0; i < count && n < (int) sizeof(line) - 64; i++) {
        unsigned slot = (current->recent_syscall_pos - count + i) % 16;
        n += snprintf(line + n, sizeof(line) - n, " %u(%#llx)=%lld", current->recent_syscalls[slot].nr,
                (unsigned long long) current->recent_syscalls[slot].arg0,
                (long long) current->recent_syscalls[slot].result);
    }
    fprintf(stderr, "%s\n", line);
}

// ISH_CRASHLOG=2: a process that calls exit_group with a nonzero code, with its last syscalls and
// the guest's frame-pointer chain (a program's fatal-error path that ends in exit()).
void log_exit(int code) {
    if (crashlog_level() < 2 || current == NULL || code == 0)
        return;
    log_crash_line("ish exit", 0, code, 0);   // "signal 0 code N": exit(N)
#ifdef GUEST_ARM64
    char line[4 * MAX_PATH], where[MAX_PATH + 32];
    int n = snprintf(line, sizeof(line), "ish exit:   frames:");
    addr_t fp = current->cpu.regs[29];
    for (int i = 0; i < 16 && fp != 0 && n < (int) (sizeof(line) - sizeof(where)); i++) {
        uint64_t frame[2];
        if (user_read(fp, frame, sizeof(frame)))
            break;
        describe_addr(frame[1], where, sizeof(where));
        n += snprintf(line + n, sizeof(line) - n, " %s", where);
        if (frame[0] <= fp)
            break;
        fp = frame[0];
    }
    fprintf(stderr, "%s\n", line);
#endif
}

// Returns whether the signal was set up to run a handler, which changes where the thread resumes.
static bool receive_signal(struct sighand *sighand, struct siginfo_ *info) {
    int sig = info->sig;
    STRACE("%d receiving signal %d\n", current->pid, sig);

    int action_type = signal_action(sighand, sig);
    switch (action_type) {
        case SIGNAL_IGNORE:
            return false;

        case SIGNAL_STOP:
            lock(&current->group->lock);
            current->group->stopped = true;
            current->group->group_exit_code = sig << 8 | 0x7f;
            unlock(&current->group->lock);
            return false;

        case SIGNAL_KILL:
            unlock(&sighand->lock); // do_exit must be called without this lock
            if (sig == SIGSEGV_ || sig == SIGBUS_ || sig == SIGILL_ || sig == SIGABRT_ || sig == SIGFPE_ ||
                    sig == SIGTRAP_ || sig == SIGSYS_)
                log_crash(sig, info->code, info->fault.addr);
#ifdef GUEST_ARM64
            // V8's IMMEDIATE_CRASH() uses BRK #0 on ARM64 (delivers SIGTRAP).
            // Generic recovery: unwind the current function frame and return 0
            // to the caller. This lets V8 continue past non-fatal CHECKs.
            if (sig == SIGTRAP_) {
                struct cpu_state *cpu = &current->cpu;
                if (ish_exec_trace())
                    fprintf(stderr, "V8_SIGTRAP: pc=0x%llx x0=0x%llx sp=%llx fp=%llx lr=%llx\n",
                            (unsigned long long)cpu->pc,
                            (unsigned long long)cpu->regs[0],
                            (unsigned long long)cpu->sp,
                            (unsigned long long)cpu->regs[29],
                            (unsigned long long)cpu->regs[30]);
                // Only treat as "clean exit 0" if this process has already
                // committed to V8 abort (printed the V8 fatal preamble to
                // stderr). Otherwise preserve normal SIGTRAP semantics so
                // legitimate errors / debugger traps aren't masked.
                //
                // Required for npx: npm's inner V8 throws non-fatal CHECKs
                // (e.g. Handle location_==nullptr during worker teardown)
                // AFTER all side-effects have landed on disk. Exit 0 lets
                // npx's outer shell pipeline continue to the actual install
                // step. Without this gate npx reports failure but the
                // install actually succeeded.
                if (current->group && current->group->v8_aborting) {
                    do_exit_group(0);
                } else {
                    do_exit_group(sig);
                }
                return false;
            }
            if (sig == SIGABRT_) {
                struct cpu_state *cpu = &current->cpu;
                if (ish_exec_trace())
                    fprintf(stderr, "V8_SIGABRT: pc=0x%llx sp=%llx fp=%llx lr=%llx\n",
                            (unsigned long long)cpu->pc,
                            (unsigned long long)cpu->sp,
                            (unsigned long long)cpu->regs[29],
                            (unsigned long long)cpu->regs[30]);
                // Like SIGTRAP: v8_aborting → exit 0; otherwise preserve
                // abort() exit semantics.
                if (current->group && current->group->v8_aborting) {
                    do_exit_group(0);
                } else {
                    do_exit_group(sig);
                }
                return false;
            }
            // V8 scope corruption GPF cascade: the deep frame unwind in
            // handle_interrupt may leave a background thread with a corrupt
            // PC pointing into the V8 heap. When that thread tries to
            // execute "code" at a heap address, it gets SIGILL.
            // Flush the host-side stdout/stderr pipes before killing the
            // process group, so buffered output (e.g. npm help) is visible.
            if (sig == SIGILL_ || sig == SIGBUS_) {
                struct cpu_state *cpu = &current->cpu;
                if (cpu->pc >= 0xb0000000 && cpu->pc < 0xf0000000) {
                    do_exit_group(1 << 8);
                    return false;
                }
            }
            // If this process has already committed to a V8 fatal abort
            // (printed the V8 fatal preamble to stderr), treat any
            // subsequent fatal signal as a clean shutdown — the side
            // effects have already landed on disk and the abort preamble
            // is suppressed, so surfacing a non-zero exit just confuses
            // callers. Without v8_aborting set, fall through to normal
            // SIGSEGV semantics so legitimate user-program crashes still
            // surface as "Segmentation fault" / non-zero exit.
            if (sig == SIGSEGV_ && current->group && current->group->v8_aborting) {
                do_exit_group(0);
                return false;
            }
#endif
            do_exit_group(sig);
    }

    if (crashlog_level() >= 2 && (sig == SIGSEGV_ || sig == SIGBUS_ || sig == SIGILL_ || sig == SIGABRT_ ||
            sig == SIGFPE_ || sig == SIGTRAP_ || sig == SIGSYS_)) {
        unlock(&sighand->lock);
        log_crash_line("ish signal to handler", sig, info->code, info->fault.addr);
        lock(&sighand->lock);
    }
    struct sigaction_ *action = &sighand->action[info->sig];
    bool need_siginfo = action->flags & SA_SIGINFO_;
#if defined(GUEST_ARM64)
    // ARM64 only provides __kernel_rt_sigreturn in the VDSO.
    // Always use an rt_sigframe for signal delivery.
    need_siginfo = true;
#endif

    // setup the frame
    union {
        struct sigframe_ sigframe;
        struct rt_sigframe_ rt_sigframe;
    } frame = {};
    size_t frame_size;
    if (need_siginfo) {
        setup_rt_sigframe(info, &frame.rt_sigframe);
        frame_size = sizeof(frame.rt_sigframe);
    } else {
        setup_sigframe(info, &frame.sigframe);
        frame_size = sizeof(frame.sigframe);
    }

    // set up registers for signal handler
#if defined(GUEST_ARM64)
    // ARM64 spec: exceptions clear the exclusive monitor
    current->cpu.excl_addr = UINT64_MAX;
    current->cpu.regs[0] = info->sig;
    current->cpu.pc = sighand->action[info->sig].handler;
    addr_t sp = current->cpu.sp;  // Use addr_t (64-bit) for ARM64
#else
    current->cpu.eax = info->sig;
    current->cpu.eip = sighand->action[info->sig].handler;
    dword_t sp = current->cpu.esp;
#endif
    if ((action->flags & SA_ONSTACK_) && current->altstack && !is_on_altstack(sp, current)) {
        sp = current->altstack + current->altstack_size;
    }
    if (xsave_extra) {
        // do as the kernel does
        // this is superhypermega condensed version of fpu__alloc_mathframe in
        // arch/x86/kernel/fpu/signal.c
        sp -= xsave_extra;
        sp &=~ 0x3f;
        sp -= fxsave_extra;
    }
    sp -= frame_size;
#if defined(GUEST_ARM64)
    // ARM64 requires the stack to be 16-byte aligned.
    sp &= ~0xf;
#else
    // align sp + 4 on a 16-byte boundary because that's what the abi says
    sp = ((sp + 4) & ~0xf) - 4;
#endif
#if defined(GUEST_ARM64)
    current->cpu.sp = sp;
#else
    current->cpu.esp = sp;
#endif

    // Update the mask. By default the signal will be blocked while in the
    // handler, but sigaction is allowed to customize this.
    if (!(action->flags & SA_NODEFER_))
        sigset_add(&current->blocked, info->sig);
    current->blocked |= action->mask;

    // these have to be filled in after the location of the frame is known
    if (need_siginfo) {
        frame.rt_sigframe.pinfo = sp + offsetof(struct rt_sigframe_, info);
        frame.rt_sigframe.puc = sp + offsetof(struct rt_sigframe_, uc);
#if defined(GUEST_ARM64)
        // ARM64 ABI: x0=signum, x1=siginfo*, x2=ucontext*
        current->cpu.regs[1] = frame.rt_sigframe.pinfo;
        current->cpu.regs[2] = frame.rt_sigframe.puc;
#else
        current->cpu.edx = frame.rt_sigframe.pinfo;
        current->cpu.ecx = frame.rt_sigframe.puc;
#endif
    }

    // Install the frame without the sighand lock: writing guest memory can
    // wait on the mm lock behind another thread's page fault, and senders
    // (kill, exit_group, shutdown) take this lock while holding pids_lock.
    // Only this thread removes entries from its own signal queue, so the
    // caller's iteration stays valid.
    unlock(&sighand->lock);
    if (user_write(sp, &frame, frame_size)) {
        printk("failed to install frame for %d at %#llx\n", info->sig, (unsigned long long) sp);
        deliver_signal(current, SIGSEGV_, SIGINFO_NIL);
    }
    lock(&sighand->lock);

#if defined(GUEST_ARM64)
    // Set LR to the signal return trampoline.
    if (need_siginfo)
        current->cpu.regs[30] = frame.rt_sigframe.restorer;
    else
        current->cpu.regs[30] = frame.sigframe.restorer;
#endif

    if (action->flags & SA_RESETHAND_)
        *action = (struct sigaction_) {.handler = SIG_DFL_};
    return true;
}

void signal_delivery_stop(int sig, struct siginfo_ *info) {
    lock(&current->ptrace.lock);
    current->ptrace.stopped = true;
    current->ptrace.signal = sig;
    current->ptrace.info = *info;
    unlock(&current->ptrace.lock);
    notify(&current->parent->group->child_exit);
    // TODO add siginfo
    send_signal(current->parent, current->group->leader->exit_signal, SIGINFO_NIL);

    unlock(&current->sighand->lock);
    lock(&current->ptrace.lock);
    while (current->ptrace.stopped) {
        wait_for_ignore_signals(&current->ptrace.cond, &current->ptrace.lock, NULL);
        lock(&current->sighand->lock);
        bool got_sigkill = sigset_has(current->pending, SIGKILL_);
        unlock(&current->sighand->lock);
        if (got_sigkill) {
            STRACE("%d received a SIGKILL in signal delivery stop\n", current->pid);
            unlock(&current->ptrace.lock);
            do_exit_group(SIGKILL_);
        }
    }
    unlock(&current->ptrace.lock);
    lock(&current->sighand->lock);
}

void receive_signals() {
    lock(&current->group->lock);
    bool was_stopped = current->group->stopped;
    unlock(&current->group->lock);

    struct sighand *sighand = current->sighand;
    if (sighand == NULL)
        return;
    lock(&sighand->lock);

    // A saved mask means that the last system call was a call like sigsuspend
    // that changes the mask during the call. Only ignore a signal right now if
    // it was both blocked during the call and should still be blocked after
    // the call.
    sigset_t_ blocked = current->blocked;
    if (current->has_saved_mask) {
        blocked &= current->saved_mask;
        current->has_saved_mask = false;
        current->blocked = current->saved_mask;
    }

    // A handler frame changes where the thread resumes, so set up one handler at a time, as Linux
    // does: when it returns (sigreturn) this runs again for the next signal. Signals with no
    // handler (ignored, stop, terminate) don't need that.
    blocked &= ~UNBLOCKABLE_MASK;
    struct sigqueue *sigqueue;
    while ((sigqueue = dequeue_signal(~blocked)) != NULL) {
        // Free the entry first: a fatal signal never returns from receive_signal, and
        // its RLIMIT_SIGPENDING charge would be kept for ever.
        struct siginfo_ info = sigqueue->info;
        sigqueue_free(sigqueue);
        int sig = info.sig;
        bool handler = false;
        if (current->ptrace.traced && sig != SIGKILL_) {
            // This notifies the parent, goes to sleep, and waits for the
            // parent to tell it to continue.
            // Any signals received while waiting are left on the queue, except
            // for SIGKILL_, which causes an immediate exit.
            signal_delivery_stop(sig, &info);
        } else {
            handler = receive_signal(sighand, &info);
        }
        if (handler)
            break;
    }

    unlock(&sighand->lock);

    // this got moved out of the switch case in receive_signal to fix locking problems
    if (!was_stopped) {
        lock(&current->group->lock);
        bool now_stopped = current->group->stopped;
        unlock(&current->group->lock);
        if (now_stopped) {
            lock(&pids_lock);
            notify(&current->parent->group->child_exit);
            // TODO add siginfo
            send_signal(current->parent, current->group->leader->exit_signal, SIGINFO_NIL);
            unlock(&pids_lock);
        }
    }
}

#if defined(GUEST_ARM64)
static void restore_sigcontext(struct sigcontext_ *context, struct cpu_state *cpu) {
    memcpy(cpu->regs, context->regs, sizeof(cpu->regs));
    cpu->sp = context->sp;
    cpu->pc = context->pc;
    arm64_set_nzcv(cpu, (uint32_t)context->pstate);

    // Restore FPSIMD context from extension area
    struct fpsimd_context_ *fpsimd = (struct fpsimd_context_ *)context->__reserved;
    if (fpsimd->magic == FPSIMD_MAGIC) {
        cpu->fpsr = fpsimd->fpsr;
        cpu->fpcr = fpsimd->fpcr;
        for (int i = 0; i < 32; i++) {
            cpu->fp[i].q = fpsimd->vregs[i];
        }
    }
}
#else
static void restore_sigcontext(struct sigcontext_ *context, struct cpu_state *cpu) {
    cpu->eax = context->ax;
    cpu->ebx = context->bx;
    cpu->ecx = context->cx;
    cpu->edx = context->dx;
    cpu->edi = context->di;
    cpu->esi = context->si;
    cpu->ebp = context->bp;
    cpu->esp = context->sp;
    cpu->eip = context->ip;
    collapse_flags(cpu);

    // Use AC, RF, OF, DF, TF, SF, ZF, AF, PF, CF
#define USE_FLAGS 0b1010000110111010101
    cpu->eflags = (context->flags & USE_FLAGS) | (cpu->eflags & ~USE_FLAGS);
}
#endif

int64_t sys_rt_sigreturn() {
    struct cpu_state *cpu = &current->cpu;
    struct rt_sigframe_ frame;
#if defined(GUEST_ARM64)
    addr_t sp = cpu->sp;  // Use addr_t (64-bit) for ARM64
#else
    dword_t sp = cpu->esp;
#endif
#if defined(GUEST_ARM64)
    // ARM64 keeps SP pointing at the start of the frame.
    addr_t frame_addr = sp;
#else
    // esp/sp points past the first field of the frame
    addr_t frame_addr = sp - offsetof(struct rt_sigframe_, sig);
#endif
    if (user_get(frame_addr, frame)) {
        deliver_signal(current, SIGSEGV_, SIGINFO_NIL);
        return _EFAULT;
    }
    restore_sigcontext(&frame.uc.mcontext, cpu);

    lock(&current->sighand->lock);
    // FIXME this duplicates logic from sys_sigaltstack
    if (!is_on_altstack(sp, current) &&
            frame.uc.stack.size >= MINSIGSTKSZ_) {
        current->altstack = frame.uc.stack.stack;
        current->altstack_size = frame.uc.stack.size;
    }
    sigmask_set(frame.uc.sigmask);
    unlock(&current->sighand->lock);
#if defined(GUEST_ARM64)
    // Return the full 64-bit x0 from the restored context.
    // IMPORTANT: The caller (handle_interrupt) must NOT modify x0 after
    // this returns, because the full register state was restored from the
    // signal frame. We return int64_t to preserve all 64 bits.
    return (int64_t)cpu->regs[0];
#else
    return cpu->eax;
#endif
}

int64_t sys_sigreturn() {
    struct cpu_state *cpu = &current->cpu;
    struct sigframe_ frame;
#if defined(GUEST_ARM64)
    addr_t sp = cpu->sp;  // Use addr_t (64-bit) for ARM64
#else
    dword_t sp = cpu->esp;
#endif
#if defined(GUEST_ARM64)
    // ARM64 keeps SP pointing at the start of the frame.
    addr_t frame_addr = sp;
#else
    // esp/sp points past the first two fields of the frame
    addr_t frame_addr = sp - offsetof(struct sigframe_, sc);
#endif
    if (user_get(frame_addr, frame)) {
        deliver_signal(current, SIGSEGV_, SIGINFO_NIL);
        return _EFAULT;
    }
    restore_sigcontext(&frame.sc, cpu);

    lock(&current->sighand->lock);
#if defined(GUEST_ARM64)
    sigmask_set(current->blocked);
#else
    sigset_t_ oldmask = ((sigset_t_) frame.extramask << 32) | frame.sc.oldmask;
    sigmask_set(oldmask);
#endif
    unlock(&current->sighand->lock);
#if defined(GUEST_ARM64)
    return (int64_t)cpu->regs[0];
#else
    return cpu->eax;
#endif
}

struct sighand *sighand_new() {
    struct sighand *sighand = malloc(sizeof(struct sighand));
    if (sighand == NULL)
        return NULL;
    memset(sighand, 0, sizeof(struct sighand));
    sighand->refcount = 1;
    lock_init(&sighand->lock);
    return sighand;
}

struct sighand *sighand_copy(struct sighand *sighand) {
    struct sighand *new_sighand = sighand_new();
    if (new_sighand == NULL)
        return NULL;
    memcpy(new_sighand->action, sighand->action, sizeof(new_sighand->action));
    return new_sighand;
}

void sighand_release(struct sighand *sighand) {
    if (--sighand->refcount == 0) {
        free(sighand);
    }
}

static int do_sigaction(int sig, const struct sigaction_ *action, struct sigaction_ *oldaction) {
    if (sig >= NUM_SIGS)
        return _EINVAL;
    if (!signal_is_blockable(sig))
        return _EINVAL;

    struct sighand *sighand = current->sighand;
    lock(&sighand->lock);
    if (oldaction)
        *oldaction = sighand->action[sig];
    if (action)
        sighand->action[sig] = *action;
    unlock(&sighand->lock);
    return 0;
}

dword_t sys_rt_sigaction(dword_t signum, addr_t action_addr, addr_t oldaction_addr, dword_t sigset_size) {
    if (!sigset_size_valid(sigset_size))
        return _EINVAL;
    struct sigaction_ action = {}, oldaction;
    if (action_addr != 0) {
#if defined(GUEST_ARM64)
        int err = user_get_sigaction_arm64(action_addr, sigset_size, &action);
        if (err)
            return err;
#else
        if (user_get(action_addr, action))
            return _EFAULT;
#endif
    }
    STRACE("rt_sigaction(%d, %#x {handler=%#x, flags=%#x, restorer=%#x, mask=%#llx}, 0x%x, %d)", signum,
            action_addr, action.handler, action.flags, action.restorer,
            (unsigned long long) action.mask, oldaction_addr, sigset_size);

    int err = do_sigaction(signum,
            action_addr ? &action : NULL,
            oldaction_addr ? &oldaction : NULL);
    if (err < 0)
        return err;

    if (oldaction_addr != 0)
    {
#if defined(GUEST_ARM64)
        int err = user_put_sigaction_arm64(oldaction_addr, sigset_size, &oldaction);
        if (err)
            return err;
#else
        if (user_put(oldaction_addr, oldaction))
            return _EFAULT;
#endif
    }
    return err;
}

dword_t sys_sigaction(dword_t signum, addr_t action_addr, addr_t oldaction_addr) {
    return sys_rt_sigaction(signum, action_addr, oldaction_addr, 1);
}

static void sigmask_set(sigset_t_ set) {
    current->blocked = (set & ~UNBLOCKABLE_MASK);
}

static void sigmask_set_temp_unlocked(sigset_t_ mask) {
    current->saved_mask = current->blocked;
    current->has_saved_mask = true;
    sigmask_set(mask);
}

void sigmask_set_temp(sigset_t_ mask) {
    lock(&current->sighand->lock);
    sigmask_set_temp_unlocked(mask);
    unlock(&current->sighand->lock);
}

static int do_sigprocmask(dword_t how, sigset_t_ set) {
    if (how == SIG_BLOCK_)
        sigmask_set(current->blocked | set);
    else if (how == SIG_UNBLOCK_)
        sigmask_set(current->blocked & ~set);
    else if (how == SIG_SETMASK_)
        sigmask_set(set);
    else
        return _EINVAL;
    return 0;
}

dword_t sys_rt_sigprocmask(dword_t how, addr_t set_addr, addr_t oldset_addr, dword_t size) {
    if (!sigset_size_valid(size))
        return _EINVAL;

    sigset_t_ set;
    if (set_addr != 0) {
        int err = user_get_sigset(set_addr, size, &set);
        if (err)
            return err;
    }
    STRACE("rt_sigprocmask(%s, %#llx, %#x, %d)",
            how == SIG_BLOCK_ ? "SIG_BLOCK" :
            how == SIG_UNBLOCK_ ? "SIG_UNBLOCK" :
            how == SIG_SETMASK_ ? "SIG_SETMASK" : "??",
            set_addr != 0 ? (long long) set : -1, oldset_addr, size);

    if (oldset_addr != 0) {
        int err = user_put_sigset(oldset_addr, size, current->blocked);
        if (err)
            return err;
    }
    if (set_addr != 0) {
        struct sighand *sighand = current->sighand;
        lock(&sighand->lock);
        int err = do_sigprocmask(how, set);
        unlock(&sighand->lock);
        if (err < 0)
            return err;
    }
    return 0;
}

int_t sys_rt_sigpending(addr_t set_addr, dword_t size) {
    STRACE("rt_sigpending(%#x, %d)", set_addr, size);
    // as defined by the standard
    sigset_t_ pending = task_pending_all(current) & current->blocked;
    return user_put_sigset(set_addr, size, pending);
}

static bool is_on_altstack(addr_t sp, struct task *task) {
    return sp > task->altstack && sp <= task->altstack + task->altstack_size;
}

static void altstack_to_user(struct task *task, struct stack_t_ *user_stack) {
    user_stack->stack = task->altstack;
    user_stack->size = task->altstack_size;
    user_stack->flags = 0;
    if (task->altstack == 0)
        user_stack->flags |= SS_DISABLE_;
#if defined(GUEST_ARM64)
    if (is_on_altstack(task->cpu.sp, task))
#else
    if (is_on_altstack(task->cpu.esp, task))
#endif
        user_stack->flags |= SS_ONSTACK_;
}

dword_t sys_sigaltstack(addr_t ss_addr, addr_t old_ss_addr) {
    STRACE("sigaltstack(0x%x, 0x%x)", ss_addr, old_ss_addr);
    struct sighand *sighand = current->sighand;
    // guest memory is accessed outside the sighand lock (see receive_signal)
    struct stack_t_ ss;
    if (ss_addr != 0 && user_get(ss_addr, ss))
        return _EFAULT;
    lock(&sighand->lock);
    struct stack_t_ old_ss;
    altstack_to_user(current, &old_ss);
    if (ss_addr != 0) {
#if defined(GUEST_ARM64)
        if (is_on_altstack(current->cpu.sp, current)) {
#else
        if (is_on_altstack(current->cpu.esp, current)) {
#endif
            unlock(&sighand->lock);
            return _EPERM;
        }
        if (ss.flags & SS_DISABLE_) {
            current->altstack = 0;
        } else {
            if (ss.size < MINSIGSTKSZ_) {
                unlock(&sighand->lock);
                return _ENOMEM;
            }
            current->altstack = ss.stack;
            current->altstack_size = ss.size;
        }
    }
    unlock(&sighand->lock);
    if (old_ss_addr != 0 && user_put(old_ss_addr, old_ss))
        return _EFAULT;
    return 0;
}

int_t sys_rt_sigsuspend(addr_t mask_addr, uint_t size) {
    sigset_t_ mask;
    int err = user_get_sigset(mask_addr, size, &mask);
    if (err)
        return err;
    STRACE("sigsuspend(0x%llx) = ...\n", (long long) mask);

    lock(&current->sighand->lock);
    sigmask_set_temp_unlocked(mask);
    while (wait_for(&current->pause, &current->sighand->lock, NULL) != _EINTR)
        continue;
    unlock(&current->sighand->lock);
    STRACE("%d done sigsuspend", current->pid);
    return _EINTR;
}

int_t sys_pause() {
    lock(&current->sighand->lock);
    while (wait_for(&current->pause, &current->sighand->lock, NULL) != _EINTR)
        continue;
    unlock(&current->sighand->lock);
    return _EINTR;
}

int_t sys_rt_sigtimedwait(addr_t set_addr, addr_t info_addr, addr_t timeout_addr, uint_t set_size) {
    sigset_t_ set;
    int err = user_get_sigset(set_addr, set_size, &set);
    if (err)
        return err;
    set &= ~UNBLOCKABLE_MASK; // SIGKILL and SIGSTOP cannot be waited for
    struct timespec timeout;
    if (timeout_addr != 0) {
        struct timespec_ fake_timeout;
        if (user_get(timeout_addr, fake_timeout))
            return _EFAULT;
        timeout.tv_sec = fake_timeout.sec;
        timeout.tv_nsec = fake_timeout.nsec;
    }
    STRACE("sigtimedwait(%#llx, %#x, %#x) = ...\n", (long long) set, info_addr, timeout_addr);

    struct timespec deadline;
    if (timeout_addr != 0) {
        clock_gettime(CLOCK_MONOTONIC, &deadline);
        deadline.tv_sec += timeout.tv_sec;
        deadline.tv_nsec += timeout.tv_nsec;
        if (deadline.tv_nsec >= 1000000000) {
            deadline.tv_sec++;
            deadline.tv_nsec -= 1000000000;
        }
    }

    lock(&current->sighand->lock);
    assert(current->waiting == 0);
    struct sigqueue *sigqueue;
    for (;;) {
        sigqueue = dequeue_signal(set);
        if (sigqueue != NULL)
            break;

        // nothing pending: sleep until a signal in the set is sent to this thread or its process
        struct timespec remaining;
        if (timeout_addr != 0) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            remaining.tv_sec = deadline.tv_sec - now.tv_sec;
            remaining.tv_nsec = deadline.tv_nsec - now.tv_nsec;
            if (remaining.tv_nsec < 0) {
                remaining.tv_sec--;
                remaining.tv_nsec += 1000000000;
            }
            if (remaining.tv_sec < 0 || (remaining.tv_sec == 0 && remaining.tv_nsec == 0)) {
                unlock(&current->sighand->lock);
                STRACE("sigtimedwait timed out\n");
                return _EAGAIN;
            }
        }
        current->waiting = set;
        int wait_err = wait_for(&current->pause, &current->sighand->lock, timeout_addr == 0 ? NULL : &remaining);
        current->waiting = 0;
        if (current->exiting)
            break; // the exit safety valve gave up on this thread: its process may be gone
        if (wait_err == _ETIMEDOUT) {
            sigqueue = dequeue_signal(set);
            if (sigqueue == NULL) {
                unlock(&current->sighand->lock);
                STRACE("sigtimedwait timed out\n");
                return _EAGAIN;
            }
            break;
        }
        if (wait_err == _EINTR) {
            // a signal this thread doesn't block arrived: a handler runs, unless ours came too
            sigqueue = dequeue_signal(set);
            break;
        }
    }
    unlock(&current->sighand->lock);
    bool found = sigqueue != NULL;
    if (!found)
        return _EINTR;
    struct siginfo_ info = sigqueue->info;
    sigqueue_free(sigqueue);
    if (info_addr != 0)
        if (user_put(info_addr, info))
            return _EFAULT;
    STRACE("done sigtimedwait = %d\n", info.sig);
    return info.sig;
}

// thread_directed: the signal is for this thread alone (tkill, tgkill); otherwise for its whole
// process, whichever thread takes it. Call with pids_lock held.
static int kill_task_info(struct task *task, dword_t sig, struct siginfo_ info, bool thread_directed) {
    if (!superuser() &&
            current->uid != task->uid &&
            current->uid != task->suid &&
            current->euid != task->uid &&
            current->euid != task->suid)
        return _EPERM;
    return send_signal_checked(task, sig, info, thread_directed);
}

static int kill_task(struct task *task, dword_t sig, bool thread_directed) {
    struct siginfo_ info = {
        .code = thread_directed ? SI_TKILL_ : SI_USER_,
        .kill.pid = current->tgid,
        .kill.uid = current->uid,
    };
    return kill_task_info(task, sig, info, thread_directed);
}

// Signal a set of processes collected under pids_lock. The lock is taken again
// for each one instead of being held across the whole set, so a target that is
// slow to take the signal (its sighand lock busy) never stalls every other
// process that needs pids_lock, e.g. to exit.
static int kill_pids(const pid_t_ *pids, int count, dword_t sig) {
    int err = _ESRCH;
    for (int i = 0; i < count; i++) {
        lock(&pids_lock);
        // like Linux, a zombie can still be signaled (to no effect)
        struct task *task = pid_get_task_zombie(pids[i]);
        int kill_err = task != NULL ? kill_task(task, sig, false) : _ESRCH;
        unlock(&pids_lock);
        // an error only if no process could be signaled
        if (err != 0 && kill_err != _ESRCH)
            err = kill_err;
    }
    return err;
}

// must be called with pids_lock, which it releases
static int kill_group(pid_t_ pgid, dword_t sig) {
    struct pid *pid = pid_get(pgid);
    if (pid == NULL) {
        unlock(&pids_lock);
        return _ESRCH;
    }
    int count = 0;
    struct tgroup *tgroup;
    list_for_each_entry(&pid->pgroup, tgroup, pgroup)
        count++;
    pid_t_ *pids = malloc(sizeof(pid_t_) * (count + 1));
    if (pids == NULL) {
        unlock(&pids_lock);
        return _ENOMEM;
    }
    count = 0;
    list_for_each_entry(&pid->pgroup, tgroup, pgroup)
        pids[count++] = tgroup->leader->pid;
    unlock(&pids_lock);
    int err = kill_pids(pids, count, sig);
    free(pids);
    return err;
}

// must be called with pids_lock, which it releases
static int kill_everything(dword_t sig) {
    pid_t_ *pids = malloc(sizeof(pid_t_) * MAX_PID);
    if (pids == NULL) {
        unlock(&pids_lock);
        return _ENOMEM;
    }
    int count = 0;
    for (int i = 2; i < MAX_PID; i++) {
        struct task *task = pid_get_task(i);
        if (task == NULL || task == current || !task_is_leader(task))
            continue;
        pids[count++] = i;
    }
    unlock(&pids_lock);
    int err = kill_pids(pids, count, sig);
    free(pids);
    // like Linux, kill(-1) fails with ESRCH only when there was nobody to signal
    return count == 0 ? _ESRCH : err;
}

static int do_kill(pid_t_ pid, dword_t sig, pid_t_ tgid, bool thread_directed) {
    STRACE("kill(%d, %d)", pid, sig);
    if (sig >= NUM_SIGS)
        return _EINVAL;
    if (pid == 0)
        pid = -current->group->pgid;

    lock(&pids_lock);
    if (pid == -1)
        return kill_everything(sig);
    if (pid < 0)
        return kill_group(-pid, sig);

    struct task *task = pid_get_task(pid);
    if (task == NULL) {
        unlock(&pids_lock);
        return _ESRCH;
    }

    // If tgid is nonzero, it must be correct
    if (tgid != 0 && task->tgid != tgid) {
        unlock(&pids_lock);
        return _ESRCH;
    }

    int err = kill_task(task, sig, thread_directed);
    unlock(&pids_lock);
    return err;
}

dword_t sys_kill(pid_t_ pid, dword_t sig) {
    return do_kill(pid, sig, 0, false);
}
// rt_sigqueueinfo / rt_tgsigqueueinfo: send a signal with caller-supplied siginfo.
// Like Linux, only the sender itself may forge a positive si_code (SI_USER and up).
static int queue_signal_info(pid_t_ tid, pid_t_ tgid, dword_t sig, addr_t info_addr, bool thread_directed) {
    if (sig >= NUM_SIGS)
        return _EINVAL;
    struct siginfo_ info;
    if (user_get(info_addr, info))
        return _EFAULT;

    lock(&pids_lock);
    struct task *task = pid_get_task(tid);
    if (task == NULL || (tgid != 0 && task->tgid != tgid)) {
        unlock(&pids_lock);
        return _ESRCH;
    }
    if ((info.code >= 0 || info.code == SI_TKILL_) && task->group != current->group) {
        unlock(&pids_lock);
        return _EPERM;
    }
    int err = kill_task_info(task, sig, info, thread_directed);
    unlock(&pids_lock);
    return err;
}

dword_t sys_rt_sigqueueinfo(pid_t_ pid, dword_t sig, addr_t info_addr) {
    STRACE("rt_sigqueueinfo(%d, %d, %#x)", pid, sig, info_addr);
    if (pid <= 0)
        return _EINVAL;
    return queue_signal_info(pid, 0, sig, info_addr, false);
}

dword_t sys_rt_tgsigqueueinfo(pid_t_ tgid, pid_t_ tid, dword_t sig, addr_t info_addr) {
    STRACE("rt_tgsigqueueinfo(%d, %d, %d, %#x)", tgid, tid, sig, info_addr);
    if (tid <= 0 || tgid <= 0)
        return _EINVAL;
    return queue_signal_info(tid, tgid, sig, info_addr, true);
}

dword_t sys_tgkill(pid_t_ tgid, pid_t_ tid, dword_t sig) {
    if (tid <= 0 || tgid <= 0)
        return _EINVAL;
    return do_kill(tid, sig, tgid, true);
}
dword_t sys_tkill(pid_t_ tid, dword_t sig) {
    if (tid <= 0)
        return _EINVAL;
    return do_kill(tid, sig, 0, true);
}
