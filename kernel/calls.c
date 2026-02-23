#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>
#include "debug.h"
#include "kernel/calls.h"
#include "emu/interrupt.h"
#include "kernel/memory.h"
#include "kernel/signal.h"
#include "kernel/task.h"
#include "fs/stat.h"
#include "fs/fd.h"
#include "fs/dev.h"
#include "fs/real.h"

dword_t syscall_stub(void) {
    return _ENOSYS;
}
// While identical, this version of the stub doesn't log below. Use this for
// syscalls that are optional (i.e. fallback on something else) but called
// frequently.
dword_t syscall_silent_stub(void) {
    return _ENOSYS;
}
dword_t syscall_success_stub(void) {
    return 0;
}

// Syscall table is defined in arch-specific files (kernel/arch/*/calls.c)
extern syscall_t syscall_table[];
extern size_t syscall_table_size;

void dump_stack(int lines);
void dump_maps(void);

// Fast path syscall handlers (forward declarations)
#ifdef GUEST_ARM64
static inline int fast_fstat64(struct cpu_state *cpu);
static inline int fast_read(struct cpu_state *cpu);
static inline int fast_write(struct cpu_state *cpu);
#endif

void handle_interrupt(int interrupt) {
    struct cpu_state *cpu = &current->cpu;
    if (interrupt == INT_SYSCALL) {
#if defined(GUEST_X86) || !defined(GUEST_ARM64)
        // x86: syscall number in eax, args in ebx, ecx, edx, esi, edi, ebp
        unsigned syscall_num = cpu->eax;
        if (syscall_num >= syscall_table_size || syscall_table[syscall_num] == NULL) {
            printk("%d(%s) missing syscall %d\n", current->pid, current->comm, syscall_num);
            cpu->eax = _ENOSYS;
        } else {
            if (syscall_table[syscall_num] == (syscall_t) syscall_stub) {
                printk("%d(%s) stub syscall %d\n", current->pid, current->comm, syscall_num);
            }
            STRACE("%d call %-3d ", current->pid, syscall_num);
            int result = syscall_table[syscall_num](cpu->ebx, cpu->ecx, cpu->edx, cpu->esi, cpu->edi, cpu->ebp);
            STRACE(" = 0x%x\n", result);
            cpu->eax = result;
        }
#elif defined(GUEST_ARM64)
        // ARM64: syscall number in x8, args in x0-x5, return in x0
        unsigned syscall_num = cpu->regs[8];

        // === FAST PATH: Hot syscalls ===
        int fast_result = -1;  // -1 means fast path not taken
        bool fast_path_taken = false;

        // Fast path 1: fstat64 (syscall 80) - most common during Python import
        if (syscall_num == 80) {
            fast_result = fast_fstat64(cpu);
            if (fast_result != -1)
                fast_path_taken = true;
        }
        // Fast path 2: read (syscall 63) - small buffer reads
        else if (syscall_num == 63) {
            fast_result = fast_read(cpu);
            if (fast_result != -1)
                fast_path_taken = true;
        }
        // Fast path 3: write (syscall 64) - small buffer writes
        else if (syscall_num == 64) {
            fast_result = fast_write(cpu);
            if (fast_result != -1)
                fast_path_taken = true;
        }

        if (fast_path_taken) {
            // Fast path succeeded, return immediately
            // Fast paths return int (small values), safe to use directly
            STRACE("%d call %-3d (fast) = 0x%x\n", current->pid, syscall_num, fast_result);
            int32_t signed_result = (int32_t)fast_result;
            if (signed_result >= -4095 && signed_result < 0) {
                cpu->regs[0] = (uint64_t)(int64_t)signed_result;
            } else {
                cpu->regs[0] = (uint64_t)(uint32_t)fast_result;
            }
        } else {
            // === SLOW PATH: Full syscall ===
            if (syscall_num >= syscall_table_size || syscall_table[syscall_num] == NULL) {
                printk("%d(%s) missing syscall %d\n", current->pid, current->comm, syscall_num);
                cpu->regs[0] = (uint64_t)(int64_t)(int32_t)_ENOSYS;
            } else {
                if (syscall_table[syscall_num] == (syscall_t) syscall_stub) {
                    printk("%d(%s) stub syscall %d\n", current->pid, current->comm, syscall_num);
                }
                STRACE("%d call %-3d ", current->pid, syscall_num);
                int64_t result = syscall_table[syscall_num](
                    cpu->regs[0], cpu->regs[1], cpu->regs[2],
                    cpu->regs[3], cpu->regs[4], cpu->regs[5]);
                STRACE(" = 0x%llx\n", (unsigned long long)result);
                // ARM64 Linux ABI: return value in x0. Errors are negative
                // (-1 to -4095). Success values are 0 or positive (up to 48-bit
                // addresses from mmap/brk).
                // Most syscalls return dword_t (uint32_t). On ARM64 ABI, returning
                // uint32_t sets w0 only; upper x0 is zero. Error codes like -EFAULT
                // become 0x00000000FFFFFFF2 instead of 0xFFFFFFFFFFFFFFF2.
                // Detect this: if low 32 bits are a valid errno (0xFFFFF001-0xFFFFFFFF)
                // but upper 32 bits are 0, sign-extend the 32-bit value.
                uint32_t low32 = (uint32_t)result;
                if ((result >> 32) == 0 && (int32_t)low32 >= -4095 && (int32_t)low32 < 0) {
                    // 32-bit errno from dword_t-returning syscall — sign-extend
                    cpu->regs[0] = (uint64_t)(int64_t)(int32_t)low32;
                } else {
                    cpu->regs[0] = (uint64_t)result;
                }
            }
        }
#endif
    } else if (interrupt == INT_GPF) {
        // some page faults, such as stack growing or CoW clones, are handled by mem_ptr
        read_wrlock(&current->mem->lock);
        void *ptr = mem_ptr(current->mem, cpu->segfault_addr, cpu->segfault_was_write ? MEM_WRITE : MEM_READ);
        read_wrunlock(&current->mem->lock);
        if (ptr == NULL) {
#if defined(GUEST_X86) || !defined(GUEST_ARM64)
            printk("%d page fault on 0x%x at 0x%x\n", current->pid, cpu->segfault_addr, cpu->eip);
#elif defined(GUEST_ARM64)
            printk("%d page fault on 0x%llx at 0x%llx (%s)\n", current->pid, (unsigned long long)cpu->segfault_addr, (unsigned long long)cpu->pc, cpu->segfault_was_write ? "write" : "read");
            // Decode a few instructions around the faulting PC
            for (int i = -2; i <= 2; i++) {
                uint32_t insn = 0;
                bool ok = true;
                for (int j = 0; j < 4; j++) {
                    uint8_t b;
                    if (user_get(cpu->pc + i*4 + j, b)) { ok = false; break; }
                    insn |= (uint32_t)b << (j*8);
                }
                if (ok) printk("  [pc%+d] %08x %s\n", i*4, insn, i==0 ? "<-- here" : "");
            }
            printk("  x0=%llx x1=%llx x2=%llx x3=%llx\n", (unsigned long long)cpu->regs[0], (unsigned long long)cpu->regs[1], (unsigned long long)cpu->regs[2], (unsigned long long)cpu->regs[3]);
            printk("  x4=%llx x5=%llx x6=%llx x7=%llx\n", (unsigned long long)cpu->regs[4], (unsigned long long)cpu->regs[5], (unsigned long long)cpu->regs[6], (unsigned long long)cpu->regs[7]);
            printk("  x8=%llx x9=%llx x10=%llx x11=%llx\n", (unsigned long long)cpu->regs[8], (unsigned long long)cpu->regs[9], (unsigned long long)cpu->regs[10], (unsigned long long)cpu->regs[11]);
            printk("  x12=%llx x13=%llx x14=%llx x15=%llx\n", (unsigned long long)cpu->regs[12], (unsigned long long)cpu->regs[13], (unsigned long long)cpu->regs[14], (unsigned long long)cpu->regs[15]);
            printk("  x16=%llx x17=%llx x18=%llx x19=%llx\n", (unsigned long long)cpu->regs[16], (unsigned long long)cpu->regs[17], (unsigned long long)cpu->regs[18], (unsigned long long)cpu->regs[19]);
            printk("  x20=%llx x21=%llx x22=%llx x23=%llx\n", (unsigned long long)cpu->regs[20], (unsigned long long)cpu->regs[21], (unsigned long long)cpu->regs[22], (unsigned long long)cpu->regs[23]);
            printk("  x24=%llx x25=%llx x26=%llx x27=%llx\n", (unsigned long long)cpu->regs[24], (unsigned long long)cpu->regs[25], (unsigned long long)cpu->regs[26], (unsigned long long)cpu->regs[27]);
            printk("  x28=%llx x29=%llx x30=%llx sp=%llx\n", (unsigned long long)cpu->regs[28], (unsigned long long)cpu->regs[29], (unsigned long long)cpu->regs[30], (unsigned long long)cpu->sp);
#endif
            struct siginfo_ info = {
                .code = mem_segv_reason(current->mem, cpu->segfault_addr),
                .fault.addr = cpu->segfault_addr,
            };
            dump_stack(8);
            dump_maps();
            deliver_signal(current, SIGSEGV_, info);
        }
    } else if (interrupt == INT_UNDEFINED) {
#if defined(GUEST_X86) || !defined(GUEST_ARM64)
        printk("%d illegal instruction at 0x%x: ", current->pid, cpu->eip);
        for (int i = 0; i < 8; i++) {
            uint8_t b;
            if (user_get(cpu->eip + i, b))
                break;
            printk("%02x ", b);
        }
#elif defined(GUEST_ARM64)
        {
            uint32_t ill_insn = 0;
            for (int i = 0; i < 4; i++) {
                uint8_t b;
                if (user_get(cpu->pc + i, b))
                    break;
                ill_insn |= (uint32_t)b << (i * 8);
            }
            printk("%d illegal instruction at 0x%llx: insn=0x%08x\n", current->pid, (unsigned long long)cpu->pc, ill_insn);
        }
#endif
        printk("\n");
        dump_stack(8);
        struct siginfo_ info = {
            .code = SI_KERNEL_,
#if defined(GUEST_X86) || !defined(GUEST_ARM64)
            .fault.addr = cpu->eip,
#elif defined(GUEST_ARM64)
            .fault.addr = cpu->pc,
#endif
        };
        deliver_signal(current, SIGILL_, info);
    } else if (interrupt == INT_BREAKPOINT) {
        lock(&pids_lock);
        send_signal(current, SIGTRAP_, (struct siginfo_) {
            .sig = SIGTRAP_,
            .code = SI_KERNEL_,
        });
        unlock(&pids_lock);
    } else if (interrupt == INT_DEBUG) {
        lock(&pids_lock);
        send_signal(current, SIGTRAP_, (struct siginfo_) {
            .sig = SIGTRAP_,
            .code = TRAP_TRACE_,
        });
        unlock(&pids_lock);
    } else if (interrupt != INT_TIMER) {
        printk("%d unhandled interrupt %d\n", current->pid, interrupt);
        sys_exit(interrupt);
    }

    receive_signals();
    struct tgroup *group = current->group;
    lock(&group->lock);
    while (group->stopped)
        wait_for_ignore_signals(&group->stopped_cond, &group->lock, NULL);
    unlock(&group->lock);
}

void dump_maps(void) {
    extern void proc_maps_dump(struct task *task, struct proc_data *buf);
    struct proc_data buf = {};
    proc_maps_dump(current, &buf);
    // go a line at a time because it can be fucking enormous
    char *orig_data = buf.data;
    while (buf.size > 0) {
        size_t chunk_size = buf.size;
        if (chunk_size > 1024)
            chunk_size = 1024;
        printk("%.*s", chunk_size, buf.data);
        buf.data += chunk_size;
        buf.size -= chunk_size;
    }
    free(orig_data);
}

void dump_mem(addr_t start, uint_t len) {
    const int width = 8;
    for (addr_t addr = start; addr < start + len; addr += sizeof(dword_t)) {
        unsigned from_left = (addr - start) / sizeof(dword_t) % width;
        if (from_left == 0)
#ifdef GUEST_ARM64
            printk("%012llx: ", (unsigned long long)addr);
#else
            printk("%08x: ", addr);
#endif
        dword_t word;
        if (user_get(addr, word))
            break;
        printk("%08x ", word);
        if (from_left == width - 1)
            printk("\n");
    }
}

void dump_stack(int lines) {
#if defined(GUEST_X86) || !defined(GUEST_ARM64)
    printk("stack at %x, base at %x, ip at %x\n", current->cpu.esp, current->cpu.ebp, current->cpu.eip);
    dump_mem(current->cpu.esp, lines * sizeof(dword_t) * 8);
#elif defined(GUEST_ARM64)
    printk("stack at %llx, base at %llx, ip at %llx\n",
           (unsigned long long)current->cpu.sp,
           (unsigned long long)current->cpu.regs[29],  // x29 is frame pointer
           (unsigned long long)current->cpu.pc);
    dump_mem(current->cpu.sp, lines * sizeof(uint64_t) * 8);
#endif
}

// TODO find a home for this
#ifdef LOG_OVERRIDE
int log_override = 0;
#endif

// === Fast Path Implementations ===
#ifdef GUEST_ARM64

// Fast path for fstat64 (syscall 80)
// Bypasses generic_statat path normalization when fd is already validated realfs
static inline int fast_fstat64(struct cpu_state *cpu) {
    fd_t fd_no = (fd_t)cpu->regs[0];
    addr_t statbuf_addr = (addr_t)cpu->regs[1];

    // Quick validation: fd must be valid
    struct fd *fd = f_get(fd_no);
    if (fd == NULL)
        return -1;  // Fall back to slow path

    // Fast path condition: fd is realfs (not adhoc, not procfs, etc.)
    if (fd->ops != &realfs_fdops)
        return -1;  // Fall back to slow path

    // Direct host fstat call (bypass generic layers)
    struct stat real_stat;
    if (fstat(fd->real_fd, &real_stat) < 0)
        return errno_map();

    // Convert to guest statbuf
    struct statbuf fake_stat = {};
    fake_stat.dev = dev_fake_from_real(real_stat.st_dev);
    fake_stat.inode = real_stat.st_ino;
    fake_stat.mode = real_stat.st_mode;
    fake_stat.nlink = real_stat.st_nlink;
    fake_stat.uid = real_stat.st_uid;
    fake_stat.gid = real_stat.st_gid;
    fake_stat.rdev = dev_fake_from_real(real_stat.st_rdev);
    fake_stat.size = real_stat.st_size;
    fake_stat.blksize = real_stat.st_blksize;
    fake_stat.blocks = real_stat.st_blocks;
    fake_stat.atime = real_stat.st_atime;
    fake_stat.mtime = real_stat.st_mtime;
    fake_stat.ctime = real_stat.st_ctime;
#if __APPLE__
    fake_stat.atime_nsec = real_stat.st_atimespec.tv_nsec;
    fake_stat.mtime_nsec = real_stat.st_mtimespec.tv_nsec;
    fake_stat.ctime_nsec = real_stat.st_ctimespec.tv_nsec;
#elif __linux__
    fake_stat.atime_nsec = real_stat.st_atim.tv_nsec;
    fake_stat.mtime_nsec = real_stat.st_mtim.tv_nsec;
    fake_stat.ctime_nsec = real_stat.st_ctim.tv_nsec;
#endif

    // Convert to ARM64 stat structure
    struct stat_arm64 arm64stat = {};
    arm64stat.dev = fake_stat.dev;
    arm64stat.ino = fake_stat.inode;
    arm64stat.mode = fake_stat.mode;
    arm64stat.nlink = fake_stat.nlink;
    arm64stat.uid = fake_stat.uid;
    arm64stat.gid = fake_stat.gid;
    arm64stat.rdev = fake_stat.rdev;
    arm64stat.__pad1 = 0;
    arm64stat.size = fake_stat.size;
    arm64stat.blksize = fake_stat.blksize;
    arm64stat.__pad2 = 0;
    arm64stat.blocks = fake_stat.blocks;
    arm64stat.atime_ = fake_stat.atime;
    arm64stat.atime_nsec = fake_stat.atime_nsec;
    arm64stat.mtime_ = fake_stat.mtime;
    arm64stat.mtime_nsec = fake_stat.mtime_nsec;
    arm64stat.ctime_ = fake_stat.ctime;
    arm64stat.ctime_nsec = fake_stat.ctime_nsec;
    arm64stat.__unused4 = 0;
    arm64stat.__unused5 = 0;

    // Copy to user space
    if (user_put(statbuf_addr, arm64stat))
        return _EFAULT;

    return 0;  // Success
}

// Fast path for read (syscall 63) - small buffers only
static inline int fast_read(struct cpu_state *cpu) {
    fd_t fd_no = (fd_t)cpu->regs[0];
    addr_t buf_addr = (addr_t)cpu->regs[1];
    dword_t size = (dword_t)cpu->regs[2];

    // Fast path condition: small buffer (≤ 4KB) and realfs fd
    if (size > 4096)
        return -1;

    struct fd *fd = f_get(fd_no);
    if (fd == NULL || fd->ops != &realfs_fdops)
        return -1;

    // Direct host read (with EINTR retry)
    char buf[4096];
    ssize_t res;
    do {
        res = read(fd->real_fd, buf, size);
    } while (res < 0 && errno == EINTR);

    if (res < 0)
        return errno_map();

    // Copy to guest memory
    if (res > 0 && user_write(buf_addr, buf, res))
        return _EFAULT;

    return res;
}

// Fast path for write (syscall 64) - small buffers only
static inline int fast_write(struct cpu_state *cpu) {
    fd_t fd_no = (fd_t)cpu->regs[0];
    addr_t buf_addr = (addr_t)cpu->regs[1];
    dword_t size = (dword_t)cpu->regs[2];

    // Fast path condition: small buffer (≤ 4KB) and realfs fd
    if (size > 4096)
        return -1;

    struct fd *fd = f_get(fd_no);
    if (fd == NULL || fd->ops != &realfs_fdops)
        return -1;

    // Copy from guest memory
    char buf[4096];
    if (user_read(buf_addr, buf, size))
        return _EFAULT;

    // Direct host write (with EINTR retry)
    ssize_t res;
    do {
        res = write(fd->real_fd, buf, size);
    } while (res < 0 && errno == EINTR);

    if (res < 0)
        return errno_map();

    return res;
}

#endif // GUEST_ARM64
