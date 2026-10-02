// Scalar FP <-> integer conversion and FRINT conformance test (GPR forms).
//   cc -O1 -march=armv8.2-a+fp16 -o conv conv.c && ./conv > native.txt
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint64_t (*f2i_fn)(uint64_t bits, uint64_t fpcr);

// FP -> GPR: input bits go to d0 (or s0/h0 via the same register), result read from x0.
#define F2I(fn, insn)                                                              \
    static uint64_t fn(uint64_t bits, uint64_t fpcr) {                             \
        uint64_t out;                                                              \
        __asm__ volatile("fmov d0, %[b]\n\t"                                       \
                         "mov x9, #0x5555555555555555\n\t"                         \
                         "msr fpcr, %[fpcr]\n\t"                                   \
                         insn "\n\t"                                               \
                         "msr fpcr, xzr\n\t"                                       \
                         "mov %[o], x9\n\t"                                        \
                         : [o] "=r"(out) : [b] "r"(bits), [fpcr] "r"(fpcr)         \
                         : "x9", "v0", "memory");                                  \
        return out;                                                                \
    }

// GPR -> FP: input in x9, result is the full q0 (low 64 bits printed; high must be 0).
#define I2F(fn, insn)                                                              \
    static uint64_t fn(uint64_t bits, uint64_t fpcr) {                             \
        uint64_t lo, hi;                                                           \
        __asm__ volatile("mov x9, %[b]\n\t"                                        \
                         "movi v0.2d, #0xffffffffffffffff\n\t"                     \
                         "msr fpcr, %[fpcr]\n\t"                                   \
                         insn "\n\t"                                               \
                         "msr fpcr, xzr\n\t"                                       \
                         "fmov %[lo], d0\n\t"                                      \
                         "mov %[hi], v0.d[1]\n\t"                                  \
                         : [lo] "=r"(lo), [hi] "=r"(hi) : [b] "r"(bits), [fpcr] "r"(fpcr) \
                         : "x9", "v0", "memory");                                  \
        return lo ^ (hi ? 0xdead000000000000ull : 0);                              \
    }

// FP -> FP (FRINT*, FCVT), result is q0.
#define F2F(fn, insn) I2F(fn, "fmov d1, x9\n\t" insn)

enum src { S_F16, S_F32, S_F64, S_INT };

#define OPS(X) \
    X(F2I, fcvtzs_ws, S_F32, "fcvtzs w9, s0") \
    X(F2I, fcvtzs_xs, S_F32, "fcvtzs x9, s0") \
    X(F2I, fcvtzs_wd, S_F64, "fcvtzs w9, d0") \
    X(F2I, fcvtzs_xd, S_F64, "fcvtzs x9, d0") \
    X(F2I, fcvtzu_ws, S_F32, "fcvtzu w9, s0") \
    X(F2I, fcvtzu_xd, S_F64, "fcvtzu x9, d0") \
    X(F2I, fcvtzu_wd, S_F64, "fcvtzu w9, d0") \
    X(F2I, fcvtzu_xs, S_F32, "fcvtzu x9, s0") \
    X(F2I, fcvtms_wd, S_F64, "fcvtms w9, d0") \
    X(F2I, fcvtms_xd, S_F64, "fcvtms x9, d0") \
    X(F2I, fcvtms_xs, S_F32, "fcvtms x9, s0") \
    X(F2I, fcvtmu_xd, S_F64, "fcvtmu x9, d0") \
    X(F2I, fcvtps_wd, S_F64, "fcvtps w9, d0") \
    X(F2I, fcvtps_xs, S_F32, "fcvtps x9, s0") \
    X(F2I, fcvtpu_wd, S_F64, "fcvtpu w9, d0") \
    X(F2I, fcvtns_wd, S_F64, "fcvtns w9, d0") \
    X(F2I, fcvtns_xs, S_F32, "fcvtns x9, s0") \
    X(F2I, fcvtnu_xd, S_F64, "fcvtnu x9, d0") \
    X(F2I, fcvtas_wd, S_F64, "fcvtas w9, d0") \
    X(F2I, fcvtas_xd, S_F64, "fcvtas x9, d0") \
    X(F2I, fcvtau_ws, S_F32, "fcvtau w9, s0") \
    X(F2I, fcvtzs_ws_fx, S_F32, "fcvtzs w9, s0, #8") \
    X(F2I, fcvtzs_xd_fx, S_F64, "fcvtzs x9, d0, #33") \
    X(F2I, fcvtzu_wd_fx, S_F64, "fcvtzu w9, d0, #1") \
    X(F2I, fcvtzu_xs_fx, S_F32, "fcvtzu x9, s0, #64") \
    X(F2I, fmov_x_d, S_F64, "fmov x9, d0") \
    X(F2I, fcvtzs_wh, S_F16, "fcvtzs w9, h0") \
    X(F2I, fcvtzs_xh, S_F16, "fcvtzs x9, h0") \
    X(F2I, fcvtmu_wh, S_F16, "fcvtmu w9, h0") \
    X(F2I, fcvtas_xh, S_F16, "fcvtas x9, h0") \
    X(F2I, fcvtzs_wh_fx, S_F16, "fcvtzs w9, h0, #5") \
    X(F2I, fcvtzu_xh_fx, S_F16, "fcvtzu x9, h0, #40") \
    X(F2I, fmov_w_h, S_F16, "fmov w9, h0") \
    X(F2I, fmov_x_h, S_F64, "fmov x9, h0") \
    X(I2F, scvtf_hw, S_INT, "scvtf h0, w9") \
    X(I2F, ucvtf_hx, S_INT, "ucvtf h0, x9") \
    X(I2F, scvtf_hx_fx, S_INT, "scvtf h0, x9, #10") \
    X(I2F, fmov_h_w, S_INT, "fmov h0, w9") \
    X(I2F, fmov_h_x, S_INT, "fmov h0, x9") \
    X(I2F, fmov_s_imm1, S_INT, "fmov s0, #3.25") \
    X(I2F, fmov_s_imm2, S_INT, "fmov s0, #-0.1328125") \
    X(I2F, fmov_d_imm1, S_INT, "fmov d0, #-31.0") \
    X(I2F, fmov_d_imm2, S_INT, "fmov d0, #0.2421875") \
    X(I2F, fmov_h_imm, S_INT, "fmov h0, #1.5") \
    X(I2F, fmov_v4s_imm, S_INT, "fmov v0.4s, #3.25") \
    X(I2F, fmov_v2d_imm, S_INT, "fmov v0.2d, #-1.5") \
    X(F2I, smov_x_b7, S_F64, "smov x9, v0.b[7]") \
    X(F2I, smov_w_b6, S_F64, "smov w9, v0.b[6]") \
    X(F2I, smov_x_h3, S_F64, "smov x9, v0.h[3]") \
    X(F2I, smov_w_h1, S_F64, "smov w9, v0.h[1]") \
    X(F2I, smov_x_s1, S_F64, "smov x9, v0.s[1]") \
    X(F2I, umov_w_b7, S_F64, "umov w9, v0.b[7]") \
    X(F2I, umov_w_h3, S_F64, "umov w9, v0.h[3]") \
    X(I2F, scvtf_sw, S_INT, "scvtf s0, w9") \
    X(I2F, scvtf_sx, S_INT, "scvtf s0, x9") \
    X(I2F, scvtf_dw, S_INT, "scvtf d0, w9") \
    X(I2F, scvtf_dx, S_INT, "scvtf d0, x9") \
    X(I2F, ucvtf_sw, S_INT, "ucvtf s0, w9") \
    X(I2F, ucvtf_sx, S_INT, "ucvtf s0, x9") \
    X(I2F, ucvtf_dw, S_INT, "ucvtf d0, w9") \
    X(I2F, ucvtf_dx, S_INT, "ucvtf d0, x9") \
    X(I2F, scvtf_dx_fx, S_INT, "scvtf d0, x9, #20") \
    X(I2F, ucvtf_sw_fx, S_INT, "ucvtf s0, w9, #31") \
    X(F2F, frintn_d, S_F64, "frintn d0, d1") \
    X(F2F, frintm_d, S_F64, "frintm d0, d1") \
    X(F2F, frintp_s, S_F32, "frintp s0, s1") \
    X(F2F, frintz_d, S_F64, "frintz d0, d1") \
    X(F2F, frinta_s, S_F32, "frinta s0, s1") \
    X(F2F, frintx_d, S_F64, "frintx d0, d1") \
    X(F2F, frinti_d, S_F64, "frinti d0, d1") \
    X(F2F, frinti_s, S_F32, "frinti s0, s1") \
    X(F2F, fcvt_sd, S_F64, "fcvt s0, d1") \
    X(F2F, fcvt_ds, S_F32, "fcvt d0, s1") \
    X(F2F, fsqrt_d, S_F64, "fsqrt d0, d1") \
    X(F2F, fabs_s, S_F32, "fabs s0, s1") \
    X(F2F, fneg_d, S_F64, "fneg d0, d1")

#define X(kind, name, src, insn) kind(t_##name, insn)
OPS(X)
#undef X

struct test { const char *name; f2i_fn fn; enum src src; };
#define X(kind, name, src, insn) { #name, t_##name, src },
static const struct test tests[] = { OPS(X) };
#undef X

static const uint64_t f64_vals[] = {
    0x0000000000000000, 0x8000000000000000, 0x3ff0000000000000, 0xbff8000000000000, 0x3fe0000000000000,
    0xbfe0000000000000, 0x4004000000000000, 0xc004000000000000, 0x400c000000000000, 0x7fefffffffffffff,
    0x0000000000000001, 0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000000, 0x7ff4000000000001,
    0x41dfffffffc00000, 0x41e0000000000000, 0xc1e0000000000000, 0xc1e0000000200000, 0x41efffffffe00000,
    0x41f0000000000000, 0x43dfffffffffffff, 0x43e0000000000000, 0xc3e0000000000000, 0x43f0000000000000,
    0x412e848000000000, 0x41cdcd6500000000, 0x3fefffffffffffff, 0xbfefffffffffffff, 0x4330000000000001,
    0x40c3880000000000, 0x3eb0c6f7a0b5ed8d, 0x4415af1d78b58c40, 0xc0f86a0000000000,
};
static const uint32_t f32_vals[] = {
    0x00000000, 0x80000000, 0x3f800000, 0xbfc00000, 0x3f000000, 0xbf000000, 0x40200000, 0xc0200000,
    0x7f7fffff, 0x00000001, 0x7f800000, 0xff800000, 0x7fc00000, 0x7fa00001, 0x4effffff, 0x4f000000,
    0xcf000000, 0xcf000001, 0x4f800000, 0x5effffff, 0x5f000000, 0xdf000000, 0x5f800000, 0x3f7fffff,
    0x4b000001, 0x49742400, 0x3fc00000,
};
static const uint16_t f16_vals[] = {
    0x0000, 0x8000, 0x3c00, 0xbe00, 0x3800, 0x4100, 0xc100, 0x7bff, 0x0001, 0x7c00, 0xfc00, 0x7e00, 0x5640,
};
static const uint64_t int_vals[] = {
    0, 1, 0xffffffffffffffff, 0x7fffffffffffffff, 0x8000000000000000, 0x00000000ffffffff, 0x000000007fffffff,
    0x0000000080000000, 0xffffffff80000000, 0x0000000001000001, 0x0020000000000001, 0x0020000000000003,
    0x00000000ffffff7f, 0xfffffffffffff800, 0x123456789abcdef0, 0x0000000000ffffff, 0x00000000c0000000,
};

#define N(a) (sizeof(a) / sizeof((a)[0]))
static const uint64_t modes[] = { 0, 1u << 22, 2u << 22, 3u << 22, 1u << 24, 1u << 25 };

int main(void) {
    for (size_t t = 0; t < N(tests); t++) {
        const struct test *tc = &tests[t];
        size_t n = tc->src == S_F16 ? N(f16_vals) : tc->src == S_F32 ? N(f32_vals) :
                   tc->src == S_F64 ? N(f64_vals) : N(int_vals);
        for (size_t m = 0; m < N(modes); m++) {
            for (size_t i = 0; i < n; i++) {
                uint64_t in = tc->src == S_F16 ? f16_vals[i] : tc->src == S_F32 ? f32_vals[i] :
                              tc->src == S_F64 ? f64_vals[i] : int_vals[i];
                uint64_t r = tc->fn(in, modes[m]);
                printf("%s fpcr=%" PRIx64 " in=%016" PRIx64 " -> %016" PRIx64 "\n", tc->name, modes[m], in, r);
            }
        }
    }
    return 0;
}
