// JIT runtime: dispatcher, block cache, invalidation, slow-path helpers,
// trampolines, host fault handling and the periodic exit ticker.
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ucontext.h>
#include <sys/mman.h>
#include <time.h>
#include <libkern/OSCacheControl.h>
#include <TargetConditionals.h>
#include <dispatch/dispatch.h>
#include "jit/jit.h"
#include "jit/jit_internal.h"
#include "jit/emit.h"
#include "emu/cpu.h"
#include "emu/tlb.h"
#include "emu/interrupt.h"
#include "asbestos/asbestos.h"
#include "asbestos/gen.h"
#include "asbestos/frame.h"
#include "kernel/mm.h"

#define FPCR_GUEST_MASK 0x07c80000u

extern __thread volatile sig_atomic_t in_jit;
extern __thread volatile addr_t jit_saved_pc;
int fiber_enter(struct fiber_block *block, struct fiber_frame *frame, struct tlb *tlb);

static int jit_state = -1;   // -1 unknown, 0 off, 1 on
static bool jit_stats;
static pthread_mutex_t init_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t reg_lock = PTHREAD_MUTEX_INITIALIZER;
static struct jit_ctx *reg_head;
static pthread_key_t ctx_key;
static __thread struct jit_ctx *tls_ctx;
static __thread unsigned reclaim_tick;   // dispatcher passes, to look for dead entries now and then
static struct sigaction old_segv, old_bus, old_ill;
static unsigned tick_us = 500;
uint32_t jit_promote_after = 128;   // tier-1 executions before tier-2 retranslation
static int force_tier;             // ISH_JIT_TIER=1/2 (testing)
int jit_force_tier1;
int jit_tier1_compact = 0;      // ISH_JIT_COMPACT=1: cacheable code starts compact (stubs, counted, promoted)

static void install_signals(void);
static void install_pressure_handler(void);
static void *ticker_main(void *arg);

// ---------------------------------------------------------------------------
// Init / per-thread context
// ---------------------------------------------------------------------------
static void ctx_destroy(void *p) {
    struct jit_ctx *ctx = p;
    pthread_mutex_lock(&reg_lock);
    if (ctx->reg_prev)
        ctx->reg_prev->reg_next = ctx->reg_next;
    else
        reg_head = ctx->reg_next;
    if (ctx->reg_next)
        ctx->reg_next->reg_prev = ctx->reg_prev;
    pthread_mutex_unlock(&reg_lock);
    free(ctx->frame);
    free(ctx);
}

// The ish_jit_* fast mode entry points are found by the app with dlsym, so
// `used` keeps the linker from dead-stripping them.

// iOS device: may the JIT start now? Without TXM, CS_DEBUGGED is enough (a
// debugger attached once, e.g. StikDebug, which then detached). With TXM the
// universal.js script must still be attached (P_TRACED) to answer the
// breakpoint calls of jit_codemem_init.
static bool debug_ready(void) {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    if (jit_txm_present())
        return jit_debugger_attached() && jit_cs_debugged();
    return jit_cs_debugged();
#else
    return false;
#endif
}

__attribute__((used)) bool ish_jit_debug_ready(void) {
    return debug_ready();
}

__attribute__((used)) bool ish_jit_txm_present(void) {
    return jit_txm_present();
}

// Acquire code memory and start the JIT's threads. init_lock held.
static bool start_locked(void) {
    if (!jit_codemem_init()) {
        fprintf(stderr, "ish: JIT unavailable (no executable memory), using gadget engine\n");
        return false;
    }
    const char *s = getenv("ISH_JIT_STATS");
    jit_stats = s && s[0] == '1';
#if TARGET_OS_IPHONE
    bool announce = true;
#else
    bool announce = jit_stats;
#endif
    if (announce)
        fprintf(stderr, "ish: native JIT on: %s, %zu MB code arena at %#lx\n", jit_codemem_mode(),
                jit_code_size() >> 20, (unsigned long) jit_code_base());
    const char *pa = getenv("ISH_JIT_PROMOTE");
    if (pa)
        jit_promote_after = atoi(pa) > 0 ? atoi(pa) : 1;
    const char *ft = getenv("ISH_JIT_TIER");
    if (ft)
        force_tier = atoi(ft);
    jit_force_tier1 = force_tier == 1;
    const char *cm = getenv("ISH_JIT_COMPACT");
    if (cm)
        jit_tier1_compact = atoi(cm) != 0;
    const char *t = getenv("ISH_JIT_TICK_US");
    if (t)
        tick_us = atoi(t);
    pthread_key_create(&ctx_key, ctx_destroy);
    install_signals();
    install_pressure_handler();
    pthread_t th;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&th, &attr, ticker_main, NULL);
    return true;
}

bool jit_enabled(void) {
    if (__builtin_expect(jit_state >= 0, 1))
        return jit_state;
    pthread_mutex_lock(&init_lock);
    if (jit_state < 0) {
        // ISH_JIT=1 forces the JIT on, ISH_JIT=0 off. Unset: off, except on an
        // iOS device that a debugger (StikDebug) has made able to run
        // generated code: the only way to get executable memory there.
        const char *e = getenv("ISH_JIT");
        int on = e && e[0] == '1';
        if (e == NULL)
            on = debug_ready();
        if (on && !start_locked())
            on = 0;
        __atomic_store_n(&jit_state, on, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&init_lock);
    return jit_state;
}

__attribute__((used)) bool ish_jit_try_enable(void) {
    if (jit_enabled())
        return true;
    pthread_mutex_lock(&init_lock);
    const char *e = getenv("ISH_JIT");
    if (jit_state == 0 && !(e && e[0] == '0') && debug_ready() && start_locked())
        __atomic_store_n(&jit_state, 1, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&init_lock);
    return jit_state == 1;
}

static void tlb_flush_ctx(struct jit_ctx *ctx) {
    if (ctx->nfilled <= JIT_FILLED_MAX) {
        for (uint32_t i = 0; i < ctx->nfilled; i++) {
            ctx->tlbe[ctx->filled[i]].page_r = 1;
            ctx->tlbe[ctx->filled[i]].page_w = 1;
        }
    } else {
        for (unsigned i = 0; i < JIT_TLB_SIZE; i++) {
            ctx->tlbe[i].page_r = 1;
            ctx->tlbe[i].page_w = 1;
        }
    }
    ctx->nfilled = 0;
}

static struct jit_ctx *get_ctx(void) {
    struct jit_ctx *ctx = tls_ctx;
    if (ctx)
        return ctx;
    if (posix_memalign((void **) &ctx, 64, sizeof(*ctx)) != 0)
        return NULL;
    memset(ctx, 0, sizeof(*ctx));
    ctx->frame = calloc(1, sizeof(struct fiber_frame));
    if (ctx->frame == NULL) {
        free(ctx);
        return NULL;
    }
    ctx->nfilled = JIT_FILLED_MAX + 1;   // force a full initialization
    tlb_flush_ctx(ctx);
    pthread_setspecific(ctx_key, ctx);
    tls_ctx = ctx;
    pthread_mutex_lock(&reg_lock);
    ctx->reg_next = reg_head;
    if (reg_head)
        reg_head->reg_prev = ctx;
    reg_head = ctx;
    pthread_mutex_unlock(&reg_lock);
    return ctx;
}

// The ticker sleeps on ticker_cond while no thread runs guest code, so an
// idle emulator (all guest threads blocked in syscalls) costs no wakeups.
static pthread_cond_t ticker_cond = PTHREAD_COND_INITIALIZER;
static volatile bool ticker_idle;

// Called after setting ctx->in_jit. The fences pair with the ticker's
// re-check below so that one side always sees the other.
static void ticker_wake(void) {
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    if (__builtin_expect(ticker_idle, 0)) {
        pthread_mutex_lock(&reg_lock);
        ticker_idle = false;
        pthread_cond_signal(&ticker_cond);
        pthread_mutex_unlock(&reg_lock);
    }
}

static void *ticker_main(void *arg) {
    (void) arg;
    pthread_setname_np("ish-jit-tick");
    // test hook: simulate memory-pressure events
    const char *te = getenv("ISH_JIT_TRIM_EVERY_MS");
    uint64_t trim_every = te ? (uint64_t) atol(te) * 1000 : 0, since_trim = 0, since_flush = 0;
    for (;;) {
        usleep(tick_us);
        if ((since_flush += tick_us) >= 1000000) {
            since_flush = 0;
            jit_pcache_tick();
        }
        if (trim_every && (since_trim += tick_us) >= trim_every) {
            since_trim = 0;
            ish_jit_trim();
        }
        pthread_mutex_lock(&reg_lock);
        bool any = false;
        for (struct jit_ctx *c = reg_head; c; c = c->reg_next) {
            if (c->in_jit) {
                c->exitflag = true;
                any = true;
            }
        }
        if (!any) {
            ticker_idle = true;
            __atomic_thread_fence(__ATOMIC_SEQ_CST);
            for (struct jit_ctx *c = reg_head; c && !any; c = c->reg_next)
                any = c->in_jit;
            if (any)
                ticker_idle = false;
            while (ticker_idle)
                pthread_cond_wait(&ticker_cond, &reg_lock);
        }
        pthread_mutex_unlock(&reg_lock);
    }
    return NULL;
}

// ---------------------------------------------------------------------------
// Address-space state
// ---------------------------------------------------------------------------
struct ss_entry {
    addr_t pc;
    struct fiber_block *block;
    struct ss_entry *next;
};

// An empty indirect-table slot. Not 0: the lookup in JIT code only compares the pc,
// so an empty {0, 0} slot matched a guest branch to address 0 (a call through a NULL
// function pointer) and jumped to host address 0, a host crash instead of the guest's
// SIGSEGV. Guest pcs are 4-aligned, so 1 never matches.
#define ITAB_EMPTY_PC 1
static inline void itab_clear(struct jit_itab_entry *e) {
    __asm__ volatile("stp %0, xzr, [%1]" :: "r"((uint64_t) ITAB_EMPTY_PC), "r"(e) : "memory");
}

static pthread_mutex_t mm_list_lock = PTHREAD_MUTEX_INITIALIZER;
static struct jit_mm *mm_list;

// NULL when the host is out of memory: the address space then runs in the
// gadget engine only (asbestos->jit == NULL).
struct jit_mm *jit_mm_new(struct mmu *mmu) {
    struct jit_mm *mm = mem_host_alloc_fails() ? NULL : calloc(1, sizeof(*mm));
    if (mm == NULL)
        return NULL;
    mm->mmu = mmu;
    mm->hash_size = 1024;
    mm->hash = calloc(mm->hash_size, sizeof(*mm->hash));
    mm->counters = mmap(NULL, JIT_COUNTERS * sizeof(uint32_t), PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANON, -1, 0);
    mm->htpub = calloc(1, sizeof(*mm->htpub));
    mm->page_hash_size = 65536;   // ~1 code page per bucket: racy empty-bucket check stays exact
    mm->page_hash = calloc(mm->page_hash_size, sizeof(*mm->page_hash));
    mm->bucket_page = calloc(mm->page_hash_size, sizeof(*mm->bucket_page));
    if (posix_memalign((void **) &mm->itab, 64, sizeof(struct jit_itab_entry) << JIT_ITAB_BITS) != 0)
        mm->itab = NULL;
    mm->ss_size = 256;
    mm->ss_hash = calloc(mm->ss_size, sizeof(*mm->ss_hash));
    if (mm->hash == NULL || mm->counters == MAP_FAILED || mm->htpub == NULL || mm->page_hash == NULL ||
            mm->bucket_page == NULL || mm->itab == NULL || mm->ss_hash == NULL) {
        free(mm->hash);
        if (mm->counters != MAP_FAILED)
            munmap(mm->counters, JIT_COUNTERS * sizeof(uint32_t));
        free(mm->htpub);
        free(mm->page_hash);
        free(mm->bucket_page);
        free(mm->itab);
        free(mm->ss_hash);
        free(mm);
        return NULL;
    }
    for (size_t i = 0; i < ((size_t) 1 << JIT_ITAB_BITS); i++)
        mm->itab[i] = (struct jit_itab_entry) {ITAB_EMPTY_PC, 0};
    mm->htpub->tab = mm->hash;
    mm->htpub->size = mm->hash_size;
    pthread_mutex_init(&mm->lock, NULL);
    atomic_init(&mm->gen, 1);
    pthread_mutex_lock(&mm_list_lock);
    mm->list_next = mm_list;
    if (mm_list)
        mm_list->list_prev = mm;
    mm_list = mm;
    pthread_mutex_unlock(&mm_list_lock);
    return mm;
}

struct jit_block_ext {
    uint32_t **in_slots;
    uint32_t nin, capin;
};

static void block_free(struct jit_block *b);
static void free_dead(struct jit_block *b, struct ss_entry *e);
static void chunk_destroy(struct jit_chunk *c);

void jit_mm_free(struct jit_mm *mm) {
    if (mm == NULL)
        return;
    jit_pcache_save();   // a process exited: persist what it translated
    pthread_mutex_lock(&mm_list_lock);
    if (mm->list_prev)
        mm->list_prev->list_next = mm->list_next;
    else
        mm_list = mm->list_next;
    if (mm->list_next)
        mm->list_next->list_prev = mm->list_prev;
    pthread_mutex_unlock(&mm_list_lock);
    if (jit_stats && mm->stats_blocks)
        fprintf(stderr, "[jit] mm %p: %llu blocks, %llu KB code, %llu fallbacks, %llu invalidations, %llu flushes, %llu far chains\n",
                (void *) mm, (unsigned long long) mm->stats_blocks,
                (unsigned long long) mm->stats_words * 4 / 1024,
                (unsigned long long) mm->stats_fallback, (unsigned long long) mm->stats_inval,
                (unsigned long long) mm->stats_flush, (unsigned long long) mm->stats_veneer_retire);
    if (jit_stats && mm->stats_blocks) {
        static const char *names[] = {"?", "chain", "indirect", "fallback", "syscall", "poll", "icivau",
                                      "gpf", "hostfault", "undef", "redispatch", "promote"};
        fprintf(stderr, "[jit]   promoted to tier 2: %llu blocks\n", (unsigned long long) mm->stats_promote);
        size_t ndead = 0, njetsam = 0, nlive = 0;
        for (struct jit_block *b = mm->dead; b; b = b->dead_next)
            ndead++;
        for (struct jit_block *b = mm->dead_pending; b; b = b->dead_next)
            ndead++;
        for (struct ss_entry *e = mm->ss_jetsam; e; e = e->next)
            njetsam++;
        for (struct ss_entry *e = mm->ss_pending; e; e = e->next)
            njetsam++;
        size_t ninvalid = 0, map_bytes = 0;
        for (struct jit_chunk *c = mm->chunks; c; c = c->next) {
            nlive += c->nblocks;
            for (size_t i = 0; i < c->nblocks; i++) {
                ninvalid += c->blocks[i]->invalid;
                map_bytes += c->blocks[i]->nmap * sizeof(struct jit_map_entry) + sizeof(struct jit_block_ext);
            }
        }
        fprintf(stderr, "[jit]   at exit: %zu blocks in %zu chunks (%zu invalidated), maps %zu KB, %zu dead negative entries and "
                "%zu dead single-step blocks not yet freed, %zu live single-step\n",
                nlive, mm->nchunks, ninvalid, map_bytes >> 10, ndead, njetsam, mm->ss_count);
        fprintf(stderr, "[jit]   translate %.1f ms, invalidate %.1f ms (%llu blocks, %llu slots)\n",
                mm->stats_translate_ns / 1e6, mm->stats_inval_ns / 1e6,
                (unsigned long long) mm->stats_inval_blocks, (unsigned long long) mm->stats_inval_slots);
        fprintf(stderr, "[jit]   guest insns %llu, host words/insn %.1f (hot %.1f)\n",
                (unsigned long long) mm->stats_insns,
                (double) mm->stats_words / (mm->stats_insns ? mm->stats_insns : 1),
                (double) mm->stats_hot / (mm->stats_insns ? mm->stats_insns : 1));
        uint64_t ph, pm, po;
        jit_pcache_stats(&ph, &pm, &po);
        fprintf(stderr, "[jit]   pcache (process-wide so far): %llu hits, %llu misses, %llu stored\n",
                (unsigned long long) ph, (unsigned long long) pm, (unsigned long long) po);
        fprintf(stderr, "[jit]   tlb misses %llu (page-crossing %llu), tlb flushes %llu\n",
                (unsigned long long) mm->stats_tlb_miss, (unsigned long long) mm->stats_bounce,
                (unsigned long long) mm->stats_tlb_flush);
        fprintf(stderr, "[jit]   exits:");
        for (int i = 1; i <= JR_PROMOTE; i++)
            if (mm->stats_exits[i])
                fprintf(stderr, " %s=%llu", names[i], (unsigned long long) mm->stats_exits[i]);
        fprintf(stderr, "\n");
        for (int i = 0; i < 32; i++)
            if (mm->stats_fb[i].n)
                fprintf(stderr, "[jit]   fallback %08x x%llu\n", mm->stats_fb[i].insn, (unsigned long long) mm->stats_fb[i].n);
    }
    for (int list = 0; list < 2; list++) {
        struct jit_chunk *c = list ? mm->retired : mm->chunks;
        while (c) {
            struct jit_chunk *next = c->next;
            chunk_destroy(c);
            c = next;
        }
    }
    for (size_t i = 0; i < mm->ss_size; i++) {
        struct ss_entry *e = mm->ss_hash[i];
        while (e) {
            struct ss_entry *n = e->next;
            free(e->block);
            free(e);
            e = n;
        }
    }
    free_dead(mm->dead, mm->ss_jetsam);
    free_dead(mm->dead_pending, mm->ss_pending);
    free(mm->ss_hash);
    free(mm->itab);
    for (struct jit_htpub *h = mm->htpub; h;) {
        struct jit_htpub *o = h->older;
        free(h->tab);   // the newest one is mm->hash
        free(h);
        h = o;
    }
    munmap(mm->counters, JIT_COUNTERS * sizeof(uint32_t));
    free(mm->page_hash);
    free(mm->bucket_page);
    pthread_mutex_destroy(&mm->lock);
    free(mm);
}

static inline size_t pc_hash(addr_t pc, size_t size) {
    return (size_t) ((pc * 0x9e3779b97f4a7c15ull) >> 32) & (size - 1);
}

// Blocks with rx == NULL are negative entries (first instruction needs the
// gadget engine).
static struct jit_block *lookup_locked(struct jit_mm *mm, addr_t pc) {
    for (struct jit_block *b = mm->hash[pc_hash(pc, mm->hash_size)]; b; b = b->hash_next)
        if (b->pc == pc)
            return b;
    return NULL;
}

static void hash_insert(struct jit_mm *mm, struct jit_block *b) {
    struct jit_block **nh = NULL;
    struct jit_htpub *pub = NULL;
    if (++mm->nblocks > mm->hash_size) {
        nh = mem_host_alloc_fails() ? NULL : calloc(mm->hash_size * 2, sizeof(*nh));
        pub = calloc(1, sizeof(*pub));
        if (nh == NULL || pub == NULL) {
            // out of host memory: keep the current table (longer chains)
            free(nh);
            free(pub);
            nh = NULL;
        }
    }
    if (nh != NULL) {
        size_t ns = mm->hash_size * 2;
        for (size_t i = 0; i < mm->hash_size; i++) {
            struct jit_block *x = mm->hash[i];
            while (x) {
                struct jit_block *n = x->hash_next;
                size_t h = pc_hash(x->pc, ns);
                x->hash_next = nh[h];
                nh[h] = x;
                x = n;
            }
        }
        // Lock-free readers may still walk the old table: keep it until the
        // mm is freed (nodes are relinked, so a reader may miss: it then
        // takes the locked path).
        pub->tab = nh;
        pub->size = ns;
        pub->older = mm->htpub;
        mm->hash = nh;
        mm->hash_size = ns;
        __atomic_store_n(&mm->htpub, pub, __ATOMIC_RELEASE);
    }
    size_t h = pc_hash(b->pc, mm->hash_size);
    b->hash_next = mm->hash[h];
    __atomic_store_n(&mm->hash[h], b, __ATOMIC_RELEASE);
    size_t p = PAGE(b->pc) % mm->page_hash_size;
    b->page_next = mm->page_hash[p];
    mm->page_hash[p] = b;
    uint64_t tag = PAGE(b->pc) + 1, cur = mm->bucket_page[p];
    if (cur != tag)
        __atomic_store_n(&mm->bucket_page[p], cur == 0 ? tag : ~0ull, __ATOMIC_RELEASE);
}

static void hash_remove(struct jit_mm *mm, struct jit_block *b) {
    struct jit_block **pp = &mm->hash[pc_hash(b->pc, mm->hash_size)];
    while (*pp && *pp != b)
        pp = &(*pp)->hash_next;
    if (*pp) {
        *pp = b->hash_next;
        mm->nblocks--;
    }
    size_t bucket = PAGE(b->pc) % mm->page_hash_size;
    pp = &mm->page_hash[bucket];
    while (*pp && *pp != b)
        pp = &(*pp)->page_next;
    if (*pp)
        *pp = b->page_next;
    if (mm->page_hash[bucket] == NULL)
        __atomic_store_n(&mm->bucket_page[bucket], 0, __ATOMIC_RELEASE);
}

// Incoming chain slots, stored behind the map array.
static struct jit_block_ext *block_ext(struct jit_block *b) {
    return (struct jit_block_ext *) &b->map[b->nmap];
}

static void block_free(struct jit_block *b) {
    if (b->rx)
        free(block_ext(b)->in_slots);
    free(b->map);
    free(b);
}

// False when the host is out of memory; the caller frees the block.
bool jit_block_insert(struct jit_mm *mm, struct jit_block *b, struct jit_chunk *c) {
    // grow the map allocation to hold the ext struct
    struct jit_map_entry *map = mem_host_alloc_fails() ? NULL : realloc(b->map, b->nmap * sizeof(*b->map) + sizeof(struct jit_block_ext));
    if (map == NULL)
        return false;
    b->map = map;
    memset(block_ext(b), 0, sizeof(struct jit_block_ext));
    if (c->nblocks == c->blocks_cap) {
        uint32_t cap = c->blocks_cap ? c->blocks_cap * 2 : 256;
        struct jit_block **blocks = realloc(c->blocks, cap * sizeof(*c->blocks));
        if (blocks == NULL)
            return false;
        c->blocks = blocks;
        c->blocks_cap = cap;
    }
    c->blocks[c->nblocks++] = b;
    hash_insert(mm, b);
    return true;
}

static void insert_negative(struct jit_mm *mm, addr_t pc) {
    struct jit_block *b = mem_host_alloc_fails() ? NULL : calloc(1, sizeof(*b));
    if (b == NULL)
        return;   // no negative entry: the lookup just misses again
    b->pc = pc;
    b->end = pc + 4;
    hash_insert(mm, b);
}

// ---------------------------------------------------------------------------
// Code allocation and patching
// ---------------------------------------------------------------------------
static void invalidate_block_locked(struct jit_mm *mm, struct jit_block *b);
#define JIT_VENEER_WORDS (16 * 1024)
static _Atomic uint64_t global_epoch = 1;
// An address space may hold three quarters of the arena. Chunks beyond the
// +-128 MB window around its first chunk are reached through veneers or
// far_chain. (A 56-chunk cap made Firefox's main process, whose code is
// about 250 MB, retire and retranslate all the time.)
static size_t max_chunks_per_mm = JIT_WINDOW_CHUNKS - 4;

// Throw away all translations of this address space. Their memory is freed
// by reclaim() once every thread of the mm has been back in the dispatcher.
// Called with mm->lock held, from the dispatcher (never from inside JIT code).
static void retire_all_locked(struct jit_mm *mm) {
    for (struct jit_chunk *c = mm->chunks; c; c = c->next) {
        for (size_t i = 0; i < c->nblocks; i++) {
            struct jit_block *b = c->blocks[i];
            if (!b->invalid) {
                hash_remove(mm, b);
                b->invalid = true;
                jit_patch_branch(b->rx, b->reentry);
            }
        }
    }
    // negative entries
    for (size_t i = 0; i < mm->hash_size; i++) {
        struct jit_block *b = mm->hash[i];
        while (b) {
            struct jit_block *n = b->hash_next;
            b->invalid = true;
            b->dead_next = mm->dead;
            mm->dead = b;
            b = n;
        }
        __atomic_store_n(&mm->hash[i], NULL, __ATOMIC_RELEASE);
    }
    memset(mm->page_hash, 0, mm->page_hash_size * sizeof(*mm->page_hash));
    memset(mm->bucket_page, 0, mm->page_hash_size * sizeof(*mm->bucket_page));
    mm->nblocks = 0;
    for (size_t i = 0; i < ((size_t) 1 << JIT_ITAB_BITS); i++) {
        struct jit_itab_entry *e = &mm->itab[i];
        if (e->pc != ITAB_EMPTY_PC)
            itab_clear(e);
    }
    struct jit_chunk *last = mm->chunks;
    if (last) {
        while (last->next)
            last = last->next;
        last->next = mm->retired;
        mm->retired = mm->chunks;
    }
    mm->chunks = NULL;
    mm->nchunks = 0;
    mm->cur = mm->cur_end = NULL;
    mm->retired_epoch = atomic_fetch_add(&global_epoch, 1) + 1;
    atomic_fetch_add(&mm->gen, 1);
    mm->stats_flush++;
}

// Retire a chunk: the oldest one (FIFO code cache), or one whose veneers ran
// out. Its blocks are invalidated like self-modified code, and chain slots
// inside it are dropped from the incoming-slot lists of the blocks that stay.
static void retire_chunk_locked(struct jit_mm *mm, struct jit_chunk *old) {
    struct jit_chunk **pp = &mm->chunks;
    while (*pp && *pp != old)
        pp = &(*pp)->next;
    if (*pp == NULL)
        return;
    if (old == mm->chunks && old->next == NULL) {
        retire_all_locked(mm);
        return;
    }
    if (old == mm->chunks)
        mm->cur = mm->cur_end = NULL;   // the next block starts a new chunk
    *pp = old->next;
    mm->nchunks--;
    for (size_t i = 0; i < old->nblocks; i++)
        if (!old->blocks[i]->invalid)
            invalidate_block_locked(mm, old->blocks[i]);
    uint32_t *lo = old->rx, *hi = old->rx + old->size / 4;
    for (struct jit_chunk *c = mm->chunks; c; c = c->next) {
        for (size_t i = 0; i < c->nblocks; i++) {
            struct jit_block *b = c->blocks[i];
            if (!b->rx)
                continue;
            struct jit_block_ext *x = block_ext(b);
            uint32_t k = 0;
            for (uint32_t j = 0; j < x->nin; j++)
                if (x->in_slots[j] < lo || x->in_slots[j] >= hi)
                    x->in_slots[k++] = x->in_slots[j];
            x->nin = k;
        }
    }
    old->next = mm->retired;
    mm->retired = old;
    mm->retired_epoch = atomic_fetch_add(&global_epoch, 1) + 1;
    atomic_fetch_add(&mm->gen, 1);
    mm->stats_flush++;
}

static void retire_oldest_locked(struct jit_mm *mm) {
    struct jit_chunk *c = mm->chunks;
    if (c == NULL)
        return;
    while (c->next)
        c = c->next;
    retire_chunk_locked(mm, c);
}

static void chunk_destroy(struct jit_chunk *c) {
    jit_chunk_unregister(c);
    for (size_t i = 0; i < c->nblocks; i++)
        block_free(c->blocks[i]);
    free(c->blocks);
    jit_codemem_free_chunk(c->rx, c->size);
    free(c);
}

// True if a thread of this mm may still be inside code or blocks that were
// retired at `epoch` (it has not been back in the dispatcher since).
static bool mm_busy(struct jit_mm *mm, uint64_t epoch) {
    bool busy = false;
    pthread_mutex_lock(&reg_lock);
    for (struct jit_ctx *c = reg_head; c; c = c->reg_next)
        if (c->mm == mm && c->in_jit && c->epoch < epoch)
            busy = true;
    pthread_mutex_unlock(&reg_lock);
    return busy;
}

static void free_dead(struct jit_block *b, struct ss_entry *e) {
    while (b) {
        struct jit_block *n = b->dead_next;
        free(b);
        b = n;
    }
    while (e) {
        struct ss_entry *n = e->next;
        free(e->block);
        free(e);
        e = n;
    }
}

// Free retired chunks, dead negative entries and dead single-step blocks once no
// thread of this mm can still be using them. Dead entries go through a pending
// list stamped with an epoch, so the ones that keep coming don't hold back the
// ones that are already safe to free.
static void reclaim(struct jit_mm *mm) {
    pthread_mutex_lock(&mm->lock);
    uint64_t retired_epoch = mm->retired_epoch, dead_epoch = mm->dead_epoch;
    bool retired = mm->retired != NULL, pending = mm->dead_pending != NULL || mm->ss_pending != NULL;
    pthread_mutex_unlock(&mm->lock);
    struct jit_chunk *c = NULL;
    struct jit_block *dead = NULL;
    struct ss_entry *ss = NULL;
    if (retired && !mm_busy(mm, retired_epoch)) {
        pthread_mutex_lock(&mm->lock);
        // a chunk retired meanwhile has a newer epoch: wait for the next pass
        if (mm->retired_epoch == retired_epoch) {
            c = mm->retired;
            mm->retired = NULL;
        }
        pthread_mutex_unlock(&mm->lock);
    }
    if (pending && !mm_busy(mm, dead_epoch)) {
        pthread_mutex_lock(&mm->lock);
        if (mm->dead_epoch == dead_epoch) {
            dead = mm->dead_pending;
            ss = mm->ss_pending;
            mm->dead_pending = NULL;
            mm->ss_pending = NULL;
        }
        pthread_mutex_unlock(&mm->lock);
    }
    pthread_mutex_lock(&mm->lock);
    if (mm->dead_pending == NULL && mm->ss_pending == NULL && (mm->dead != NULL || mm->ss_jetsam != NULL)) {
        mm->dead_pending = mm->dead;
        mm->ss_pending = mm->ss_jetsam;
        mm->dead = NULL;
        mm->ss_jetsam = NULL;
        mm->dead_epoch = atomic_fetch_add(&global_epoch, 1) + 1;
    }
    pthread_mutex_unlock(&mm->lock);
    while (c) {
        struct jit_chunk *n = c->next;
        chunk_destroy(c);
        c = n;
    }
    free_dead(dead, ss);
}

// The arena is full: retire the oldest chunk of the address space that ran
// least recently, so an idle process (a background Firefox content process,
// a parked shell) gives up its code before the active one evicts its own hot
// code. No lock held on entry.
static void evict_for(struct jit_mm *self) {
    struct jit_mm *victim = NULL;
    pthread_mutex_lock(&mm_list_lock);
    for (struct jit_mm *m = mm_list; m; m = m->list_next)
        if (m->nchunks > 0 && (victim == NULL || m->last_active < victim->last_active))
            victim = m;
    if (victim && victim != self && pthread_mutex_trylock(&victim->lock) == 0) {
        retire_oldest_locked(victim);
        pthread_mutex_unlock(&victim->lock);
    } else {
        victim = self;
        pthread_mutex_lock(&self->lock);
        retire_oldest_locked(self);
        pthread_mutex_unlock(&self->lock);
    }
    reclaim(victim);   // frees it now unless one of its threads is inside JIT code
    pthread_mutex_unlock(&mm_list_lock);   // (held: keeps victim from being freed)
}

uint32_t *jit_alloc_code(struct jit_mm *mm, uint32_t nwords, struct jit_chunk **chunk) {
    if (mm->cur == NULL || mm->cur + nwords > mm->cur_end) {
        size_t size;
        size_t cap = jit_code_size() / (2u << 20) * 3 / 4;
        if (cap < max_chunks_per_mm)
            cap = max_chunks_per_mm;
        if (mm->nchunks >= cap)
            retire_oldest_locked(mm);
        uint32_t *rx = jit_codemem_alloc_chunk(&size, mm->anchor);
        if (rx && !mm->anchor)
            mm->anchor = rx;
        if (rx == NULL)
            return NULL;   // arena full: the caller evicts (evict_for) and retries
        struct jit_chunk *c = mem_host_alloc_fails() ? NULL : calloc(1, sizeof(*c));
        if (c == NULL) {
            if (mm->anchor == rx && mm->nchunks == 0)
                mm->anchor = NULL;
            jit_codemem_free_chunk(rx, size);
            return NULL;
        }
        c->rx = rx;
        c->size = size;
        c->mm = mm;
        jit_write_begin();
        uint32_t used = jit_emit_trampolines(c, jit_rw(rx), rx);
        jit_write_end(rx, used * 4);
        if (used == 0) {   // out of host memory while emitting them
            free(c);
            if (mm->anchor == rx && mm->nchunks == 0)
                mm->anchor = NULL;
            jit_codemem_free_chunk(rx, size);
            return NULL;
        }
        c->next = mm->chunks;
        mm->chunks = c;
        mm->nchunks++;
        mm->cur = rx + ((used + 15) & ~15u);
        // the last 64 KB hold far-jump veneers for chains more than 128 MB away
        mm->cur_end = rx + size / 4 - JIT_VENEER_WORDS;
        c->veneer_next = mm->cur_end;
        c->veneer_end = rx + size / 4;
        jit_chunk_register(c);
        if (mm->cur + nwords > mm->cur_end)
            return NULL;
    }
    uint32_t *p = mm->cur;
    mm->cur += (nwords + 3) & ~3u;
    *chunk = mm->chunks;
    return p;
}

void jit_patch_branch(uint32_t *slot_rx, uint32_t *target_rx) {
    int64_t woff = target_rx - slot_rx;
    uint32_t insn = (woff >= -(1 << 25) && woff < (1 << 25)) ? e_b((int32_t) woff) : e_nop();
    jit_write_begin();
    __atomic_store_n(jit_rw(slot_rx), insn, __ATOMIC_RELEASE);
    jit_write_end(slot_rx, 4);
}

// Patch one word without the trailing barrier (callers batch: write_begin,
// N x patch_word_nosync, write_end-style sync).
// Patched words are collected and their cache lines maintained in one batch
// (one barrier for all of them) by patch_flush().
#define PATCH_BATCH 256
static __thread uint32_t *patch_q[PATCH_BATCH];
static __thread unsigned patch_n;

static void patch_flush(void) {
    if (patch_n == 0)
        return;
    for (unsigned i = 0; i < patch_n; i++)
        __asm__ volatile("dc cvau, %0" :: "r"(jit_rw(patch_q[i])) : "memory");
    __asm__ volatile("dsb ish" ::: "memory");
    for (unsigned i = 0; i < patch_n; i++)
        __asm__ volatile("ic ivau, %0" :: "r"(patch_q[i]) : "memory");
    __asm__ volatile("dsb ish\n isb" ::: "memory");
    patch_n = 0;
}

static void patch_word_nosync(uint32_t *rx, uint32_t insn) {
    __atomic_store_n(jit_rw(rx), insn, __ATOMIC_RELEASE);
    if (patch_n == PATCH_BATCH)
        patch_flush();
    patch_q[patch_n++] = rx;
}

static void unlink_block_locked(struct jit_mm *mm, struct jit_block *b) {
    struct jit_block **pp = &mm->hash[pc_hash(b->pc, mm->hash_size)];
    while (*pp && *pp != b)
        pp = &(*pp)->hash_next;
    if (*pp) {
        *pp = b->hash_next;
        mm->nblocks--;
    }
}

// Caller holds mm->lock, has called jit_write_begin and calls
// jit_write_end afterwards; b is already off the page list.
static void invalidate_block_nosync(struct jit_mm *mm, struct jit_block *b) {
    unlink_block_locked(mm, b);
    b->invalid = true;
    struct jit_itab_entry *e = &mm->itab[(b->pc >> 2) & ((1 << JIT_ITAB_BITS) - 1)];
    if (e->pc == b->pc)
        itab_clear(e);
    if (b->rx) {
        int64_t woff = b->reentry - b->rx;
        patch_word_nosync(b->rx, e_b((int32_t) woff));
        struct jit_block_ext *x = block_ext(b);
        for (uint32_t i = 0; i < x->nin; i++)
            patch_word_nosync(x->in_slots[i], e_nop());
        mm->stats_inval_blocks++;
        mm->stats_inval_slots += x->nin;
        x->nin = 0;
    } else {
        b->dead_next = mm->dead;   // negative entry: freed by reclaim (lock-free readers)
        mm->dead = b;
    }
}

static void invalidate_block_locked(struct jit_mm *mm, struct jit_block *b) {
    hash_remove(mm, b);
    b->invalid = true;
    struct jit_itab_entry *e = &mm->itab[(b->pc >> 2) & ((1 << JIT_ITAB_BITS) - 1)];
    if (e->pc == b->pc)
        itab_clear(e);
    if (b->rx) {
        jit_patch_branch(b->rx, b->reentry);
        struct jit_block_ext *x = block_ext(b);
        for (uint32_t i = 0; i < x->nin; i++) {
            jit_write_begin();
            __atomic_store_n(jit_rw(x->in_slots[i]), e_nop(), __ATOMIC_RELEASE);
            jit_write_end(x->in_slots[i], 4);
        }
        x->nin = 0;
    } else {
        b->dead_next = mm->dead;   // negative entry: freed by reclaim (lock-free readers)
        mm->dead = b;
    }
}

struct jit_block *jit_lookup_locked(struct jit_mm *mm, addr_t pc) {
    return lookup_locked(mm, pc);
}
void jit_invalidate_block_locked(struct jit_mm *mm, struct jit_block *b) {
    invalidate_block_locked(mm, b);
}

static void ss_invalidate_locked(struct jit_mm *mm, page_t start, page_t end) {
    for (size_t i = 0; i < mm->ss_size; i++) {
        struct ss_entry **pp = &mm->ss_hash[i];
        while (*pp) {
            struct ss_entry *e = *pp;
            if (PAGE(e->pc) >= start && PAGE(e->pc) < end) {
                *pp = e->next;
                if (--mm->ss_count == 0)
                    __atomic_store_n(&mm->ss_bloom, 0, __ATOMIC_RELEASE);
                e->next = mm->ss_jetsam;
                mm->ss_jetsam = e;
            } else {
                pp = &e->next;
            }
        }
    }
}

// The address space is being torn down (mm_release dropped the last
// reference and mem_destroy is unmapping everything). Every struct mem lives
// in a struct mm (kernel/mmap.c). Nothing can run this code any more, and the
// whole jit_mm is freed right after, so skip the per-page invalidation.
static bool mm_dying(struct jit_mm *mm) {
    struct mem *mem = container_of(mm->mmu, struct mem, mmu);
    struct mm *kmm = container_of(mem, struct mm, mem);
    return atomic_load_explicit(&kmm->refcount, memory_order_relaxed) == 0;
}

void jit_invalidate_range(struct jit_mm *mm, page_t start, page_t end) {
    if (mm == NULL || mm_dying(mm))
        return;
    if (end - start <= 64) {
        bool any = false;
        for (page_t p = start; p < end && !any; p++)
        {
            // exact unless the bucket holds blocks of several pages
            uint64_t bp = __atomic_load_n(&mm->bucket_page[p % mm->page_hash_size], __ATOMIC_ACQUIRE);
            any = bp == ~0ull || bp == p + 1;
        }
        uint64_t bloom = __atomic_load_n(&mm->ss_bloom, __ATOMIC_RELAXED);
        for (page_t p = start; p < end && !any && bloom; p++)
            any = (bloom >> (p & 63)) & 1;
        if (!any)
            return;
    }
    pthread_mutex_lock(&mm->lock);
    uint64_t t0 = jit_stats ? clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) : 0;
    bool did = false;
    if (end - start > mm->page_hash_size) {
        for (size_t i = 0; i < mm->page_hash_size; i++) {
            struct jit_block *b = mm->page_hash[i];
            while (b) {
                struct jit_block *n = b->page_next;
                if (PAGE(b->pc) >= start && PAGE(b->pc) < end) {
                    invalidate_block_locked(mm, b);
                    did = true;
                }
                b = n;
            }
        }
    } else {
        jit_write_begin();
        for (page_t p = start; p < end; p++) {
            size_t bucket = p % mm->page_hash_size;
            struct jit_block **pp = &mm->page_hash[bucket];
            while (*pp) {
                struct jit_block *b = *pp;
                if (PAGE(b->pc) == p) {
                    *pp = b->page_next;
                    invalidate_block_nosync(mm, b);
                    did = true;
                } else {
                    pp = &b->page_next;
                }
            }
            if (mm->page_hash[bucket] == NULL)
                __atomic_store_n(&mm->bucket_page[bucket], 0, __ATOMIC_RELEASE);
        }
        patch_flush();
        jit_write_finish();
    }
    ss_invalidate_locked(mm, start, end);
    if (did) {
        atomic_fetch_add(&mm->gen, 1);
        mm->stats_inval++;
    }
    if (jit_stats)
        mm->stats_inval_ns += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - t0;
    pthread_mutex_unlock(&mm->lock);
}

void jit_invalidate_all(struct jit_mm *mm) {
    jit_invalidate_range(mm, 0, BAD_PAGE);
}

// ---------------------------------------------------------------------------
// Trampolines
// ---------------------------------------------------------------------------
#define CPU_FP_OFF (offsetof(struct jit_ctx, cpu) + offsetof(struct cpu_state, fp))

// Save/restore every guest register that lives in a host register, using
// stp/ldp where two consecutive guest registers sit in consecutive host ones.
static void emit_gprs(struct asmbuf *b, bool store, int skip_host) {
    for (int g = 0; g < 31; g++) {
        int h = jit_g2h[g];
        if (h < 0 || h == skip_host)
            continue;
        if (g + 1 < 31 && jit_g2h[g + 1] == h + 1 && h + 1 != skip_host && (CTX_REG(g) % 8) == 0) {
            ab_put(b, store ? e_stp_x(h, h + 1, HR_CTX, CTX_REG(g)) : e_ldp_x(h, h + 1, HR_CTX, CTX_REG(g)));
            g++;
        } else {
            ab_put(b, store ? e_str_x(h, HR_CTX, CTX_REG(g)) : e_ldr_x(h, HR_CTX, CTX_REG(g)));
        }
    }
}

static void emit_save(struct asmbuf *b, int skip_host) {
    emit_gprs(b, true, skip_host);
    ab_put(b, e_str_x(HR_SP, HR_CTX, CTX_OFF(cpu.sp)));
    ab_put(b, e_mrs_nzcv(HR_T0));
    ab_put(b, e_str_w(HR_T0, HR_CTX, CTX_OFF(cpu.nzcv)));
    ab_put(b, e_mrs_fpsr(HR_T0));
    ab_put(b, e_str_w(HR_T0, HR_CTX, CTX_OFF(cpu.fpsr)));
    ab_put(b, e_add_imm(HR_T0, HR_CTX, CPU_FP_OFF, 0));
    for (int v = 0; v < 32; v += 2)
        ab_put(b, e_stp_q(v, v + 1, HR_T0, v * 16));
}

static void emit_restore(struct asmbuf *b) {
    ab_put(b, e_add_imm(HR_T0, HR_CTX, CPU_FP_OFF, 0));
    for (int v = 0; v < 32; v += 2)
        ab_put(b, e_ldp_q(v, v + 1, HR_T0, v * 16));
    ab_put(b, e_ldr_w(HR_T0, HR_CTX, CTX_OFF(cpu.nzcv)));
    ab_put(b, e_msr_nzcv(HR_T0));
    ab_put(b, e_ldr_w(HR_T0, HR_CTX, CTX_OFF(cpu.fpsr)));
    ab_put(b, e_msr_fpsr(HR_T0));
    ab_put(b, e_ldr_x(HR_SP, HR_CTX, CTX_OFF(cpu.sp)));
    emit_gprs(b, false, -1);
}

static void emit_mov64(struct asmbuf *b, int rd, uint64_t v) {
    ab_put(b, e_movz(rd, v & 0xffff, 0));
    for (int i = 1; i < 4; i++)
        if ((v >> (16 * i)) & 0xffff)
            ab_put(b, e_movk(rd, (v >> (16 * i)) & 0xffff, i));
}

uint64_t jit_helper(struct jit_ctx *ctx);

uint32_t jit_emit_trampolines(struct jit_chunk *c, uint32_t *rw, uint32_t *rx) {
    struct asmbuf b = {0};
    // enter(ctx = x0, code = x1)
    uint32_t enter = b.n;
    ab_put(&b, e_sub_imm(31, 31, 0xa0, 0));
    for (int i = 0; i < 6; i++)
        ab_put(&b, e_stp_x(19 + 2 * i, 20 + 2 * i, 31, 16 * i));
    for (int i = 0; i < 4; i++)
        ab_put(&b, e_stp_d(8 + 2 * i, 9 + 2 * i, 31, 96 + 16 * i));
    ab_put(&b, e_mov(HR_CTX, 0));
    ab_put(&b, e_mov(HR_T2, 1));
    ab_put(&b, e_add_imm(9, 31, 0, 0));
    ab_put(&b, e_str_x(9, HR_CTX, CTX_OFF(host_sp)));
    ab_put(&b, e_mrs_fpcr(9));
    ab_put(&b, e_str_x(9, HR_CTX, CTX_OFF(host_fpcr)));
    ab_put(&b, e_ldr_w(9, HR_CTX, CTX_OFF(guest_fpcr_masked)));
    ab_put(&b, e_msr_fpcr(9));
    emit_restore(&b);
    ab_put(&b, e_br(HR_T2));

    // exit_chain: T0 = pc, T1 = slot
    uint32_t exit_chain = b.n;
    ab_put(&b, e_str_x(HR_T1, HR_CTX, CTX_OFF(exit_slot)));
    ab_put(&b, e_movz(HR_T2, JR_CHAIN, 0));
    // exit_pc: T0 = pc, T2 = reason
    uint32_t exit_pc = b.n;
    ab_put(&b, e_str_x(HR_T0, HR_CTX, CTX_OFF(cpu.pc)));
    ab_put(&b, e_str_x(HR_T2, HR_CTX, CTX_OFF(reason)));
    emit_save(&b, -1);
    // exit_saved
    uint32_t exit_saved = b.n;
    ab_put(&b, e_ldr_x(9, HR_CTX, CTX_OFF(host_fpcr)));
    ab_put(&b, e_msr_fpcr(9));
    ab_put(&b, e_ldr_x(9, HR_CTX, CTX_OFF(host_sp)));
    ab_put(&b, e_add_imm(31, 9, 0, 0));
    for (int i = 0; i < 6; i++)
        ab_put(&b, e_ldp_x(19 + 2 * i, 20 + 2 * i, 31, 16 * i));
    for (int i = 0; i < 4; i++)
        ab_put(&b, e_ldp_d(8 + 2 * i, 9 + 2 * i, 31, 96 + 16 * i));
    ab_put(&b, e_add_imm(31, 31, 0xa0, 0));
    ab_put(&b, e_ldr_x(0, HR_CTX, CTX_OFF(reason)));
    ab_put(&b, e_ret());

    // far_chain: a direct-branch exit to a block more than 128 MB away once
    // the chunk's veneers are used up. T0 = pc, T1 = slot. The target is
    // looked up in the indirect table without leaving JIT code (chains must
    // not exit, see chain()); a miss exits like exit_chain.
    uint32_t far_chain = b.n;
    ab_put(&b, e_str_x(HR_T1, HR_CTX, CTX_OFF(exit_slot)));
    ab_put(&b, e_ldr_x(HR_T1, HR_CTX, CTX_OFF(itab)));
    ab_put(&b, e_ubfx(HR_T2, HR_T0, 2, JIT_ITAB_BITS));
    ab_put(&b, e_add_sh(HR_T1, HR_T1, HR_T2, 0, 4));
    ab_put(&b, e_ldp_x(HR_T2, HR_T1, HR_T1, 0));
    ab_put(&b, e_eor_sh(HR_T2, HR_T2, HR_T0, 0, 0));
    ab_put(&b, e_cbnz_x(HR_T2, 2));
    ab_put(&b, e_br(HR_T1));
    ab_put(&b, e_movz(HR_T2, JR_CHAIN, 0));
    ab_put(&b, e_b((int32_t) exit_pc - (int32_t) b.n));

    // helper: T2 = literal pointer, T0 = argument. helper_stub: the same,
    // entered from a TLB stub: x30 is the return address into the block, and
    // the block already stored guest x30 in its slot before the bl.
    uint32_t helper = 0, helper_stub = 0;
    for (int from_stub = 0; from_stub <= 1; from_stub++) {
        if (from_stub)
            helper_stub = b.n;
        else
            helper = b.n;
        ab_put(&b, e_str_x(HR_T2, HR_CTX, CTX_OFF(helper_ret)));
        ab_put(&b, e_str_x(HR_T0, HR_CTX, CTX_OFF(helper_arg)));
        if (from_stub)
            ab_put(&b, e_str_x(30, HR_CTX, CTX_OFF(lr_save)));
        emit_save(&b, from_stub ? 30 : -1);
        ab_put(&b, e_mov(19, HR_CTX));
        ab_put(&b, e_mov(0, HR_CTX));
        emit_mov64(&b, 9, (uint64_t) (uintptr_t) jit_helper);
        ab_put(&b, e_blr(9));
        ab_put(&b, e_mov(HR_CTX, 19));
        uint32_t cb = b.n;
        ab_put(&b, e_cbnz_w(0, (int32_t) exit_saved - (int32_t) cb));
        emit_restore(&b);
        if (from_stub)
            ab_put(&b, e_ldr_x(30, HR_CTX, CTX_OFF(lr_save)));
        ab_put(&b, e_ldr_x(HR_T0, HR_CTX, CTX_OFF(helper_arg)));   // the compact load path reuses T0
        ab_put(&b, e_ldr_x(HR_T1, HR_CTX, CTX_OFF(helper_result)));
        ab_put(&b, e_ldr_x(HR_T2, HR_CTX, CTX_OFF(helper_ret)));
        ab_put(&b, e_add_imm(HR_T2, HR_T2, 4, 0));
        ab_put(&b, e_br(HR_T2));
    }

    // TLB-lookup stubs (see JIT_STUB): in T0 or x15 = guest address, out
    // T1 = addend; clobbers T2. A miss calls the helper, which finds the
    // guest PC through the return address in x30. A page-crossing store is
    // done into the bounce buffer and written back ("committed") lazily: the
    // helper empties this thread's TLB, so the next access of any kind
    // misses and commits first (JH_MEM), and the dispatcher commits on exit.
    static const int stub_size[JIT_STUB_SIZES] = {1, 2, 4, 8, 16, 32};
    uint32_t stub_at[JIT_NSTUBS];
    for (int szi = 0; szi < JIT_STUB_SIZES; szi++) {
        for (int atomic = 0; atomic <= 1; atomic++) {
            for (int sp = 0; sp <= 1; sp++) {
                for (int write = 0; write <= 1; write++) {
                    int A = sp ? HR_SP : HR_T0, size = stub_size[szi];
                    stub_at[JIT_STUB(szi, atomic, sp, write)] = b.n;
                    ab_put(&b, e_eor_sh(HR_T1, A, A, 1, 13));
                    ab_put(&b, e_ubfx(HR_T1, HR_T1, 12, JIT_TLB_BITS));
                    ab_put(&b, e_add_sh(HR_T1, HR_CTX, HR_T1, 0, 5));
                    ab_put(&b, e_ldr_x(HR_T2, HR_T1, JIT_TLB_OFF + (write ? 8 : 0)));
                    ab_put(&b, e_sub_sh(HR_T2, A, HR_T2, 0, 0));
                    if (size > 1)
                        ab_put(&b, e_add_imm(HR_T2, HR_T2, size - 1, 0));
                    ab_put(&b, e_lsr(HR_T2, HR_T2, 12));
                    ab_put(&b, e_cbnz_x(HR_T2, 3));
                    ab_put(&b, e_ldr_x(HR_T1, HR_T1, JIT_TLB_OFF + 16));
                    ab_put(&b, e_ret());
                    // miss
                    uint32_t desc = size | (write << 8) | (atomic << 9) | (1 << 10) | (A << 11) | (1 << 16);
                    ab_put(&b, e_adr(HR_T2, 8));
                    ab_put(&b, e_b((int32_t) helper_stub - (int32_t) b.n));
                    ab_put(&b, JH_MEM | (desc << 2));
                    ab_put(&b, e_ret());
                }
            }
        }
    }

    if (b.oom) {
        free(b.w);
        return 0;
    }
    memcpy(rw, b.w, b.n * 4);
    for (int k = 0; k < JIT_NSTUBS; k++)
        c->t_stub[k] = rx + stub_at[k];
    c->t_enter = rx + enter;
    c->t_exit_chain = rx + exit_chain;
    c->t_far_chain = rx + far_chain;
    c->t_exit_pc = rx + exit_pc;
    c->t_exit_saved = rx + exit_saved;
    c->t_helper = rx + helper;
    uint32_t n = b.n;
    free(b.w);
    return n;
}

// ---------------------------------------------------------------------------
// TLB fill and slow-path helpers
// ---------------------------------------------------------------------------
static inline unsigned jtlb_index(addr_t addr) {
    return ((addr >> 12) ^ (addr >> 25)) & (JIT_TLB_SIZE - 1);
}

static void check_changes(struct jit_ctx *ctx) {
    uint64_t ch = __atomic_load_n(&ctx->mm->mmu->changes, __ATOMIC_ACQUIRE);
    if (ch != ctx->mem_changes) {
        tlb_flush_ctx(ctx);
        ctx->mem_changes = ch;
        if (jit_stats && ctx->mm)
            ctx->mm->stats_tlb_flush++;
    }
}

// Returns host pointer for addr, filling the TLB. NULL = fault.
static void *jtlb_fill(struct jit_ctx *ctx, addr_t addr, int type) {
    struct mmu *mmu = ctx->mm->mmu;
    check_changes(ctx);
    addr_t page = addr & ~(addr_t) (PAGE_SIZE - 1);
    char *ptr = mmu_translate(mmu, page, type);
    if (__atomic_load_n(&mmu->changes, __ATOMIC_ACQUIRE) != ctx->mem_changes) {
        check_changes(ctx);
        ptr = mmu_translate(mmu, page, type);
        ctx->mem_changes = __atomic_load_n(&mmu->changes, __ATOMIC_ACQUIRE);
    }
    if (ptr == NULL)
        return NULL;
    unsigned idx = jtlb_index(addr);
    struct jit_tlb_entry *e = &ctx->tlbe[idx];
    if (e->page_r == 1 && e->page_w == 1) {
        if (ctx->nfilled < JIT_FILLED_MAX)
            ctx->filled[ctx->nfilled] = idx;
        ctx->nfilled++;
    }
    e->page_r = page;
    e->addend = (uintptr_t) ptr - page;
    if (type == MEM_WRITE) {
        e->page_w = page;
    } else if (mmu->ops->translate_write_nofault) {
        e->page_w = mmu->ops->translate_write_nofault(mmu, page) ? page : 1;
    } else {
        e->page_w = 1;
    }
    return ptr + PGOFFSET(addr);
}

static struct jit_block *block_at(struct jit_chunk *c, uintptr_t pc);

// Guest PC of the instruction whose slow path called the helper.
static addr_t helper_pc(struct jit_ctx *ctx, uint32_t gi) {
    uintptr_t ret = ctx->helper_ret;
    struct jit_chunk *c = jit_chunk_of(ret);
    pthread_mutex_lock(&ctx->mm->lock);
    struct jit_block *b = c ? block_at(c, ret) : NULL;
    addr_t pc = b ? b->pc + 4 * gi : 0;
    pthread_mutex_unlock(&ctx->mm->lock);
    return pc;
}

static uint64_t guest_fault(struct jit_ctx *ctx, addr_t addr, bool write, uint32_t gi) {
    addr_t pc = helper_pc(ctx, gi);
    if (ctx->helper_from_stub) {
        // called from a TLB stub: the faulting load is where x30 returns to
        uintptr_t ret = ctx->lr_save;
        struct jit_chunk *c = jit_chunk_of(ret);
        pthread_mutex_lock(&ctx->mm->lock);
        struct jit_block *b = c ? block_at(c, ret) : NULL;
        pc = 0;
        if (b) {
            uint32_t off = (ret - (uintptr_t) b->rx) / 4, g = 0;
            for (uint32_t i = 0; i < b->nmap && b->map[i].host_off <= off; i++)
                g = b->map[i].guest_idx;
            pc = b->pc + 4 * g;
        }
        pthread_mutex_unlock(&ctx->mm->lock);
    }
    ctx->cpu.segfault_addr = addr;
    ctx->cpu.segfault_was_write = write;
    ctx->cpu.pc = pc;
    ctx->reason = JR_GPF;
    return 1;
}

// Write a pending page-crossing store from the bounce buffer to guest memory.
static int commit_bounce(struct jit_ctx *ctx) {
    if (!ctx->bounce_active)
        return 0;
    addr_t addr = ctx->bounce_addr;
    unsigned size = ctx->bounce_size;
    addr_t second = (addr | (PAGE_SIZE - 1)) + 1;
    unsigned part1 = second - addr;
    char *p1 = jtlb_fill(ctx, addr, MEM_WRITE);
    char *p2 = p1 ? jtlb_fill(ctx, second, MEM_WRITE) : NULL;
    ctx->bounce_active = 0;
    if (p1 == NULL || p2 == NULL)
        return -1;
    memcpy(p1, ctx->bounce, part1);
    memcpy(p2, ctx->bounce + part1, size - part1);
    return 0;
}

uint64_t jit_helper(struct jit_ctx *ctx) {
    uint32_t lit = *(uint32_t *) ctx->helper_ret;
    uint32_t kind = lit & 3, desc = (lit >> 2) & 0x3fffff, pc = lit >> 24;   // pc: guest insn index
    ctx->helper_from_stub = (desc >> 16) & 1;
    switch (kind) {
        case JH_MEM: {
            if (ctx->bounce_active && commit_bounce(ctx) != 0)
                return guest_fault(ctx, ctx->bounce_addr, true, pc);
            bool want_addend = (desc >> 10) & 1;
            int areg = (desc >> 11) & 31;
            addr_t addr = ctx->helper_arg;
            if (want_addend && areg != HR_T0) {
                // areg is a host register: find the guest register living there
                if (areg == HR_SP)
                    addr = ctx->cpu.sp;
                else
                    for (int g = 0; g < 31; g++)
                        if (jit_g2h[g] == areg)
                            addr = ctx->cpu.regs[g];
            }
            if (jit_stats)
                ctx->mm->stats_tlb_miss++;
            unsigned size = desc & 0xff;
            bool write = (desc >> 8) & 1, atomic = (desc >> 9) & 1;
            int type = write ? MEM_WRITE : MEM_READ;
            ctx->bounce_active = 0;
            if (PGOFFSET(addr) + size <= PAGE_SIZE) {
                void *p = jtlb_fill(ctx, addr, type);
                if (p == NULL)
                    return guest_fault(ctx, addr, write, pc);
                ctx->helper_result = want_addend ? (uint64_t) p - addr : (uint64_t) p;
                return 0;
            }
            if (atomic)
                return guest_fault(ctx, addr, write, pc);
            addr_t second = (addr | (PAGE_SIZE - 1)) + 1;
            unsigned part1 = second - addr;
            char *p1 = jtlb_fill(ctx, addr, type);
            if (p1 == NULL)
                return guest_fault(ctx, addr, write, pc);
            char *p2 = jtlb_fill(ctx, second, type);
            if (p2 == NULL)
                return guest_fault(ctx, second, write, pc);
            if (jit_stats)
                ctx->mm->stats_bounce++;
            if (!write) {
                memcpy(ctx->bounce, p1, part1);
                memcpy(ctx->bounce + part1, p2, size - part1);
            } else {
                ctx->bounce_active = 1;
                ctx->bounce_addr = addr;
                ctx->bounce_size = size;
                // A TLB stub can't commit after the store: empty the TLB so
                // the next access misses and commits first. Inline slow
                // paths commit right after the store (JH_COMMIT).
                if (ctx->helper_from_stub)
                    tlb_flush_ctx(ctx);
            }
            ctx->helper_result = want_addend ? (uint64_t) ctx->bounce - addr : (uint64_t) ctx->bounce;
            return 0;
        }
        case JH_COMMIT:
            if (commit_bounce(ctx) != 0)
                return guest_fault(ctx, ctx->bounce_addr, true, pc);
            return 0;
        case JH_FLUSH:
            check_changes(ctx);
            return 0;
    }
    abort();
}

// Guest code from pc up to the end of its page (at most max words), read in
// place: a guest page is contiguous host memory, and the translator reads
// each word once (copying it cost 4% of a vite build).
int jit_fetch_code(struct jit_ctx *ctx, addr_t pc, const uint32_t **code, int max) {
    int n = (int) ((PAGE_SIZE - PGOFFSET(pc)) / 4);
    if (n > max)
        n = max;
    struct tlb *tlb = ctx->tlb;
    if (tlb->mem_changes != __atomic_load_n(&tlb->mmu->changes, __ATOMIC_ACQUIRE))
        tlb_flush(tlb);
    void *p = __tlb_read_ptr(tlb, pc);
    if (p == NULL)
        return 0;
    *code = p;
    return n;
}

// ---------------------------------------------------------------------------
// Gadget single-step fallback
// ---------------------------------------------------------------------------
static struct fiber_block *ss_get(struct jit_mm *mm, addr_t pc, struct tlb *tlb) {
    size_t h = pc_hash(pc, mm->ss_size);
    pthread_mutex_lock(&mm->lock);
    for (struct ss_entry *e = mm->ss_hash[h]; e; e = e->next) {
        if (e->pc == pc) {
            struct fiber_block *b = e->block;
            pthread_mutex_unlock(&mm->lock);
            return b;
        }
    }
    uint64_t gen = atomic_load(&mm->gen);
    pthread_mutex_unlock(&mm->lock);

    struct gen_state state;
    gen_start(pc, &state);
    gen_step(&state, tlb);
    gen_exit(&state);
    gen_end(&state);
    struct fiber_block *block = state.block;

    pthread_mutex_lock(&mm->lock);
    struct ss_entry *e = mem_host_alloc_fails() ? NULL : malloc(sizeof(*e));
    if (e == NULL) {
        // Out of host memory: the block cannot be tracked, so it cannot be
        // freed later either. It is still valid for this one step.
        mm->stats_fallback++;
        pthread_mutex_unlock(&mm->lock);
        return block;
    }
    e->pc = pc;
    e->block = block;
    if (atomic_load(&mm->gen) == gen) {
        e->next = mm->ss_hash[h];
        mm->ss_hash[h] = e;
        mm->ss_count++;
        __atomic_fetch_or(&mm->ss_bloom, 1ull << (PAGE(pc) & 63), __ATOMIC_RELEASE);
    } else {
        e->next = mm->ss_jetsam;   // used once, freed by reclaim
        mm->ss_jetsam = e;
    }
    mm->stats_fallback++;
    pthread_mutex_unlock(&mm->lock);
    return block;
}

static int gadget_step(struct jit_ctx *ctx, struct tlb *tlb) {
    struct jit_mm *mm = ctx->mm;
    struct fiber_frame *frame = ctx->frame;
    for (int tries = 0; tries < 16; tries++) {
        if (tlb->mem_changes != __atomic_load_n(&tlb->mmu->changes, __ATOMIC_ACQUIRE))
            tlb_flush(tlb);
        struct fiber_block *block = ss_get(mm, ctx->cpu.pc, tlb);
        frame->cpu = ctx->cpu;
        frame->last_block = NULL;
        jit_saved_pc = ctx->cpu.pc;
        in_jit = 1;
        int interrupt = fiber_enter(block, frame, tlb);
        in_jit = 0;
        ctx->cpu = frame->cpu;
        ctx->guest_fpcr_masked = ctx->cpu.fpcr & FPCR_GUEST_MASK;   // MSR FPCR runs here
        if (interrupt != INT_JIT_CRASH)
            return interrupt;
        tlb_flush(tlb);
    }
    return INT_GPF;
}

// ---------------------------------------------------------------------------
// Dispatcher
// ---------------------------------------------------------------------------
typedef uint64_t (*enter_fn)(struct jit_ctx *ctx, uint32_t *code);

static struct jit_block *get_block_slow(struct jit_ctx *ctx, addr_t pc);

static struct jit_block *get_block(struct jit_ctx *ctx, addr_t pc) {
    struct jit_mm *mm = ctx->mm;
    uint64_t gen = atomic_load_explicit(&mm->gen, memory_order_acquire);
    size_t i = (pc >> 2) & (JIT_LC_SIZE - 1);
    if (ctx->lc[i].pc == pc && ctx->lc[i].gen == gen && ctx->lc[i].b && !ctx->lc[i].b->invalid)
        return ctx->lc[i].b;
    struct jit_block *b = get_block_slow(ctx, pc);
    // Only cache if nothing was invalidated meanwhile (b may be stale then).
    if (b && atomic_load_explicit(&mm->gen, memory_order_acquire) == gen) {
        ctx->lc[i].pc = pc;
        ctx->lc[i].b = b;
        ctx->lc[i].gen = gen;
    }
    return b;
}

static struct jit_block *lookup_lockfree(struct jit_mm *mm, addr_t pc) {
    struct jit_htpub *ht = __atomic_load_n(&mm->htpub, __ATOMIC_ACQUIRE);
    struct jit_block *b = __atomic_load_n(&ht->tab[pc_hash(pc, ht->size)], __ATOMIC_ACQUIRE);
    for (; b; b = __atomic_load_n(&b->hash_next, __ATOMIC_ACQUIRE))
        if (b->pc == pc)
            return __atomic_load_n(&b->invalid, __ATOMIC_ACQUIRE) ? NULL : b;
    return NULL;
}

static struct jit_block *get_block_slow(struct jit_ctx *ctx, addr_t pc) {
    struct jit_mm *mm = ctx->mm;
    int flushes = 0;
    struct jit_block *fast = lookup_lockfree(mm, pc);
    if (fast)
        return fast;
    for (;;) {
        pthread_mutex_lock(&mm->lock);
        struct jit_block *b = lookup_locked(mm, pc);
        uint64_t gen = atomic_load(&mm->gen);
        pthread_mutex_unlock(&mm->lock);
        if (b)
            return b;
        uint64_t t0 = jit_stats ? clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) : 0;
        b = jit_translate(mm, ctx, pc, gen, force_tier == 2 ? 2 : 1);
        if (jit_stats)
            __atomic_fetch_add(&mm->stats_translate_ns, clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - t0, __ATOMIC_RELAXED);
        if (b == (struct jit_block *) -1)
            continue;
        if (b == (struct jit_block *) -2) {
            // no code memory right now: reclaim retired chunks and retry once,
            // else run this step in the gadget engine (no negative entry)
            ctx->epoch = atomic_load(&global_epoch);
            evict_for(mm);
            reclaim(mm);
            if (flushes++ < 2)
                continue;
            return NULL;
        }
        if (b == NULL) {
            pthread_mutex_lock(&mm->lock);
            if (lookup_locked(mm, pc) == NULL)
                insert_negative(mm, pc);
            b = lookup_locked(mm, pc);
            pthread_mutex_unlock(&mm->lock);
        }
        return b;
    }
}

static void chain(struct jit_mm *mm, uint32_t *slot, uint64_t flush_gen, struct jit_block *target) {
    // Unlocked pre-check (repeated under the lock): another thread chained this
    // slot already, or the target died. Saves mm->lock round trips when many
    // threads run the same code.
    if (__atomic_load_n(slot, __ATOMIC_RELAXED) != e_nop() || __atomic_load_n(&target->invalid, __ATOMIC_RELAXED) ||
        __atomic_load_n(&mm->stats_flush, __ATOMIC_RELAXED) != flush_gen)
        return;
    pthread_mutex_lock(&mm->lock);
    if (mm->stats_flush == flush_gen && !target->invalid && target->rx && *slot == e_nop()) {
        int64_t woff = target->rx - slot;
        uint32_t *dest = target->rx;
        static int force_veneer = -1;
        if (force_veneer < 0) {
            const char *fv = getenv("ISH_JIT_FORCE_VENEER");   // testing
            force_veneer = fv ? atoi(fv) : 0;   // 1: veneers for every chain, 2: far_chain for every chain
        }
        if (force_veneer || woff < -(1 << 25) || woff >= (1 << 25)) {
            // The target chunk is too far for a b: go through a veneer
            // (ldr x13, 8; br x13; .quad target) in the slot's chunk.
            struct jit_chunk *c = jit_chunk_of((uintptr_t) slot);
            dest = NULL;
            if (c && c->mm == mm && force_veneer != 2 && c->veneer_next && c->veneer_next + 4 <= c->veneer_end) {
                uint32_t *v = c->veneer_next;
                c->veneer_next += 4;
                uint32_t *vw = jit_rw(v);
                uint64_t a = (uint64_t) target->rx;
                jit_write_begin();
                vw[0] = 0x58000040u | HR_T1;            // ldr x13, #8
                vw[1] = e_br(HR_T1);
                memcpy(&vw[2], &a, 8);
                jit_write_end(v, 16);
                dest = v;
            } else if (c && c->mm == mm) {
                // Out of veneers. An exit that keeps going through the
                // dispatcher can livelock an LDXR/STXR loop, so send this one
                // through the chunk's far_chain lookup instead: patch its
                // final `b exit_chain` (after `adr T1, slot`), and enter the
                // target in the indirect table. Nothing to undo when the
                // target is invalidated: the lookup then misses and exits.
                for (uint32_t *p = slot + 1; p < slot + 12; p++) {
                    if ((*p & 0x9f00001fu) == (0x10000000u | HR_T1)) {
                        jit_patch_branch(p + 1, c->t_far_chain);
                        struct jit_itab_entry *e = &mm->itab[(target->pc >> 2) & ((1 << JIT_ITAB_BITS) - 1)];
                        __asm__ volatile("stp %0, %1, [%2]" :: "r"(target->pc), "r"(target->rx), "r"(e) : "memory");
                        mm->stats_veneer_retire++;
                        break;
                    }
                }
            }
        }
        if (dest) {
            struct jit_block_ext *x = block_ext(target);
            if (x->nin == x->capin) {
                uint32_t cap = x->capin ? x->capin * 2 : 4;
                uint32_t **in = mem_host_alloc_fails() ? NULL : realloc(x->in_slots, cap * sizeof(*x->in_slots));
                if (in != NULL) {
                    x->in_slots = in;
                    x->capin = cap;
                }
            }
            // Out of host memory: leave the exit unchained (it still works,
            // through the dispatcher), since an unrecorded chain could not be
            // undone when the target is invalidated.
            if (x->nin < x->capin) {
                x->in_slots[x->nin++] = slot;
                jit_patch_branch(slot, dest);
            }
        }
    }
    pthread_mutex_unlock(&mm->lock);
}

static void itab_set(struct jit_mm *mm, addr_t pc, struct jit_block *b) {
    pthread_mutex_lock(&mm->lock);
    if (!b->invalid && b->rx) {
        struct jit_itab_entry *e = &mm->itab[(pc >> 2) & ((1 << JIT_ITAB_BITS) - 1)];
        __asm__ volatile("stp %0, %1, [%2]" :: "r"(pc), "r"(b->rx), "r"(e) : "memory");
    }
    pthread_mutex_unlock(&mm->lock);
}

int jit_run(struct cpu_state *cpu, struct tlb *tlb, struct jit_mm *mm) {
    struct jit_ctx *ctx = get_ctx();
    if (ctx == NULL) {
        // Out of host memory for this thread's state: fail the guest (SIGSEGV
        // at its pc), as the gadget engine does when it cannot get a frame.
        cpu->segfault_addr = cpu->pc;
        cpu->segfault_was_write = 0;
        return INT_GPF;
    }
    if (ctx->mm != mm || ctx->mmu_id != mm->mmu->id) {
        tlb_flush_ctx(ctx);
        ctx->mem_changes = __atomic_load_n(&mm->mmu->changes, __ATOMIC_ACQUIRE);
        ctx->mmu_id = mm->mmu->id;
        ctx->lc_gen = 0;
        memset(ctx->lc, 0, sizeof(ctx->lc));
    }
    ctx->mm = mm;
    ctx->tlb = tlb;
    ctx->itab = (uint64_t) mm->itab;
    ctx->changes_ptr = (uint64_t) &mm->mmu->changes;
    ctx->cpu = *cpu;
    ctx->guest_fpcr_masked = cpu->fpcr & FPCR_GUEST_MASK;
    ctx->exitflag = false;
    __atomic_store_n(&cpu->poked_ptr, (bool *) &ctx->exitflag, __ATOMIC_SEQ_CST);
    if (__atomic_exchange_n(&cpu->_poked, false, __ATOMIC_SEQ_CST))
        ctx->exitflag = true;
    ctx->in_jit = 1;
    __atomic_store_n(&mm->last_active, clock_gettime_nsec_np(CLOCK_UPTIME_RAW), __ATOMIC_RELAXED);
    ticker_wake();

    uint32_t *pending_slot = NULL;
    uint64_t pending_flush = 0;
    int interrupt = INT_NONE;
    while (interrupt == INT_NONE) {
        ctx->epoch = atomic_load(&global_epoch);
        if (mm->retired || ((++reclaim_tick & 1023) == 0 &&
                (mm->dead || mm->ss_jetsam || mm->dead_pending || mm->ss_pending)))
            reclaim(mm);
        check_changes(ctx);
        if (ctx->exitflag) {
            ctx->exitflag = false;
            interrupt = INT_TIMER;
            break;
        }
        addr_t pc = ctx->cpu.pc;
        if (pc == 0 || (pc & 0xffff000000000000ull)) {
            ctx->cpu.segfault_addr = pc;
            ctx->cpu.segfault_was_write = 0;
            ctx->cpu.pc = pc & 0xffffffffffffull;
            interrupt = INT_GPF;
            break;
        }
        struct jit_block *b = get_block(ctx, pc);
        if (b == NULL || b->rx == NULL) {
            pending_slot = NULL;
            interrupt = gadget_step(ctx, tlb);
            continue;
        }
        if (pending_slot) {
            chain(mm, pending_slot, pending_flush, b);
            pending_slot = NULL;
        }
        struct jit_chunk *c = jit_chunk_of((uintptr_t) b->rx);
        uint64_t reason = ((enter_fn) c->t_enter)(ctx, b->rx);
        if (ctx->bounce_active && commit_bounce(ctx) != 0) {
            ctx->cpu.segfault_addr = ctx->bounce_addr;
            ctx->cpu.segfault_was_write = 1;
            interrupt = INT_GPF;
            break;
        }
        if (jit_stats && reason < 16) {
            __atomic_fetch_add(&mm->stats_exits[reason], 1, __ATOMIC_RELAXED);
            if (reason == JR_FALLBACK) {
                uint32_t insn = 0;
                if (tlb->mem_changes != __atomic_load_n(&tlb->mmu->changes, __ATOMIC_ACQUIRE))
                    tlb_flush(tlb);
                tlb_read(tlb, ctx->cpu.pc, &insn, 4);
                pthread_mutex_lock(&mm->lock);
                int slot = -1;
                for (int i = 0; i < 32; i++) {
                    if (mm->stats_fb[i].insn == insn && mm->stats_fb[i].n) { slot = i; break; }
                    if (slot < 0 && mm->stats_fb[i].n == 0) slot = i;
                }
                if (slot >= 0) { mm->stats_fb[slot].insn = insn; mm->stats_fb[slot].n++; }
                pthread_mutex_unlock(&mm->lock);
            }
        }
        switch (reason) {
            case JR_CHAIN:
                pending_slot = (uint32_t *) ctx->exit_slot;
                pending_flush = __atomic_load_n(&mm->stats_flush, __ATOMIC_RELAXED);
                break;
            case JR_INDIRECT: {
                struct jit_block *t = get_block(ctx, ctx->cpu.pc);
                if (t && t->rx)
                    itab_set(mm, ctx->cpu.pc, t);
                break;
            }
            case JR_FALLBACK:
                interrupt = gadget_step(ctx, tlb);
                break;
            case JR_SYSCALL:
                interrupt = INT_SYSCALL;
                break;
            case JR_POLL:
            case JR_REDISPATCH:
                break;
            case JR_PROMOTE: {
                // hot tier-1 block: retranslate with inline TLB lookups; the
                // new block replaces the old one (chains are redone)
                struct jit_block *ob = lookup_lockfree(mm, ctx->cpu.pc);   // the block whose counter ran out
                uint32_t *cnt = ob ? ob->counter : NULL;
                pthread_mutex_lock(&mm->lock);
                uint64_t gen = atomic_load(&mm->gen);
                pthread_mutex_unlock(&mm->lock);
                struct jit_block *nb = force_tier == 1 ? NULL : jit_translate(mm, ctx, ctx->cpu.pc, gen, 2);
                if (nb == NULL || nb == (struct jit_block *) -1 || nb == (struct jit_block *) -2) {
                    if (cnt)
                        *cnt = 1u << 30;   // try much later
                } else {
                    mm->stats_promote++;
                }
                break;
            }
            case JR_ICIVAU: {
                page_t p = PAGE(ctx->ic_addr);
                asbestos_invalidate_page(mm->mmu->asbestos, p);   // also reaches jit_invalidate_range
                // A translation of this page that read the old bytes and is
                // inserted after this point must be rejected (jit_translate
                // checks gen), even if no block existed yet.
                atomic_fetch_add(&mm->gen, 1);
                break;
            }
            case JR_GPF:
                interrupt = INT_GPF;
                break;
            case JR_HOSTFAULT:
                tlb_flush_ctx(ctx);
                if (ctx->crash_pc == ctx->cpu.pc && ++ctx->crash_count >= 3) {
                    ctx->crash_count = 0;
                    ctx->cpu.segfault_addr = ctx->cpu.pc;
                    ctx->cpu.segfault_was_write = 0;
                    interrupt = INT_GPF;
                } else if (ctx->crash_pc != ctx->cpu.pc) {
                    ctx->crash_pc = ctx->cpu.pc;
                    ctx->crash_count = 1;
                }
                break;
            case JR_UNDEFINED:
                interrupt = INT_UNDEFINED;
                break;
            default:
                fprintf(stderr, "jit: bad exit reason %llu\n", (unsigned long long) reason);
                abort();
        }
    }
    ctx->in_jit = 0;
    __atomic_store_n(&cpu->poked_ptr, &cpu->_poked, __ATOMIC_SEQ_CST);
    if (ctx->exitflag)
        __atomic_store_n(&cpu->_poked, true, __ATOMIC_SEQ_CST);
    ctx->cpu.poked_ptr = &cpu->_poked;
    memcpy(cpu, &ctx->cpu, offsetof(struct cpu_state, _poked));
    return interrupt;
}

// ---------------------------------------------------------------------------
// Memory pressure
// ---------------------------------------------------------------------------
void ish_jit_trim(void) {
    if (jit_state != 1)
        return;
    size_t over = jit_codemem_trim();
    pthread_mutex_lock(&mm_list_lock);
    for (struct jit_mm *mm = mm_list; mm; mm = mm->list_next) {
        pthread_mutex_lock(&mm->lock);
        // keep each address space's newest chunk, retire the rest while over budget
        while (over > 0 && mm->nchunks > 1) {
            retire_oldest_locked(mm);
            over--;
        }
        pthread_mutex_unlock(&mm->lock);
        reclaim(mm);   // frees right away unless one of its threads is inside JIT code
    }
    pthread_mutex_unlock(&mm_list_lock);
    jit_pcache_save();
    if (jit_stats) {
        size_t u, b;
        jit_codemem_usage(&u, &b);
        fprintf(stderr, "[jit] trim: code cache %zu MB in use, budget %zu MB\n", u >> 20, b >> 20);
    }
}

static void pressure_handler(void *ctx) {
    (void) ctx;
    ish_jit_trim();
}

static void install_pressure_handler(void) {
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (src == NULL)
        return;
    dispatch_source_set_event_handler_f(src, pressure_handler);
    dispatch_resume(src);
}

// ---------------------------------------------------------------------------
// Host faults inside translated code
// ---------------------------------------------------------------------------
static struct jit_block *block_at(struct jit_chunk *c, uintptr_t pc) {
    size_t lo = 0, hi = c->nblocks;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if ((uintptr_t) c->blocks[mid]->rx <= pc)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo == 0)
        return NULL;
    struct jit_block *b = c->blocks[lo - 1];
    if (pc >= (uintptr_t) (b->rx + b->nwords))
        return NULL;
    return b;
}

static void chain_old(int sig, siginfo_t *info, void *uc) {
    struct sigaction *old = sig == SIGSEGV ? &old_segv : sig == SIGBUS ? &old_bus : &old_ill;
    if (old->sa_flags & SA_SIGINFO) {
        old->sa_sigaction(sig, info, uc);
    } else if (old->sa_handler == SIG_DFL || old->sa_handler == SIG_IGN) {
        signal(sig, SIG_DFL);
    } else {
        old->sa_handler(sig);
    }
}

static void jit_signal(int sig, siginfo_t *info, void *ucv) {
    ucontext_t *uc = ucv;
    uintptr_t pc = uc->uc_mcontext->__ss.__pc;
    struct jit_ctx *ctx = tls_ctx;
    struct jit_chunk *c = jit_chunk_of(pc);
    struct jit_block *b = c ? block_at(c, pc) : NULL;
    if (ctx == NULL || !ctx->in_jit || b == NULL) {
        chain_old(sig, info, ucv);
        return;
    }
    uint32_t off = (pc - (uintptr_t) b->rx) / 4;
    uint32_t gi = 0, borrow = 0;
    for (uint32_t i = 0; i < b->nmap && b->map[i].host_off <= off; i++) {
        gi = b->map[i].guest_idx;
        borrow = b->map[i].borrow;
    }

    struct __darwin_arm_thread_state64 *ss = &uc->uc_mcontext->__ss;
    for (int g = 0; g < 31; g++) {
        int h = jit_g2h[g];
        if (h < 0 || (borrow & (1u << h)))
            continue;   // spilled, or borrowed as a temp (value parked in ctx)
        ctx->cpu.regs[g] = h == 29 ? ss->__fp : h == 30 ? ss->__lr : ss->__x[h];
    }
    ctx->cpu.sp = ss->__x[HR_SP];
    ctx->cpu.nzcv = ss->__cpsr & 0xf0000000u;
    for (int v = 0; v < 32; v++)
        memcpy(&ctx->cpu.fp[v], &uc->uc_mcontext->__ns.__v[v], 16);
    ctx->cpu.fpsr = uc->uc_mcontext->__ns.__fpsr;
    ctx->cpu.pc = b->pc + 4 * gi;
    ctx->reason = sig == SIGILL ? JR_UNDEFINED : JR_HOSTFAULT;
    ss->__x[HR_CTX] = (uint64_t) ctx;
    ss->__pc = (uint64_t) c->t_exit_saved;
}

// Debug aid (ISH_JIT_DEBUG=1): SIGINFO (^T) prints each JIT thread's last
// dispatcher state, to locate a spinning guest thread.
static void debug_dump(int sig) {
    (void) sig;
    char line[256];
    for (struct jit_ctx *c = reg_head; c; c = c->reg_next) {
        int n = snprintf(line, sizeof(line), "[jit] ctx %p in_jit=%d pc=%#llx x0=%#llx x30=%#llx sp=%#llx reason=%llu\n",
                         (void *) c, c->in_jit, (unsigned long long) c->cpu.pc,
                         (unsigned long long) c->cpu.regs[0], (unsigned long long) c->cpu.regs[30],
                         (unsigned long long) c->cpu.sp, (unsigned long long) c->reason);
        write(2, line, n);
        if (c->mm) {
            n = snprintf(line, sizeof(line), "[jit]   mm exits: chain %llu indirect %llu fallback %llu poll %llu redispatch %llu promote %llu (promoted %llu)\n",
                         (unsigned long long) c->mm->stats_exits[JR_CHAIN], (unsigned long long) c->mm->stats_exits[JR_INDIRECT],
                         (unsigned long long) c->mm->stats_exits[JR_FALLBACK], (unsigned long long) c->mm->stats_exits[JR_POLL],
                         (unsigned long long) c->mm->stats_exits[JR_REDISPATCH], (unsigned long long) c->mm->stats_exits[JR_PROMOTE],
                         (unsigned long long) c->mm->stats_promote);
            write(2, line, n);
        }
    }
}

static void install_signals(void) {
    const char *d = getenv("ISH_JIT_DEBUG");
    if (d && d[0] == '1')
        signal(SIGINFO, debug_dump);
    struct sigaction sa = {0};
    sa.sa_sigaction = jit_signal;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &old_segv);
    sigaction(SIGBUS, &sa, &old_bus);
    sigaction(SIGILL, &sa, &old_ill);
}
