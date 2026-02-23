#define DEFAULT_CHANNEL instr
#include "debug.h"
#include <setjmp.h>
#include <signal.h>
#include <time.h>
#include "asbestos/asbestos.h"
#include "asbestos/gen.h"
#include "asbestos/frame.h"
#include "emu/cpu.h"
#include "emu/interrupt.h"
#include "emu/tlb.h"
#include "util/list.h"

// Thread-local recovery state for JIT crash handling.
// When a host SIGSEGV occurs inside JIT code (due to a stale TLB pointer
// from a concurrent CoW), the signal handler uses _longjmp to recover
// instead of crashing. The interrupt is converted to INT_GPF, which
// handle_interrupt resolves via mem_ptr (CoW/GROWSDOWN).
//
// We use _setjmp/_longjmp instead of sigsetjmp/siglongjmp to avoid calling
// sigprocmask (a syscall) on every JIT cycle. The crash handler manually
// unblocks SIGSEGV/SIGBUS before _longjmp.
__thread jmp_buf jit_recover_buf;
__thread volatile sig_atomic_t in_jit;
__thread volatile uintptr_t jit_crash_host_addr;  // host fault address from last JIT crash
__thread volatile uint64_t jit_crash_segfault_addr;  // reconstructed guest fault address
__thread volatile int jit_crash_segfault_was_write;   // read/write from ESR

// Architecture-specific instruction pointer access
#if defined(GUEST_ARM64)
#define CPU_IP(cpu) ((cpu)->pc)
#define CPU_HAS_SINGLE_STEP 0
#else
#define CPU_IP(cpu) ((cpu)->eip)
#define CPU_HAS_SINGLE_STEP ((cpu)->tf)
#endif

extern int current_pid(void);

static void fiber_block_disconnect(struct asbestos *asbestos, struct fiber_block *block);
static void fiber_block_free(struct asbestos *asbestos, struct fiber_block *block);
static void fiber_free_jetsam(struct asbestos *asbestos);
static void fiber_resize_hash(struct asbestos *asbestos, size_t new_size);

struct asbestos *asbestos_new(struct mmu *mmu) {
    struct asbestos *asbestos = calloc(1, sizeof(struct asbestos));
    asbestos->mmu = mmu;
    fiber_resize_hash(asbestos, FIBER_INITIAL_HASH_SIZE);
    asbestos->page_hash = calloc(FIBER_PAGE_HASH_SIZE, sizeof(*asbestos->page_hash));
    list_init(&asbestos->jetsam);
    lock_init(&asbestos->lock);
    wrlock_init(&asbestos->jetsam_lock);
    atomic_init(&asbestos->jit_active_threads, 0);
    atomic_init(&asbestos->jetsam_gen, 0);
    return asbestos;
}

void asbestos_free(struct asbestos *asbestos) {
    for (size_t i = 0; i < asbestos->hash_size; i++) {
        struct fiber_block *block, *tmp;
        if (list_null(&asbestos->hash[i]))
            continue;
        list_for_each_entry_safe(&asbestos->hash[i], block, tmp, chain) {
            fiber_block_free(asbestos, block);
        }
    }
    fiber_free_jetsam(asbestos);
    free(asbestos->page_hash);
    free(asbestos->hash);
    free(asbestos);
}

static inline struct list *blocks_list(struct asbestos *asbestos, page_t page, int i) {
    // TODO is this a good hash function?
    return &asbestos->page_hash[page % FIBER_PAGE_HASH_SIZE].blocks[i];
}

void asbestos_invalidate_range(struct asbestos *absestos, page_t start, page_t end) {
    lock(&absestos->lock);
    bool did_invalidate = false;
    struct fiber_block *block, *tmp;
    for (page_t page = start; page < end; page++) {
        for (int i = 0; i <= 1; i++) {
            struct list *blocks = blocks_list(absestos, page, i);
            if (list_null(blocks))
                continue;
            list_for_each_entry_safe(blocks, block, tmp, page[i]) {
                fiber_block_disconnect(absestos, block);
                block->is_jetsam = true;
                list_add(&absestos->jetsam, &block->jetsam);
                did_invalidate = true;
            }
        }
    }
    if (did_invalidate)
        absestos->invalidate_gen++;
    unlock(&absestos->lock);
}

void asbestos_invalidate_page(struct asbestos *asbestos, page_t page) {
    // Fast path: skip lock if no blocks exist on this page.
    // page_hash is only modified under asbestos->lock, and list_null is a
    // single pointer read, so a racy false-negative just means we take
    // the slow path unnecessarily (safe). A false-positive is impossible
    // because blocks are always added before being linked into page_hash.
    for (int i = 0; i <= 1; i++) {
        struct list *blocks = blocks_list(asbestos, page, i);
        if (!list_null(blocks))
            goto slow_path;
    }
    return;
slow_path:
    asbestos_invalidate_range(asbestos, page, page + 1);
}
void asbestos_invalidate_all(struct asbestos *asbestos) {
    lock(&asbestos->lock);
    bool did_invalidate = false;
    struct fiber_block *block, *tmp;
    for (size_t bucket = 0; bucket < FIBER_PAGE_HASH_SIZE; bucket++) {
        for (int i = 0; i <= 1; i++) {
            struct list *blocks = &asbestos->page_hash[bucket].blocks[i];
            if (list_null(blocks))
                continue;
            list_for_each_entry_safe(blocks, block, tmp, page[i]) {
                fiber_block_disconnect(asbestos, block);
                block->is_jetsam = true;
                list_add(&asbestos->jetsam, &block->jetsam);
                did_invalidate = true;
            }
        }
    }
    if (did_invalidate)
        asbestos->invalidate_gen++;
    unlock(&asbestos->lock);
}

static void fiber_resize_hash(struct asbestos *asbestos, size_t new_size) {
    TRACE_(verbose, "%d resizing hash to %lu, using %lu bytes for gadgets\n", current_pid(), new_size, asbestos->mem_used);
    struct list *new_hash = calloc(new_size, sizeof(struct list));
    for (size_t i = 0; i < asbestos->hash_size; i++) {
        if (list_null(&asbestos->hash[i]))
            continue;
        struct fiber_block *block, *tmp;
        list_for_each_entry_safe(&asbestos->hash[i], block, tmp, chain) {
            list_remove(&block->chain);
            list_init_add(&new_hash[block->addr % new_size], &block->chain);
        }
    }
    free(asbestos->hash);
    asbestos->hash = new_hash;
    asbestos->hash_size = new_size;
}

static void fiber_insert(struct asbestos *asbestos, struct fiber_block *block) {
    asbestos->mem_used += block->used;
    asbestos->num_blocks++;
    // target an average hash chain length of 1-2
    if (asbestos->num_blocks >= asbestos->hash_size * 2)
        fiber_resize_hash(asbestos, asbestos->hash_size * 2);

    list_init_add(&asbestos->hash[block->addr % asbestos->hash_size], &block->chain);
    list_init_add(blocks_list(asbestos, PAGE(block->addr), 0), &block->page[0]);
    if (PAGE(block->addr) != PAGE(block->end_addr))
        list_init_add(blocks_list(asbestos, PAGE(block->end_addr), 1), &block->page[1]);
}

static struct fiber_block *fiber_lookup(struct asbestos *asbestos, addr_t addr) {
    struct list *bucket = &asbestos->hash[addr % asbestos->hash_size];
    if (list_null(bucket))
        return NULL;
    struct fiber_block *block;
    list_for_each_entry(bucket, block, chain) {
        if (block->addr == addr)
            return block;
    }
    return NULL;
}

static struct fiber_block *fiber_block_compile(addr_t ip, struct tlb *tlb) {
    struct gen_state state;
    TRACE("%d %08x --- compiling:\n", current_pid(), ip);
    gen_start(ip, &state);
    while (true) {
        if (!gen_step(&state, tlb))
            break;
        // no block should span more than 2 pages
        // guarantee this by limiting total block size to 1 page
        // guarantee that by stopping as soon as there's less space left than
        // the maximum length of an x86 instruction
        // TODO refuse to decode instructions longer than 15 bytes
        if (state.ip - ip >= PAGE_SIZE - 15) {
            gen_exit(&state);
            break;
        }
    }
    gen_end(&state);
    assert(state.ip - ip <= PAGE_SIZE);
    state.block->used = state.capacity;
    return state.block;
}

// Remove all pointers to the block. It can't be freed yet because another
// thread may be executing it.
static void fiber_block_disconnect(struct asbestos *asbestos, struct fiber_block *block) {
    if (asbestos != NULL) {
        asbestos->mem_used -= block->used;
        asbestos->num_blocks--;
    }
    list_remove(&block->chain);
    for (int i = 0; i <= 1; i++) {
        list_remove_safe(&block->page[i]);
        list_remove_safe(&block->jumps_from_links[i]);

        struct fiber_block *prev_block, *tmp;
        list_for_each_entry_safe(&block->jumps_from[i], prev_block, tmp, jumps_from_links[i]) {
            if (prev_block->jump_ip[i] != NULL)
                *prev_block->jump_ip[i] = prev_block->old_jump_ip[i];
            list_remove(&prev_block->jumps_from_links[i]);
        }
    }
}

static void fiber_block_free(struct asbestos *asbestos, struct fiber_block *block) {
    fiber_block_disconnect(asbestos, block);
    free(block);
}

static void fiber_free_jetsam(struct asbestos *asbestos) {
    struct fiber_block *block, *tmp;
    list_for_each_entry_safe(&asbestos->jetsam, block, tmp, jetsam) {
        list_remove(&block->jetsam);
        free(block);
    }
}

int fiber_enter(struct fiber_block *block, struct fiber_frame *frame, struct tlb *tlb);

static inline size_t fiber_cache_hash(addr_t ip) {
    return (ip ^ (ip >> 12)) & (FIBER_CACHE_SIZE - 1);
}

static int cpu_step_to_interrupt(struct cpu_state *cpu, struct tlb *tlb) {
    struct asbestos *asbestos = cpu->mmu->asbestos;

    // Hold jetsam_lock read during JIT execution.
    // This prevents jetsam cleanup from freeing blocks while we're executing them.
    read_wrlock(&asbestos->jetsam_lock);

    // Use persistent block cache and frame from TLB; invalidate when blocks are jetsam'd
    bool caches_stale = (tlb->block_cache_gen != asbestos->invalidate_gen);
    struct fiber_block **cache = tlb->block_cache;
    if (caches_stale) {
        memset(cache, 0, sizeof(tlb->block_cache));
        tlb->block_cache_gen = asbestos->invalidate_gen;
    }

    // Use persistent frame from TLB (avoids malloc/free + ret_cache zeroing)
    struct fiber_frame *frame = tlb->frame;
    if (frame == NULL) {
        frame = calloc(1, sizeof(struct fiber_frame));
        tlb->frame = frame;
    } else if (caches_stale) {
        // ret_cache holds pointers into block->code; must clear on invalidation
        memset(frame->ret_cache, 0, sizeof(frame->ret_cache));
    }
    frame->last_block = NULL;
    frame->cpu = *cpu;
    assert(asbestos->mmu == cpu->mmu);

    int interrupt = INT_NONE;
    int crash_retry_count = 0;
    while (interrupt == INT_NONE) {
        // Check if blocks were invalidated since last check (e.g. CoW by another thread).
        // This must be inside the loop, not just at function entry, because invalidation
        // can happen while we're in the JIT cycle (between fiber_enter calls).
        if (tlb->block_cache_gen != asbestos->invalidate_gen) {
            memset(cache, 0, sizeof(tlb->block_cache));
            tlb->block_cache_gen = asbestos->invalidate_gen;
            memset(frame->ret_cache, 0, sizeof(frame->ret_cache));
        }

        addr_t ip = CPU_IP(&frame->cpu);
        size_t cache_index = fiber_cache_hash(ip);
        struct fiber_block *block = cache[cache_index];
        if (block == NULL || block->addr != ip) {
            lock(&asbestos->lock);
            block = fiber_lookup(asbestos, ip);
            if (block == NULL) {
                block = fiber_block_compile(ip, tlb);
                fiber_insert(asbestos, block);
            } else {
                TRACE("%d %08x --- missed cache\n", current_pid(), ip);
            }
            cache[cache_index] = block;
            unlock(&asbestos->lock);
        }
        struct fiber_block *last_block = frame->last_block;
        if (last_block != NULL &&
                !last_block->is_jetsam && !block->is_jetsam &&
                (last_block->jump_ip[0] != NULL ||
                 last_block->jump_ip[1] != NULL)) {
            if (trylock(&asbestos->lock) == 0) {
                // can't mint new pointers to a block that has been marked jetsam
                // and is thus assumed to have no pointers left
                if (!last_block->is_jetsam && !block->is_jetsam) {
                    for (int i = 0; i <= 1; i++) {
                        if (last_block->jump_ip[i] != NULL &&
                                (*last_block->jump_ip[i] & 0xffffffff) == block->addr) {
                            *last_block->jump_ip[i] = (unsigned long) block->code;
                            list_add(&block->jumps_from[i], &last_block->jumps_from_links[i]);
                        }
                    }
                }
                unlock(&asbestos->lock);
            }
        }
        frame->last_block = block;

        // block may be jetsam, but that's ok, because it can't be freed until
        // every thread on this asbestos is not executing anything

        TRACE("%d %08x --- cycle %ld\n", current_pid(), ip, frame->cpu.cycle);

        // Save guest CPU state before entering JIT.
        // If a host SIGSEGV occurs mid-block, the crash leaves guest regs
        // in an inconsistent state (partially-executed gadgets). We restore
        // this snapshot so the retry starts with a clean state.
        struct cpu_state saved_cpu = frame->cpu;

        in_jit = 1;
        if (_setjmp(jit_recover_buf) == 0) {
            interrupt = fiber_enter(block, frame, tlb);
            crash_retry_count = 0;  // successful execution resets retry counter
        } else {
            // Recovered from host SIGSEGV inside JIT code.
            // Restore guest CPU state to the snapshot taken before fiber_enter.
            // This ensures guest registers are consistent for the retry.
            frame->cpu = saved_cpu;

            // Apply crash recovery info AFTER restore (crash_handler stored
            // these in thread-locals because saved_cpu restore overwrites cpu).
            frame->cpu.segfault_addr = jit_crash_segfault_addr;
            frame->cpu.segfault_was_write = jit_crash_segfault_was_write;

            // Flush all caches to get fresh host pointers.
            tlb_flush(tlb);
            memset(cache, 0, sizeof(tlb->block_cache));
            tlb->block_cache_gen = asbestos->invalidate_gen;
            memset(frame->ret_cache, 0, sizeof(frame->ret_cache));
            frame->last_block = NULL;

            crash_retry_count++;
            if (crash_retry_count >= 16) {
                // Too many consecutive crashes — escalate to INT_GPF
                interrupt = INT_GPF;
                crash_retry_count = 0;
            } else {
                interrupt = INT_NONE;
            }
        }
        in_jit = 0;
        if (interrupt == INT_NONE && __atomic_exchange_n(frame->cpu.poked_ptr, false, __ATOMIC_ACQUIRE))
            interrupt = INT_TIMER;
        if (interrupt == INT_NONE && (++frame->cpu.cycle & ((1 << 10) - 1)) == 0)
            interrupt = INT_TIMER;
    }
    *cpu = frame->cpu;

    // Release jetsam_lock read. Jetsam cleanup can now proceed.
    read_wrunlock(&asbestos->jetsam_lock);

    return interrupt;
}

static int cpu_single_step(struct cpu_state *cpu, struct tlb *tlb) {
    struct gen_state state;
    gen_start(CPU_IP(cpu), &state);
    gen_step(&state, tlb);
    gen_exit(&state);
    gen_end(&state);

    struct fiber_block *block = state.block;
    struct fiber_frame frame = {.cpu = *cpu};
    int interrupt = fiber_enter(block, &frame, tlb);
    *cpu = frame.cpu;
    fiber_block_free(NULL, block);
    if (interrupt == INT_NONE)
        interrupt = INT_DEBUG;
    return interrupt;
}

int cpu_run_to_interrupt(struct cpu_state *cpu, struct tlb *tlb) {
    if (cpu->poked_ptr == NULL)
        cpu->poked_ptr = &cpu->_poked;
#ifdef GUEST_ARM64
    // Invalidate exclusive monitor on every entry to JIT.
    // Any interrupt/exception/context switch clears the exclusive state,
    // ensuring STXR will fail if the monitor was set in a previous run.
    cpu->excl_addr = UINT64_MAX;
#endif
    struct asbestos *asbestos = cpu->mmu->asbestos;
    __atomic_add_fetch(&asbestos->active_threads, 1, __ATOMIC_RELAXED);
    tlb_refresh(tlb, cpu->mmu);
    int interrupt = (CPU_HAS_SINGLE_STEP ? cpu_single_step : cpu_step_to_interrupt)(cpu, tlb);
    cpu->trapno = interrupt;
    __atomic_sub_fetch(&asbestos->active_threads, 1, __ATOMIC_RELAXED);

    lock(&asbestos->lock);
    if (!list_empty(&asbestos->jetsam)) {
        unlock(&asbestos->lock);

        // Write lock ensures all JIT threads have exited (they hold read lock).
        // This is watertight — no TOCTOU race possible.
        write_wrlock(&asbestos->jetsam_lock);
        lock(&asbestos->lock);
        fiber_free_jetsam(asbestos);
        unlock(&asbestos->lock);
        write_wrunlock(&asbestos->jetsam_lock);
    } else {
        unlock(&asbestos->lock);
    }

    return interrupt;
}

void cpu_poke(struct cpu_state *cpu) {
    __atomic_store_n(cpu->poked_ptr, true, __ATOMIC_SEQ_CST);
}
