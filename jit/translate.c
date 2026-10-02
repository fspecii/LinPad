// Guest AArch64 -> host AArch64 block translator.
//
// Most instructions are copied with only their register fields renamed
// (identity for most registers, see jit_g2h). Memory accesses get an inline
// software-TLB lookup, branches become chainable exits, and a few system
// instructions are emulated. Anything else ends the block with a JR_FALLBACK
// exit so the gadget engine runs that one instruction.
#include <string.h>
#include <stdlib.h>
#include "jit/jit_internal.h"
#include "jit/emit.h"
#include "emu/tlb.h"
#include "emu/interrupt.h"

// Identifies this translator build for the persistent cache (pcache.c).
const char jit_translator_build[] = "translate.c " __DATE__ " " __TIME__;

const int8_t jit_g2h[32] = {
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
    -1, -1, -1, -1, -1,           // x11-x15 spilled
    16, 17,
    -1,                           // x18 spilled
    19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30,
    HR_SP,                        // guest SP
};

#define MAX_INSNS 200

enum { HOT = 0, COLD = 1 };
enum { FX_B26, FX_B19, FX_B14, FX_ADR };
enum { TGT_LABEL, TGT_EXIT_CHAIN, TGT_EXIT_PC, TGT_HELPER, TGT_LIT, TGT_CNT, TGT_STUB = 16 };   // TGT_STUB + variant

struct label { uint8_t buf; uint32_t idx; };
struct fixup {
    uint8_t buf, kind, tgt;   // tgt >= TGT_STUB: load stub variant tgt - TGT_STUB
    uint32_t idx;
    struct label l;
};

struct tr {
    struct asmbuf b[2];
    struct fixup *fx;
    uint32_t nfx, capfx;
    struct { uint8_t buf; uint32_t idx; uint32_t gi; uint32_t borrow; } *map;
    uint32_t nmap, capmap;
    addr_t start, pc;     // pc = address of the instruction being translated
    uint32_t gi;          // guest instruction index
    bool ended;
    int tier;
};

void ab_put(struct asmbuf *b, uint32_t insn) {
    if (b->n == b->cap) {
        b->cap = b->cap ? b->cap * 2 : 256;
        b->w = realloc(b->w, b->cap * 4);
    }
    b->w[b->n++] = insn;
}

static inline void put(struct tr *t, int buf, uint32_t insn) { ab_put(&t->b[buf], insn); }
static inline struct label here(struct tr *t, int buf) { return (struct label) {buf, t->b[buf].n}; }

static void add_fix(struct tr *t, int buf, int kind, int tgt, struct label l) {
    if (t->nfx == t->capfx) {
        t->capfx = t->capfx ? t->capfx * 2 : 64;
        t->fx = realloc(t->fx, t->capfx * sizeof(*t->fx));
    }
    t->fx[t->nfx++] = (struct fixup) {.buf = buf, .kind = kind, .tgt = tgt, .idx = t->b[buf].n, .l = l};
}
static void put_fix(struct tr *t, int buf, uint32_t insn, int kind, int tgt, struct label l) {
    add_fix(t, buf, kind, tgt, l);
    put(t, buf, insn);
}
static void mark_map_b(struct tr *t, int buf, uint32_t borrow) {
    if (t->nmap == t->capmap) {
        t->capmap = t->capmap ? t->capmap * 2 : 64;
        t->map = realloc(t->map, t->capmap * sizeof(*t->map));
    }
    t->map[t->nmap++] = (typeof(*t->map)) {buf, t->b[buf].n, t->gi, borrow};
}
static void mark_map(struct tr *t, int buf) { mark_map_b(t, buf, 0); }

static void mov_imm64(struct tr *t, int buf, int rd, uint64_t v) {
    int zeros = 0, ones = 0;
    for (int i = 0; i < 4; i++) {
        uint16_t h = v >> (16 * i);
        zeros += h == 0;
        ones += h == 0xffff;
    }
    if (ones > zeros) {
        bool first = true;
        for (int i = 0; i < 4; i++) {
            uint16_t h = v >> (16 * i);
            if (h == 0xffff)
                continue;
            put(t, buf, first ? e_movn(rd, ~h, i) : e_movk(rd, h, i));
            first = false;
        }
        if (first)
            put(t, buf, e_movn(rd, 0, 0));
        return;
    }
    bool first = true;
    for (int i = 0; i < 4; i++) {
        uint16_t h = v >> (16 * i);
        if (h == 0)
            continue;
        put(t, buf, first ? e_movz(rd, h, i) : e_movk(rd, h, i));
        first = false;
    }
    if (first)
        put(t, buf, e_movz(rd, 0, 0));
}

// rd = rn + imm (rd, rn are host regs; rn may be HR_SP-as-x15, never real SP)
static void add_imm64(struct tr *t, int buf, int rd, int rn, int64_t imm) {
    if (imm == 0) {
        if (rd != rn)
            put(t, buf, e_mov(rd, rn));
        return;
    }
    uint64_t a = imm < 0 ? -(uint64_t) imm : (uint64_t) imm;
    if (a < (1 << 24)) {
        uint32_t lo = a & 0xfff, hi = a >> 12;
        int src = rn;
        if (hi) {
            put(t, buf, imm < 0 ? e_sub_imm(rd, src, hi, 1) : e_add_imm(rd, src, hi, 1));
            src = rd;
        }
        if (lo || src != rd)
            put(t, buf, imm < 0 ? e_sub_imm(rd, src, lo, 0) : e_add_imm(rd, src, lo, 0));
        return;
    }
    int tmp = rd == HR_T2 ? HR_T1 : HR_T2;
    mov_imm64(t, buf, tmp, (uint64_t) imm);
    put(t, buf, e_add_sh(rd, rn, tmp, 0, 0));
}

// rd = guest address v. Code is position independent with respect to guest
// addresses: every block ends with a literal holding its own guest start PC
// (written when the block is installed), and guest PCs are formed as
// literal + delta. That lets a translation be reused at another address
// (persistent translation cache, pcache.c).
extern int jit_tier1_compact;

static void guest_addr(struct tr *t, int buf, int rd, addr_t v) {
    if (t->tier != 1) {
        // tier 2 is never cached: a constant is cheaper than the literal load
        mov_imm64(t, buf, rd, v);
        return;
    }
    put_fix(t, buf, 0x58000000u | rd, FX_B19, TGT_LIT, (struct label) {0});   // ldr rd, =block pc
    add_imm64(t, buf, rd, rd, (int64_t) (v - t->start));
}

// ---------------------------------------------------------------------------
// Operand renaming
// ---------------------------------------------------------------------------
#define R 1
#define W 2
#define RW 3
struct opnd { int8_t shift; int8_t role; bool sp; };
#define OP(sh, role, sp) ((struct opnd) {sh, role, sp})

struct rename {
    uint32_t out;
    int n;
    struct { int g, h, role; } t[4];
};

// Rename GPR fields of insn. temps: list of host scratch regs that may be used
// for spilled guest regs. Returns false if out of temps.
static bool rename_ops(struct rename *rn, uint32_t insn, const struct opnd *ops, int nops,
                       const int *temps, int ntemps) {
    rn->out = insn;
    rn->n = 0;
    for (int i = 0; i < nops; i++) {
        int f = (insn >> ops[i].shift) & 31;
        int h;
        if (f == 31) {
            h = ops[i].sp ? HR_SP : HR_ZR;
        } else if (jit_g2h[f] >= 0) {
            h = jit_g2h[f];
        } else {
            int k;
            for (k = 0; k < rn->n; k++)
                if (rn->t[k].g == f)
                    break;
            if (k == rn->n) {
                if (rn->n == ntemps)
                    return false;
                rn->t[k].g = f;
                rn->t[k].h = temps[k];
                rn->t[k].role = 0;
                rn->n++;
            }
            rn->t[k].role |= ops[i].role;
            h = rn->t[k].h;
        }
        rn->out = (rn->out & ~(31u << ops[i].shift)) | ((uint32_t) h << ops[i].shift);
    }
    return true;
}
static void rename_pre(struct tr *t, int buf, struct rename *rn) {
    for (int k = 0; k < rn->n; k++)
        if (rn->t[k].role & R)
            put(t, buf, e_ldr_x(rn->t[k].h, HR_CTX, CTX_REG(rn->t[k].g)));
}
static void rename_post(struct tr *t, int buf, struct rename *rn) {
    for (int k = 0; k < rn->n; k++)
        if (rn->t[k].role & W)
            put(t, buf, e_str_x(rn->t[k].h, HR_CTX, CTX_REG(rn->t[k].g)));
}


static int generic(struct tr *t, uint32_t insn, const struct opnd *ops, int nops) {
    struct rename rn;
    int temps[4] = {HR_T0, HR_T1, HR_T2, -1};
    int nt = 3;
    if (!rename_ops(&rn, insn, ops, nops, temps, nt)) {
        // four distinct spilled registers (e.g. smaddl x15, w14, w12, x11):
        // borrow a home register the instruction doesn't use
        for (int h = 0; h <= 10 && nt == 3; h++) {
            bool used = false;
            for (int k = 0; k < nops; k++)
                if ((int) ((insn >> ops[k].shift) & 31) == h)
                    used = true;
            if (!used)
                temps[nt++] = h;
        }
        if (!rename_ops(&rn, insn, ops, nops, temps, nt))
            return -1;
    }
    bool borrowed = rn.n == 4;
    if (borrowed)
        put(t, HOT, e_str_x(temps[3], HR_CTX, CTX_REG(temps[3])));
    rename_pre(t, HOT, &rn);
    put(t, HOT, rn.out);
    rename_post(t, HOT, &rn);
    if (borrowed)
        put(t, HOT, e_ldr_x(temps[3], HR_CTX, CTX_REG(temps[3])));
    return 1;
}

// Host register currently holding guest reg g (loading spilled into tmp).
static int read_greg(struct tr *t, int buf, int g, int tmp, bool sp) {
    if (g == 31)
        return sp ? HR_SP : HR_ZR;
    if (jit_g2h[g] >= 0)
        return jit_g2h[g];
    put(t, buf, e_ldr_x(tmp, HR_CTX, CTX_REG(g)));
    return tmp;
}
// Write host reg src to guest reg g (g != 31 or sp)
static void write_greg(struct tr *t, int buf, int g, int src, bool sp) {
    int h = g == 31 ? (sp ? HR_SP : HR_ZR) : jit_g2h[g];
    if (h == HR_ZR)
        return;
    if (h >= 0) {
        if (h != src)
            put(t, buf, e_mov(h, src));
    } else {
        put(t, buf, e_str_x(src, HR_CTX, CTX_REG(g)));
    }
}

// ---------------------------------------------------------------------------
// Exits
// ---------------------------------------------------------------------------
static void exit_pc(struct tr *t, int buf, addr_t pc, int reason) {
    guest_addr(t, buf, HR_T0, pc);
    put(t, buf, e_movz(HR_T2, reason, 0));
    put_fix(t, buf, e_b(0), FX_B26, TGT_EXIT_PC, (struct label) {0});
}

// Chainable exit to a known guest pc. Emitted at the current position of buf.
static void exit_direct(struct tr *t, int buf, addr_t target) {
    if (target <= t->pc) {
        // possible loop: poll the exit flag before the (patchable) slot
        put(t, buf, e_ldrb(HR_T0, HR_CTX, CTX_OFF(exitflag)));
        put(t, buf, e_cbnz_w(HR_T0, 2));
    }
    struct label slot = here(t, buf);
    put(t, buf, e_nop());
    guest_addr(t, buf, HR_T0, target);
    put_fix(t, buf, e_adr(HR_T1, 0), FX_ADR, TGT_LABEL, slot);
    put_fix(t, buf, e_b(0), FX_B26, TGT_EXIT_CHAIN, (struct label) {0});
}

// Helper call: T2 = address of the inline literal word (kind | desc << 2 |
// guest insn index << 16). Doesn't touch x30, so guest x30 stays live.
static void call_helper(struct tr *t, int buf, int kind, uint32_t desc) {
    put(t, buf, e_adr(HR_T2, 8));
    put_fix(t, buf, e_b(0), FX_B26, TGT_HELPER, (struct label) {0});
    put(t, buf, kind | (desc << 2) | (t->gi << 24));   // gi < MAX_INSNS + 1 <= 255
}

// ---------------------------------------------------------------------------
// Memory accesses
// ---------------------------------------------------------------------------
enum { AK_IMM, AK_REG, AK_LIT };
struct memop {
    int base;                 // guest base reg (31 = SP)
    int ak;
    int64_t imm;              // AK_IMM offset
    int rm, rm_opt, rm_sh;    // AK_REG
    uint64_t lit;             // AK_LIT address
    int size;
    bool write, atomic, sync;
    uint32_t insn_base;       // Rn field = HR_T1, data fields still guest numbers
    bool regoff_ok;
    uint32_t insn_regoff;     // Rn = HR_T1, Rm = 0 (filled with A)
    struct opnd data[3];
    int ndata;
    int wb;                   // 0 none, 1 imm, 2 reg
    int64_t wb_imm;
    int wb_rm;
};

#define DESC(size, write, atomic) ((size) | ((write) << 8) | ((atomic) << 9))
// Compact load slow path: the helper takes the guest address from host
// register `areg` and returns the TLB addend (host - guest) in T1, then the
// slow path branches back into the hot path, which redoes the access.
#define DESC_ADDEND(size, atomic, areg) ((size) | ((atomic) << 9) | (1 << 10) | ((areg) << 11))

static void emit_changes_check(struct tr *t) {
    // Before atomics/acquire-release: if another thread changed the page
    // tables (e.g. CoW), refill the TLB so we don't use a stale page.
    struct label top = here(t, HOT);
    put(t, HOT, e_ldr_x(HR_T2, HR_CTX, CTX_OFF(changes_ptr)));
    put(t, HOT, e_ldr_x(HR_T2, HR_T2, 0));
    put(t, HOT, e_ldr_x(HR_T1, HR_CTX, CTX_OFF(mem_changes)));
    put(t, HOT, e_eor_sh(HR_T2, HR_T2, HR_T1, 0, 0));
    struct label cold = here(t, COLD);
    put_fix(t, HOT, e_cbnz_x(HR_T2, 0), FX_B19, TGT_LABEL, cold);
    call_helper(t, COLD, JH_FLUSH, 0);
    put_fix(t, COLD, e_b(0), FX_B26, TGT_LABEL, top);
}

static int emit_mem(struct tr *t, struct memop *m) {
    if (m->sync)
        emit_changes_check(t);

    // Data operand temps
    struct rename rn;
    int A;
    bool use_regoff = m->regoff_ok;

    // Address -> A
    if (m->ak == AK_IMM && m->imm == 0 && (m->base == 31 || jit_g2h[m->base] >= 0)) {
        A = m->base == 31 ? HR_SP : jit_g2h[m->base];
    } else {
        A = HR_T0;
        if (m->ak == AK_LIT) {
            guest_addr(t, HOT, HR_T0, m->lit);
        } else {
            int b = read_greg(t, HOT, m->base, HR_T0, true);
            if (m->ak == AK_IMM) {
                add_imm64(t, HOT, HR_T0, b, m->imm);
            } else {
                int r = read_greg(t, HOT, m->rm, HR_T2, false);
                put(t, HOT, e_add_ext(HR_T0, b, r, m->rm_opt, m->rm_sh));
            }
        }
    }

    // Choose data temps: T1 always holds the host address at the access.
    int temps[4], nt = 0;
    int nborrow = 0;
    if (use_regoff) {
        if (A != HR_T0)
            temps[nt++] = HR_T0;
        temps[nt++] = HR_T2;
    } else {
        temps[nt++] = HR_T0;
        temps[nt++] = HR_T2;
    }
    if (!rename_ops(&rn, m->insn_base, m->data, m->ndata, temps, nt)) {
        use_regoff = false;
        nt = 0;
        temps[nt++] = HR_T0;
        temps[nt++] = HR_T2;
        if (!rename_ops(&rn, m->insn_base, m->data, m->ndata, temps, nt)) {
            // Borrow home registers the instruction doesn't use (e.g. stxp
            // w12, x13, x14: three spilled operands). Their guest values are
            // parked in ctx while they carry data; the block map's borrow mask
            // tells the fault handler to take them from ctx.
            static const int cand[] = {9, 10, 8, 7, 6, 5, 4, 3, 2, 1, 0, 16, 17, 19, 20, 21};   // identity homes only
            for (unsigned c = 0; c < sizeof(cand) / sizeof(cand[0]) && nt < 4; c++) {
                int h = cand[c];
                bool used = h == A || (m->base != 31 && jit_g2h[m->base] == h);
                for (int k = 0; k < m->ndata; k++)
                    if ((int) ((m->insn_base >> m->data[k].shift) & 31) == h)
                        used = true;
                if (!used)
                    temps[nt++] = h;
            }
            if (!rename_ops(&rn, m->insn_base, m->data, m->ndata, temps, nt))
                return -1;
            nborrow = rn.n > 2 ? rn.n - 2 : 0;
        }
    }
    // A must survive until the access in the regoff form; in the base form A
    // is consumed by the add before data temps are loaded.
    uint32_t base_insn = rn.out;
    uint32_t regoff_insn = 0;
    if (use_regoff) {
        struct rename rn2;
        rename_ops(&rn2, m->insn_regoff, m->data, m->ndata, temps, nt);
        regoff_insn = rn2.out | ((uint32_t) A << 16);
    }

    // Accesses of common sizes call a shared per-chunk TLB stub (bl): 2-3
    // words instead of the 11-word inline lookup plus a cold slow path.
    int szi = -1;
    switch (m->size) {
        case 1: szi = 0; break; case 2: szi = 1; break; case 4: szi = 2; break;
        case 8: szi = 3; break; case 16: szi = 4; break; case 32: szi = 5; break;
    }
    if (t->tier == 1 && jit_tier1_compact && nborrow == 0 && szi >= 0) {
        if (A != HR_T0 && A != HR_SP) {
            put(t, HOT, e_mov(HR_T0, A));
            A = HR_T0;
            if (use_regoff) {
                // T0 now holds the address up to the access: data temps can
                // only use T2 (else fall back to the base form)
                int t2[1] = {HR_T2};
                struct rename rn1, rn2;
                if (rename_ops(&rn1, m->insn_base, m->data, m->ndata, t2, 1)) {
                    rn = rn1;
                    base_insn = rn1.out;
                    rename_ops(&rn2, m->insn_regoff, m->data, m->ndata, t2, 1);
                    regoff_insn = rn2.out | ((uint32_t) A << 16);
                } else {
                    use_regoff = false;
                    int t02[2] = {HR_T0, HR_T2};
                    rename_ops(&rn, m->insn_base, m->data, m->ndata, t02, 2);
                    base_insn = rn.out;
                }
            }
        }
        // guest x30 lives in host x30: park it across the bl
        put(t, HOT, e_str_x(30, HR_CTX, CTX_REG(30)));
        put_fix(t, HOT, e_bl(0), FX_B26, TGT_STUB + JIT_STUB(szi, m->atomic, A == HR_SP, m->write), (struct label) {0});
        put(t, HOT, e_ldr_x(30, HR_CTX, CTX_REG(30)));
        if (use_regoff) {
            rename_pre(t, HOT, &rn);
            mark_map(t, HOT);
            put(t, HOT, regoff_insn);
        } else {
            put(t, HOT, e_add_sh(HR_T1, HR_T1, A, 0, 0));
            rename_pre(t, HOT, &rn);
            mark_map(t, HOT);
            put(t, HOT, base_insn);
        }
        rename_post(t, HOT, &rn);
        goto writeback;
    }

    uint32_t bmask = 0;
    for (int k = 2; k < 2 + nborrow; k++)
        bmask |= 1u << rn.t[k].h;
    struct label slow = here(t, COLD);
    // TLB lookup
    put(t, HOT, e_eor_sh(HR_T1, A, A, 1, 13));
    put(t, HOT, e_ubfx(HR_T1, HR_T1, 12, JIT_TLB_BITS));
    put(t, HOT, e_add_sh(HR_T1, HR_CTX, HR_T1, 0, 5));
    put(t, HOT, e_ldr_x(HR_T2, HR_T1, JIT_TLB_OFF + (m->write ? 8 : 0)));
    put(t, HOT, e_sub_sh(HR_T2, A, HR_T2, 0, 0));
    if (m->size > 1)
        put(t, HOT, e_add_imm(HR_T2, HR_T2, m->size - 1, 0));
    put(t, HOT, e_lsr(HR_T2, HR_T2, 12));
    put_fix(t, HOT, e_cbnz_x(HR_T2, 0), FX_B19, TGT_LABEL, slow);
    put(t, HOT, e_ldr_x(HR_T1, HR_T1, JIT_TLB_OFF + 16));
    bool compact = !m->write && nborrow == 0;
    struct label resume = here(t, HOT);
    if (use_regoff) {
        rename_pre(t, HOT, &rn);
        mark_map(t, HOT);
        put(t, HOT, regoff_insn);
    } else {
        put(t, HOT, e_add_sh(HR_T1, HR_T1, A, 0, 0));
        // Borrowed home registers: park their guest values in ctx. The map
        // tells the fault handler to take them from ctx, not the registers.
        for (int k = 2; k < 2 + nborrow; k++)
            put(t, HOT, e_str_x(rn.t[k].h, HR_CTX, CTX_REG(rn.t[k].h)));
        rename_pre(t, HOT, &rn);
        mark_map_b(t, HOT, bmask);
        put(t, HOT, base_insn);
        if (bmask)
            mark_map(t, HOT);
    }
    rename_post(t, HOT, &rn);
    for (int k = 2; k < 2 + nborrow; k++)
        put(t, HOT, e_ldr_x(rn.t[k].h, HR_CTX, CTX_REG(rn.t[k].h)));
    struct label join = here(t, HOT);

    // Slow path
    mark_map(t, COLD);
    if (compact) {
        call_helper(t, COLD, JH_MEM, DESC_ADDEND(m->size, m->atomic, A));
        put_fix(t, COLD, e_b(0), FX_B26, TGT_LABEL, resume);
    } else {
        if (A != HR_T0)
            put(t, COLD, e_mov(HR_T0, A));
        call_helper(t, COLD, JH_MEM, DESC(m->size, m->write, m->atomic));
        for (int k = 2; k < 2 + nborrow; k++)
            put(t, COLD, e_str_x(rn.t[k].h, HR_CTX, CTX_REG(rn.t[k].h)));
        rename_pre(t, COLD, &rn);
        put(t, COLD, base_insn);
        rename_post(t, COLD, &rn);
        for (int k = 2; k < 2 + nborrow; k++)
            put(t, COLD, e_ldr_x(rn.t[k].h, HR_CTX, CTX_REG(rn.t[k].h)));
        if (m->write && !m->atomic) {
            put(t, COLD, e_ldrb(HR_T2, HR_CTX, CTX_OFF(bounce_active)));
            put_fix(t, COLD, e_cbz_w(HR_T2, 0), FX_B19, TGT_LABEL, join);
            call_helper(t, COLD, JH_COMMIT, 0);
        }
        put_fix(t, COLD, e_b(0), FX_B26, TGT_LABEL, join);
    }

writeback:
    if (m->wb && (m->base == 31 || jit_g2h[m->base] >= 0)) {
        int h = m->base == 31 ? HR_SP : jit_g2h[m->base];
        if (m->wb == 1) {
            add_imm64(t, HOT, h, h, m->wb_imm);
        } else {
            int r = read_greg(t, HOT, m->wb_rm, HR_T2, false);
            put(t, HOT, e_add_sh(h, h, r, 0, 0));
        }
    } else if (m->wb) {
        int b = read_greg(t, HOT, m->base, HR_T0, true);
        if (m->wb == 1) {
            add_imm64(t, HOT, HR_T0, b, m->wb_imm);
        } else {
            int r = read_greg(t, HOT, m->wb_rm, HR_T2, false);
            put(t, HOT, e_add_sh(HR_T0, b, r, 0, 0));
        }
        write_greg(t, HOT, m->base, HR_T0, true);
    }
    return 1;
}

static inline int64_t sext(uint64_t v, int bits) {
    return (int64_t) (v << (64 - bits)) >> (64 - bits);
}

static int tr_ldst(struct tr *t, uint32_t insn) {
    struct memop m = {0};
    int rt = insn & 31, rn = (insn >> 5) & 31;
    m.base = rn;
    m.ak = AK_IMM;

    // Load/store exclusive, ordered, CAS
    if ((insn & 0x3f000000) == 0x08000000) {
        int size = insn >> 30;
        int o2 = (insn >> 23) & 1, L = (insn >> 22) & 1, o1 = (insn >> 21) & 1;
        m.atomic = true;
        m.sync = true;
        m.insn_base = (insn & ~(31u << 5)) | (HR_T1 << 5);
        if (!o2 && !o1) {
            m.size = 1 << size;
            m.write = !L;
            if (L)
                m.data[m.ndata++] = OP(0, W, false);
            else {
                m.data[m.ndata++] = OP(16, W, false);
                m.data[m.ndata++] = OP(0, R, false);
            }
        } else if (!o2 && o1) {
            if (!(size & 2))
                return -1;  // CASP: gadget (CAS semantics, no monitor state)
            m.size = 2 << (size & 1 ? 3 : 2);
            m.write = !L;
            if (L) {
                m.data[m.ndata++] = OP(0, W, false);
                m.data[m.ndata++] = OP(10, W, false);
            } else {
                m.data[m.ndata++] = OP(16, W, false);
                m.data[m.ndata++] = OP(0, R, false);
                m.data[m.ndata++] = OP(10, R, false);
            }
        } else if (o2 && !o1) {
            m.size = 1 << size;
            m.write = !L;
            m.data[m.ndata++] = OP(0, L ? W : R, false);
        } else {
            m.size = 1 << size;
            m.write = true;
            m.data[m.ndata++] = OP(16, RW, false);
            m.data[m.ndata++] = OP(0, R, false);
        }
        return emit_mem(t, &m);
    }

    // Load register (literal)
    if ((insn & 0x3b000000) == 0x18000000) {
        int opc = insn >> 30, V = (insn >> 26) & 1;
        m.ak = AK_LIT;
        m.lit = t->pc + sext((insn >> 5) & 0x7ffff, 19) * 4;
        if (!V && opc == 3)
            return 1;  // PRFM literal
        uint32_t size, nopc;
        if (V) {
            static const uint32_t sz[3] = {2, 3, 0}, oc[3] = {1, 1, 3};
            if (opc == 3)
                return -1;
            size = sz[opc]; nopc = oc[opc];
            m.size = 4 << opc;
        } else {
            size = opc == 1 ? 3 : 2;
            nopc = opc == 2 ? 2 : 1;
            m.size = opc == 1 ? 8 : 4;
            m.data[m.ndata++] = OP(0, W, false);
        }
        m.insn_base = (size << 30) | 0x39000000u | (V << 26) | (nopc << 22) | (HR_T1 << 5) | rt;
        m.regoff_ok = true;
        m.insn_regoff = (size << 30) | 0x38206800u | (V << 26) | (nopc << 22) | (HR_T1 << 5) | rt;
        return emit_mem(t, &m);
    }

    // Load/store pair (incl. no-allocate)
    if ((insn & 0x3a000000) == 0x28000000) {
        int opc = insn >> 30, V = (insn >> 26) & 1, type = (insn >> 23) & 3, L = (insn >> 22) & 1;
        int scale;
        if (V) {
            if (opc == 3)
                return -1;
            scale = 2 + opc;
        } else {
            if (opc == 3 || (opc == 1 && !L))
                return -1;   // STGP / unallocated
            scale = opc == 2 ? 3 : 2;
            if (opc == 1 && type == 0)
                return -1;
        }
        int64_t off = sext((insn >> 15) & 0x7f, 7) << scale;
        m.size = 2 << scale;
        m.write = !L;
        if (type == 1) {               // post-index
            m.wb = 1; m.wb_imm = off;
        } else if (type == 3) {        // pre-index
            m.imm = off; m.wb = 1; m.wb_imm = off;
        } else {
            m.imm = off;
        }
        m.insn_base = (insn & 0xfc407c1fu) | (2u << 23) | (HR_T1 << 5);
        if (!V) {
            m.data[m.ndata++] = OP(0, L ? W : R, false);
            m.data[m.ndata++] = OP(10, L ? W : R, false);
        }
        return emit_mem(t, &m);
    }

    // Single register forms: size 111 V 0x opc ...
    if ((insn & 0x3a000000) == 0x38000000) {
        int size = insn >> 30, V = (insn >> 26) & 1, opc = (insn >> 22) & 3;
        bool uimm = (insn >> 24) & 1;
        if (!uimm && (insn & (1 << 21))) {
            int kind = (insn >> 10) & 3;
            if (kind == 0) {
                // Atomic memory operations
                if (V)
                    return -1;
                int o3 = (insn >> 15) & 1, aop = (insn >> 12) & 7;
                m.atomic = true;
                m.sync = true;
                m.size = 1 << size;
                m.insn_base = (insn & ~(31u << 5)) | (HR_T1 << 5);
                if (o3 && aop == 4) {          // LDAPR
                    if (((insn >> 16) & 31) != 31)
                        return -1;
                    m.write = false;
                    m.data[m.ndata++] = OP(0, W, false);
                } else if (!o3 || aop == 0) {  // LDADD..LDUMIN, SWP
                    m.write = true;
                    m.data[m.ndata++] = OP(16, R, false);
                    m.data[m.ndata++] = OP(0, W, false);
                } else {
                    return -1;
                }
                return emit_mem(t, &m);
            }
            if (kind != 2)
                return -1;   // PAC loads
            // register offset
            int opt = (insn >> 13) & 7;
            if (!(opt & 2))
                return -1;
            m.ak = AK_REG;
            m.rm = (insn >> 16) & 31;
            m.rm_opt = opt;
        } else if (!uimm) {
            int kind = (insn >> 10) & 3;
            int64_t imm9 = sext((insn >> 12) & 0x1ff, 9);
            if (kind == 1) {           // post
                m.wb = 1; m.wb_imm = imm9;
            } else if (kind == 3) {    // pre
                m.imm = imm9; m.wb = 1; m.wb_imm = imm9;
            } else {                   // unscaled, unprivileged
                m.imm = imm9;
            }
        }
        int scale = size;
        if (V) {
            if (opc & 2) {
                if (size != 0)
                    return -1;
                scale = 4;
            }
        } else {
            if (size == 3 && opc == 2)
                return 1;   // PRFM / PRFUM: no-op
            if ((size == 3 && opc == 3) || (size == 2 && opc == 3))
                return -1;
        }
        if (uimm)
            m.imm = (int64_t) ((insn >> 10) & 0xfff) << scale;
        if (m.ak == AK_REG)
            m.rm_sh = ((insn >> 12) & 1) ? scale : 0;
        m.size = 1 << scale;
        m.write = V ? !(opc & 1) : opc == 0;
        m.insn_base = ((uint32_t) size << 30) | 0x39000000u | (V << 26) | (opc << 22) | (HR_T1 << 5) | rt;
        m.regoff_ok = true;
        m.insn_regoff = ((uint32_t) size << 30) | 0x38206800u | (V << 26) | (opc << 22) | (HR_T1 << 5) | rt;
        if (!V)
            m.data[m.ndata++] = OP(0, m.write ? R : W, false);
        return emit_mem(t, &m);
    }

    // AdvSIMD load/store multiple structures
    if ((insn & 0xbfbf0000) == 0x0c000000 || (insn & 0xbfa00000) == 0x0c800000) {
        int Q = (insn >> 30) & 1, L = (insn >> 22) & 1, opcode = (insn >> 12) & 15;
        int nregs;
        switch (opcode) {
            case 0: case 2: nregs = 4; break;
            case 4: case 6: nregs = 3; break;
            case 7: nregs = 1; break;
            case 8: case 10: nregs = 2; break;
            default: return -1;
        }
        if (((insn >> 10) & 3) == 3 && !Q && (opcode == 0 || opcode == 4 || opcode == 8))
            return -1;  // .1d with LD2/3/4 is reserved
        m.size = nregs * (Q ? 16 : 8);
        m.write = !L;
        if (insn & (1 << 23)) {
            int rm = (insn >> 16) & 31;
            if (rm == 31) {
                m.wb = 1; m.wb_imm = m.size;
            } else {
                m.wb = 2; m.wb_rm = rm;
            }
        }
        m.insn_base = (insn & ~((1u << 23) | (31u << 16) | (31u << 5))) | (HR_T1 << 5);
        return emit_mem(t, &m);
    }

    // AdvSIMD load/store single structure
    if ((insn & 0xbf9f0000) == 0x0d000000 || (insn & 0xbf800000) == 0x0d800000) {
        int Q = (insn >> 30) & 1, L = (insn >> 22) & 1, Rbit = (insn >> 21) & 1;
        int opcode = (insn >> 13) & 7, S = (insn >> 12) & 1, size = (insn >> 10) & 3;
        int selem = (((opcode & 1) << 1) | Rbit) + 1;
        int esize;
        switch (opcode >> 1) {
            case 0: esize = 1; break;
            case 1: if (size & 1) return -1; esize = 2; break;
            case 2:
                if (size & 2) return -1;
                if (size == 1 && S) return -1;
                esize = size == 0 ? 4 : 8;
                break;
            default:
                if (!L || S) return -1;
                esize = 1 << size;
                break;
        }
        (void) Q;
        m.size = selem * esize;
        m.write = !L;
        if (insn & (1 << 23)) {
            int rm = (insn >> 16) & 31;
            if (rm == 31) {
                m.wb = 1; m.wb_imm = m.size;
            } else {
                m.wb = 2; m.wb_rm = rm;
            }
        }
        m.insn_base = (insn & ~((1u << 23) | (31u << 16) | (31u << 5))) | (HR_T1 << 5);
        return emit_mem(t, &m);
    }

    return -1;
}

// ---------------------------------------------------------------------------
// Branches and system instructions
// ---------------------------------------------------------------------------
static void indirect(struct tr *t, int target_host) {
    if (target_host != HR_T0)
        put(t, HOT, e_mov(HR_T0, target_host));
    struct label poll = here(t, COLD);
    put(t, HOT, e_ldrb(HR_T1, HR_CTX, CTX_OFF(exitflag)));
    put_fix(t, HOT, e_cbnz_w(HR_T1, 0), FX_B19, TGT_LABEL, poll);
    put(t, COLD, e_movz(HR_T2, JR_POLL, 0));
    put_fix(t, COLD, e_b(0), FX_B26, TGT_EXIT_PC, (struct label) {0});

    put(t, HOT, e_ldr_x(HR_T1, HR_CTX, CTX_OFF(itab)));
    put(t, HOT, e_ubfx(HR_T2, HR_T0, 2, JIT_ITAB_BITS));
    put(t, HOT, e_add_sh(HR_T1, HR_T1, HR_T2, 0, 4));
    put(t, HOT, e_ldp_x(HR_T2, HR_T1, HR_T1, 0));
    put(t, HOT, e_eor_sh(HR_T2, HR_T2, HR_T0, 0, 0));
    struct label miss = here(t, COLD);
    put_fix(t, HOT, e_cbnz_x(HR_T2, 0), FX_B19, TGT_LABEL, miss);
    put(t, HOT, e_br(HR_T1));
    put(t, COLD, e_movz(HR_T2, JR_INDIRECT, 0));
    put_fix(t, COLD, e_b(0), FX_B26, TGT_EXIT_PC, (struct label) {0});
}

static int tr_branch(struct tr *t, uint32_t insn) {
    addr_t next = t->pc + 4;

    if ((insn & 0x7c000000) == 0x14000000) {          // B, BL
        addr_t target = t->pc + sext(insn & 0x3ffffff, 26) * 4;
        if (insn >> 31)
            guest_addr(t, HOT, jit_g2h[30], next);
        exit_direct(t, HOT, target);
        return 0;
    }
    if ((insn & 0xff000010) == 0x54000000) {          // B.cond
        addr_t target = t->pc + sext((insn >> 5) & 0x7ffff, 19) * 4;
        int cond = insn & 15;
        if (cond >= 14) {
            exit_direct(t, HOT, target);
            return 0;
        }
        struct label taken = here(t, COLD);
        put_fix(t, HOT, e_bcond(cond, 0), FX_B19, TGT_LABEL, taken);
        exit_direct(t, COLD, target);
        exit_direct(t, HOT, next);
        return 0;
    }
    if ((insn & 0x7e000000) == 0x34000000 || (insn & 0x7e000000) == 0x36000000) {  // CB(N)Z, TB(N)Z
        bool tb = (insn & 0x7e000000) == 0x36000000;
        addr_t target = tb ? t->pc + sext((insn >> 5) & 0x3fff, 14) * 4
                           : t->pc + sext((insn >> 5) & 0x7ffff, 19) * 4;
        int h = read_greg(t, HOT, insn & 31, HR_T0, false);
        struct label taken = here(t, COLD);
        put_fix(t, HOT, (insn & ~31u) | h, tb ? FX_B14 : FX_B19, TGT_LABEL, taken);
        exit_direct(t, COLD, target);
        exit_direct(t, HOT, next);
        return 0;
    }
    if ((insn & 0xfffffc1f) == 0xd61f0000 || (insn & 0xfffffc1f) == 0xd63f0000 ||
        (insn & 0xfffffc1f) == 0xd65f0000) {          // BR, BLR, RET
        int rn = (insn >> 5) & 31;
        bool link = (insn & 0xfffffc1f) == 0xd63f0000;
        if (rn == 31) {
            put(t, HOT, e_mov(HR_T0, HR_ZR));
            rn = -1;
        }
        int h = rn < 0 ? HR_T0 : read_greg(t, HOT, rn, HR_T0, false);
        if (link) {
            if (h != HR_T0)
                put(t, HOT, e_mov(HR_T0, h));
            h = HR_T0;
            guest_addr(t, HOT, jit_g2h[30], next);
        }
        indirect(t, h);
        return 0;
    }
    if ((insn & 0xffe0001f) == 0xd4000001) {          // SVC
        exit_pc(t, HOT, next, JR_SYSCALL);
        return 0;
    }
    if ((insn & 0xffc00000) == 0xd5000000) {          // system
        if ((insn & 0xfffff01f) == 0xd503201f)        // HINT space (NOP, YIELD, PAC hints, BTI, ...)
            return 1;
        if ((insn & 0xfffff01f) == 0xd503301f) {      // CLREX, DSB, DMB, ISB, SB
            int op2 = (insn >> 5) & 7;
            if (op2 == 2 || op2 == 4 || op2 == 5 || op2 == 6 || op2 == 7) {
                put(t, HOT, insn);
                return 1;
            }
            return -1;
        }
        if ((insn & 0xffffffe0) == 0xd50b7520) {      // IC IVAU
            int h = read_greg(t, HOT, insn & 31, HR_T0, false);
            put(t, HOT, e_str_x(h, HR_CTX, CTX_OFF(ic_addr)));
            exit_pc(t, HOT, next, JR_ICIVAU);
            return 0;
        }
        uint32_t dc = insn & 0xffffffe0;
        if (dc == 0xd50b7e20 || dc == 0xd50b7b20 || dc == 0xd50b7a20 ||
            dc == 0xd50b7c20 || dc == 0xd50b7d20)      // DC C*VA*: no-op
            return 1;
        uint32_t sys = insn & 0xffffffe0;
        int rt = insn & 31;
        static const struct opnd rt_w = {0, W, false}, rt_r = {0, R, false};
        if (sys == 0xd53bd040) {                      // MRS Xt, TPIDR_EL0
            if (rt == 31) return 1;
            int h = jit_g2h[rt];
            if (h >= 0) {
                put(t, HOT, e_ldr_x(h, HR_CTX, CTX_OFF(cpu.tls_ptr)));
            } else {
                put(t, HOT, e_ldr_x(HR_T0, HR_CTX, CTX_OFF(cpu.tls_ptr)));
                put(t, HOT, e_str_x(HR_T0, HR_CTX, CTX_REG(rt)));
            }
            return 1;
        }
        if (sys == 0xd53b0020 || sys == 0xd53b00e0) {  // MRS CTR_EL0 / DCZID_EL0: same values as the gadget engine
            uint64_t v = sys == 0xd53b0020 ? 0x84448004 : 0x14;
            if (rt == 31) return 1;
            int h = jit_g2h[rt];
            mov_imm64(t, HOT, h >= 0 ? h : HR_T0, v);
            if (h < 0)
                put(t, HOT, e_str_x(HR_T0, HR_CTX, CTX_REG(rt)));
            return 1;
        }
        if (sys == 0xd51bd040) {                      // MSR TPIDR_EL0, Xt
            int h = read_greg(t, HOT, rt, HR_T0, false);
            put(t, HOT, e_str_x(h, HR_CTX, CTX_OFF(cpu.tls_ptr)));
            return 1;
        }
        if (sys == 0xd53b4200 || sys == 0xd53b4420 || sys == 0xd53b4400 ||   // MRS NZCV, FPSR, FPCR
            sys == 0xd53be040 || sys == 0xd53be000)                          // MRS CNTVCT_EL0, CNTFRQ_EL0
            return generic(t, insn, &rt_w, 1);
        if (sys == 0xd51b4200 || sys == 0xd51b4420)   // MSR NZCV, FPSR
            return generic(t, insn, &rt_r, 1);
        return -1;
    }
    return -1;
}

// ---------------------------------------------------------------------------
// Data processing
// ---------------------------------------------------------------------------
static int tr_dp_imm(struct tr *t, uint32_t insn) {
    int rd = insn & 31;
    switch ((insn >> 23) & 7) {
        case 0: case 1: {                             // ADR, ADRP
            int64_t imm = sext((((insn >> 5) & 0x7ffff) << 2) | ((insn >> 29) & 3), 21);
            if (rd == 31)
                return 1;
            int h = jit_g2h[rd];
            int r = h >= 0 ? h : HR_T0;
            if ((insn >> 31) && t->tier != 1) {
                mov_imm64(t, HOT, r, (t->pc & ~0xfffull) + (imm << 12));
            } else if (insn >> 31) {                  // ADRP: page of the block + imm pages
                put_fix(t, HOT, 0x58000000u | r, FX_B19, TGT_LIT, (struct label) {0});
                put(t, HOT, 0x92400000u | (52 << 16) | (51 << 10) | (r << 5) | r);   // and r, r, #~0xfff
                add_imm64(t, HOT, r, r, imm << 12);
            } else {
                guest_addr(t, HOT, r, t->pc + imm);
            }
            if (h < 0)
                put(t, HOT, e_str_x(HR_T0, HR_CTX, CTX_REG(rd)));
            return 1;
        }
        case 2: {                                     // ADD/SUB imm
            bool S = (insn >> 29) & 1;
            struct opnd ops[2] = {OP(0, W, !S), OP(5, R, true)};
            return generic(t, insn, ops, 2);
        }
        case 3:
            return -1;                                // MTE tag arithmetic
        case 4: {                                     // logical imm
            bool ands = ((insn >> 29) & 3) == 3;
            struct opnd ops[2] = {OP(0, W, !ands), OP(5, R, false)};
            return generic(t, insn, ops, 2);
        }
        case 5: {                                     // move wide
            int opc = (insn >> 29) & 3;
            if (opc == 1)
                return -1;
            struct opnd ops[1] = {OP(0, opc == 3 ? RW : W, false)};
            return generic(t, insn, ops, 1);
        }
        case 6: {                                     // bitfield
            int opc = (insn >> 29) & 3;
            if (opc == 3)
                return -1;
            struct opnd ops[2] = {OP(0, opc == 1 ? RW : W, false), OP(5, R, false)};
            return generic(t, insn, ops, 2);
        }
        default: {                                    // extract
            struct opnd ops[3] = {OP(0, W, false), OP(5, R, false), OP(16, R, false)};
            return generic(t, insn, ops, 3);
        }
    }
}

static int tr_dp_reg(struct tr *t, uint32_t insn) {
    struct opnd d = OP(0, W, false), n = OP(5, R, false), mm = OP(16, R, false), a = OP(10, R, false);
    if ((insn & 0x1f000000) == 0x0a000000) {          // logical shifted
        struct opnd ops[3] = {d, n, mm};
        return generic(t, insn, ops, 3);
    }
    if ((insn & 0x1f200000) == 0x0b000000) {          // add/sub shifted
        if (((insn >> 22) & 3) == 3)
            return -1;
        struct opnd ops[3] = {d, n, mm};
        return generic(t, insn, ops, 3);
    }
    if ((insn & 0x1f200000) == 0x0b200000) {          // add/sub extended
        bool S = (insn >> 29) & 1;
        if (((insn >> 22) & 3) != 0 || ((insn >> 10) & 7) > 4)
            return -1;
        struct opnd ops[3] = {OP(0, W, !S), OP(5, R, true), mm};
        return generic(t, insn, ops, 3);
    }
    if ((insn & 0x1fe00000) == 0x1a000000) {          // ADC/SBC
        if (insn & 0xfc00)
            return -1;
        struct opnd ops[3] = {d, n, mm};
        return generic(t, insn, ops, 3);
    }
    if ((insn & 0x1fe00000) == 0x1a400000) {          // CCMN/CCMP
        if (!((insn >> 29) & 1) || (insn & 0x410))
            return -1;
        if (insn & 0x800) {
            struct opnd ops[1] = {n};
            return generic(t, insn, ops, 1);
        }
        struct opnd ops[2] = {n, mm};
        return generic(t, insn, ops, 2);
    }
    if ((insn & 0x1fe00000) == 0x1a800000) {          // CSEL family
        if ((insn >> 29) & 1 || ((insn >> 10) & 3) >= 2)
            return -1;
        struct opnd ops[3] = {d, n, mm};
        return generic(t, insn, ops, 3);
    }
    if ((insn & 0x1f000000) == 0x1b000000) {          // 3-source
        int op = ((insn >> 29) & 3) << 4 | ((insn >> 21) & 7) << 1 | ((insn >> 15) & 1);
        bool sf = insn >> 31;
        // op54=00; op31: 000 MADD/MSUB, 001 SMADDL/SMSUBL, 010 SMULH, 101 UMADDL/UMSUBL, 110 UMULH
        int op31 = (insn >> 21) & 7;
        if ((op >> 4) != 0)
            return -1;
        if (op31 != 0 && !sf)
            return -1;
        if (op31 != 0 && op31 != 1 && op31 != 2 && op31 != 5 && op31 != 6)
            return -1;
        struct opnd ops[4] = {d, n, mm, a};
        return generic(t, insn, ops, 4);
    }
    if ((insn & 0x5fe00000) == 0x1ac00000) {          // 2-source
        int opcode = (insn >> 10) & 63;
        bool ok = opcode == 2 || opcode == 3 || (opcode >= 8 && opcode <= 11) || (opcode >= 16 && opcode <= 23);
        if (!ok || ((insn >> 29) & 1))
            return -1;
        struct opnd ops[3] = {d, n, mm};
        return generic(t, insn, ops, 3);
    }
    if ((insn & 0x5fe00000) == 0x5ac00000) {          // 1-source
        int opcode = (insn >> 10) & 63;
        if (((insn >> 16) & 31) != 0 || opcode > 5 || ((insn >> 29) & 1))
            return -1;
        if (!(insn >> 31) && opcode == 3)
            return -1;
        struct opnd ops[2] = {d, n};
        return generic(t, insn, ops, 2);
    }
    return -1;
}

static int tr_simd(struct tr *t, uint32_t insn) {
    // FP <-> integer conversions (incl. FMOV general)
    if ((insn & 0x5f20fc00) == 0x1e200000) {
        int opcode = (insn >> 16) & 7;
        bool gpr_rn = opcode == 2 || opcode == 3 || opcode == 7;
        struct opnd op = gpr_rn ? OP(5, R, false) : OP(0, W, false);
        return generic(t, insn, &op, 1);
    }
    // FP <-> fixed-point
    if ((insn & 0x5f200000) == 0x1e000000) {
        int opcode = (insn >> 16) & 7;
        struct opnd op = (opcode & 2) ? OP(5, R, false) : OP(0, W, false);
        return generic(t, insn, &op, 1);
    }
    // AdvSIMD copy: DUP/INS (general), SMOV, UMOV
    if ((insn & 0x9fe08400) == 0x0e000400 && !((insn >> 29) & 1)) {
        int imm4 = (insn >> 11) & 15;
        if (imm4 == 1 || imm4 == 3) {
            struct opnd op = OP(5, R, false);
            return generic(t, insn, &op, 1);
        }
        if (imm4 == 5 || imm4 == 7) {
            struct opnd op = OP(0, W, false);
            return generic(t, insn, &op, 1);
        }
    }
    put(t, HOT, insn);
    return 1;
}

static int tr_insn(struct tr *t, uint32_t insn) {
    switch ((insn >> 25) & 15) {
        case 8: case 9:
            return tr_dp_imm(t, insn);
        case 10: case 11:
            return tr_branch(t, insn);
        case 4: case 6: case 12: case 14:
            return tr_ldst(t, insn);
        case 5: case 13:
            return tr_dp_reg(t, insn);
        case 7: case 15:
            return tr_simd(t, insn);
        default:
            return -1;
    }
}

// ---------------------------------------------------------------------------
// Block assembly
// ---------------------------------------------------------------------------
uint32_t *jit_alloc_code(struct jit_mm *mm, uint32_t nwords, struct jit_chunk **chunk);
struct jit_block *jit_lookup_locked(struct jit_mm *mm, addr_t pc);
void jit_invalidate_block_locked(struct jit_mm *mm, struct jit_block *b);
extern uint32_t jit_promote_after;
extern int jit_force_tier1;
int jit_fetch_code(struct jit_ctx *ctx, addr_t pc, const uint32_t **code, int max);
void jit_block_insert(struct jit_mm *mm, struct jit_block *b, struct jit_chunk *c);

// Translation buffers are kept per thread and reused (capacity only grows).
static __thread struct tr tr_cache;

static void tr_init(struct tr *t, addr_t pc) {
    *t = tr_cache;
    t->b[0].n = t->b[1].n = 0;
    t->nfx = t->nmap = 0;
    t->start = pc;
    t->pc = pc;
    t->gi = 0;
    t->ended = false;
}

static void tr_free(struct tr *t) {
    tr_cache = *t;
}

struct jit_block *jit_translate(struct jit_mm *mm, struct jit_ctx *ctx, addr_t pc, uint64_t gen, int tier) {
    const uint32_t *insns;
    int n = jit_fetch_code(ctx, pc, &insns, MAX_INSNS);
    if (n == 0)
        return NULL;
    // Tier 1 (compact, counted, position independent, cacheable) is for code
    // from read-only file mappings; anything else (guest JIT output, CoW'd
    // code) starts at tier 2: it isn't cacheable, and V8/SpiderMonkey code
    // is usually hot.
    bool cacheable = jit_pcache_wanted(ctx, pc);
    if (tier == 1 && !cacheable && !jit_force_tier1)
        tier = 2;
    struct jit_image cached;
    if (tier == 1 && jit_pcache_lookup(pc, insns, n, &cached))
        return jit_install_image(mm, pc, &cached, gen);
    bool offer = tier == 1 && cacheable;

    struct tr t;
    tr_init(&t, pc);
    t.tier = tier;
    bool counted = tier == 1 && jit_tier1_compact;
    if (counted) {
        // execution countdown: promote to tier 2 when it reaches zero
        mark_map(&t, HOT);
        put_fix(&t, HOT, 0x58000000u | HR_T0, FX_B19, TGT_CNT, (struct label) {0});   // ldr T0, =counter
        put(&t, HOT, 0xb9400000u | (HR_T0 << 5) | HR_T1);        // ldr wT1, [T0]
        put(&t, HOT, 0x51000400u | (HR_T1 << 5) | HR_T1);        // sub wT1, wT1, #1
        put(&t, HOT, 0xb9000000u | (HR_T0 << 5) | HR_T1);        // str wT1, [T0]
        struct label promote = here(&t, COLD);
        put_fix(&t, HOT, e_cbz_w(HR_T1, 0), FX_B19, TGT_LABEL, promote);
        exit_pc(&t, COLD, pc, JR_PROMOTE);
    }
    int i;
    for (i = 0; i < n; i++) {
        t.pc = pc + 4 * i;
        t.gi = i;
        uint32_t mark_hot = t.b[HOT].n, mark_cold = t.b[COLD].n, mark_fx = t.nfx, mark_map_n = t.nmap;
        mark_map(&t, HOT);
        int r = tr_insn(&t, insns[i]);
        if (r < 0) {
            t.b[HOT].n = mark_hot;
            t.b[COLD].n = mark_cold;
            t.nfx = mark_fx;
            t.nmap = mark_map_n;
            if (i == 0) {
                tr_free(&t);
                return NULL;
            }
            mark_map(&t, HOT);
            exit_pc(&t, HOT, t.pc, JR_FALLBACK);
            break;
        }
        if (r == 0)
            break;
        // keep every block well inside TBZ's +-32 KB reach to its cold stubs
        if (t.b[HOT].n + t.b[COLD].n > 6000)
            n = i + 1;
    }
    if (i == n) {
        t.pc = pc + 4 * n;
        t.gi = n;
        mark_map(&t, HOT);
        exit_direct(&t, HOT, t.pc);
    }
    int ninsn = i < n ? i + 1 : n;

    // re-entry stub for invalidation
    struct label reentry = here(&t, COLD);
    t.gi = 0;
    t.pc = pc;
    mark_map(&t, COLD);
    exit_pc(&t, COLD, pc, JR_REDISPATCH);

    // Build the relocatable image: hot | cold | pad | 8-byte guest-PC literal
    // | (tier 1) 8-byte counter-address literal.
    uint32_t nhot = t.b[HOT].n, ncode = nhot + t.b[COLD].n;
    uint32_t lit = (ncode + 1) & ~1u, total = lit + (counted ? 4 : 2);
    static __thread uint32_t *img_words, *img_reloc;
    static __thread struct jit_map_entry *img_map;
    static __thread uint32_t img_cap, img_rcap, img_mcap;
    if (total > img_cap) {
        img_cap = total * 2;
        img_words = realloc(img_words, img_cap * 4);
    }
    if (t.nfx > img_rcap) {
        img_rcap = t.nfx * 2;
        img_reloc = realloc(img_reloc, img_rcap * 4);
    }
    if (t.nmap > img_mcap) {
        img_mcap = t.nmap * 2;
        img_map = realloc(img_map, img_mcap * sizeof(*img_map));
    }
    memcpy(img_words, t.b[HOT].w, nhot * 4);
    memcpy(img_words + nhot, t.b[COLD].w, t.b[COLD].n * 4);
    for (uint32_t k = ncode; k < total; k++)
        img_words[k] = 0;
    struct jit_image img = {
        .ninsn = ninsn, .nwords = total, .nhot = nhot,
        .reentry = nhot + reentry.idx, .lit = lit, .cnt_lit = counted ? lit + 2 : 0,
        .words = img_words, .reloc = img_reloc, .map = img_map,
    };
    for (uint32_t k = 0; k < t.nfx; k++) {
        struct fixup *f = &t.fx[k];
        uint32_t at = f->buf == HOT ? f->idx : nhot + f->idx;
        uint32_t target;
        switch (f->tgt) {
            case TGT_LABEL: target = f->l.buf == HOT ? f->l.idx : nhot + f->l.idx; break;
            case TGT_LIT: target = lit; break;
            case TGT_CNT: target = lit + 2; break;
            default:
                img.reloc[img.nreloc++] = JREL(at, f->tgt >= TGT_STUB ? JREL_STUB + (f->tgt - TGT_STUB) :
                                                   f->tgt == TGT_EXIT_CHAIN ? JREL_CHAIN :
                                                   f->tgt == TGT_EXIT_PC ? JREL_PC : JREL_HELPER);
                continue;
        }
        int32_t woff = (int32_t) target - (int32_t) at;
        uint32_t w = img.words[at];
        switch (f->kind) {
            case FX_B26: w = fix_b26(w, woff); break;
            case FX_B19: w = fix_b19(w, woff); break;
            case FX_B14: w = fix_b14(w, woff); break;
            case FX_ADR: w = fix_adr(w, woff * 4); break;
        }
        img.words[at] = w;
    }
    img.nmap = t.nmap;
    for (uint32_t k = 0; k < t.nmap; k++) {
        img.map[k].host_off = t.map[k].buf == HOT ? t.map[k].idx : nhot + t.map[k].idx;
        img.map[k].guest_idx = t.map[k].gi;
        img.map[k].borrow = t.map[k].borrow;
    }
    // sort by host offset (hot and cold runs are each ordered: a merge)
    for (uint32_t k = 1; k < img.nmap; k++) {
        struct jit_map_entry v = img.map[k];
        uint32_t j2 = k;
        while (j2 > 0 && img.map[j2 - 1].host_off > v.host_off) {
            img.map[j2] = img.map[j2 - 1];
            j2--;
        }
        img.map[j2] = v;
    }
    tr_free(&t);
    if (offer)
        jit_pcache_offer(pc, insns, &img);
    return jit_install_image(mm, pc, &img, gen);
}

struct jit_block *jit_install_image(struct jit_mm *mm, addr_t pc, const struct jit_image *img, uint64_t gen) {
    struct jit_block *b = calloc(1, sizeof(*b));
    b->pc = pc;
    b->end = pc + 4 * img->ninsn;
    b->nwords = img->nwords;

    pthread_mutex_lock(&mm->lock);
    if (atomic_load(&mm->gen) != gen) {
        // the code may have changed while we read it
        pthread_mutex_unlock(&mm->lock);
        free(b);
        return (struct jit_block *) -1;
    }
    struct jit_chunk *chunk;
    uint32_t *rx = jit_alloc_code(mm, img->nwords, &chunk);
    if (rx == NULL) {
        pthread_mutex_unlock(&mm->lock);
        free(b);
        return (struct jit_block *) -2;   // no code memory now; caller reclaims and retries
    }
    uint32_t *counter = NULL;
    if (img->cnt_lit) {
        if (mm->ncounters < JIT_COUNTERS) {
            counter = &mm->counters[mm->ncounters++];
            *counter = jit_promote_after;
        } else {
            static uint32_t never = 0xffffffffu;   // out of counters: never promote
            counter = &never;
        }
    }
    // A newer translation of the same pc (tier 2, or a racing thread)
    // replaces the old one.
    struct jit_block *old = jit_lookup_locked(mm, pc);
    if (old && old->rx)
        jit_invalidate_block_locked(mm, old);
    uint32_t *rw = jit_rw(rx);
    jit_write_begin();
    memcpy(rw, img->words, img->nwords * 4);
    for (uint32_t k = 0; k < img->nreloc; k++) {
        uint32_t at = JREL_IDX(img->reloc[k]), kind = JREL_KIND(img->reloc[k]);
        uint32_t *target = kind >= JREL_STUB ? chunk->t_stub[kind - JREL_STUB] :
                           kind == JREL_CHAIN ? chunk->t_exit_chain :
                           kind == JREL_PC ? chunk->t_exit_pc : chunk->t_helper;
        rw[at] = fix_b26(rw[at], (int32_t) (target - (rx + at)));
    }
    memcpy(rw + img->lit, &pc, 8);
    if (img->cnt_lit)
        memcpy(rw + img->cnt_lit, &counter, 8);
    jit_write_end(rx, img->nwords * 4);

    b->rx = rx;
    b->reentry = rx + img->reentry;
    b->counter = img->cnt_lit ? counter : NULL;
    b->nmap = img->nmap;
    b->map = malloc(img->nmap * sizeof(*b->map));
    memcpy(b->map, img->map, img->nmap * sizeof(*b->map));
    jit_block_insert(mm, b, chunk);
    mm->stats_blocks++;
    mm->stats_insns += img->ninsn;
    mm->stats_hot += img->nhot;
    mm->stats_words += img->nwords;
    pthread_mutex_unlock(&mm->lock);
    return b;
}
