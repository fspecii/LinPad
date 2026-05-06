// Shape-A trace JIT — see tracejit.h.
//
// First-milestone translator: block of N×movz(w,#imm16) followed by
// `ret x30`. Native output:
//   for each (rd, imm): movz x16, #imm; str x16, [x1, #CPU_x<rd>]
//   ldr x16, [x1, #CPU_x30]; str x16, [x1, #CPU_pc]
//   movn w0, #0           ; return INT_NONE (-1)
//   ret                   ; back to caller
//
// Calling convention of translated fn: int fn(struct fiber_frame *frame)
// frame in x0 (host arg0). We move it to x1 in prologue so subsequent
// loads/stores use a stable register that doesn't get clobbered by the
// `movn w0, #0` epilogue. Actually we just keep frame in x1 throughout
// by copying it once at entry.

#include "tracejit/tracejit.h"
#include "tracejit/page_alloc.h"
#include "tracejit/dispatch.h"
#include "asbestos/frame.h"
#include "emu/cpu.h"
#include "emu/interrupt.h"
#include "kernel/memory.h"
#include "kernel/task.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---- gating ---------------------------------------------------------------

static int g_enabled = -1;
int tracejit_enabled(void) {
    if (g_enabled == -1) {
        const char *e = getenv("ISH_TRACEJIT");
        g_enabled = (e && e[0] == '1') ? 1 : 0;
    }
    return g_enabled;
}

// V8/node binary codespace bounds. Determined empirically via PC histogram
// (see tools/pc_hist study). 0xed1dd000-0xeff08000 is the node binary
// mapping, contiguous, immutable for process lifetime (verified protect-
// stable). Hot subset is 0xee*-0xeef* but we'll consider the whole range
// a translation candidate; non-hot blocks just won't get many calls.
//
// TODO: at first dispatch into this range, walk /proc/self/maps to get
// exact bounds for the running node binary. For now, hardcoded.
#define V8_CODESPACE_LO 0xed1dd000ULL
#define V8_CODESPACE_HI 0xeff08000ULL

// Optional override (for micro-benchmarks that load outside the V8 range):
// ISH_TRACEJIT_RANGE=lo-hi  (hex, e.g. 400000-500000)
static int g_range_init = 0;
static void range_init(void) {
    if (g_range_init) return;
    g_range_init = 1;
    const char *e = getenv("ISH_TRACEJIT_RANGE");
    if (!e) return;
    unsigned long long lo = 0, hi = 0;
    if (sscanf(e, "%llx-%llx", &lo, &hi) == 2 && hi > lo) {
        tracejit_set_range(lo, hi);
        fprintf(stderr, "[tracejit] codespace override: 0x%llx-0x%llx\n", lo, hi);
    }
}

bool tracejit_pc_in_codespace(uint64_t pc) {
    range_init();
    return tracejit_pc_in_table(pc);
}

// ---- stats ---------------------------------------------------------------

static _Atomic uint64_t s_translate_attempts;
static _Atomic uint64_t s_translate_hits;
static _Atomic uint64_t s_translate_pattern_miss;
static _Atomic uint64_t s_translate_alloc_fail;
static _Atomic uint64_t s_invocations;
_Atomic uint64_t s_dispatch_iterations;  // public; bumped from asbestos.c

// ---- entry point --------------------------------------------------------
// Called from cpu_run_to_interrupt when ISH_TRACEJIT=1 and pc is in
// codespace. Looks up the dispatch table; on hit, runs the translation.
// On miss, returns INT_NONE so the caller falls through to the gadget
// path.

#include "emu/interrupt.h"

int tracejit_enter(struct fiber_frame *frame) {
    if (!tracejit_enabled()) return INT_NONE;
    uint64_t pc = frame->cpu.pc;
    if (!tracejit_pc_in_table(pc)) return INT_NONE;

    void **table = tracejit_dispatch_table();
    if (!table) return INT_NONE;

    void *fn = __atomic_load_n(&table[tracejit_pc_to_idx(pc)],
                               __ATOMIC_RELAXED);
    if (!fn) return INT_NONE;

    int rc = ((tracejit_block_fn)fn)(frame);
    atomic_fetch_add_explicit(&s_invocations, 1, memory_order_relaxed);
    return rc;
}

void tracejit_count_invocation(void) {
    atomic_fetch_add_explicit(&s_invocations, 1, memory_order_relaxed);
}

void tracejit_dump_stats(void) {
    if (!tracejit_enabled() && s_dispatch_iterations == 0) return;
    fprintf(stderr, "=== tracejit stats ===\n");
    fprintf(stderr, "  translate_attempts:    %llu\n", (unsigned long long)s_translate_attempts);
    fprintf(stderr, "  translate_hits:        %llu\n", (unsigned long long)s_translate_hits);
    fprintf(stderr, "  translate_pattern_miss:%llu\n", (unsigned long long)s_translate_pattern_miss);
    fprintf(stderr, "  translate_alloc_fail:  %llu\n", (unsigned long long)s_translate_alloc_fail);
    fprintf(stderr, "  invocations:           %llu\n", (unsigned long long)s_invocations);
    fprintf(stderr, "  dispatch_iterations:   %llu\n", (unsigned long long)s_dispatch_iterations);
    fflush(stderr);
}

// ---- translation cache ---------------------------------------------------
// Hash map keyed by guest PC. Single-writer, multi-reader; protected by
// a mutex on the write side, atomic loads on the read side.

#define CACHE_BUCKETS 16384  // power of 2; 16K entries
struct cache_entry {
    uint64_t pc;
    tracejit_block_fn fn;
};
static struct cache_entry g_cache[CACHE_BUCKETS];
static pthread_mutex_t g_cache_mu = PTHREAD_MUTEX_INITIALIZER;

static inline size_t cache_hash(uint64_t pc) {
    // Mix bits; guest PCs are 4-byte aligned, low 2 bits zero.
    uint64_t h = pc * 0x9e3779b97f4a7c15ULL;
    return (size_t)(h >> (64 - 14)) & (CACHE_BUCKETS - 1);
}

static tracejit_block_fn cache_lookup(uint64_t pc) {
    // Fast path: single probe, relaxed load. Hot lookups (a leaf called
    // a million times in a loop) have one PC and that PC always lands
    // in the same bucket. For collision resolution the slow path probes.
    size_t i = cache_hash(pc);
    struct cache_entry *e0 = &g_cache[i];
    if (__atomic_load_n(&e0->pc, __ATOMIC_RELAXED) == pc) return e0->fn;

    for (int probe = 1; probe < 8; probe++) {
        struct cache_entry *e = &g_cache[(i + probe) & (CACHE_BUCKETS - 1)];
        uint64_t epc = __atomic_load_n(&e->pc, __ATOMIC_RELAXED);
        if (epc == 0) return NULL;
        if (epc == pc) return e->fn;
    }
    return NULL;
}

// Inserts (pc, fn) into cache. Returns true if inserted, false if full.
static bool cache_insert(uint64_t pc, tracejit_block_fn fn) {
    size_t i = cache_hash(pc);
    pthread_mutex_lock(&g_cache_mu);
    for (int probe = 0; probe < 8; probe++) {
        struct cache_entry *e = &g_cache[(i + probe) & (CACHE_BUCKETS - 1)];
        if (e->pc == 0 || e->pc == pc) {
            e->fn = fn;
            __atomic_store_n(&e->pc, pc, __ATOMIC_RELEASE);
            pthread_mutex_unlock(&g_cache_mu);
            return true;
        }
    }
    pthread_mutex_unlock(&g_cache_mu);
    return false;
}

// ---- code buffer (bump allocator) ---------------------------------------
// One MAP_JIT region; we bump-allocate translations into it. No reclaim
// for now (V8 codespace is immutable, translations live forever).

#define CODE_BUF_SIZE (16 * 1024 * 1024)  // 16 MB initial
static uint32_t *g_code_buf;
static size_t g_code_used;          // bytes
static pthread_mutex_t g_code_mu = PTHREAD_MUTEX_INITIALIZER;

static bool code_buf_init(void) {
    if (g_code_buf) return true;
    g_code_buf = jit_page_alloc(CODE_BUF_SIZE);
    return g_code_buf != NULL;
}

// Reserve `n_words` of native instructions; returns pointer to buffer.
// Caller must hold g_code_mu and call jit_page_writable_begin/end around
// the actual emission + jit_icache_flush after.
static uint32_t *code_buf_reserve(size_t n_words) {
    size_t need = n_words * 4;
    if (g_code_used + need > CODE_BUF_SIZE) return NULL;
    uint32_t *p = (uint32_t *)((uint8_t *)g_code_buf + g_code_used);
    g_code_used += need;
    return p;
}

// ---- ARM64 instruction encoders -----------------------------------------
// Minimal helpers for the patterns we emit. All 32-bit encodings.

static inline uint32_t enc_movz_x(unsigned rd, uint16_t imm16) {
    // movz xRd, #imm16, lsl #0   (sf=1, opc=10, hw=00)
    return 0xd2800000u | ((uint32_t)imm16 << 5) | (rd & 31);
}
static inline uint32_t enc_movn_w(unsigned rd, uint16_t imm16) {
    // movn wRd, #imm16, lsl #0   (sf=0, opc=00, hw=00)
    return 0x12800000u | ((uint32_t)imm16 << 5) | (rd & 31);
}
static inline uint32_t enc_str_x(unsigned rt, unsigned rn, unsigned off_bytes) {
    // str xT, [xN, #off]    (unsigned imm; imm12 scaled by 8; size=11, V=0, opc=00)
    unsigned imm12 = off_bytes / 8;
    return 0xf9000000u | (imm12 << 10) | ((rn & 31) << 5) | (rt & 31);
}
static inline uint32_t enc_ldr_x(unsigned rt, unsigned rn, unsigned off_bytes) {
    // ldr xT, [xN, #off]    (size=11, V=0, opc=01)
    unsigned imm12 = off_bytes / 8;
    return 0xf9400000u | (imm12 << 10) | ((rn & 31) << 5) | (rt & 31);
}
static inline uint32_t enc_mov_reg_x(unsigned rd, unsigned rm) {
    // mov xRd, xRm  ==  orr xRd, xzr, xRm
    return 0xaa0003e0u | ((rm & 31) << 16) | (rd & 31);
}
static inline uint32_t enc_ret(void) { return 0xd65f03c0u; }

// Unconditional `b <imm26>`: opcode 000101, imm26 = signed words
static inline uint32_t enc_b_rel(int32_t off_words) {
    uint32_t imm26 = (uint32_t)(off_words & 0x3ffffff);
    return 0x14000000u | imm26;
}
// add xRd, xRn, #imm12 (sf=1, sh=0)
static inline uint32_t enc_add_imm_x(unsigned rd, unsigned rn, uint16_t imm12) {
    return 0x91000000u | ((uint32_t)imm12 << 10) | ((rn & 31) << 5) | (rd & 31);
}
// movk xRd, #imm16, lsl #(shift)
static inline uint32_t enc_movk_x(unsigned rd, uint16_t imm16, unsigned shift) {
    uint32_t hw = shift / 16;
    return 0xf2800000u | (hw << 21) | ((uint32_t)imm16 << 5) | (rd & 31);
}

// Emit movz/movk sequence to load a 64-bit constant into xRd.
// Skips upper 16-bit chunks that are zero. Returns word count emitted (1-4).
static int emit_load_imm64(uint32_t *out, unsigned rd, uint64_t imm) {
    int n = 0;
    out[n++] = enc_movz_x(rd, (uint16_t)(imm & 0xffff));
    if ((imm >> 16) & 0xffff) out[n++] = enc_movk_x(rd, (uint16_t)((imm >> 16) & 0xffff), 16);
    if ((imm >> 32) & 0xffff) out[n++] = enc_movk_x(rd, (uint16_t)((imm >> 32) & 0xffff), 32);
    if ((imm >> 48) & 0xffff) out[n++] = enc_movk_x(rd, (uint16_t)((imm >> 48) & 0xffff), 48);
    return n;
}

// Emit fallback epilogue: writes guest_pc into cpu->pc, returns INT_NONE.
// This is used when a translated block needs to bail out to the dispatch
// loop (table miss on chain target, unsupported terminator, etc.).
// Maximum footprint: 4 + 1 + 1 + 1 = 7 words. Caller must reserve.
static int emit_fallback_epilogue(uint32_t *out, uint64_t guest_pc) {
    int k = 0;
    k += emit_load_imm64(&out[k], 17, guest_pc);
    out[k++] = enc_str_x(17, 0, 272);     // str x17, [x0, #cpu_pc]
    out[k++] = enc_movn_w(0, 0);          // mov w0, #-1 (INT_NONE)
    out[k++] = enc_ret();
    return k;
}

// ---- guest insn pattern matching ----------------------------------------

// Returns true and fills (*rd, *imm) if `insn` is `movz wRd, #imm16, lsl #0`.
// Encoding: sf=0, opc=10, hw=00, imm16, rd. Mask 0xff800000 == 0x52800000.
static bool decode_movz_w0(uint32_t insn, unsigned *rd, uint16_t *imm) {
    if ((insn & 0xff800000u) != 0x52800000u) return false;
    *imm = (insn >> 5) & 0xffff;
    *rd  = insn & 31;
    return true;
}
// `ret x30`  ==  0xd65f03c0
static bool decode_ret(uint32_t insn) {
    return insn == 0xd65f03c0u;
}

// Decode `add xRd, xRn, #imm12` (sf=1, op=0, S=0, sh=0). Mask to 0x7FC00000.
// Encoding: 1001 0001 00 sh imm12 rn rd  → top 8 bits = 0x91, sh=0.
static bool decode_add_imm_x(uint32_t insn, unsigned *rd, unsigned *rn, uint16_t *imm12) {
    if ((insn & 0xff800000u) != 0x91000000u) return false;  // sf=1, op=0, S=0, sh=0
    *imm12 = (insn >> 10) & 0xfff;
    *rn = (insn >> 5) & 31;
    *rd = insn & 31;
    return true;
}

// Decode unconditional `b <label>` (not bl). Encoding: 000101 imm26.
// Returns true and fills *target_off_bytes with sign-extended byte offset.
static bool decode_b_uncond(uint32_t insn, int64_t *target_off_bytes) {
    if ((insn & 0xfc000000u) != 0x14000000u) return false;
    int32_t imm26 = (int32_t)(insn & 0x03ffffffu);
    if (imm26 & 0x02000000) imm26 |= 0xfc000000;  // sign-extend 26-bit
    *target_off_bytes = (int64_t)imm26 * 4;
    return true;
}

// ---- the translator -----------------------------------------------------

#define MAX_BLOCK_INSNS 64
#define MAX_TRANSLATE_DEPTH 8

// Block terminator kind for the mini PoC.
enum term_kind { TERM_RET, TERM_B_DIRECT };

static __thread int g_translate_depth;

static tracejit_block_fn tracejit_translate_inner(uint64_t ip);

tracejit_block_fn tracejit_translate(uint64_t ip) {
    if (!tracejit_enabled()) return NULL;
    if (!tracejit_pc_in_codespace(ip)) return NULL;

    tracejit_block_fn cached = cache_lookup(ip);
    if (cached) return cached;

    if (g_translate_depth >= MAX_TRANSLATE_DEPTH) return NULL;
    g_translate_depth++;
    tracejit_block_fn r = tracejit_translate_inner(ip);
    g_translate_depth--;
    return r;
}

enum op_kind { OP_MOVZ, OP_ADD_IMM };
struct op {
    enum op_kind kind;
    unsigned rd, rn;     // rn used by ADD_IMM
    uint16_t imm;
};

static tracejit_block_fn tracejit_translate_inner(uint64_t ip) {
    atomic_fetch_add_explicit(&s_translate_attempts, 1, memory_order_relaxed);

    if (current == NULL || current->mem == NULL) return NULL;
    uint32_t guest[MAX_BLOCK_INSNS];
    struct op ops[MAX_BLOCK_INSNS];
    int n_ops = 0;
    enum term_kind term = TERM_RET;
    int64_t b_target_off = 0;

    for (int i = 0; i < MAX_BLOCK_INSNS; i++) {
        void *p = mem_ptr(current->mem, ip + i * 4, MEM_READ);
        if (p == NULL) {
            atomic_fetch_add_explicit(&s_translate_pattern_miss, 1, memory_order_relaxed);
            return NULL;
        }
        memcpy(&guest[i], p, 4);

        unsigned rd, rn; uint16_t imm; uint16_t imm12;
        if (decode_movz_w0(guest[i], &rd, &imm)) {
            ops[n_ops++] = (struct op){.kind = OP_MOVZ, .rd = rd, .imm = imm};
            continue;
        }
        if (decode_add_imm_x(guest[i], &rd, &rn, &imm12)) {
            ops[n_ops++] = (struct op){.kind = OP_ADD_IMM, .rd = rd, .rn = rn, .imm = imm12};
            continue;
        }
        if (decode_ret(guest[i])) {
            term = TERM_RET;
            goto matched;
        }
        int64_t off;
        if (decode_b_uncond(guest[i], &off)) {
            term = TERM_B_DIRECT;
            b_target_off = (int64_t)(ip + i * 4) + off;
            goto matched;
        }
        atomic_fetch_add_explicit(&s_translate_pattern_miss, 1, memory_order_relaxed);
        return NULL;
    }
    atomic_fetch_add_explicit(&s_translate_pattern_miss, 1, memory_order_relaxed);
    return NULL;

matched: {
    // Worst-case footprint: n_ops×3 body + 7 epilogue
    // (3 max per op: ldr+add+str for ADD_IMM; 2 for MOVZ).
    size_t need_words = (size_t)n_ops * 3 + 7;

    pthread_mutex_lock(&g_code_mu);
    if (!code_buf_init()) {
        pthread_mutex_unlock(&g_code_mu);
        atomic_fetch_add_explicit(&s_translate_alloc_fail, 1, memory_order_relaxed);
        return NULL;
    }
    uint32_t *out = code_buf_reserve(need_words);
    if (!out) {
        pthread_mutex_unlock(&g_code_mu);
        atomic_fetch_add_explicit(&s_translate_alloc_fail, 1, memory_order_relaxed);
        return NULL;
    }

    // Pre-publish this translation in the cache *before* recursing on the
    // branch target. This breaks tight loops (A → B → A → ...): when we
    // recurse into B and B's `b` lands back on A, cache_lookup returns
    // this A's pointer immediately, so we can chain B → A on this pass.
    //
    // We also publish to the dispatch table now so any concurrent thread
    // that's about to enter A can pick it up. Translated code at `out`
    // hasn't been written yet, but readers that hit it would find a stub
    // that's still all-zeros (initial mmap state) — which is `udf #0` and
    // would crash. So defer the table publish until after emission completes.
    tracejit_block_fn self_fn = (tracejit_block_fn)(void *)out;
    cache_insert(ip, self_fn);

    // Decide chain target. Only relevant for TERM_B_DIRECT.
    tracejit_block_fn chain_to = NULL;
    uint64_t chain_target_pc = 0;
    if (term == TERM_B_DIRECT) {
        chain_target_pc = (uint64_t)b_target_off;
        if (tracejit_pc_in_codespace(chain_target_pc)) {
            // Release code lock before recursing; recursion will re-acquire.
            pthread_mutex_unlock(&g_code_mu);
            chain_to = tracejit_translate(chain_target_pc);
            pthread_mutex_lock(&g_code_mu);
        }
    }

    jit_page_writable_begin();
    size_t k = 0;
    for (int i = 0; i < n_ops; i++) {
        struct op *o = &ops[i];
        if (o->kind == OP_MOVZ) {
            out[k++] = enc_movz_x(16, o->imm);
            out[k++] = enc_str_x(16, 0, 16 + o->rd * 8);
        } else {  // OP_ADD_IMM
            out[k++] = enc_ldr_x(16, 0, 16 + o->rn * 8);
            out[k++] = enc_add_imm_x(16, 16, o->imm);
            out[k++] = enc_str_x(16, 0, 16 + o->rd * 8);
        }
    }

    if (term == TERM_RET) {
        // ret x30: pc <- guest x30. We don't know the value at emit time,
        // so emit "ldr x16,[x0,#x30]; str x16,[x0,#pc]" then exit to
        // dispatch. Future improvement: emit a return-cache lookup.
        out[k++] = enc_ldr_x(16, 0, 256);
        out[k++] = enc_str_x(16, 0, 272);
        out[k++] = enc_movn_w(0, 0);
        out[k++] = enc_ret();
    } else {
        // TERM_B_DIRECT
        bool emitted_chain = false;
        if (chain_to != NULL) {
            // Compute relative offset from where the chain `b` would be
            // emitted to chain_to. We pre-budget a 1-word slot for the b.
            int64_t cur_pc = (int64_t)(uintptr_t)&out[k];
            int64_t tgt_pc = (int64_t)(uintptr_t)chain_to;
            int64_t off_bytes = tgt_pc - cur_pc;
            if (off_bytes >= -(1LL << 27) && off_bytes < (1LL << 27) &&
                    (off_bytes & 3) == 0) {
                int32_t off_words = (int32_t)(off_bytes / 4);
                out[k++] = enc_b_rel(off_words);
                emitted_chain = true;
            }
        }
        if (!emitted_chain) {
            // No chain (target not translated yet, or out of range):
            // emit fallback that sets pc = target and returns to dispatch.
            k += emit_fallback_epilogue(&out[k], chain_target_pc);
        }
    }
    jit_page_writable_end();
    jit_icache_flush(out, k * 4);

    pthread_mutex_unlock(&g_code_mu);

    tracejit_block_fn fn = self_fn;
    if (getenv("ISH_TRACEJIT_DEBUG")) {
        fprintf(stderr, "[tracejit] translated 0x%llx → %p (%zu words):\n",
                (unsigned long long)ip, (void *)out, need_words);
        for (size_t i = 0; i < need_words; i++) {
            fprintf(stderr, "  %p: 0x%08x\n", (void *)(out + i), out[i]);
        }
    }
    cache_insert(ip, fn);
    tracejit_table_publish(ip, fn);   // make discoverable to chained dispatch
    atomic_fetch_add_explicit(&s_translate_hits, 1, memory_order_relaxed);
    return fn;
}
}
