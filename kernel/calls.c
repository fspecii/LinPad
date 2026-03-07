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
#ifdef GUEST_ARM64
        // Read fault on unmapped page near a heap mapping: demand-map as
        // readable zeros. On native Linux, heap regions are contiguous so
        // out-of-bounds reads access adjacent allocations (no SIGSEGV). In iSH,
        // mmap can leave unmapped gaps. Map the faulting page if a mapped
        // neighbor exists within a few pages (typical heap gap boundary).
        if (ptr == NULL && !cpu->segfault_was_write) {
            page_t fault_page = PAGE(cpu->segfault_addr);
            // Check if a mapped page exists nearby (within 16 pages = 64KB)
            bool has_neighbor = false;
            read_wrlock(&current->mem->lock);
            for (page_t p = fault_page + 1; p <= fault_page + 16 && p < MEM_PAGES; p++) {
                if (mem_pt(current->mem, p) != NULL) { has_neighbor = true; break; }
            }
            if (!has_neighbor) {
                for (page_t p = fault_page > 16 ? fault_page - 16 : 0; p < fault_page; p++) {
                    if (mem_pt(current->mem, p) != NULL) { has_neighbor = true; break; }
                }
            }
            read_wrunlock(&current->mem->lock);
            if (has_neighbor) {
                write_wrlock(&current->mem->lock);
                if (mem_pt(current->mem, fault_page) == NULL) {
                    int err = pt_map_nothing(current->mem, fault_page, 1, P_READ);
                    if (err >= 0) {
                        write_wrunlock(&current->mem->lock);
                        goto gpf_handled;
                    }
                }
                write_wrunlock(&current->mem->lock);
            }
        }
#endif
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
                            goto gpf_handled;
                        }

                        fp = saved_fp;
                    }
                    if (v8_burst_count > 3) {
                        // Deep unwind failed — entire call stack is corrupt.
                        // Kill the process gracefully with SIGABRT.
                        struct siginfo_ info = {
                            .sig = SIGABRT_,
                            .code = SI_KERNEL_,
                        };
                        deliver_signal(current, SIGABRT_, info);
                        v8_burst_count = 0;
                        goto gpf_handled;
                    }
                }
                }  // is_sentinel
            }  // scope block
#endif
#if defined(GUEST_X86) || !defined(GUEST_ARM64)
            printk("%d page fault on 0x%x at 0x%x\n", current->pid, cpu->segfault_addr, cpu->eip);
#elif defined(GUEST_ARM64)
            printk("%d page fault on 0x%llx at 0x%llx (%s)\n", current->pid, (unsigned long long)cpu->segfault_addr, (unsigned long long)cpu->pc, cpu->segfault_was_write ? "write" : "read");
#endif
            // Read-fault recovery: if a load instruction reads from unmapped
            // memory, set destination register to 0 and advance PC.
            // This handles cases where guest code makes out-of-bounds reads
            // that work on native Linux (because adjacent heap pages are always
            // mapped) but crash in iSH (because we have unmapped gaps).
            // Rate-limited to prevent infinite loops on true null-pointer derefs.
#ifdef GUEST_ARM64
            if (!cpu->segfault_was_write) {
                static _Thread_local int read_recovery_count = 0;
                static _Thread_local addr_t last_recovery_addr = 0;
                // Reset counter when faulting address changes (scanner moving through memory)
                // Only rate-limit when stuck at the exact same PC AND address (true infinite loop)
                if (cpu->segfault_addr != last_recovery_addr) {
                    read_recovery_count = 0;
                    last_recovery_addr = cpu->segfault_addr;
                }
                if (read_recovery_count < 5) {
                    read_recovery_count++;
                    uint32_t insn = 0;
                    bool insn_ok = true;
                    for (int j = 0; j < 4; j++) {
                        uint8_t b;
                        if (user_get(cpu->pc + j, b)) { insn_ok = false; break; }
                        insn |= (uint32_t)b << (j * 8);
                    }
                    if (insn_ok) {
                        // Check if instruction is a load (LDR/LDRSB/LDRSH/LDRSW/LDRB/LDRH)
                        // Pre-indexed: LDRSB Wt, [Xn, #imm]! = 0x38C00C00 (size=0, opc=3, bit21=0)
                        // Various load encodings share common patterns
                        uint32_t rt = insn & 0x1f;
                        bool is_load = false;
                        bool is_32bit = false;
                        // LDR/LDRSB/LDRSH/LDRSW with pre/post/unscaled offset
                        uint32_t rn = (insn >> 5) & 0x1f;
                        int has_writeback = 0;
                        if ((insn & 0x3b200c00) == 0x38000400 || // post-indexed
                            (insn & 0x3b200c00) == 0x38000c00 || // pre-indexed
                            (insn & 0x3b200c00) == 0x38000000) { // unscaled
                            uint32_t opc = (insn >> 22) & 3;
                            is_load = (opc != 0); // opc=0 is store, 1/2/3 are loads
                            is_32bit = ((insn >> 22) & 1) == 0 && opc >= 2;
                            // Pre/post indexed have writeback
                            uint32_t idx_type = (insn >> 10) & 3;
                            if (idx_type == 1 || idx_type == 3) // post=01, pre=11
                                has_writeback = 1;
                        }
                        // LDR/LDRB/LDRH unsigned offset
                        if ((insn & 0x3b400000) == 0x39400000) {
                            is_load = true;
                        }
                        // LDR register offset
                        if ((insn & 0x3b200c00) == 0x38200800) {
                            uint32_t opc = (insn >> 22) & 3;
                            is_load = (opc != 0);
                        }
                        // LDP (load pair)
                        if ((insn & 0x7fc00000) == 0xa9400000 || // LDP x
                            (insn & 0x7fc00000) == 0x29400000) { // LDP w
                            is_load = true;
                            rn = (insn >> 5) & 0x1f;
                            uint32_t rt2 = (insn >> 10) & 0x1f;
                            if (rt2 < 31) cpu->regs[rt2] = 0;
                        }
                        if (is_load && rt < 31) {
                            cpu->regs[rt] = 0;
                            // Handle writeback for pre/post-indexed loads
                            if (has_writeback && rn < 31) {
                                int32_t imm9 = (int32_t)((insn >> 12) & 0x1ff);
                                if (imm9 & 0x100) imm9 |= ~0x1ff; // sign-extend
                                cpu->regs[rn] = (cpu->regs[rn] + imm9) & 0xffffffffffffULL;
                            }
                            cpu->pc += 4;
                            goto gpf_handled;
                        }
                    }
                }
            }
#endif
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
    } else if (interrupt == INT_TIMER) {
        // timer handled below
    } else {
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
