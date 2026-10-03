#ifndef ISH_JIT_INTERNAL_H
#define ISH_JIT_INTERNAL_H

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "emu/cpu.h"
#include "emu/mmu.h"

// ---------------------------------------------------------------------------
// Host register assignment (see DESIGN.md "Register allocation").
//
// Guest x0-x10, x16, x17, x19-x30 live in the host register of the same
// number. Guest SP lives in host x15. Guest x11-x15 and x18 live in
// ctx->cpu.regs[] ("spilled") and are moved through scratch registers.
// Host x11 holds the jit_ctx pointer, x12-x14 are scratch, x18 is never used
// (Darwin platform register). Tier-1 code parks guest x30 in its slot around
// the bl to a shared TLB stub.
// ---------------------------------------------------------------------------
#define HR_CTX 11
#define HR_T0 12
#define HR_T1 13
#define HR_T2 14
#define HR_SP 15
#define HR_ZR 31

extern const int8_t jit_g2h[32];   // guest reg (31 = SP) -> host reg, -1 = spilled

// ---------------------------------------------------------------------------
// Per-thread context. Host x11 points here while JIT code runs.
// ---------------------------------------------------------------------------
struct jit_tlb_entry {
    uint64_t page_r;     // guest page if readable, else 1
    uint64_t page_w;     // guest page if writable, else 1
    uint64_t addend;     // host = guest + addend
    uint64_t pad;
};
#define JIT_TLB_BITS 13
#define JIT_TLB_SIZE (1 << JIT_TLB_BITS)
#define JIT_TLB_OFF 0x800
#define JIT_LC_SIZE 4096
#define JIT_FILLED_MAX 1024

enum jit_reason {
    JR_CHAIN = 1,       // direct branch exit; ctx->exit_slot = patchable slot
    JR_INDIRECT,        // indirect branch table miss, pc = target
    JR_FALLBACK,        // instruction not handled natively: gadget single-step at pc
    JR_SYSCALL,         // SVC, pc = next insn
    JR_POLL,            // exitflag was set (poke / periodic tick)
    JR_ICIVAU,          // IC IVAU of ctx->ic_addr, pc = next insn
    JR_GPF,             // guest fault, segfault_addr/was_write set, pc = faulting insn
    JR_HOSTFAULT,       // host SIGSEGV/SIGBUS inside JIT code (stale TLB), pc = insn
    JR_UNDEFINED,       // host SIGILL inside JIT code, pc = insn
    JR_REDISPATCH,      // block was invalidated, pc = its start
    JR_PROMOTE,         // tier-1 block's counter ran out, pc = its start: retranslate as tier 2
};

enum jit_helper_kind {
    JH_MEM = 1,         // resolve guest addr T0 -> host ptr (T1); may use bounce buffer
    JH_COMMIT,          // write bounce buffer back after a page-crossing store
    JH_FLUSH,           // page tables changed: flush the TLB
};

struct jit_mm;
struct jit_ctx {
  union {
   struct {
    struct cpu_state cpu;          // must be first: JIT code addresses it at offset 0
    uint64_t host_sp;
    uint64_t host_fpcr;
    uint64_t reason;
    uint64_t exit_slot;            // RX address of the patch slot for JR_CHAIN
    uint64_t helper_ret;
    uint64_t helper_result;
    uint64_t itab;                 // indirect-branch table base (mm->itab)
    uint64_t ic_addr;
    uint64_t bounce_addr;          // guest address the bounce buffer stands for
    uint64_t bounce_size;
    uint64_t mem_changes;          // mmu->changes the TLB was filled for
    uint64_t changes_ptr;          // &mmu->changes
    uint64_t helper_arg;           // T0 at helper entry
    uint64_t lr_save;              // host x30 at helper entry (return into a block from a stub)
    uint64_t helper_from_stub;
    uint8_t bounce_active;
    volatile bool exitflag;        // cpu->poked_ptr points here while in jit_run
    uint8_t in_jit;
    uint8_t pad0[5];
    uint8_t bounce[128];
    struct jit_mm *mm;
    struct tlb *tlb;
    void *frame;                   // fiber_frame for gadget single-step
    struct jit_ctx *reg_next, *reg_prev;
    uint64_t epoch;                // last dispatcher pass (code-cache reclamation)
    uint64_t mmu_id;               // address space the TLB and lookup cache belong to
    uint64_t lc_gen;               // mm->gen the lookup cache is valid for
    uint32_t guest_fpcr_masked;
    uint32_t crash_count;
    uint64_t crash_pc;
   };
   char hdr_raw[JIT_TLB_OFF];
  };
    struct jit_tlb_entry tlbe[JIT_TLB_SIZE];
    struct { addr_t pc; struct jit_block *b; uint64_t gen; } lc[JIT_LC_SIZE];   // dispatcher lookup cache (valid if gen == mm->gen)
    // TLB entries filled since the last flush, so a flush only touches those
    // (page tables change often: every mmap/munmap/mprotect in the process).
    uint16_t filled[JIT_FILLED_MAX];
    uint32_t nfilled;
};
_Static_assert(offsetof(struct jit_ctx, tlbe) == JIT_TLB_OFF, "tlb offset");

#define CTX_OFF(f) offsetof(struct jit_ctx, f)
#define CTX_REG(g) (offsetof(struct jit_ctx, cpu) + offsetof(struct cpu_state, regs) + 8 * (g))

// ---------------------------------------------------------------------------
// Relocatable translation: what the translator produces, what the persistent
// translation cache stores, and what jit_install_image places into a chunk.
// ---------------------------------------------------------------------------
struct jit_map_entry { uint32_t host_off, guest_idx, borrow; };
// Relocations: B/BL to a chunk trampoline or a TLB-lookup stub (JREL_STUB + variant).
enum { JREL_CHAIN = 1, JREL_PC = 2, JREL_HELPER = 3, JREL_STUB = 16 };
#define JREL(idx, kind) ((idx) | ((uint32_t) (kind) << 20))
#define JREL_IDX(r) ((r) & 0xfffff)
#define JREL_KIND(r) ((r) >> 20)
// Load TLB-lookup stubs (shared per chunk, called with bl): T0 or x15 = guest
// address, returns T1 = addend. Variants: size class x atomic x address reg.
#define JIT_STUB_SIZES 6           // 1, 2, 4, 8, 16, 32 bytes
#define JIT_NSTUBS (JIT_STUB_SIZES * 2 * 2 * 2)
#define JIT_STUB(szi, atomic, sp, write) ((((szi) * 2 + (atomic)) * 2 + (sp)) * 2 + (write))
struct jit_image {
    uint32_t ninsn;        // guest instructions covered (block = pc .. pc + 4 * ninsn)
    uint32_t nwords;       // code words incl. the trailing 2-word guest-PC literal
    uint32_t nhot;
    uint32_t reentry;      // word index of the redispatch stub
    uint32_t lit;          // word index of the guest-PC literal (8-byte aligned)
    uint32_t cnt_lit;      // tier 1: word index of the execution-counter address literal (0 = none)
    uint32_t nreloc, nmap;
    uint32_t *words;
    uint32_t *reloc;
    struct jit_map_entry *map;   // sorted by host_off
};

// ---------------------------------------------------------------------------
// Translated blocks and the per-address-space state.
// ---------------------------------------------------------------------------
struct jit_block {
    addr_t pc;               // guest start
    addr_t end;              // guest end (exclusive)
    uint32_t *rx;            // executable entry
    uint32_t nwords;         // code size in words
    uint32_t nmap;
    struct jit_map_entry *map;   // sorted by host_off
    uint32_t *reentry;       // RX address of the "redispatch at pc" stub
    uint32_t *counter;       // tier 1: execution countdown (promotion at 0), else NULL
    bool invalid;
    struct jit_block *hash_next;
    struct jit_block *page_next;
    struct jit_block *dead_next;   // negative entries awaiting free (lock-free readers)
};

#define JIT_ITAB_BITS 16
struct jit_itab_entry { uint64_t pc; uint64_t host; };

struct jit_htpub { struct jit_block **tab; size_t size; struct jit_htpub *older; };
#define JIT_COUNTERS (1u << 20)   // per mm, 4 MB of address space, touched lazily
struct jit_chunk;
struct jit_mm {
    struct mmu *mmu;
    struct jit_mm *list_next, *list_prev;   // all address spaces (ish_jit_trim)
    uint64_t last_active;                   // CLOCK_UPTIME_RAW ns of the last jit_run (eviction)
    pthread_mutex_t lock;
    struct jit_block **hash;
    size_t hash_size, nblocks;
    struct jit_htpub *htpub;          // {hash, hash_size} for lock-free lookups; old ones kept
    struct jit_block *dead;           // freed with the mm
    uint32_t *counters;               // tier-1 execution counters
    uint32_t ncounters;
    uint64_t stats_promote;
    struct jit_block **page_hash;     // page -> blocks (chained via page_next)
    uint64_t *bucket_page;            // per bucket: 0 empty, page+1 if one page, ~0 mixed
    size_t page_hash_size;
    struct jit_itab_entry *itab;
    struct jit_chunk *chunks;         // newest first
    size_t nchunks;
    uint32_t *cur, *cur_end;          // bump allocation in chunks->rx
    uint32_t *anchor;                 // first chunk ever: all chunks stay near it
    struct jit_chunk *retired;        // flushed code, freed once no thread can be in it
    uint64_t retired_epoch;
    _Atomic uint64_t gen;             // bumped on invalidation
    struct ss_entry **ss_hash;        // gadget single-step blocks
    size_t ss_size, ss_count;
    uint64_t ss_bloom;                // bit (page & 63) set for pages with single-step blocks
    void *ss_jetsam;                  // freed single-step blocks (freed with mm)
    uint64_t stats_blocks, stats_insns, stats_hot, stats_words, stats_fallback, stats_inval, stats_flush;
    uint64_t stats_veneer_retire;      // exits routed through far_chain (veneers used up)
    uint64_t stats_exits[16];
    uint64_t stats_translate_ns, stats_inval_ns, stats_inval_blocks, stats_inval_slots;
    uint64_t stats_tlb_miss, stats_bounce, stats_tlb_flush;
    struct { uint32_t insn; uint64_t n; } stats_fb[32];   // most frequent fallback encodings
};

// ---------------------------------------------------------------------------
// Code memory (codemem.c)
// ---------------------------------------------------------------------------
bool jit_codemem_init(void);
size_t jit_codemem_trim(void);   // budget back to the minimum; returns chunks over budget
void jit_codemem_usage(size_t *used_bytes, size_t *budget_bytes);
const char *jit_codemem_mode(void);
bool jit_debugger_attached(void);   // P_TRACED (iOS: StikDebug attached)
bool jit_cs_debugged(void);        // CS_DEBUGGED (a debugger attached at some point)
bool jit_txm_present(void);
// Returns RX address of a fresh chunk of `size` bytes or NULL.
#define JIT_WINDOW_CHUNKS 60   // 120 MB: within b's +-128 MB reach
uint32_t *jit_codemem_alloc_chunk(size_t *size, uint32_t *anchor);
void jit_codemem_free_chunk(uint32_t *rx, size_t size);
// RW view of an RX address.
uint32_t *jit_rw(uint32_t *rx);
void jit_write_begin(void);
void jit_icache_lines(void *rx, size_t len);   // no barrier; follow with jit_icache_sync
void jit_icache_sync(void);
void jit_write_finish(void);   // end a write section without cache maintenance
void jit_write_end(void *rx, size_t len);
bool jit_in_code(uintptr_t pc);
uintptr_t jit_code_base(void);
size_t jit_code_size(void);

struct jit_chunk {
    struct jit_chunk *next;
    struct jit_mm *mm;
    uint32_t *rx;
    size_t size;
    // trampolines at the start of the chunk
    uint32_t *t_enter, *t_exit_chain, *t_exit_pc, *t_exit_saved, *t_helper;
    uint32_t *t_far_chain;   // chain exit through the indirect table (far target, no veneer)
    uint32_t *t_stub[JIT_NSTUBS];
    uint32_t *veneer_next, *veneer_end;   // far-jump veneers at the end of the chunk
    // blocks placed in this chunk, in address order (for signal handler lookup)
    struct jit_block **blocks;
    size_t nblocks, blocks_cap;
};
struct jit_chunk *jit_chunk_of(uintptr_t pc);
void jit_chunk_register(struct jit_chunk *c);
void jit_chunk_unregister(struct jit_chunk *c);

// ---------------------------------------------------------------------------
// Assembler buffer (emit.c / translate.c)
// ---------------------------------------------------------------------------
struct asmbuf {
    uint32_t *w;
    uint32_t n, cap;
    bool oom;   // a word was dropped: out of host memory, the buffer is garbage
};
void ab_put(struct asmbuf *b, uint32_t insn);

// kernel/memory.c: true for every Nth host allocation with ISH_FAIL_HOST_ALLOC=N
// (fault injection for the out-of-memory paths).
bool mem_host_alloc_fails(void);

// Trampolines: emitted at chunk start. Returns words used.
uint32_t jit_emit_trampolines(struct jit_chunk *c, uint32_t *rw, uint32_t *rx);

// Translation: produce a block for guest pc. Returns NULL if the first
// instruction can't be translated (caller falls back to the gadget engine).
// tier 1: compact code (shared TLB stubs) plus an execution counter;
// tier 2: inline TLB lookups, for blocks that ran JIT_PROMOTE_AFTER times.
struct jit_block *jit_translate(struct jit_mm *mm, struct jit_ctx *ctx, addr_t pc, uint64_t gen, int tier);

// Place an image for guest pc into the mm's code cache. Returns the block,
// (struct jit_block *) -1 if the mm's invalidation generation moved past gen
// (retry), or -2 if there is no code memory right now.
struct jit_block *jit_install_image(struct jit_mm *mm, addr_t pc, const struct jit_image *img, uint64_t gen);

// Persistent translation cache (pcache.c). Lookup returns an image whose
// guest bytes equal code[0 .. img->ninsn) exactly; offer stores one.
bool jit_pcache_lookup(addr_t pc, const uint32_t *code, int ncode, struct jit_image *img);
void jit_pcache_offer(addr_t pc, const uint32_t *code, const struct jit_image *img);
void jit_pcache_save(void);
void jit_pcache_tick(void);
bool jit_pcache_wanted(struct jit_ctx *ctx, addr_t pc);
void jit_pcache_stats(uint64_t *hit, uint64_t *miss, uint64_t *offer);

// Patching
void jit_patch_branch(uint32_t *slot_rx, uint32_t *target_rx);

#endif
