#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <time.h>
#include "debug.h"
#include "fs/proc.h"
#include "kernel/calls.h"
#include "kernel/memory.h"
#include "kernel/mm.h"
#include "kernel/oom.h"
#include "kernel/signal.h"
#include "kernel/task.h"
#include "platform/platform.h"

#define MB (1ull << 20)

// Thresholds, as headroom left before the host's limit. Soft: Firefox's low-memory
// watcher fires at the same 20% of MemAvailable (gecko-tune.sh). Hard: a tenth of
// the allowance and never less than 320 MB, so it stays above kernel/mmap.c's
// 192 MB ENOMEM guard with room for one burst of allocation between two polls.
#define SOFT_PERCENT 20
#define HARD_PERCENT 10
#define HARD_MIN (320 * MB)
// What one guest thread costs the emulator on the host besides guest memory
// (JIT context, TLBs, fiber stack; ipad-jit/emulator-fixes.md row 59).
#define THREAD_COST (1300ull << 10)
// Helper processes (a child running its parent's executable: Firefox content, RDD and
// utility processes, Chromium/Electron renderers, GPU and utility processes, VS Code's
// extension host) count with an oom_score_adj of at least this, as Chromium sets for
// its renderers: closing one costs a tab or a window, closing the parent costs the
// whole app. Firefox 128 on desktop Linux leaves them at 0 or 100.
#define HELPER_ADJ 300
#define MIN_VICTIM (96 * MB)

void (*oom_kill_hook)(const char *app, const char *message);

static pthread_mutex_t oom_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t oom_wake = PTHREAD_COND_INITIALIZER;
static pthread_cond_t oom_round_done = PTHREAD_COND_INITIALIZER;
static bool started;
static bool enabled = true;
static bool poked;
static uint64_t rounds; // kill rounds finished, for waiters
static char *user_protect; // guarded by oom_lock

static const char *const builtin_protect[] = {
    "init", "ishwl", "ishwl-session", "Xwayland", "dbus-daemon", "dbus-launch",
    "pulseaudio", "sh", "ash", "bash", "zsh", "fish", "dash", "login", "getty",
    "sshd", "openrc", "su", "sudo", "tmux", "screen",
};

#define KILLS_KEPT 8
static struct kill_record {
    time_t when;
    int pid;
    char app[48];
    uint64_t freed; // estimated footprint of the victim
    uint64_t footprint, allowance;
} kills[KILLS_KEPT];
static unsigned kill_count;

// Memory pressure, kept like Linux PSI: the share of time "some" or "all" work was
// held back by memory, as running averages over 10, 60 and 300 s plus a total in µs.
// The emulator has no reclaim to stall on, so the stall is synthesised from the
// headroom: none above the soft limit, rising linearly to all of the time at the
// hard limit ("some"); "full" is the time spent at or below the hard limit.
static struct pressure {
    double avg[3];
    uint64_t total_us;
    double period_us; // stalled µs in the current 2 s averaging period
} psi_some, psi_full;
static uint64_t psi_period_start_ns;

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t) ts.tv_sec * 1000000000ull + (uint64_t) ts.tv_nsec;
}

struct limits {
    uint64_t headroom, footprint, allowance, soft, hard;
};

static struct limits read_limits(void) {
    struct limits l = {};
    l.headroom = host_memory_headroom();
    if (l.headroom == 0)
        return l;
    l.footprint = host_memory_footprint();
    l.allowance = l.footprint + l.headroom;
    l.soft = l.allowance * SOFT_PERCENT / 100;
    l.hard = l.allowance * HARD_PERCENT / 100;
    if (l.hard < HARD_MIN)
        l.hard = HARD_MIN;
    if (l.soft < l.hard + 128 * MB)
        l.soft = l.hard + 128 * MB;
    static uint64_t soft_env = UINT64_MAX, hard_env = UINT64_MAX;
    if (soft_env == UINT64_MAX) {
        const char *s = getenv("ISH_OOM_SOFT_MB"), *h = getenv("ISH_OOM_HARD_MB");
        soft_env = s ? (uint64_t) atoll(s) * MB : 0;
        hard_env = h ? (uint64_t) atoll(h) * MB : 0;
    }
    if (soft_env)
        l.soft = soft_env;
    if (hard_env)
        l.hard = hard_env;
    return l;
}

static void psi_account(const struct limits *l, uint64_t dt_ns) {
    double some = 0, full = 0;
    if (l->allowance != 0 && l->headroom < l->soft) {
        some = l->headroom <= l->hard ? 1 :
            (double) (l->soft - l->headroom) / (double) (l->soft - l->hard);
        full = l->headroom <= l->hard ? 1 : 0;
    }
    double dt_us = dt_ns / 1000.0;
    psi_some.period_us += some * dt_us;
    psi_full.period_us += full * dt_us;
    psi_some.total_us += (uint64_t) (some * dt_us);
    psi_full.total_us += (uint64_t) (full * dt_us);

    uint64_t now = now_ns();
    if (psi_period_start_ns == 0)
        psi_period_start_ns = now;
    double period_us = (now - psi_period_start_ns) / 1000.0;
    if (period_us < 2e6)
        return;
    static const double windows[3] = {10, 60, 300};
    struct pressure *ps[2] = {&psi_some, &psi_full};
    for (int p = 0; p < 2; p++) {
        double pct = ps[p]->period_us * 100 / period_us;
        if (pct > 100)
            pct = 100;
        for (int w = 0; w < 3; w++) {
            double decay = exp(-(period_us / 1e6) / windows[w]);
            ps[p]->avg[w] = ps[p]->avg[w] * decay + pct * (1 - decay);
        }
        ps[p]->period_us = 0;
    }
    psi_period_start_ns = now;
}

// What killing an address space would give back to the host: its pages that are
// resident or compressed and charged to this app (anonymous memory and private
// copies of file pages). Clean file pages and pages of shared file mappings are
// not in phys_footprint, so they don't count. Pages shared after fork() count in
// every process that maps them, as in Linux RSS.
// Called with mem->lock read-locked.
static uint64_t mm_footprint(struct mm *mm) {
    struct mem *mem = &mm->mem;
    static char vec[(4096 * PAGE_SIZE) / 4096 + 2];
    static pthread_mutex_t vec_lock = PTHREAD_MUTEX_INITIALIZER;
    uint64_t pages = 0;
    pthread_mutex_lock(&vec_lock);
    for (page_t page = 0; page < MEM_PAGES; mem_next_page(mem, &page)) {
        struct pt_entry *pt = mem_pt(mem, page);
        if (pt == NULL)
            continue;
        struct data *data = pt->data;
        size_t offset = pt->offset;
        pages_t n = 1;
        while (n < 4096) {
            struct pt_entry *next = mem_pt(mem, page + n);
            if (next == NULL || next->data != data || next->offset != offset + n * PAGE_SIZE)
                break;
            n++;
        }
        bool anonymous = pt->flags & P_ANONYMOUS;
        page += n - 1;
        uintptr_t host = (uintptr_t) data->data + offset;
        uintptr_t lo = host & ~(uintptr_t) (real_page_size - 1);
        uintptr_t hi = (host + n * PAGE_SIZE + real_page_size - 1) & ~(uintptr_t) (real_page_size - 1);
        if (mincore((void *) lo, hi - lo, vec) != 0)
            continue;
        for (pages_t i = 0; i < n; i++) {
            char f = vec[(host + i * PAGE_SIZE - lo) / real_page_size];
#ifdef MINCORE_ANONYMOUS
            (void) anonymous;
            if ((f & (MINCORE_INCORE | MINCORE_PAGED_OUT)) && (f & (MINCORE_ANONYMOUS | MINCORE_COPIED)))
                pages++;
#else
            if ((f & 1) && anonymous)
                pages++;
#endif
        }
    }
    pthread_mutex_unlock(&vec_lock);
    return pages * PAGE_SIZE;
}

// Called with mem->lock read-locked. Reads the guest memory directly, without
// mem_ptr, which may fault pages in.
static size_t mm_read_argv(struct mm *mm, char *out, size_t size) {
    size_t len = mm->argv_end > mm->argv_start ? mm->argv_end - mm->argv_start : 0;
    if (len > size)
        len = size;
    size_t done = 0;
    while (done < len) {
        addr_t addr = mm->argv_start + done;
        struct pt_entry *pt = mem_pt(&mm->mem, PAGE(addr));
        if (pt == NULL || (pt->flags & P_PAST_EOF))
            break;
        size_t in_page = PAGE_SIZE - (addr & (PAGE_SIZE - 1));
        size_t n = len - done < in_page ? len - done : in_page;
        memcpy(out + done, (char *) pt->data->data + pt->offset + (addr & (PAGE_SIZE - 1)), n);
        done += n;
    }
    return done;
}

struct candidate {
    int pid;
    int ppid;
    int adj;
    int effective_adj; // adj, raised to HELPER_ADJ for a helper process
    bool has_helpers;  // the app's main process: some child is a helper (see kill_one)
    int threads;
    struct mm *mm;
    char comm[16];
    char argv[256];
    size_t argv_len;
    uint64_t footprint;
    bool protected;
    long long score;
};

static const char *argv0_base(const struct candidate *c) {
    const char *slash = strrchr(c->argv, '/');
    return slash ? slash + 1 : c->argv;
}

static bool has_arg(const struct candidate *c, const char *arg) {
    for (size_t i = 0; i < c->argv_len; i += strlen(c->argv + i) + 1)
        if (strncmp(c->argv + i, arg, strlen(arg)) == 0)
            return true;
    return false;
}

static void friendly_name(const struct candidate *c, char *out, size_t size) {
    const char *base = c->argv[0] ? argv0_base(c) : c->comm;
    if (strncmp(base, "firefox", 7) == 0) {
        if (!has_arg(c, "-contentproc"))
            snprintf(out, size, "Firefox");
        else if (has_arg(c, "-isForBrowser"))
            snprintf(out, size, "a Firefox tab process");
        else
            snprintf(out, size, "a Firefox helper process");
    } else if (strcmp(base, "code") == 0 || strcmp(base, "code-oss") == 0 || strcmp(base, "electron") == 0) {
        const char *app = strcmp(base, "electron") == 0 ? "Electron" : "VS Code";
        // Renderers are forked from the zygote and may still show its command line;
        // Chromium gives them oom_score_adj 300 and up, its other helpers less.
        if (has_arg(c, "--type=renderer") || (has_arg(c, "--type=zygote") && c->adj >= 300))
            snprintf(out, size, "a %s window", app);
        else if (has_arg(c, "--type="))
            snprintf(out, size, "a %s helper process", app);
        else
            snprintf(out, size, "%s", app);
    } else {
        snprintf(out, size, "%s", base[0] ? base : c->comm);
    }
}

static bool name_in_list(const char *list, const char *name) {
    if (list == NULL || name[0] == '\0')
        return false;
    size_t len = strlen(name);
    for (const char *p = list; *p;) {
        while (*p == ',' || *p == '\n' || *p == ' ')
            p++;
        const char *end = p;
        while (*end && *end != ',' && *end != '\n')
            end++;
        const char *trim = end;
        while (trim > p && trim[-1] == ' ')
            trim--;
        if ((size_t) (trim - p) == len && strncmp(p, name, len) == 0)
            return true;
        p = end;
    }
    return false;
}

static bool is_protected(const struct candidate *c) {
    if (c->pid == 1 || c->adj < 0)
        return true;
    const char *base = argv0_base(c);
    for (size_t i = 0; i < sizeof(builtin_protect) / sizeof(builtin_protect[0]); i++)
        if (strcmp(c->comm, builtin_protect[i]) == 0 || strcmp(base, builtin_protect[i]) == 0)
            return true;
    pthread_mutex_lock(&oom_lock);
    bool listed = name_in_list(user_protect, c->comm) || name_in_list(user_protect, base);
    pthread_mutex_unlock(&oom_lock);
    return listed;
}

// A process that holds its address space's write lock (in mmap, possibly waiting in
// oom_wait_for_headroom) can't be walked, so the last measurement stands in.
#define MEASURE_CACHE 64
static struct {
    struct mm *mm;
    uint64_t footprint;
    char argv[256];
    size_t argv_len;
} measure_cache[MEASURE_CACHE];
static pthread_mutex_t measure_cache_lock = PTHREAD_MUTEX_INITIALIZER;

static bool measure(struct candidate *c, bool shared_mm) {
    struct mem *mem = &c->mm->mem;
    unsigned slot = (unsigned) (((uintptr_t) c->mm >> 6) % MEASURE_CACHE);
    bool locked = false;
    for (int tries = 0; tries < 20 && !(locked = read_wrtrylock(&mem->lock)); tries++) {
        struct timespec ms = {0, 1000000};
        nanosleep(&ms, NULL);
    }
    if (!locked) {
        pthread_mutex_lock(&measure_cache_lock);
        bool cached = measure_cache[slot].mm == c->mm;
        if (cached) {
            c->footprint = measure_cache[slot].footprint;
            c->argv_len = measure_cache[slot].argv_len;
            memcpy(c->argv, measure_cache[slot].argv, sizeof(c->argv));
        }
        pthread_mutex_unlock(&measure_cache_lock);
        return cached;
    }
    c->argv_len = mm_read_argv(c->mm, c->argv, sizeof(c->argv) - 1);
    c->argv[c->argv_len] = '\0';
    c->footprint = shared_mm ? 0 : mm_footprint(c->mm);
    read_wrunlock(&mem->lock);
    pthread_mutex_lock(&measure_cache_lock);
    measure_cache[slot].mm = c->mm;
    measure_cache[slot].footprint = c->footprint;
    measure_cache[slot].argv_len = c->argv_len;
    memcpy(measure_cache[slot].argv, c->argv, sizeof(c->argv));
    pthread_mutex_unlock(&measure_cache_lock);
    return true;
}

// Every live process (thread group leader) with its memory. Caller frees with
// free_candidates.
static struct candidate *list_candidates(int *count, uint64_t allowance, int only_pid) {
    int cap = 64, n = 0;
    struct candidate *list = malloc(cap * sizeof(*list));
    if (list == NULL)
        return NULL;
    lock(&pids_lock);
    for (int pid = 1; pid < MAX_PID; pid++) {
        struct task *task = pid_get_task(pid);
        if (only_pid != 0 && pid != only_pid)
            continue;
        if (task == NULL || task->zombie || task->exiting || task->sighand == NULL ||
                task->group == NULL || task->group->leader != task || task->group->doing_group_exit)
            continue;
        if (n == cap) {
            struct candidate *bigger = realloc(list, cap * 2 * sizeof(*list));
            if (bigger == NULL)
                break;
            list = bigger;
            cap *= 2;
        }
        struct candidate *c = &list[n];
        memset(c, 0, sizeof(*c));
        c->pid = pid;
        c->adj = task->group->oom_score_adj;
        c->ppid = task->parent != NULL ? task->parent->tgid : 0;
        struct task *t;
        list_for_each_entry(&task->group->threads, t, group_links)
            c->threads++;
        lock(&task->general_lock);
        strncpy(c->comm, task->comm, sizeof(c->comm) - 1);
        c->mm = task->mm;
        if (c->mm != NULL)
            mm_retain(c->mm);
        unlock(&task->general_lock);
        if (c->mm == NULL)
            continue;
        n++;
    }
    unlock(&pids_lock);

    for (int i = 0; i < n; i++) {
        struct candidate *c = &list[i];
        bool shared_mm = false;
        for (int j = 0; j < i; j++)
            if (list[j].mm == c->mm)
                shared_mm = true; // vfork child: its memory is its parent's
        measure(c, shared_mm);
        c->footprint += (uint64_t) c->threads * THREAD_COST;
        c->protected = is_protected(c);
    }
    long long allowance_pages = (long long) (allowance / PAGE_SIZE);
    for (int i = 0; i < n; i++) {
        struct candidate *c = &list[i];
        c->effective_adj = c->adj;
        if (c->argv[0] != '\0') {
            for (int j = 0; j < n; j++) {
                if (list[j].pid != c->ppid || list[j].argv[0] == '\0')
                    continue;
                if (strcmp(c->argv, list[j].argv) == 0 || strcmp(c->argv, "/proc/self/exe") == 0) {
                    if (c->adj >= 0 && c->adj < HELPER_ADJ)
                        c->effective_adj = HELPER_ADJ;
                    if (!c->protected)
                        list[j].has_helpers = true;
                }
                break;
            }
        }
        // Linux oom_badness: pages charged + oom_score_adj thousandths of all memory.
        c->score = (long long) (c->footprint / PAGE_SIZE) + (long long) c->effective_adj * allowance_pages / 1000;
        if (c->score < 1)
            c->score = 1;
    }
    *count = n;
    return list;
}

static void free_candidates(struct candidate *list, int n) {
    for (int i = 0; i < n; i++)
        mm_release(list[i].mm);
    free(list);
}

static bool pid_alive(int pid) {
    lock(&pids_lock);
    struct task *task = pid_get_task(pid);
    bool alive = task != NULL && !task->zombie;
    unlock(&pids_lock);
    return alive;
}

static void format_gb(char *out, size_t size, uint64_t bytes) {
    snprintf(out, size, "%.1f GB", bytes / (double) (1ull << 30));
}

// Kill the process with the highest badness. Returns its pid, or 0 if none.
static int kill_one(const struct limits *l) {
    int n;
    struct candidate *list = list_candidates(&n, l->allowance, 0);
    if (list == NULL)
        return 0;
    // An app's main process is only closed once none of its helpers is left, as
    // Chrome and Android protect the browser process: closing a helper costs a tab.
    // A process that would give back less than MIN_VICTIM is only picked when there is
    // nothing bigger, so a high oom_score_adj alone doesn't cost a process per round.
    struct candidate *victim = NULL;
    for (int pass = 0; pass < 3 && victim == NULL; pass++)
        for (int i = 0; i < n; i++)
            if (!list[i].protected && (pass == 2 || !list[i].has_helpers) &&
                    (pass >= 1 || list[i].footprint >= MIN_VICTIM) &&
                    (victim == NULL || list[i].score > victim->score))
                victim = &list[i];
    int pid = 0;
    if (victim != NULL) {
        lock(&pids_lock);
        struct task *task = pid_get_task(victim->pid);
        if (task != NULL && !task->zombie) {
            send_signal(task, SIGKILL_, SIGINFO_NIL);
            pid = victim->pid;
        }
        unlock(&pids_lock);
    }
    if (pid != 0) {
        char app[48], used[16], total[16], message[256];
        friendly_name(victim, app, sizeof(app));
        format_gb(used, sizeof(used), l->footprint);
        format_gb(total, sizeof(total), l->allowance);
        printk("Out of memory: Killed process %d (%s) total-vm-charged:%llukB oom_score_adj:%d (as %d); "
               "host footprint %lluMB of %lluMB\n", pid, victim->comm,
               (unsigned long long) (victim->footprint >> 10), victim->adj, victim->effective_adj,
               (unsigned long long) (l->footprint / MB), (unsigned long long) (l->allowance / MB));
        snprintf(message, sizeof(message),
                 "Closed %s to free memory. LinPad was using %s of the %s iPadOS allows it.",
                 app, used, total);
        pthread_mutex_lock(&oom_lock);
        struct kill_record *r = &kills[kill_count++ % KILLS_KEPT];
        *r = (struct kill_record) {time(NULL), pid, "", victim->footprint, l->footprint, l->allowance};
        strncpy(r->app, app, sizeof(r->app) - 1);
        pthread_mutex_unlock(&oom_lock);
        if (oom_kill_hook != NULL)
            oom_kill_hook(app, message);
    } else {
        static time_t last_complaint;
        if (time(NULL) - last_complaint >= 10) {
            last_complaint = time(NULL);
            printk("Out of memory: no process left that may be killed (host footprint %lluMB of %lluMB)\n",
                   (unsigned long long) (l->footprint / MB), (unsigned long long) (l->allowance / MB));
        }
    }
    free_candidates(list, n);
    return pid;
}

static void *monitor(void *UNUSED(arg)) {
    uint64_t last = now_ns();
    int pending_victim = 0;
    uint64_t victim_deadline = 0, settle_until = 0;
    for (;;) {
        struct limits l = read_limits();
        uint64_t now = now_ns();
        pthread_mutex_lock(&oom_lock);
        psi_account(&l, now - last);
        pthread_mutex_unlock(&oom_lock);
        last = now;

        unsigned wait_ms = 2000;
        if (l.allowance != 0) {
            wait_ms = l.headroom > 2 * l.soft ? 1000 : l.headroom > l.soft ? 250 : 100;
            if (pending_victim != 0 && (!pid_alive(pending_victim) || now > victim_deadline)) {
                pending_victim = 0;
                // Let the host take back the victim's memory before judging again.
                settle_until = now + 300000000ull;
            }
            pthread_mutex_lock(&oom_lock);
            bool on = enabled;
            pthread_mutex_unlock(&oom_lock);
            // One victim at a time: wait until the last one is gone (its memory freed)
            // before judging again, so one spike doesn't take several processes.
            if (on && pending_victim == 0 && now >= settle_until && l.headroom <= l.hard) {
                pending_victim = kill_one(&l);
                victim_deadline = now + 5000000000ull;
                wait_ms = 50;
            }
            if (pending_victim == 0) {
                pthread_mutex_lock(&oom_lock);
                rounds++;
                pthread_cond_broadcast(&oom_round_done);
                pthread_mutex_unlock(&oom_lock);
            } else {
                wait_ms = 50;
            }
        }

        struct timespec until;
        clock_gettime(CLOCK_REALTIME, &until);
        until.tv_nsec += (long) (wait_ms % 1000) * 1000000;
        until.tv_sec += wait_ms / 1000 + until.tv_nsec / 1000000000;
        until.tv_nsec %= 1000000000;
        pthread_mutex_lock(&oom_lock);
        while (!poked && pthread_cond_timedwait(&oom_wake, &oom_lock, &until) == 0)
            ;
        poked = false;
        pthread_mutex_unlock(&oom_lock);
    }
    return NULL;
}

void oom_start(void) {
    pthread_mutex_lock(&oom_lock);
    if (started) {
        pthread_mutex_unlock(&oom_lock);
        return;
    }
    started = true;
    const char *env = getenv("ISH_OOM");
    if (env != NULL && strcmp(env, "0") == 0)
        enabled = false;
    env = getenv("ISH_OOM_PROTECT");
    if (env != NULL)
        user_protect = strdup(env);
    pthread_mutex_unlock(&oom_lock);
    pthread_t thread;
    if (pthread_create(&thread, NULL, monitor, NULL) == 0)
        pthread_detach(thread);
}

void oom_set_enabled(bool on) {
    pthread_mutex_lock(&oom_lock);
    enabled = on;
    pthread_mutex_unlock(&oom_lock);
}

bool oom_enabled(void) {
    pthread_mutex_lock(&oom_lock);
    bool on = enabled;
    pthread_mutex_unlock(&oom_lock);
    return on;
}

void oom_set_protect(const char *names) {
    char *copy = names && names[0] ? strdup(names) : NULL;
    pthread_mutex_lock(&oom_lock);
    free(user_protect);
    user_protect = copy;
    pthread_mutex_unlock(&oom_lock);
}

void oom_poke(void) {
    pthread_mutex_lock(&oom_lock);
    poked = true;
    pthread_cond_signal(&oom_wake);
    pthread_mutex_unlock(&oom_lock);
}

bool oom_wait_for_headroom(uint64_t bytes) {
    if (!started || !oom_enabled())
        return false;
    uint64_t deadline = now_ns() + 2000000000ull;
    while (now_ns() < deadline) {
        pthread_mutex_lock(&oom_lock);
        uint64_t seen = rounds;
        poked = true;
        pthread_cond_signal(&oom_wake);
        struct timespec until;
        clock_gettime(CLOCK_REALTIME, &until);
        until.tv_nsec += 100000000;
        until.tv_sec += until.tv_nsec / 1000000000;
        until.tv_nsec %= 1000000000;
        while (rounds == seen && pthread_cond_timedwait(&oom_round_done, &oom_lock, &until) == 0)
            ;
        pthread_mutex_unlock(&oom_lock);
        if (host_memory_headroom() >= bytes)
            return true;
    }
    return false;
}

void oom_show_pressure(struct proc_data *buf) {
    pthread_mutex_lock(&oom_lock);
    struct pressure some = psi_some, full = psi_full;
    pthread_mutex_unlock(&oom_lock);
    proc_printf(buf, "some avg10=%.2f avg60=%.2f avg300=%.2f total=%llu\n",
                some.avg[0], some.avg[1], some.avg[2], (unsigned long long) some.total_us);
    proc_printf(buf, "full avg10=%.2f avg60=%.2f avg300=%.2f total=%llu\n",
                full.avg[0], full.avg[1], full.avg[2], (unsigned long long) full.total_us);
}

void oom_show_policy(struct proc_data *buf) {
    struct limits l = read_limits();
    pthread_mutex_lock(&oom_lock);
    proc_printf(buf, "enabled %d\n", enabled);
    proc_printf(buf, "protect %s\n", user_protect ? user_protect : "");
    pthread_mutex_unlock(&oom_lock);
    proc_printf(buf, "builtin");
    for (size_t i = 0; i < sizeof(builtin_protect) / sizeof(builtin_protect[0]); i++)
        proc_printf(buf, "%s%s", i ? "," : " ", builtin_protect[i]);
    proc_printf(buf, "\nsoft_mb %llu\nhard_mb %llu\n",
                (unsigned long long) (l.soft / MB), (unsigned long long) (l.hard / MB));
}

// "enabled 0|1" and/or "protect name,name" lines.
int oom_update_policy(const char *text, size_t size) {
    char *copy = strndup(text, size);
    if (copy == NULL)
        return _ENOMEM;
    int err = 0;
    char *save = NULL;
    for (char *line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        if (strncmp(line, "enabled ", 8) == 0)
            oom_set_enabled(atoi(line + 8) != 0);
        else if (strcmp(line, "protect") == 0 || strncmp(line, "protect ", 8) == 0)
            oom_set_protect(line[7] ? line + 8 : "");
        else
            err = _EINVAL;
    }
    free(copy);
    return err;
}

static int compare_score(const void *a, const void *b) {
    const struct candidate *x = a, *y = b;
    return x->footprint < y->footprint ? 1 : x->footprint > y->footprint ? -1 : 0;
}

// For Settings › Performance › Memory: the app's footprint and allowance, the
// policy, recent kills and the processes using the most memory.
void oom_show_memory(struct proc_data *buf) {
    struct limits l = read_limits();
    uint64_t footprint = l.footprint ? l.footprint : host_memory_footprint();
    proc_printf(buf, "footprint_mb %llu\n", (unsigned long long) (footprint / MB));
    proc_printf(buf, "allowance_mb %llu\n", (unsigned long long) (l.allowance / MB));
    proc_printf(buf, "headroom_mb %llu\n", (unsigned long long) (l.headroom / MB));
    proc_printf(buf, "soft_mb %llu\nhard_mb %llu\n",
                (unsigned long long) (l.soft / MB), (unsigned long long) (l.hard / MB));
    pthread_mutex_lock(&oom_lock);
    proc_printf(buf, "oom_enabled %d\n", enabled);
    proc_printf(buf, "kills %u\n", kill_count);
    unsigned first = kill_count > KILLS_KEPT ? kill_count - KILLS_KEPT : 0;
    for (unsigned i = first; i < kill_count; i++) {
        struct kill_record *r = &kills[i % KILLS_KEPT];
        proc_printf(buf, "kill %lld %d %llu %llu %llu %s\n", (long long) r->when, r->pid,
                    (unsigned long long) (r->freed / MB), (unsigned long long) (r->footprint / MB),
                    (unsigned long long) (r->allowance / MB), r->app);
    }
    pthread_mutex_unlock(&oom_lock);
    int n;
    struct candidate *list = list_candidates(&n, l.allowance ? l.allowance : footprint, 0);
    if (list == NULL)
        return;
    qsort(list, n, sizeof(*list), compare_score);
    for (int i = 0; i < n && i < 12; i++) {
        char app[48];
        friendly_name(&list[i], app, sizeof(app));
        proc_printf(buf, "proc %d %llu %d %d %s\n", list[i].pid,
                    (unsigned long long) (list[i].footprint / MB), list[i].adj,
                    list[i].protected, app);
    }
    free_candidates(list, n);
}

int oom_score_of_pid(int pid) {
    struct limits l = read_limits();
    uint64_t total = l.allowance ? l.allowance : host_memory_footprint();
    if (total == 0)
        return 0;
    int n;
    struct candidate *list = list_candidates(&n, total, pid);
    if (list == NULL)
        return 0;
    int score = 0;
    for (int i = 0; i < n; i++) {
        if (list[i].pid != pid)
            continue;
        if (list[i].adj == -1000)
            break;
        // Linux: (1000 + badness * 1000 / totalpages) * 2 / 3, in 0..2000
        long long pages = (long long) (total / PAGE_SIZE);
        long long s = (1000 + list[i].score * 1000 / pages) * 2 / 3;
        score = s < 0 ? 0 : s > 2000 ? 2000 : (int) s;
    }
    free_candidates(list, n);
    return score;
}
