#include <stdlib.h>
#include <time.h>
#include <string.h>
#include <sys/stat.h>
#include "kernel/memory.h"
#include "kernel/calls.h"
#include "fs/proc.h"
#include "platform/platform.h"
#include "kernel/mm.h"
#include "fs/fd.h"
#include "fs/tty.h"
#include "kernel/fs.h"
#include "kernel/vdso.h"
#include "util/sync.h"

static void proc_pid_getname(struct proc_entry *entry, char *buf) {
    sprintf(buf, "%d", entry->pid);
}

static struct task *proc_get_task(struct proc_entry *entry) {
    lock(&pids_lock);
    struct task *task = pid_get_task(entry->pid);
    // Also reject tasks that are mid-exit: sighand/group may already be freed.
    if (task != NULL && (task->exiting || task->sighand == NULL || task->group == NULL))
        task = NULL;
    if (task == NULL)
        unlock(&pids_lock);
    return task;
}
static void proc_put_task(struct task *UNUSED(task)) {
    unlock(&pids_lock);
}

// The task's mm, with a reference. Guest memory locks are never taken under
// pids_lock: a thread waiting for one (behind a page fault or a stuck
// process) would then block every kill, exit, wait and fork in the system.
// So the mm is looked up under pids_lock, and read after dropping it.
// *gone is set if the task doesn't exist (as opposed to having no mm).
static struct mm *proc_get_mm_or_gone(struct proc_entry *entry, bool *gone) {
    struct task *task = proc_get_task(entry);
    *gone = task == NULL;
    if (task == NULL)
        return NULL;
    lock(&task->general_lock);
    struct mm *mm = task->mm;
    if (mm != NULL)
        mm_retain(mm);
    unlock(&task->general_lock);
    proc_put_task(task);
    return mm;
}

static struct mm *proc_get_mm(struct proc_entry *entry) {
    bool gone;
    return proc_get_mm_or_gone(entry, &gone);
}

// Page counts of an address space.
struct vm_counts {
    uint64_t size;   // mapped + reserved pages (VmSize)
    uint64_t rss;    // pages backed by host memory (VmRSS)
    uint64_t shared; // file-backed pages (RssFile)
    uint64_t anon;   // anonymous pages (RssAnon)
};
static struct vm_counts mm_vm_counts(struct mm *mm) {
    struct vm_counts c = {};
    if (mm == NULL)
        return c;
    struct mem *mem = &mm->mem;
    read_wrlock(&mem->lock);
    for (page_t page = 0; page < MEM_PAGES; mem_next_page(mem, &page)) {
        struct pt_entry *pt = mem_pt(mem, page);
        if (pt == NULL)
            continue;
        c.rss++;
        if (pt->flags & P_ANONYMOUS)
            c.anon++;
        else
            c.shared++;
    }
    c.size = c.rss;
    for (struct mem_reservation *r = mem->reservations; r; r = r->next)
        c.size += r->pages;
    read_wrunlock(&mem->lock);
    return c;
}

// Counting walks every page of the address space under its lock: about 10 ms for a
// Firefox process, and ps/top (or a benchmark sampling CPU time) read stat/status of
// every thread, which also holds off the process's mmaps. So remember the counts per
// address space until it changes (mmu.changes moves on mmap/munmap/mprotect/CoW) or
// for at most a second.
#define VM_COUNTS_CACHE 16
static struct {
    struct mm *mm;
    uint64_t changes;
    uint64_t when_ns;
    struct vm_counts counts;
} vm_counts_cache[VM_COUNTS_CACHE];
static lock_t vm_counts_lock = LOCK_INITIALIZER;

static uint64_t monotonic_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t) ts.tv_sec * 1000000000ull + (uint64_t) ts.tv_nsec;
}

static struct vm_counts mm_vm_counts_cached(struct mm *mm) {
    if (mm == NULL)
        return (struct vm_counts) {};
    uint64_t changes = __atomic_load_n(&mm->mem.mmu.changes, __ATOMIC_ACQUIRE);
    uint64_t now = monotonic_ns();
    unsigned slot = (unsigned) (((uintptr_t) mm >> 6) % VM_COUNTS_CACHE);
    lock(&vm_counts_lock);
    if (vm_counts_cache[slot].mm == mm && vm_counts_cache[slot].changes == changes &&
        now - vm_counts_cache[slot].when_ns < 1000000000ull) {
        struct vm_counts c = vm_counts_cache[slot].counts;
        unlock(&vm_counts_lock);
        return c;
    }
    unlock(&vm_counts_lock);
    struct vm_counts c = mm_vm_counts(mm);
    lock(&vm_counts_lock);
    vm_counts_cache[slot].mm = mm;
    vm_counts_cache[slot].changes = changes;
    vm_counts_cache[slot].when_ns = now;
    vm_counts_cache[slot].counts = c;
    unlock(&vm_counts_lock);
    return c;
}

static struct vm_counts proc_vm_counts(struct proc_entry *entry) {
    struct mm *mm = proc_get_mm(entry);
    struct vm_counts c = mm_vm_counts_cached(mm);
    if (mm != NULL)
        mm_release(mm);
    return c;
}

static int proc_pid_status_show(struct proc_entry *entry, struct proc_data *buf) {
    struct vm_counts vm = proc_vm_counts(entry);
    struct task *task = proc_get_task(entry);
    if (task == NULL)
        return _ESRCH;
    lock(&task->group->lock);
    char state = task->zombie ? 'Z' : task->group->stopped ? 'T' : 'S';
    long threads = list_size(&task->group->threads);
    unlock(&task->group->lock);
    unsigned long kb = PAGE_SIZE / 1024;
    proc_printf(buf, "Name:\t%.16s\n", task->comm);
    proc_printf(buf, "State:\t%c\n", state);
    proc_printf(buf, "Tgid:\t%d\n", task->tgid);
    proc_printf(buf, "Pid:\t%d\n", task->pid);
    proc_printf(buf, "PPid:\t%d\n", task->parent ? task->parent->pid : 0);
    proc_printf(buf, "Uid:\t%d\t%d\t%d\t%d\n", task->uid, task->euid, task->suid, task->euid);
    proc_printf(buf, "Gid:\t%d\t%d\t%d\t%d\n", task->gid, task->egid, task->sgid, task->egid);
    proc_printf(buf, "VmPeak:\t%8llu kB\n", (unsigned long long) (vm.size * kb));
    proc_printf(buf, "VmSize:\t%8llu kB\n", (unsigned long long) (vm.size * kb));
    proc_printf(buf, "VmHWM:\t%8llu kB\n", (unsigned long long) (vm.rss * kb));
    proc_printf(buf, "VmRSS:\t%8llu kB\n", (unsigned long long) (vm.rss * kb));
    proc_printf(buf, "RssAnon:\t%8llu kB\n", (unsigned long long) (vm.anon * kb));
    proc_printf(buf, "RssFile:\t%8llu kB\n", (unsigned long long) (vm.shared * kb));
    proc_printf(buf, "RssShmem:\t%8llu kB\n", 0ull);
    proc_printf(buf, "VmData:\t%8llu kB\n", (unsigned long long) (vm.anon * kb));
    proc_printf(buf, "VmSwap:\t%8llu kB\n", 0ull);
    proc_printf(buf, "Threads:\t%ld\n", threads);
    proc_put_task(task);
    return 0;
}

static int proc_pid_stat_show(struct proc_entry *entry, struct proc_data *buf) {
    struct vm_counts vm = proc_vm_counts(entry);
    struct task *task = proc_get_task(entry);
    if (task == NULL)
        return _ESRCH;
    // host CPU time of the process's threads (pids_lock is held)
    struct rusage_ ru = rusage_get_group(task->group);
    lock(&task->group->lock);
    struct rusage_ cru = task->group->children_rusage;
    unlock(&task->group->lock);
    lock(&task->general_lock);
    lock(&task->group->lock);
    lock(&task->sighand->lock);

    proc_printf(buf, "%d ", task->pid);
    proc_printf(buf, "(%.16s) ", task->comm);
    proc_printf(buf, "%c ",
            task->zombie ? 'Z' :
            task->group->stopped ? 'T' :
            'R'); // I have no visibility into sleep state at the moment
    proc_printf(buf, "%d ", task->parent ? task->parent->pid : 0);
    proc_printf(buf, "%d ", task->group->pgid);
    proc_printf(buf, "%d ", task->group->sid);
    struct tty *tty = task->group->tty;
    proc_printf(buf, "%d ", tty ? dev_make(tty->driver->major, tty->num) : 0);
    proc_printf(buf, "%d ", tty ? tty->fg_group : 0);
    proc_printf(buf, "%u ", 0); // flags

    // page faults (no data available)
    proc_printf(buf, "%lu ", 0l); // minor faults
    proc_printf(buf, "%lu ", 0l); // children minor faults
    proc_printf(buf, "%lu ", 0l); // major faults
    proc_printf(buf, "%lu ", 0l); // children major faults

    // values that would be returned from getrusage
    // finding these for a given process isn't too easy
#define RU_TICKS(tv) ((long) (tv).sec * 100 + (long) (tv).usec / 10000) // clock ticks (100 Hz)
    proc_printf(buf, "%lu ", RU_TICKS(ru.utime)); // user time
    proc_printf(buf, "%lu ", RU_TICKS(ru.stime)); // system time
    proc_printf(buf, "%ld ", RU_TICKS(cru.utime)); // children user time
    proc_printf(buf, "%ld ", RU_TICKS(cru.stime)); // children system time
#undef RU_TICKS

    proc_printf(buf, "%ld ", 20l); // priority (not adjustable)
    proc_printf(buf, "%ld ", 0l); // nice (also not adjustable)
    proc_printf(buf, "%ld ", list_size(&task->group->threads));
    proc_printf(buf, "%ld ", 0l); // itimer value (deprecated, always 0)
    // starttime: clock ticks after boot, matching /proc/uptime and btime
    {
        struct uptime_info uptime = get_uptime();
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        int64_t now_ticks = (int64_t) now.tv_sec * 100 + now.tv_nsec / 10000000;
        int64_t boot_ticks = now_ticks - (int64_t) uptime.uptime_ticks;
        int64_t start_ticks = (int64_t) (task->group->leader->start_realtime_ns / 10000000) - boot_ticks;
        proc_printf(buf, "%lld ", (long long) (start_ticks > 0 ? start_ticks : 0));
    }

    proc_printf(buf, "%llu ", (unsigned long long) (vm.size * PAGE_SIZE)); // vsize
    proc_printf(buf, "%lld ", (long long) vm.rss); // rss
    proc_printf(buf, "%lu ", 0l); // rss limit

    // bunch of shit that can only be accessed by a debugger
    proc_printf(buf, "%lu ", 0l); // startcode
    proc_printf(buf, "%lu ", 0l); // endcode
    proc_printf(buf, "%lu ", task->mm ? task->mm->stack_start : 0);
    proc_printf(buf, "%lu ", 0l); // kstkesp
    proc_printf(buf, "%lu ", 0l); // kstkeip

    proc_printf(buf, "%lu ", (unsigned long) task->pending & 0xffffffff);
    proc_printf(buf, "%lu ", (unsigned long) task->blocked & 0xffffffff);
    uint32_t ignored = 0;
    uint32_t caught = 0;
    for (int i = 0; i < 32; i++) {
        if (task->sighand->action[i].handler == SIG_IGN_)
            ignored |= 1l << i;
        else if (task->sighand->action[i].handler != SIG_DFL_)
            caught |= 1l << i;
    }
    proc_printf(buf, "%lu ", (unsigned long) ignored);
    proc_printf(buf, "%lu ", (unsigned long) caught);

    proc_printf(buf, "%lu ", 0l); // wchan (wtf)
    proc_printf(buf, "%lu ", 0l); // nswap
    proc_printf(buf, "%lu ", 0l); // cnswap
    proc_printf(buf, "%d ", task->exit_signal);
    proc_printf(buf, "%d", 0); // processor
    // that's enough for now
    proc_printf(buf, "\n");

    unlock(&task->sighand->lock);
    unlock(&task->group->lock);
    unlock(&task->general_lock);
    proc_put_task(task);
    return 0;
}

static int proc_pid_statm_show(struct proc_entry *entry, struct proc_data *buf) {
    struct vm_counts vm = proc_vm_counts(entry);
    struct task *task = proc_get_task(entry);
    if (task == NULL)
        return _ESRCH;

    proc_printf(buf, "%llu ", (unsigned long long) vm.size); // total vm size
    proc_printf(buf, "%llu ", (unsigned long long) vm.rss); // vm resident size
    proc_printf(buf, "%llu ", (unsigned long long) vm.shared); // resident shared
    proc_printf(buf, "%lu ", 0ul); // text
    proc_printf(buf, "%lu ", 0ul); // lib (always 0 since linux 2.6)
    proc_printf(buf, "%llu ", (unsigned long long) vm.anon); // data + stack
    proc_printf(buf, "%lu ", 0ul); // dirty (always 0 since linux 2.6)
    proc_printf(buf, "\n");

    proc_put_task(task);
    return 0;
}

static int proc_pid_auxv_show(struct proc_entry *entry, struct proc_data *buf) {
    bool gone;
    struct mm *mm = proc_get_mm_or_gone(entry, &gone);
    if (mm == NULL)
        return gone ? _ESRCH : 0;
    int err = 0;
    size_t size = mm->auxv_end - mm->auxv_start;
    char *data = malloc(size);
    if (data == NULL) {
        err = _ENOMEM;
    } else {
        if (user_read_mem(&mm->mem, mm->auxv_start, data, size) == 0)
            proc_buf_append(buf, data, size);
        free(data);
    }
    mm_release(mm);
    return err;
}

static int proc_pid_cmdline_show(struct proc_entry *entry, struct proc_data *buf) {
    bool gone;
    struct mm *mm = proc_get_mm_or_gone(entry, &gone);
    if (mm == NULL)
        return gone ? _ESRCH : 0;
    int err = 0;
    size_t size = mm->argv_end - mm->argv_start;
    char *data = malloc(size);
    if (data == NULL) {
        err = _ENOMEM;
    } else {
        if (user_read_mem(&mm->mem, mm->argv_start, data, size) == 0)
            proc_buf_append(buf, data, size);
        free(data);
    }
    mm_release(mm);
    return err;
}

static void proc_maps_dump_mem(struct mem *mem, struct proc_data *buf) {

    read_wrlock(&mem->lock);
    page_t page = 0;
    while (page < MEM_PAGES) {
        // find a region
        while (page < MEM_PAGES && mem_pt(mem, page) == NULL) {
            mem_next_page(mem, &page);
        }
        if (page >= MEM_PAGES)
            break;
        page_t start = page;
        struct pt_entry *start_pt = mem_pt(mem, start);
        struct data *data = start_pt->data;

        // find the end of said region
        while (page < MEM_PAGES) {
            struct pt_entry *pt = mem_pt(mem, page);
            if (pt == NULL)
                break;
            if ((pt->flags & P_RWX) != (start_pt->flags & P_RWX))
                break;
            // region continues if data is the same or both are anonymous
            if (!(pt->data == data || (pt->flags & P_ANONYMOUS && start_pt->flags & P_ANONYMOUS)))
                break;
            mem_next_page(mem, &page);
        }
        page_t end = page;

        // output info
        char path[MAX_PATH] = "";
        if (start_pt->flags & P_GROWSDOWN) {
            strcpy(path, "[stack]");
        } else if (data->name != NULL) {
            strcpy(path, data->name);
        } else if (data->fd != NULL) {
            generic_getpath(start_pt->data->fd, path);
        }
#ifdef GUEST_ARM64
        proc_printf(buf, "%012llx-%012llx %c%c%c%c %08lx 00:00 %-10d %s\n",
                (unsigned long long)(start << PAGE_BITS),
                (unsigned long long)(end << PAGE_BITS),
#else
        proc_printf(buf, "%08x-%08x %c%c%c%c %08lx 00:00 %-10d %s\n",
                start << PAGE_BITS, end << PAGE_BITS,
#endif
                start_pt->flags & P_READ ? 'r' : '-',
                start_pt->flags & P_WRITE ? 'w' : '-',
                start_pt->flags & P_EXEC ? 'x' : '-',
                start_pt->flags & P_SHARED ? '-' : 'p',
                (unsigned long) data->file_offset, // offset
                0, // inode
                path);
    }
    read_wrunlock(&mem->lock);
}

// for the current task (which keeps its mm)
void proc_maps_dump(struct task *task, struct proc_data *buf) {
    if (task->mem != NULL)
        proc_maps_dump_mem(task->mem, buf);
}

static int proc_pid_maps_show(struct proc_entry *entry, struct proc_data *buf) {
    struct mm *mm = proc_get_mm(entry);
    if (mm != NULL) {
        proc_maps_dump_mem(&mm->mem, buf);
        mm_release(mm);
    }
    return 0;
}

static ssize_t proc_pid_mem_pread(struct proc_entry *entry, struct proc_data *buf, off_t offset) {
    struct mm *mm = proc_get_mm(entry);
    if (mm == NULL)
        return -1;
    int result = user_read_mem(&mm->mem, (addr_t)offset, buf->data, buf->size);
    mm_release(mm);
    return result ? -1 : buf->size;
}

static ssize_t proc_pid_mem_pwrite(struct proc_entry *entry, struct proc_data *buf, off_t offset) {
    struct mm *mm = proc_get_mm(entry);
    if (mm == NULL)
        return -1;
    int result = user_write_mem_ptrace(&mm->mem, (addr_t)offset, buf->data, buf->size);
    mm_release(mm);
    return result ? -1 : buf->size;
}


// OOM score files: Chromium and systemd-style launchers write them for their
// children. There is no OOM killer to steer, so the value is only kept for
// reading back.
static int proc_pid_oom_score_show(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "0\n");
    return 0;
}

static int proc_oom_read(struct proc_entry *entry, int *value) {
    struct task *task = proc_get_task(entry);
    if (task == NULL)
        return _ESRCH;
    *value = task->group->oom_score_adj;
    proc_put_task(task);
    return 0;
}

static int proc_oom_write(struct proc_entry *entry, struct proc_data *data, int min, int max, int scale_num, int scale_den) {
    char text[16];
    size_t n = data->size < sizeof(text) - 1 ? data->size : sizeof(text) - 1;
    memcpy(text, data->data, n);
    text[n] = '\0';
    char *end;
    long value = strtol(text, &end, 10);
    if (end == text || value < min || value > max)
        return _EINVAL;
    struct task *task = proc_get_task(entry);
    if (task == NULL)
        return _ESRCH;
    task->group->oom_score_adj = (int) (value * scale_num / scale_den);
    proc_put_task(task);
    return 0;
}

static int proc_pid_oom_score_adj_show(struct proc_entry *entry, struct proc_data *buf) {
    int value;
    int err = proc_oom_read(entry, &value);
    if (err < 0)
        return err;
    proc_printf(buf, "%d\n", value);
    return 0;
}

static int proc_pid_oom_score_adj_update(struct proc_entry *entry, struct proc_data *data) {
    return proc_oom_write(entry, data, -1000, 1000, 1, 1);
}

// the old interface, -17..15, scaled like Linux does
static int proc_pid_oom_adj_show(struct proc_entry *entry, struct proc_data *buf) {
    int value;
    int err = proc_oom_read(entry, &value);
    if (err < 0)
        return err;
    proc_printf(buf, "%d\n", value == 1000 ? 15 : value * 17 / 1000);
    return 0;
}

static int proc_pid_oom_adj_update(struct proc_entry *entry, struct proc_data *data) {
    return proc_oom_write(entry, data, -17, 15, 1000, 17);
}

static struct proc_dir_entry proc_pid_fd;

static bool proc_pid_fd_readdir(struct proc_entry *entry, unsigned long *index, struct proc_entry *next_entry) {
    struct task *task = proc_get_task(entry);
    if (task == NULL)
        return _ESRCH;
    lock(&task->files->lock);
    while (*index < task->files->size && task->files->files[*index] == NULL)
        (*index)++;
    fd_t f = (*index)++;
    bool any_left = (unsigned) f < task->files->size;
    unlock(&task->files->lock);
    proc_put_task(task);
    *next_entry = (struct proc_entry) {&proc_pid_fd, .pid = entry->pid, .fd = f};
    return any_left;
}

static void proc_pid_fd_getname(struct proc_entry *entry, char *buf) {
    sprintf(buf, "%d", entry->fd);
}

static int proc_pid_fd_readlink(struct proc_entry *entry, char *buf) {
    struct task *task = proc_get_task(entry);
    if (task == NULL)
        return _ESRCH;
    int err = _ENOENT;
    lock(&task->general_lock);
    if (task->files != NULL) {
        lock(&task->files->lock);
        struct fd *fd = fdtable_get(task->files, entry->fd);
        if (fd != NULL)
            err = generic_getpath(fd, buf);
        unlock(&task->files->lock);
    }
    unlock(&task->general_lock);
    proc_put_task(task);
    return err;
}

static int proc_pid_exe_readlink(struct proc_entry *entry, char *buf) {
    struct task *task = proc_get_task(entry);
    if (task == NULL)
        return _ESRCH;
    lock(&task->general_lock);
    int err;
    if (task->mm == NULL || task->mm->exefile == NULL)
        err = _ENOENT;
    else
        err = generic_getpath(task->mm->exefile, buf);
    unlock(&task->general_lock);
    proc_put_task(task);
    return err;
}

static void proc_pid_task_getname(struct proc_entry *entry, char *buf) {
    sprintf(buf, "%d", entry->pid);
}

static int proc_pid_task_readlink(struct proc_entry *entry, char *buf) {
    sprintf(buf, "/proc/%d", entry->pid);
    return 0;
}

static struct proc_dir_entry proc_pid_task;

static bool proc_pid_task_readdir(struct proc_entry *entry, unsigned long *index, struct proc_entry *next_entry) {
    // One entry per thread of the process (each links to /proc/<tid>)
    lock(&pids_lock);
    struct task *task = pid_get_task(entry->pid);
    pid_t_ tid = 0;
    if (task != NULL && task->group != NULL) {
        unsigned long i = 0;
        struct task *thread;
        list_for_each_entry(&task->group->threads, thread, group_links) {
            if (i++ == *index) {
                tid = thread->pid;
                break;
            }
        }
    }
    unlock(&pids_lock);
    if (tid == 0)
        return false;
    *next_entry = (struct proc_entry) {&proc_pid_task, .pid = tid};
    (*index)++;
    return true;
}

static int proc_pid_cwd_readlink(struct proc_entry *entry, char *buf) {
    struct task *task = proc_get_task(entry);
    if (task == NULL)
        return _ESRCH;
    int err = _ENOENT;
    lock(&task->general_lock);
    if (task->fs != NULL) {
        lock(&task->fs->lock);
        err = generic_getpath(task->fs->pwd, buf);
        unlock(&task->fs->lock);
    }
    unlock(&task->general_lock);
    proc_put_task(task);
    return err;
}


struct proc_children proc_pid_children = PROC_CHILDREN({
    {"auxv", .show = proc_pid_auxv_show},
    {"cmdline", .show = proc_pid_cmdline_show},
    {"cwd", S_IFLNK, .readlink = proc_pid_cwd_readlink},
    {"exe", S_IFLNK, .readlink = proc_pid_exe_readlink},
    {"fd", S_IFDIR, .readdir = proc_pid_fd_readdir},
    {"maps", .show = proc_pid_maps_show},
    {"mem", .pread = proc_pid_mem_pread, .pwrite = proc_pid_mem_pwrite},
    {"oom_adj", 0644, .show = proc_pid_oom_adj_show, .update = proc_pid_oom_adj_update},
    {"oom_score", .show = proc_pid_oom_score_show},
    {"oom_score_adj", 0644, .show = proc_pid_oom_score_adj_show, .update = proc_pid_oom_score_adj_update},
    {"stat", .show = proc_pid_stat_show},
    {"statm", .show = proc_pid_statm_show},
    {"status", .show = proc_pid_status_show},
    {"task", S_IFDIR, .readdir = proc_pid_task_readdir},
});

struct proc_dir_entry proc_pid = {NULL, S_IFDIR,
    .children = &proc_pid_children, .getname = proc_pid_getname};

static struct proc_dir_entry proc_pid_fd = {NULL, S_IFLNK,
    .getname = proc_pid_fd_getname, .readlink = proc_pid_fd_readlink};

static struct proc_dir_entry proc_pid_task = {NULL, S_IFLNK,
    .getname = proc_pid_task_getname, .readlink = proc_pid_task_readlink};
