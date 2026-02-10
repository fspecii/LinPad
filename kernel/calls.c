#include <string.h>
#include "debug.h"
#include "kernel/calls.h"
#include "emu/interrupt.h"
#include "kernel/memory.h"
#include "kernel/signal.h"
#include "kernel/task.h"

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
        if (syscall_num >= syscall_table_size || syscall_table[syscall_num] == NULL) {
            printk("%d(%s) missing syscall %d\n", current->pid, current->comm, syscall_num);
            cpu->regs[0] = (uint32_t)_ENOSYS;
        } else {
            if (syscall_table[syscall_num] == (syscall_t) syscall_stub) {
                printk("%d(%s) stub syscall %d\n", current->pid, current->comm, syscall_num);
            }
            STRACE("%d call %-3d ", current->pid, syscall_num);
            int result = syscall_table[syscall_num](
                cpu->regs[0], cpu->regs[1], cpu->regs[2],
                cpu->regs[3], cpu->regs[4], cpu->regs[5]);
            STRACE(" = 0x%x\n", result);
            // ARM64 ABI: error codes are -1 to -4095 (sign-extended), success is 0 or positive.
            // We need to check if result is in the error range (-1 to -4095).
            // Since we run a 32-bit address space, addresses like 0xf7ff2000 are valid
            // but would appear as "negative" if treated as int32_t.
            // Linux ARM64 syscall ABI: return value is in x0, errors are negative (-errno).
            // Valid error range: -1 to -4095 (MAX_ERRNO is typically 4095)
            int32_t signed_result = (int32_t)result;
            if (signed_result >= -4095 && signed_result < 0) {
                // Error code: sign-extend to 64-bit
                cpu->regs[0] = (uint64_t)(int64_t)signed_result;
            } else {
                // Success: zero-extend the 32-bit value
                cpu->regs[0] = (uint32_t)result;
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
            printk("%d page fault on 0x%llx at 0x%llx\n", current->pid, (unsigned long long)cpu->segfault_addr, (unsigned long long)cpu->pc);
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
            printk("%08x: ", addr);
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
