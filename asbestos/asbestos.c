#define DEFAULT_CHANNEL instr
#include "debug.h"
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <time.h>
#include "asbestos/asbestos.h"
#include "asbestos/gen.h"
#include "asbestos/frame.h"
#include "emu/cpu.h"
#include "emu/interrupt.h"
#include "emu/tlb.h"
#include "kernel/memory.h"
#include "util/list.h"
#include "util/signpost.h"
#ifdef ISH_JIT
#include "jit/jit.h"
#endif

// Thread-local recovery state for JIT crash handling.
// When a host SIGSEGV occurs inside JIT code (due to a stale TLB pointer
// from a concurrent CoW), the signal handler redirects PC to
// jit_crash_trampoline via ucontext, which returns INT_GPF to the
// dispatch loop. handle_interrupt resolves via mem_ptr (CoW/GROWSDOWN).
//
// This avoids the overhead of _setjmp on every block entry (~1.5% of
// total execution time). The signal handler writes crash info directly
// to cpu_state via the _cpu pointer (x1) from ucontext.
__thread volatile sig_atomic_t in_jit;
_Atomic uint64_t s_dispatch_iterations = 0;
__thread volatile addr_t jit_saved_pc;  // block start PC, read by signal handler

// PC dispatch trace: capture first N consecutive guest PCs hitting the
// dispatch loop. Used for V8-realistic micro-bench harness. Set
// ISH_PC_TRACE_FILE=/path to enable; trace is filtered to a hot range
// for size, written at exit.
#define PC_TRACE_MAX 4096
static uint64_t g_pc_trace[PC_TRACE_MAX];
static _Atomic int g_pc_trace_n;
static int g_pc_trace_enabled = -1;
static uint64_t g_pc_trace_lo, g_pc_trace_hi;

static inline void pc_trace_record(uint64_t pc) {
    if (g_pc_trace_enabled == -1) {
        const char *path = getenv("ISH_PC_TRACE_FILE");
        g_pc_trace_enabled = path ? 1 : 0;
        const char *r = getenv("ISH_PC_TRACE_RANGE");
        if (r) {
            unsigned long long lo, hi;
            if (sscanf(r, "%llx-%llx", &lo, &hi) == 2) {
                g_pc_trace_lo = lo; g_pc_trace_hi = hi;
            }
        }
        if (g_pc_trace_lo == 0) {
            g_pc_trace_lo = 0xee900000ULL;
            g_pc_trace_hi = 0xee940000ULL;
        }
    }
    if (g_pc_trace_enabled <= 0) return;
    if (pc < g_pc_trace_lo || pc >= g_pc_trace_hi) return;
    int n = atomic_fetch_add_explicit(&g_pc_trace_n, 1, memory_order_relaxed);
    if (n < PC_TRACE_MAX) g_pc_trace[n] = pc;
}

void dump_pc_trace(void) {
    if (g_pc_trace_enabled <= 0) return;
    const char *path = getenv("ISH_PC_TRACE_FILE");
    if (!path) return;
    FILE *f = fopen(path, "w");
    if (!f) return;
    int n = atomic_load_explicit(&g_pc_trace_n, memory_order_relaxed);
    if (n > PC_TRACE_MAX) n = PC_TRACE_MAX;
    for (int i = 0; i < n; i++) fprintf(f, "0x%llx\n", (unsigned long long)g_pc_trace[i]);
    fclose(f);
    fprintf(stderr, "[pc_trace] wrote %d PCs to %s\n", n, path);
}

// PC histogram for trace-JIT feasibility study.
// Sampled at every INT_TIMER tick (every 1024 blocks). 1MB buckets covering
// low 4GB. Set ISH_PC_HIST=1 to enable. Dump via dump_pc_hist() at exit.
#define PC_HIST_BUCKETS 65536  // 64KB each, low 4GB
#define PC_HIST_SHIFT   16
static _Atomic uint64_t pc_hist[PC_HIST_BUCKETS];
static int pc_hist_enabled = -1;
static inline int pc_hist_on(void) {
    if (pc_hist_enabled == -1) {
        const char *e = getenv("ISH_PC_HIST");
        pc_hist_enabled = (e && e[0] == '1') ? 1 : 0;
    }
    return pc_hist_enabled;
}
void dump_pc_hist(void) {
    if (!pc_hist_on()) return;
    uint64_t total = 0;
    for (int i = 0; i < PC_HIST_BUCKETS; i++) total += pc_hist[i];
    if (total == 0) return;
    fprintf(stderr, "=== PC histogram (insn-weighted, dispatched blocks, total=%llu) ===\n",
            (unsigned long long)total);
    for (int i = 0; i < PC_HIST_BUCKETS; i++) {
        uint64_t c = pc_hist[i];
        if (c == 0) continue;
        double pct = 100.0 * (double)c / (double)total;
        if (pct < 0.1) continue;
        fprintf(stderr, "  0x%08x-0x%08x  %8llu  %6.2f%%\n",
                i << PC_HIST_SHIFT, ((i + 1) << PC_HIST_SHIFT) - 1,
                (unsigned long long)c, pct);
    }
    fflush(stderr);
}
// Marker set to 1 on iSH execution threads so the signal handler can distinguish
// iSH threads from app threads (Swift async, networking, UI).
__thread int ish_thread_marker;

// Architecture-specific instruction pointer access
#if defined(GUEST_ARM64)
#define CPU_IP(cpu) ((cpu)->pc)
#define CPU_HAS_SINGLE_STEP 0
#else
#define CPU_IP(cpu) ((cpu)->eip)
#define CPU_HAS_SINGLE_STEP ((cpu)->tf)
#endif

extern int current_pid(void);

// Stubs for debug hooks referenced from assembly/gen.c/tlb.c
volatile bool g_trace_highbits = false;
volatile addr_t g_watch_page_val = 0;

#ifdef ISH_GADGET_PROFILE
// Gadget call profile: ring buffer of next-gadget pointers, written by `gret`.
// 64K entries; reader (atexit handler) processes after run.
__attribute__((aligned(64))) uint64_t g_profile_buf[65536] = {0};
__attribute__((aligned(64))) uint64_t g_profile_idx = 0;

// ISH_PAIR_PROFILE=<file>: a sampler thread snapshots the ring every 2 ms and
// accumulates adjacent gadget pairs over the whole run (the atexit dump in
// main.c only sees the last 64K dispatches). Written to <file> as
// "count addr_a addr_b" lines (host addresses; symbolize with nm) at exit.
#include <pthread.h>
#include <unistd.h>
#define PAIR_TBL (1 << 16)
static struct { uint64_t a, b, n; } pair_tbl[PAIR_TBL];
static const char *pair_out;
static void pair_add(uint64_t a, uint64_t b) {
    uint64_t h = ((a * 0x9e3779b97f4a7c15ull) ^ (b * 0xbf58476d1ce4e5b9ull)) >> 48;
    for (unsigned i = 0; i < PAIR_TBL; i++) {
        unsigned j = (h + i) & (PAIR_TBL - 1);
        if (pair_tbl[j].n == 0) { pair_tbl[j].a = a; pair_tbl[j].b = b; }
        if (pair_tbl[j].a == a && pair_tbl[j].b == b) { pair_tbl[j].n++; return; }
    }
}
static void pair_dump(void);
static void *pair_sampler(void *arg) {
    (void) arg;
    for (unsigned tick = 1;; tick++) {
        usleep(2000);
        if (tick % 500 == 0)
            pair_dump();
        uint64_t idx = __atomic_load_n(&g_profile_idx, __ATOMIC_RELAXED);
        if (idx < 4096) continue;
        for (uint64_t k = idx - 4096; k + 1 < idx - 64; k++) {
            uint64_t a = g_profile_buf[k & 0xffff], b = g_profile_buf[(k + 1) & 0xffff];
            if (a && b) pair_add(a, b);
        }
    }
    return NULL;
}
static void pair_dump(void) {
    FILE *f = fopen(pair_out, "w");
    if (!f) return;
    fprintf(f, "ANCHOR %#llx\n", (unsigned long long) (uintptr_t) pair_dump);
    for (unsigned j = 0; j < PAIR_TBL; j++)
        if (pair_tbl[j].n) fprintf(f, "%llu %#llx %#llx\n", (unsigned long long) pair_tbl[j].n,
                                   (unsigned long long) pair_tbl[j].a, (unsigned long long) pair_tbl[j].b);
    fclose(f);
}
__attribute__((constructor)) static void pair_profile_init(void) {
    pair_out = getenv("ISH_PAIR_PROFILE");
    if (!pair_out) return;
    pthread_t t;
    pthread_create(&t, NULL, pair_sampler, NULL);
}
#endif

void jit_trace_regs(struct cpu_state *cpu) { (void)cpu; }
void c_watch_write_hit(addr_t addr, const char *caller) { (void)addr; (void)caller; }
void jit_watch_write_hit(struct cpu_state *cpu, addr_t store_addr, unsigned long *code_ptr) {
    (void)cpu; (void)store_addr; (void)code_ptr;
}
void jit_highbit_alert(struct cpu_state *cpu) { (void)cpu; }

static void fiber_block_disconnect(struct asbestos *asbestos, struct fiber_block *block);
static void fiber_block_free(struct asbestos *asbestos, struct fiber_block *block);
static void fiber_free_jetsam(struct asbestos *asbestos);
static void fiber_resize_hash(struct asbestos *asbestos, size_t new_size);

// Generations are unique across all asbestos instances. A TLB keeps its block
// cache and return cache across execve, and the new mm (and so the new asbestos)
// is often malloc'd at the old address, so tlb_refresh cannot tell them apart.
// If both started at generation 0 the TLB would keep pointers to the old
// asbestos's freed blocks and jump into them.
static unsigned asbestos_gen_counter;

static unsigned asbestos_next_gen(void) {
    unsigned gen;
    do
        gen = __atomic_add_fetch(&asbestos_gen_counter, 1, __ATOMIC_RELAXED);
    while (gen == 0);  // 0 is what tlb_refresh resets block_cache_gen to
    return gen;
}

// Exact page -> blocks index. Each guest page that ever held a block gets a
// page_entry (never freed before asbestos_free; there are only as many as code
// pages). The slot array is open-addressed and grows under asbestos->lock; old
// arrays are kept on a retired chain so the lock-free reader in
// asbestos_invalidate_page never touches freed memory.
//
// This replaced a 1024-bucket `page % N` table. Invalidating any page dropped
// every block in its bucket, so a write to an unrelated data page threw away
// code (retranslation showed up in every JIT-heavy workload). Making that table
// page-precise but keeping buckets made huge munmaps (V8 reserves GBs) cost
// pages x bucket-length, which is why the first attempt slowed node down 4x.
struct page_entry {
    page_t page;
    struct list blocks[2];
};
struct page_table {
    size_t size, used;
    struct page_table *retired;
    struct page_entry *slot[];
};

static inline size_t page_slot(page_t page, size_t size) {
    return (size_t) (((uint64_t) page * 0x9e3779b97f4a7c15ull) >> 32) & (size - 1);
}

static struct page_table *page_table_new(size_t size) {
    struct page_table *t = mem_host_alloc_fails() ? NULL : calloc(1, sizeof(*t) + size * sizeof(t->slot[0]));
    if (t != NULL)
        t->size = size;
    return t;
}

static void page_table_free(struct page_table *t) {
    for (size_t i = 0; i < t->size; i++)
        free(t->slot[i]);  // the newest table holds every entry
    while (t != NULL) {
        struct page_table *next = t->retired;
        free(t);
        t = next;
    }
}

static struct page_entry *page_find(struct asbestos *asbestos, page_t page) {
    struct page_table *t = __atomic_load_n(&asbestos->pages, __ATOMIC_ACQUIRE);
    for (size_t i = page_slot(page, t->size);; i = (i + 1) & (t->size - 1)) {
        struct page_entry *e = __atomic_load_n(&t->slot[i], __ATOMIC_ACQUIRE);
        if (e == NULL || e->page == page)
            return e;
    }
}

// Caller holds asbestos->lock. NULL when the host is out of memory.
static struct page_entry *page_get(struct asbestos *asbestos, page_t page) {
    struct page_entry *e = page_find(asbestos, page);
    if (e != NULL)
        return e;
    struct page_table *t = asbestos->pages;
    struct page_table *bigger = NULL;
    if ((t->used + 1) * 2 > t->size)
        bigger = page_table_new(t->size * 2);
    // Without a bigger table keep filling this one, leaving a free slot so
    // page_find's probe still ends.
    if (bigger == NULL && t->used + 2 > t->size)
        return NULL;
    if (bigger != NULL) {
        for (size_t i = 0; i < t->size; i++) {
            struct page_entry *old = t->slot[i];
            if (old == NULL)
                continue;
            size_t j = page_slot(old->page, bigger->size);
            while (bigger->slot[j] != NULL)
                j = (j + 1) & (bigger->size - 1);
            bigger->slot[j] = old;
        }
        bigger->used = t->used;
        bigger->retired = t;  // entries are shared; only the newest table owns them
        __atomic_store_n(&asbestos->pages, bigger, __ATOMIC_RELEASE);
        t = bigger;
    }
    e = mem_host_alloc_fails() ? NULL : calloc(1, sizeof(*e));
    if (e == NULL)
        return NULL;
    e->page = page;
    list_init(&e->blocks[0]);
    list_init(&e->blocks[1]);
    size_t i = page_slot(page, t->size);
    while (t->slot[i] != NULL)
        i = (i + 1) & (t->size - 1);
    t->used++;
    __atomic_store_n(&t->slot[i], e, __ATOMIC_RELEASE);
    return e;
}

static bool page_has_blocks(struct page_entry *e) {
    return e != NULL && (!list_empty(&e->blocks[0]) || !list_empty(&e->blocks[1]));
}

// Caller holds asbestos->lock.
static bool page_drop_blocks(struct asbestos *asbestos, struct page_entry *e) {
    bool dropped = false;
    struct fiber_block *block, *tmp;
    for (int i = 0; i <= 1; i++) {
        list_for_each_entry_safe(&e->blocks[i], block, tmp, page[i]) {
            fiber_block_disconnect(asbestos, block);
            block->is_jetsam = true;
            list_add(&asbestos->jetsam, &block->jetsam);
            dropped = true;
        }
    }
    return dropped;
}

struct asbestos *asbestos_new(struct mmu *mmu) {
    struct asbestos *asbestos = calloc(1, sizeof(struct asbestos));
    if (asbestos == NULL)
        return NULL;
    asbestos->mmu = mmu;
    asbestos->invalidate_gen = asbestos_next_gen();
    fiber_resize_hash(asbestos, FIBER_INITIAL_HASH_SIZE);
    asbestos->pages = page_table_new(256);
    if (asbestos->hash == NULL || asbestos->pages == NULL) {
        free(asbestos->hash);
        free(asbestos->pages);
        free(asbestos);
        return NULL;
    }
    list_init(&asbestos->jetsam);
    lock_init(&asbestos->lock);
    wrlock_init(&asbestos->jetsam_lock);
    atomic_init(&asbestos->jit_active_threads, 0);
    atomic_init(&asbestos->jetsam_gen, 0);
#ifdef ISH_JIT
    asbestos->jit = jit_enabled() ? jit_mm_new(mmu) : NULL;
#endif
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
#ifdef ISH_JIT
    jit_mm_free(asbestos->jit);
#endif
    page_table_free(asbestos->pages);
    free(asbestos->hash);
    free(asbestos);
}

void asbestos_invalidate_range(struct asbestos *absestos, page_t start, page_t end) {
#ifdef ISH_JIT
    jit_invalidate_range(absestos->jit, start, end);
#endif
    lock(&absestos->lock);
    bool did_invalidate = false;
    struct page_table *t = absestos->pages;
    if (end - start <= t->size) {
        for (page_t page = start; page < end; page++) {
            struct page_entry *e = page_find(absestos, page);
            if (page_has_blocks(e))
                did_invalidate |= page_drop_blocks(absestos, e);
        }
    } else {
        // Large ranges (munmap of a multi-GB reservation): walk the table once.
        for (size_t i = 0; i < t->size; i++) {
            struct page_entry *e = t->slot[i];
            if (e != NULL && e->page >= start && e->page < end && page_has_blocks(e))
                did_invalidate |= page_drop_blocks(absestos, e);
        }
    }
    if (did_invalidate)
        absestos->invalidate_gen = asbestos_next_gen();
    unlock(&absestos->lock);
}

void asbestos_invalidate_page(struct asbestos *asbestos, page_t page) {
    // Fast path without the lock. The racy read can only miss a block that is
    // being translated concurrently with a write to its code: munmap/mprotect/
    // CoW paths hold mem->lock for writing, which excludes running and
    // translating guest code, and a guest that modifies code it is executing
    // must issue IC IVAU anyway (handled by the ic_ivau gadget).
#ifdef ISH_JIT
    jit_invalidate_range(asbestos->jit, page, page + 1);
#endif
    if (!page_has_blocks(page_find(asbestos, page)))
        return;
    lock(&asbestos->lock);
    struct page_entry *e = page_find(asbestos, page);
    if (page_has_blocks(e) && page_drop_blocks(asbestos, e))
        asbestos->invalidate_gen = asbestos_next_gen();
    unlock(&asbestos->lock);
}

void asbestos_invalidate_all(struct asbestos *asbestos) {
#ifdef ISH_JIT
    jit_invalidate_all(asbestos->jit);
#endif
    lock(&asbestos->lock);
    bool did_invalidate = false;
    struct page_table *t = asbestos->pages;
    for (size_t i = 0; i < t->size; i++) {
        struct page_entry *e = t->slot[i];
        if (page_has_blocks(e))
            did_invalidate |= page_drop_blocks(asbestos, e);
    }
    if (did_invalidate)
        asbestos->invalidate_gen = asbestos_next_gen();
    unlock(&asbestos->lock);
}

// Block hash: guest code addresses are 4-byte aligned and clustered, so a plain
// `addr % size` (size is a power of two) left 3/4 of the buckets empty and gave
// long chains that dominated block lookups. Multiplicative hashing spreads them.
static inline size_t fiber_hash(addr_t addr, size_t size) {
    return (size_t) (((uint64_t) addr * 0x9e3779b97f4a7c15ull) >> 32) & (size - 1);
}

static void fiber_resize_hash(struct asbestos *asbestos, size_t new_size) {
    TRACE_(verbose, "%d resizing hash to %lu, using %lu bytes for gadgets\n", current_pid(), new_size, asbestos->mem_used);
    struct list *new_hash = mem_host_alloc_fails() ? NULL : calloc(new_size, sizeof(struct list));
    if (new_hash == NULL)
        return;  // out of host memory: keep the current (longer) chains
    for (size_t i = 0; i < asbestos->hash_size; i++) {
        if (list_null(&asbestos->hash[i]))
            continue;
        struct fiber_block *block, *tmp;
        list_for_each_entry_safe(&asbestos->hash[i], block, tmp, chain) {
            list_remove(&block->chain);
            list_init_add(&new_hash[fiber_hash(block->addr, new_size)], &block->chain);
        }
    }
    free(asbestos->hash);
    asbestos->hash = new_hash;
    asbestos->hash_size = new_size;
}

// False when the host is out of memory for the page index: the block could
// not be invalidated when its code changes, so it must not be used.
static bool fiber_insert(struct asbestos *asbestos, struct fiber_block *block) {
    struct page_entry *first = page_get(asbestos, PAGE(block->addr));
    struct page_entry *last = PAGE(block->addr) == PAGE(block->end_addr) ? first :
        page_get(asbestos, PAGE(block->end_addr));
    if (first == NULL || last == NULL)
        return false;
    asbestos->mem_used += block->used;
    asbestos->num_blocks++;
    // target an average hash chain length of 1-2
    if (asbestos->num_blocks >= asbestos->hash_size)
        fiber_resize_hash(asbestos, asbestos->hash_size * 2);

    list_init_add(&asbestos->hash[fiber_hash(block->addr, asbestos->hash_size)], &block->chain);
    list_add(&first->blocks[0], &block->page[0]);
    if (PAGE(block->addr) != PAGE(block->end_addr))
        list_add(&last->blocks[1], &block->page[1]);
    return true;
}

static struct fiber_block *fiber_lookup(struct asbestos *asbestos, addr_t addr) {
    struct list *bucket = &asbestos->hash[fiber_hash(addr, asbestos->hash_size)];
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
    ISH_SIGNPOST_SCOPE_BEGIN(jit, "block_compile", _bc_spid);
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
    ISH_SIGNPOST_SCOPE_END(jit, "block_compile", _bc_spid);
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

int fiber_enter_raw(struct fiber_block *block, struct fiber_frame *frame, struct tlb *tlb);

// Frame of the fiber this thread is running, for the host crash handler. It
// used to take the frame from x1 (_cpu), but faults can also happen inside C
// helpers called from gadgets (c_atomic_cas, crosspage copies, ...), where x1
// is clobbered: the handler then read jit_exit_sp from a random address and
// took the whole emulator down instead of returning INT_JIT_CRASH.
__thread struct fiber_frame *volatile jit_saved_frame;

int fiber_enter(struct fiber_block *block, struct fiber_frame *frame, struct tlb *tlb) {
    struct fiber_frame *outer = jit_saved_frame;
    jit_saved_frame = frame;
    int interrupt = fiber_enter_raw(block, frame, tlb);
    jit_saved_frame = outer;
    return interrupt;
}
static int cpu_single_step(struct cpu_state *cpu, struct tlb *tlb);

static inline size_t fiber_cache_hash(addr_t ip) {
    return (ip ^ (ip >> 12)) & (FIBER_CACHE_SIZE - 1);
}

// Copy the frame's CPU state back to the task, except _poked. The frame copy of
// _poked is a snapshot from fiber entry; writing it back re-armed a poke that
// the dispatch loop had already consumed (and could drop one that arrived
// meanwhile), so after the first poke every block transition became an
// INT_TIMER round trip through handle_interrupt. _poked is the last field.
static inline void cpu_writeback(struct cpu_state *cpu, const struct cpu_state *frame_cpu) {
    memcpy(cpu, frame_cpu, offsetof(struct cpu_state, _poked));
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
        if (frame == NULL) {
            // Out of memory. fiber_frame is ~48KB; under heavy Node/npm
            // workloads with many worker threads each needing their own
            // TLB+frame, allocation can fail. Release jetsam_lock and
            // surface this as INT_GPF so the guest sees a crash rather
            // than the host deref'ing a NULL frame pointer below.
            read_wrunlock(&asbestos->jetsam_lock);
            return INT_GPF;
        }
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
        pc_trace_record(ip);
        // Diagnostic: fake_ip leaked into cpu->pc (bit 63 set). This
        // indicates a gadget wrote a tagged pointer without masking.
        // Trace the first occurrence per task with the frame's LR /
        // previous block so we can locate the culprit gadget.
        // Guest PC with bit 63 set indicates corrupted state — BLR/RET
        // landed on a fake_ip tag or a sentinel pointer leaked through
        // guest memory (e.g. a zero-initialized V8 heap slot combined
        // with pointer tagging). Convert to an INT_GPF at a canonical
        // NULL fault so handle_interrupt's V8 zone recovery can try to
        // unwind instead of looping on fiber_block_compile at the
        // tagged address (which reads unmapped memory forever).
        if (ip & 0xffff000000000000ULL) {
            read_wrunlock(&asbestos->jetsam_lock);
            cpu_writeback(cpu, &frame->cpu);
            cpu->segfault_addr = ip;
            cpu->segfault_was_write = 0;
            cpu->pc = ip & 0xffffffffffffULL;
            return INT_GPF;
        }
        // Guard: null guest PC means corrupted state (e.g., RET with LR=0
        // after a BL return-address got clobbered, or BR to NULL). Native
        // Linux would deliver SIGSEGV and terminate. In iSH the fault
        // address resolves to the guard-page zeros we map at 0x0-0x1MB,
        // so no SIGSEGV fires from the JIT; instead handle_interrupt
        // re-enters the loop forever. Force-exit with 139 (128+SIGSEGV) so
        // the shell reports "Segmentation fault" and userspace sees a
        // non-zero exit status.
        if (ip == 0) {
            // Release asbestos jetsam_lock held by cpu_step_to_interrupt
            // before calling do_exit_group (which may synchronously reap).
            read_wrunlock(&asbestos->jetsam_lock);
            cpu_writeback(cpu, &frame->cpu);
            // Fall through to cpu_run_to_interrupt — return INT_GPF with
            // a canonical write=0 so handle_interrupt delivers SIGSEGV.
            cpu->segfault_addr = 0;
            cpu->segfault_was_write = 0;
            cpu->pc = 0;
            return INT_GPF;
        }
        // Trace-JIT bypass: if a native translation already exists for
        // this PC (in the dispatch table), skip the gadget block compile
        // and run native instead. If no translation exists yet, kick off
        // an async translation attempt — but DON'T call into native this
        // iteration; let the gadget run once, future iterations get the
        // native fast path.
        struct fiber_block *block = NULL;
        {
            size_t cache_index = fiber_cache_hash(ip);
            block = cache[cache_index];
            if (block == NULL || block->addr != ip) {
                lock(&asbestos->lock);
                block = fiber_lookup(asbestos, ip);
                unsigned gen = asbestos->invalidate_gen;
                unlock(&asbestos->lock);
                if (block == NULL) {
                    // Translate without holding asbestos->lock: with many guest
                    // threads (Firefox, node) the lock was mostly held by
                    // translation and the other threads queued behind it.
                    struct fiber_block *fresh = fiber_block_compile(ip, tlb);
                    lock(&asbestos->lock);
                    block = fiber_lookup(asbestos, ip);
                    if (block == NULL) {
                        if (asbestos->invalidate_gen != gen) {
                            // Something was invalidated meanwhile; the bytes we
                            // translated may be stale, so translate again here.
                            free(fresh);
                            fresh = fiber_block_compile(ip, tlb);
                        }
                        if (!fiber_insert(asbestos, fresh)) {
                            // Out of host memory: drop the block and yield;
                            // this ip is translated again after the interrupt.
                            unlock(&asbestos->lock);
                            free(fresh);
                            interrupt = INT_TIMER;
                            break;
                        }
                        block = fresh;
                        fresh = NULL;
                    }
                    unlock(&asbestos->lock);
                    free(fresh);  // another thread inserted this ip first
                } else {
                    TRACE("%d %08x --- missed cache\n", current_pid(), ip);
                }
                cache[cache_index] = block;
            }
        }
        struct fiber_block *last_block = frame->last_block;
        if (block != NULL && last_block != NULL &&
                !last_block->is_jetsam && !block->is_jetsam &&
                (last_block->jump_ip[0] != NULL ||
                 last_block->jump_ip[1] != NULL)) {
            if (trylock(&asbestos->lock) == 0) {
                // can't mint new pointers to a block that has been marked jetsam
                // and is thus assumed to have no pointers left
                if (!last_block->is_jetsam && !block->is_jetsam) {
                    for (int i = 0; i <= 1; i++) {
                        // Unpatched slots hold the target as a fake_ip (bit 63 set,
                        // 48-bit guest address). Comparing only the low 32 bits
                        // never chained branches above 4 GB (JIT code heaps,
                        // libpas) and could match an already-patched host pointer.
                        unsigned long slot = last_block->jump_ip[i] != NULL ? *last_block->jump_ip[i] : 0;
                        if ((slot >> 63) && (slot & 0xffffffffffffUL) == block->addr) {
                            *last_block->jump_ip[i] = (unsigned long) block->code;
                            list_add(&block->jumps_from[i], &last_block->jumps_from_links[i]);
                        }
                    }
                }
                unlock(&asbestos->lock);
            }
        }
        if (block != NULL) frame->last_block = block;

        // block may be jetsam, but that's ok, because it can't be freed until
        // every thread on this asbestos is not executing anything

        TRACE("%d %08x --- cycle %ld\n", current_pid(), ip, frame->cpu.cycle);

        // Save block start PC to thread-local for crash recovery.
        // The signal handler reads this to restore cpu->pc on SIGSEGV.
        jit_saved_pc = frame->cpu.pc;

        // Count dispatch-loop iterations (gated). Cached env check.
        {
            static int g_dispatch_count = -1;
            extern _Atomic uint64_t s_dispatch_iterations;
            if (g_dispatch_count == -1) {
                const char *e = getenv("ISH_DISPATCH_COUNT");
                g_dispatch_count = (e && e[0] == '1') ? 1 : 0;
            }
            if (g_dispatch_count)
                atomic_fetch_add_explicit(&s_dispatch_iterations, 1, memory_order_relaxed);
        }

        in_jit = 1;
        interrupt = fiber_enter(block, frame, tlb);
        in_jit = 0;


        // Check if fiber_enter returned due to a JIT crash (signal handler
        // redirected PC to jit_crash_trampoline which returns INT_JIT_CRASH).
        // The signal handler already set cpu->segfault_addr, cpu->pc, etc.
        if (interrupt == INT_JIT_CRASH) {
            // Flush all caches to get fresh host pointers.
            tlb_flush(tlb);
            memset(cache, 0, sizeof(tlb->block_cache));
            tlb->block_cache_gen = asbestos->invalidate_gen;
            memset(frame->ret_cache, 0, sizeof(frame->ret_cache));
            frame->last_block = NULL;

            crash_retry_count++;
            if (crash_retry_count >= 16) {
                // Too many consecutive crashes — escalate to INT_GPF for handle_interrupt
                interrupt = INT_GPF;
                crash_retry_count = 0;
            } else {
                // Retry: convert to INT_NONE so the loop continues
                interrupt = INT_NONE;
            }
        } else {
            crash_retry_count = 0;
        }

        // (debug trace removed)

        // Check if page table changed (mmap/munmap by another thread) EVERY BLOCK.
        if (tlb->mem_changes != __atomic_load_n(&tlb->mmu->changes, __ATOMIC_ACQUIRE)) {
            tlb_flush(tlb);
            memset(cache, 0, sizeof(tlb->block_cache));
            tlb->block_cache_gen = asbestos->invalidate_gen;
            memset(frame->ret_cache, 0, sizeof(frame->ret_cache));
            frame->last_block = NULL;
        }

        if (interrupt == INT_NONE && __atomic_exchange_n(frame->cpu.poked_ptr, false, __ATOMIC_ACQUIRE))
            interrupt = INT_TIMER;
        // Same period as TIMER_PERIOD_MASK in the arm64 gadgets (chained transitions
        // count too, so this fires about every 8K blocks however they are reached).
        if (interrupt == INT_NONE && (++frame->cpu.cycle & ((1 << 13) - 1)) == 0)
            interrupt = INT_TIMER;
        // PC histogram: sample on every block exit (not just timer ticks).
        // Weight by guest insn count of the block just executed; this gives
        // the per-insn share rather than per-block-dispatch share.
        // Chained blocks skip this loop entirely — but V8 jitless interp
        // dispatch ends in computed-goto (gret, unchainable) so V8 ranges
        // remain fully visible. Other code (loops with direct jumps) gets
        // chained and becomes invisible, biasing the histogram TOWARD V8.
        // Therefore the V8 share measured here is a lower bound on V8's
        // true insn-level share.
        if (pc_hist_on() && frame->last_block != NULL) {
            struct fiber_block *b = frame->last_block;
            uint64_t pc = b->addr;
            uint64_t weight = (b->end_addr - b->addr) >> 2;  // insns
            if (weight == 0) weight = 1;
            if (pc < ((uint64_t)PC_HIST_BUCKETS << PC_HIST_SHIFT))
                atomic_fetch_add_explicit(&pc_hist[pc >> PC_HIST_SHIFT], weight, memory_order_relaxed);
        }
    }
    cpu_writeback(cpu, &frame->cpu);

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
    ish_thread_marker = 1;
    // Always our own flag: fork/clone copy the whole parent task (task_create_
    // does *task = *parent), so a child's poked_ptr starts out pointing into the
    // parent's task struct.
    cpu->poked_ptr = &cpu->_poked;
#ifdef GUEST_ARM64
    // NOTE: Do NOT invalidate exclusive monitor here.
    // This function is called once, but the inner loop (cpu_step_to_interrupt)
    // calls fiber_enter repeatedly. The LDXR/STXR pair may span multiple
    // fiber_enter calls (unchained blocks). Invalidating here would break
    // LDXR/STXR atomicity across block boundaries.
    // The exclusive monitor is invalidated by STXR itself (success or fail)
    // and by context switches / signal delivery.
#endif
    struct asbestos *asbestos = cpu->mmu->asbestos;
    __atomic_add_fetch(&asbestos->active_threads, 1, __ATOMIC_RELAXED);
    tlb_refresh(tlb, cpu->mmu);
#ifdef ISH_JIT
    int interrupt = asbestos->jit ? jit_run(cpu, tlb, asbestos->jit) :
        (CPU_HAS_SINGLE_STEP ? cpu_single_step : cpu_step_to_interrupt)(cpu, tlb);
#else
    int interrupt = (CPU_HAS_SINGLE_STEP ? cpu_single_step : cpu_step_to_interrupt)(cpu, tlb);
#endif
    cpu->trapno = interrupt;
    __atomic_sub_fetch(&asbestos->active_threads, 1, __ATOMIC_RELAXED);

    lock(&asbestos->lock);
    if (!list_empty(&asbestos->jetsam)) {
        unlock(&asbestos->lock);

        // Write lock ensures all JIT threads have exited (they hold read lock).
        // Use trylock so only ONE cleaner thread runs at a time; others skip
        // and let the winner handle the jetsam list. This avoids a
        // multi-writer contention pattern that can wedge macOS psynch rwlock
        // when many node/npm worker threads all try to clean jetsam at once.
        // (The jetsam list will still get drained by whichever thread wins.)
        if (write_wrtrylock(&asbestos->jetsam_lock)) {
            lock(&asbestos->lock);
            fiber_free_jetsam(asbestos);
            unlock(&asbestos->lock);
            write_wrunlock(&asbestos->jetsam_lock);
        }
    } else {
        unlock(&asbestos->lock);
    }

    return interrupt;
}

void cpu_poke(struct cpu_state *cpu) {
    __atomic_store_n(cpu->poked_ptr, true, __ATOMIC_SEQ_CST);
}
