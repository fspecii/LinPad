#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>
#include <time.h>
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
        if (current->group->doing_group_exit)
            do_exit(current->group->group_exit_code);
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
                // sigreturn/rt_sigreturn restore the full CPU state from the
                // signal frame. Do NOT touch regs[0] — it was already restored
                // by restore_sigcontext. Any post-processing could corrupt the
                // restored x0 value (e.g., errno sign-extension).
                if (syscall_num == 139 /* rt_sigreturn */ ||
                    syscall_num == 119 /* sigreturn */) {
                    // x0 already set by restore_sigcontext, skip writeback
                } else {
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
        }
        // Update deadlock detection state.
        atomic_fetch_add(&current->group->syscall_count, 1);
        // Update last_unblocked_ns for non-blocking syscalls only.
        // Blocking calls (futex, epoll, ppoll, waitid, nanosleep) that
        // return and retry should NOT refresh the timestamp, as they
        // don't represent real forward progress.
        if (syscall_num != 22 && syscall_num != 73 && syscall_num != 95 &&
            syscall_num != 98 && syscall_num != 101) {
            struct timespec _ts;
            clock_gettime(CLOCK_MONOTONIC, &_ts);
            uint64_t now = (uint64_t)_ts.tv_sec * 1000000000ULL + _ts.tv_nsec;
            current->last_unblocked_ns = now;
            atomic_store_explicit(&current->group->last_progress_ns, now,
                                  memory_order_relaxed);
        }
        // Check for pending group exit. When do_exit_group sends SIGKILL to
        // all threads, a thread stuck in a retrying syscall (e.g., musl's
        // futex_wait loops on EINTR) would never return to the JIT dispatch
        // loop where receive_signals() handles SIGKILL. Catch it here.
        if (current->group->doing_group_exit) {
            do_exit(current->group->group_exit_code);
        }
#endif
    } else if (interrupt == INT_GPF) {
        // some page faults, such as stack growing or CoW clones, are handled by mem_ptr
        read_wrlock(&current->mem->lock);
        void *ptr = mem_ptr(current->mem, cpu->segfault_addr, cpu->segfault_was_write ? MEM_WRITE : MEM_READ);
        read_wrunlock(&current->mem->lock);
        if (ptr == NULL) {
#ifdef GUEST_ARM64
            // V8 Zone memory reuse workaround: V8's Zone bump allocator reuses
            // memory without zeroing. A DeclarationScope can be allocated over
            // stale Variable data, inheriting -1 sentinel values in uninitialized
            // fields (offsets 0xB0-0xD0). When AllocateVariablesRecursively reads
            // scope+0xD0 and dereferences -1, we crash here.
            //
            // Pattern: LDR Xd, [Xn, #imm] faults on addr=0xFFFF...  (sentinel -1)
            //          followed by CBZ Xd, <target>  (V8's own null check)
            // Recovery: set Xd=0 and advance PC by 4. The CBZ takes the null branch.
            // Detect clearly-unmapped addresses that indicate dereferencing a
            // corrupt/sentinel pointer. In our memory layout, valid pages are in
            // the range 0x0-0xefffd000 (mmap) and 0xffff1000-0xfffff000 (stack).
            // Anything above 0xf0000000 that's not stack, or anything in the
            // 48-bit upper range, is a sentinel pointer dereference.
            {
                // Rate-limit V8 zone fix recoveries to prevent cascading
                static _Thread_local int v8_zone_fix_count = 0;
                static _Thread_local int v8_burst_count = 0;    // consecutive recoveries
                static _Thread_local uint64_t v8_last_recovery_pc = 0;
                (void)0;

                // Detect faults on corrupt/sentinel pointers.
                // mem_ptr already returned NULL, so the address is truly unmapped.
                // We catch these cases:
                // 1. NULL page (addr < 0x1000): null pointer + small offset
                // 2. Above 4GB: clearly garbage 48/64-bit address
                // 3. Gap between mmap top and stack (0xf0000000..0xffff0000)
                // 4. Any unmapped address when PC is within the node binary text
                //    segment — V8 scope corruption causes derefs of stale pointers
                //    to freed/reused Zone memory at arbitrary addresses
                bool is_sentinel = (cpu->segfault_addr >= 0x100000000ULL) ||
                    (cpu->segfault_addr >= 0xf0000000ULL &&
                     cpu->segfault_addr < 0xffff0000ULL) ||
                    (cpu->segfault_addr < 0x1000);
                // Also treat as sentinel if PC is within node binary text and the
                // fault address is in an area that shouldn't hold valid V8 objects.
                // V8 heap is typically above 0xc0000000 in our layout; anything
                // below that is likely a stale/corrupt pointer.
                if (!is_sentinel && cpu->segfault_addr < 0xc0000000) {
                    // Check if PC looks like it's in a mapped code segment
                    // (node binary or shared libs: 0xec000000..0xf0000000)
                    if (cpu->pc >= 0xec000000 && cpu->pc < 0xf0000000)
                        is_sentinel = true;
                }
                // Only recover from V8 scope-walking crashes, not general
                // pointer corruptions. The scope-walking code is in a narrow
                // PC range. For other crashes, let the signal handler deal.
                // Check if we're in V8 scope/module code, or if the caller (LR)
                // is in that range (e.g., V8 code called memset/memcpy in musl
                // with a corrupt argument). Also check a few FP chain frames.
                bool is_scope_pc = false;
                {
                    // Direct PC ranges
                    uint64_t check_pcs[] = { cpu->pc, cpu->regs[30] };
                    for (int ci = 0; ci < 2; ci++) {
                        uint64_t pc = check_pcs[ci];
                        if ((pc >= 0xee270000 && pc < 0xee290000) ||
                            (pc >= 0xee810000 && pc < 0xee830000) ||
                            (pc >= 0xee7e0000 && pc < 0xee830000)) {
                            is_scope_pc = true;
                            break;
                        }
                    }
                    // Also check first few FP chain entries
                    if (!is_scope_pc) {
                        uint64_t fp = cpu->regs[29];
                        for (int ci = 0; ci < 3 && !is_scope_pc; ci++) {
                            uint64_t sfp = 0, slr = 0;
                            bool ok = true;
                            for (int j = 0; j < 8; j++) {
                                uint8_t b;
                                if (user_get(fp + j, b)) { ok = false; break; }
                                sfp |= (uint64_t)b << (j * 8);
                            }
                            if (ok) for (int j = 0; j < 8; j++) {
                                uint8_t b;
                                if (user_get(fp + 8 + j, b)) { ok = false; break; }
                                slr |= (uint64_t)b << (j * 8);
                            }
                            if (!ok || slr < 0xed000000 || slr >= 0xf0000000) break;
                            if ((slr >= 0xee270000 && slr < 0xee290000) ||
                                (slr >= 0xee7e0000 && slr < 0xee830000)) {
                                is_scope_pc = true;
                            }
                            fp = sfp;
                        }
                    }
                }
                if (is_sentinel && is_scope_pc && v8_zone_fix_count < 500) {
                v8_burst_count++;
                // Read faulting instruction
                uint32_t fault_insn = 0;
                bool insn_ok = true;
                for (int j = 0; j < 4; j++) {
                    uint8_t b;
                    if (user_get(cpu->pc + j, b)) { insn_ok = false; break; }
                    fault_insn |= (uint32_t)b << (j * 8);
                }
                // Deep frame unwind: skip ALL V8 scope/module-loader/musl frames.
                // V8 Zone corruption poisons entire call subtrees — returning to
                // intermediate frames just triggers cascade crashes. Skip the
                // ENTIRE subtree to reach a safe return point.
                {
                    uint64_t fp = cpu->regs[29];
                    uint64_t saved_fp = 0, saved_lr = 0;
                    int frames_unwound = 0;
                    const int max_unwind = 50;
                    while (frames_unwound < max_unwind) {
                        saved_fp = 0;
                        saved_lr = 0;
                        bool fp_ok = true;
                        for (int j = 0; j < 8; j++) {
                            uint8_t b;
                            if (user_get(fp + j, b)) { fp_ok = false; break; }
                            saved_fp |= (uint64_t)b << (j * 8);
                        }
                        if (fp_ok) for (int j = 0; j < 8; j++) {
                            uint8_t b;
                            if (user_get(fp + 8 + j, b)) { fp_ok = false; break; }
                            saved_lr |= (uint64_t)b << (j * 8);
                        }
                        if (!fp_ok || saved_lr < 0xed000000 || saved_lr >= 0xf0000000)
                            break;
                        // FP must be on the stack
                        if (!(saved_fp >= 0xffff0000 && saved_fp < 0xfffff000))
                            break;

                        frames_unwound++;

                        // Normally skip only V8 scope-walking frames.
                        // After 8+ consecutive recoveries (burst mode), also skip
                        // module loader frames to escape the corrupt subtree.
                        bool is_scope =
                            (saved_lr >= 0xee270000 && saved_lr < 0xee290000) ||
                            (saved_lr >= 0xed11a000 && saved_lr < 0xed1dd000);
                        if (v8_burst_count > 3) {
                            // Deep unwind: skip entire node binary text segment
                            is_scope = is_scope ||
                                (saved_lr >= 0xed1dd000 && saved_lr < 0xeff08000);
                        }

                        if (!is_scope) {
                            // Restore callee-saved registers from the target frame.
                            // Scan backward from saved_lr for STP patterns.
                            // Support both:
                            // 1. SUB SP,SP,#N; STP x29,x30,[SP,#off]; STP x19,x20,[SP,#off]
                            // 2. STP x29,x30,[SP,#-N]! (pre-indexed, combines alloc+store)
                            {
                                int64_t x19_off = -1, x21_off = -1, fp_off = -1;
                                uint64_t sp_sub = 0;
                                bool found_preindex_fp = false;

                                for (int scan = 1; scan <= 128; scan++) {
                                    uint32_t pi = 0;
                                    bool pi_ok = true;
                                    for (int j = 0; j < 4; j++) {
                                        uint8_t b;
                                        if (user_get(saved_lr - scan * 4 + j, b)) { pi_ok = false; break; }
                                        pi |= (uint32_t)b << (j * 8);
                                    }
                                    if (!pi_ok) break;

                                    // SUB SP, SP, #imm (sf=1, op=1, S=0, shift=00)
                                    if ((pi & 0xFF0003FF) == 0xD10003FF) {
                                        sp_sub = (pi >> 10) & 0xFFF;
                                        break;
                                    }
                                    // STP x29,x30,[SP,#-N]! (pre-indexed: opc=10 V=0 type=011 L=0)
                                    // 10 101 0 011 0 imm7 11110 11111 11101
                                    // Mask: bits[31:22]=1010100110, Rt2=x30(11110), Rn=SP(11111), Rt=x29(11101)
                                    if ((pi & 0xFFC07FFF) == 0xA9807BFD) {
                                        int imm7 = (pi >> 15) & 0x7F;
                                        if (imm7 & 0x40) imm7 -= 128;
                                        sp_sub = (uint64_t)(-imm7 * 8);
                                        fp_off = 0; // FP is at SP after pre-index
                                        found_preindex_fp = true;
                                        break;
                                    }
                                    // STP x19, x20, [SP, #offset] (signed offset)
                                    if ((pi & 0xFFC003FF) == 0xA90003F3 && ((pi >> 10) & 0x1F) == 20) {
                                        int imm7 = (pi >> 15) & 0x7F;
                                        if (imm7 & 0x40) imm7 -= 128;
                                        x19_off = imm7 * 8;
                                    }
                                    // STP x21, x22, [SP, #offset]
                                    if ((pi & 0xFFC003FF) == 0xA90003F5 && ((pi >> 10) & 0x1F) == 22) {
                                        int imm7 = (pi >> 15) & 0x7F;
                                        if (imm7 & 0x40) imm7 -= 128;
                                        x21_off = imm7 * 8;
                                    }
                                    // STP x29, x30, [SP, #offset] (signed offset, non-preindex)
                                    if (!found_preindex_fp &&
                                        (pi & 0xFFC003FF) == 0xA90003FD && ((pi >> 10) & 0x1F) == 30) {
                                        int imm7 = (pi >> 15) & 0x7F;
                                        if (imm7 & 0x40) imm7 -= 128;
                                        fp_off = imm7 * 8;
                                    }
                                }

                                // Compute the target frame's SP
                                if (sp_sub > 0 && fp_off >= 0) {
                                    uint64_t func_sp = saved_fp - fp_off;
                                    if (x19_off >= 0) {
                                        uint64_t v19 = 0, v20 = 0;
                                        for (int j = 0; j < 8; j++) {
                                            uint8_t b;
                                            if (user_get(func_sp + x19_off + j, b) == 0)
                                                v19 |= (uint64_t)b << (j*8);
                                            if (user_get(func_sp + x19_off + 8 + j, b) == 0)
                                                v20 |= (uint64_t)b << (j*8);
                                        }
                                        cpu->regs[19] = v19;
                                        cpu->regs[20] = v20;
                                    }
                                    if (x21_off >= 0) {
                                        uint64_t v21 = 0, v22 = 0;
                                        for (int j = 0; j < 8; j++) {
                                            uint8_t b;
                                            if (user_get(func_sp + x21_off + j, b) == 0)
                                                v21 |= (uint64_t)b << (j*8);
                                            if (user_get(func_sp + x21_off + 8 + j, b) == 0)
                                                v22 |= (uint64_t)b << (j*8);
                                        }
                                        cpu->regs[21] = v21;
                                        cpu->regs[22] = v22;
                                    }
                                    // Set SP = func_sp (post-prologue SP of the target frame)
                                    cpu->sp = func_sp;
                                } else {
                                    cpu->sp = saved_fp; // fallback
                                }
                            }
                            cpu->regs[29] = saved_fp;
                            cpu->regs[30] = saved_lr;
                            cpu->pc = saved_lr;
                            cpu->regs[0] = 0;
                            v8_zone_fix_count++;
                            if (frames_unwound > 3)
                                v8_burst_count = 0; // deep unwind succeeded
                            if (v8_zone_fix_count <= 3 || frames_unwound > 3)
                                printk("V8 GPF recovery #%d: unwound %d frames to pc=0x%llx\n",
                                    v8_zone_fix_count, frames_unwound,
                                    (unsigned long long)cpu->pc);
                            goto gpf_handled;
                        }

                        fp = saved_fp;
                    }
                    if (v8_burst_count > 3) {
                        // Deep unwind failed — entire call stack is corrupt.
                        // Kill the process gracefully with SIGABRT.
                        printk("GPF DEEP UNWIND FAILED: frames=%d, sending SIGABRT\n", frames_unwound);
                        struct siginfo_ info = {
                            .sig = SIGABRT_,
                            .code = SI_KERNEL_,
                        };
                        deliver_signal(current, SIGABRT_, info);
                        v8_burst_count = 0;
                        goto gpf_handled;
                    }
                    printk("GPF UNWIND FAILED: frames=%d fp=0x%llx\n",
                        frames_unwound, (unsigned long long)cpu->regs[29]);
                }
                }  // is_sentinel
            }  // scope block
#endif
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
            // Unwind guest stack frames (FP chain)
            {
                addr_t fp = cpu->regs[29]; // x29 = frame pointer
                addr_t lr = cpu->regs[30]; // x30 = link register (return addr)
                printk("  Stack unwind (FP chain):\n");
                printk("    frame 0: LR=0x%llx (file+0x%llx)\n",
                       (unsigned long long)lr, (unsigned long long)(lr - 0xed1dd000));
                for (int frame = 1; frame < 30 && fp != 0 && fp < 0xfffff000; frame++) {
                    uint64_t saved_fp = 0, saved_lr = 0;
                    bool ok = true;
                    for (int j = 0; j < 8; j++) {
                        uint8_t b;
                        if (user_get(fp + j, b)) { ok = false; break; }
                        saved_fp |= (uint64_t)b << (j * 8);
                    }
                    for (int j = 0; j < 8; j++) {
                        uint8_t b;
                        if (user_get(fp + 8 + j, b)) { ok = false; break; }
                        saved_lr |= (uint64_t)b << (j * 8);
                    }
                    if (!ok || saved_lr == 0) break;
                    printk("    frame %d: LR=0x%llx (file+0x%llx) FP=0x%llx\n",
                           frame, (unsigned long long)saved_lr,
                           (unsigned long long)(saved_lr - 0xed1dd000),
                           (unsigned long long)saved_fp);
                    fp = saved_fp;
                }
            }
            // Dump the source of the corrupt pointer
            {
                addr_t src_addr = cpu->regs[21]; // x21 = source object (scope)
                printk("  Source obj at x21=0x%llx:\n", (unsigned long long)src_addr);
                // Dump 0x120 bytes to see past scope end into next allocation
                for (int off = 0; off <= 0x120; off += 8) {
                    uint64_t val = 0;
                    bool ok = true;
                    for (int j = 0; j < 8; j++) {
                        uint8_t b;
                        if (user_get(src_addr + off + j, b)) { ok = false; break; }
                        val |= (uint64_t)b << (j * 8);
                    }
                    const char *note = "";
                    if (off == 0x78) note = " <-- flags_";
                    else if (off == 0xb0) note = " <-- scope+0xB0 (Variable?)";
                    else if (off == 0xb8) note = " <-- scope+0xB8";
                    else if (off == 0xd0) note = " <-- scope+0xD0 (x19 source)";
                    if (ok) printk("    [+0x%02x] 0x%llx%s\n", off, (unsigned long long)val, note);
                }
                // Also check flags bit 16 explicitly
                uint64_t flags = 0;
                bool flags_ok = true;
                for (int j = 0; j < 8; j++) {
                    uint8_t b;
                    if (user_get(src_addr + 120 + j, b)) { flags_ok = false; break; }
                    flags |= (uint64_t)b << (j * 8);
                }
                if (flags_ok) {
                    printk("  flags=0x%llx bit16=%d (is_declaration_scope)\n",
                           (unsigned long long)flags, (int)((flags >> 16) & 1));
                }
            }
            // Dump PC trace (last N blocks before crash)
            {
                extern __thread addr_t g_pc_trace[];
                extern __thread int g_pc_trace_idx;
                #define PC_TRACE_SIZE 256
                int start = g_pc_trace_idx > 32 ? g_pc_trace_idx - 32 : 0;
                printk("  PC trace (last %d blocks):\n", g_pc_trace_idx - start);
                for (int i = start; i < g_pc_trace_idx; i++) {
                    addr_t trace_pc = g_pc_trace[i & (PC_TRACE_SIZE - 1)];
                    printk("    [%d] 0x%llx\n", i - start, (unsigned long long)trace_pc);
                }
            }
            // Decode instructions at last 5 blocks and at caller
            {
                extern __thread addr_t g_pc_trace[];
                extern __thread int g_pc_trace_idx;
                int start2 = g_pc_trace_idx > 8 ? g_pc_trace_idx - 8 : 0;
                for (int bi = start2; bi < g_pc_trace_idx; bi++) {
                    addr_t bpc = g_pc_trace[bi & (PC_TRACE_SIZE - 1)];
                    printk("  Block[%d] at 0x%llx:\n", bi - start2, (unsigned long long)bpc);
                    for (int i = 0; i < 12; i++) {
                        uint32_t block_insn = 0;
                        bool ok = true;
                        for (int j = 0; j < 4; j++) {
                            uint8_t b;
                            if (user_get(bpc + i*4 + j, b)) { ok = false; break; }
                            block_insn |= (uint32_t)b << (j*8);
                        }
                        if (ok) printk("    %llx: %08x\n", (unsigned long long)(bpc + i*4), block_insn);
                        else break;
                    }
                }
            }
            // Decode instructions at caller
            printk("  Caller code at x30=0x%llx:\n", (unsigned long long)cpu->regs[30]);
            for (int i = -6; i <= 2; i++) {
                uint32_t caller_insn = 0;
                bool ok = true;
                for (int j = 0; j < 4; j++) {
                    uint8_t b;
                    if (user_get(cpu->regs[30] + i*4 + j, b)) { ok = false; break; }
                    caller_insn |= (uint32_t)b << (j*8);
                }
                if (ok) printk("    [lr%+d] %08x %s\n", i*4, caller_insn, i==0 ? "<-- return" : "");
            }
            struct siginfo_ info = {
                .code = mem_segv_reason(current->mem, cpu->segfault_addr),
                .fault.addr = cpu->segfault_addr,
            };
            dump_stack(8);
            dump_maps();
            deliver_signal(current, SIGSEGV_, info);
        }
#ifdef GUEST_ARM64
        gpf_handled:;
#endif
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
#ifdef GUEST_ARM64
        {
            uint32_t brk_insn = 0;
            for (int j = 0; j < 4; j++) {
                uint8_t b;
                if (user_get(cpu->pc + j, b)) break;
                brk_insn |= (uint32_t)b << (j * 8);
            }
            uint16_t brk_imm = (brk_insn >> 5) & 0xFFFF;

            // BRK #0xBC handler: V8 derived constructor new.target fix
            // (binary trampoline at code cave handles this now — no BRK needed)
        }
#endif
        fprintf(stderr, "BRK_HIT: pc=0x%llx lr=0x%llx sp=0x%llx\n",
                (unsigned long long)cpu->pc,
                (unsigned long long)cpu->regs[30],
                (unsigned long long)cpu->sp);
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
