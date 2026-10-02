// AdvSIMD/FP instruction conformance test.
// Build the same source natively (Apple Silicon) and in the guest, then diff the output:
//   cc -O1 -march=armv8.2-a+fp16 -o neon neon.c && ./neon > native.txt
// Every line is "<test> fpcr=<hex> <i> <j> <result hi> <result lo>".
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct { uint64_t lo, hi; } v128;

#define VREGS "v0","v1","v2","v3","v4","v5","v6","v7","v8","v9","v10","v11","v12","v13","v14","v15", \
    "v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31"

typedef void (*op_fn)(const v128 *d, const v128 *n, const v128 *m, v128 *o, uint64_t fpcr);

#define DEF(fn, D, N, M, insn) \
    static void fn(const v128 *d, const v128 *n, const v128 *m, v128 *o, uint64_t fpcr) { \
        __asm__ volatile( \
            "ldr q" #D ", [%[d]]\n\t" \
            "ldr q" #N ", [%[n]]\n\t" \
            "ldr q" #M ", [%[m]]\n\t" \
            "msr fpcr, %[fpcr]\n\t" \
            insn "\n\t" \
            "msr fpcr, xzr\n\t" \
            "str q" #D ", [%[o]]\n\t" \
            :: [d] "r"(d), [n] "r"(n), [m] "r"(m), [o] "r"(o), [fpcr] "r"(fpcr) \
            : "memory", VREGS); \
    }

enum kind { F16, F32, F64, I8, I16, I32, I64, SH };

// Register choices vary so the decoder's Rd/Rn/Rm extraction is exercised, including Rd == Rn.
#define OPS(X) \
    /* two-reg misc, vector */ \
    X(rev16_8b,   I8,  I8, 5, 17, 30, "rev16 v5.8b, v17.8b") \
    X(rev16_16b,  I8,  I8, 0, 1, 2,   "rev16 v0.16b, v1.16b") \
    X(rev32_8b,   I8,  I8, 31, 3, 2,  "rev32 v31.8b, v3.8b") \
    X(rev32_16b,  I8,  I8, 0, 1, 2,   "rev32 v0.16b, v1.16b") \
    X(rev32_4h,   I16, I16, 0, 1, 2,  "rev32 v0.4h, v1.4h") \
    X(rev32_8h,   I16, I16, 9, 9, 2,  "rev32 v9.8h, v9.8h") \
    X(rev64_8b,   I8,  I8, 0, 1, 2,   "rev64 v0.8b, v1.8b") \
    X(rev64_16b,  I8,  I8, 0, 1, 2,   "rev64 v0.16b, v1.16b") \
    X(rev64_4h,   I16, I16, 0, 1, 2,  "rev64 v0.4h, v1.4h") \
    X(rev64_8h,   I16, I16, 0, 1, 2,  "rev64 v0.8h, v1.8h") \
    X(rev64_2s,   I32, I32, 0, 1, 2,  "rev64 v0.2s, v1.2s") \
    X(rev64_4s,   I32, I32, 0, 1, 2,  "rev64 v0.4s, v1.4s") \
    X(suqadd_8b,  I8,  I8, 0, 1, 2,   "suqadd v0.8b, v1.8b") \
    X(suqadd_16b, I8,  I8, 0, 1, 2,   "suqadd v0.16b, v1.16b") \
    X(suqadd_4h,  I16, I16, 0, 1, 2,  "suqadd v0.4h, v1.4h") \
    X(suqadd_8h,  I16, I16, 0, 1, 2,  "suqadd v0.8h, v1.8h") \
    X(suqadd_2s,  I32, I32, 0, 1, 2,  "suqadd v0.2s, v1.2s") \
    X(suqadd_4s,  I32, I32, 0, 1, 2,  "suqadd v0.4s, v1.4s") \
    X(suqadd_2d,  I64, I64, 0, 1, 2,  "suqadd v0.2d, v1.2d") \
    X(usqadd_8b,  I8,  I8, 0, 1, 2,   "usqadd v0.8b, v1.8b") \
    X(usqadd_16b, I8,  I8, 20, 21, 2, "usqadd v20.16b, v21.16b") \
    X(usqadd_4h,  I16, I16, 0, 1, 2,  "usqadd v0.4h, v1.4h") \
    X(usqadd_8h,  I16, I16, 0, 1, 2,  "usqadd v0.8h, v1.8h") \
    X(usqadd_2s,  I32, I32, 0, 1, 2,  "usqadd v0.2s, v1.2s") \
    X(usqadd_4s,  I32, I32, 0, 1, 2,  "usqadd v0.4s, v1.4s") \
    X(usqadd_2d,  I64, I64, 0, 1, 2,  "usqadd v0.2d, v1.2d") \
    X(sqabs_8b,   I8,  I8, 0, 1, 2,   "sqabs v0.8b, v1.8b") \
    X(sqabs_16b,  I8,  I8, 0, 1, 2,   "sqabs v0.16b, v1.16b") \
    X(sqabs_4h,   I16, I16, 0, 1, 2,  "sqabs v0.4h, v1.4h") \
    X(sqabs_8h,   I16, I16, 30, 30, 2, "sqabs v30.8h, v30.8h") \
    X(sqabs_2s,   I32, I32, 0, 1, 2,  "sqabs v0.2s, v1.2s") \
    X(sqabs_4s,   I32, I32, 0, 1, 2,  "sqabs v0.4s, v1.4s") \
    X(sqabs_2d,   I64, I64, 0, 1, 2,  "sqabs v0.2d, v1.2d") \
    X(sqneg_8b,   I8,  I8, 0, 1, 2,   "sqneg v0.8b, v1.8b") \
    X(sqneg_16b,  I8,  I8, 0, 1, 2,   "sqneg v0.16b, v1.16b") \
    X(sqneg_4h,   I16, I16, 0, 1, 2,  "sqneg v0.4h, v1.4h") \
    X(sqneg_8h,   I16, I16, 23, 23, 2, "sqneg v23.8h, v23.8h") \
    X(sqneg_2s,   I32, I32, 0, 1, 2,  "sqneg v0.2s, v1.2s") \
    X(sqneg_4s,   I32, I32, 0, 1, 2,  "sqneg v0.4s, v1.4s") \
    X(sqneg_2d,   I64, I64, 0, 1, 2,  "sqneg v0.2d, v1.2d") \
    X(fcvtn_4h,   F32, F32, 0, 1, 2,  "fcvtn v0.4h, v1.4s") \
    X(fcvtn2_8h,  F32, F32, 7, 8, 2,  "fcvtn2 v7.8h, v8.4s") \
    X(fcvtn_2s,   F64, F64, 0, 1, 2,  "fcvtn v0.2s, v1.2d") \
    X(fcvtn2_4s,  F64, F64, 0, 1, 2,  "fcvtn2 v0.4s, v1.2d") \
    X(fcvtl_4s,   F16, F16, 0, 1, 2,  "fcvtl v0.4s, v1.4h") \
    X(fcvtl2_4s,  F16, F16, 0, 1, 2,  "fcvtl2 v0.4s, v1.8h") \
    X(fcvtl_2d,   F32, F32, 0, 1, 2,  "fcvtl v0.2d, v1.2s") \
    X(fcvtl2_2d,  F32, F32, 4, 4, 2,  "fcvtl2 v4.2d, v4.4s") \
    X(fcvtxn_2s,  F64, F64, 0, 1, 2,  "fcvtxn v0.2s, v1.2d") \
    X(fcvtxn2_4s, F64, F64, 0, 1, 2,  "fcvtxn2 v0.4s, v1.2d") \
    /* two-reg misc, scalar */ \
    X(suqadd_b,   I8,  I8, 0, 1, 2,   "suqadd b0, b1") \
    X(suqadd_h,   I16, I16, 0, 1, 2,  "suqadd h0, h1") \
    X(suqadd_s,   I32, I32, 0, 1, 2,  "suqadd s0, s1") \
    X(suqadd_d,   I64, I64, 0, 1, 2,  "suqadd d0, d1") \
    X(usqadd_b,   I8,  I8, 0, 1, 2,   "usqadd b0, b1") \
    X(usqadd_h,   I16, I16, 0, 1, 2,  "usqadd h0, h1") \
    X(usqadd_s,   I32, I32, 0, 1, 2,  "usqadd s0, s1") \
    X(usqadd_d,   I64, I64, 0, 1, 2,  "usqadd d0, d1") \
    X(sqabs_b,    I8,  I8, 0, 1, 2,   "sqabs b0, b1") \
    X(sqabs_h,    I16, I16, 0, 1, 2,  "sqabs h0, h1") \
    X(sqabs_s,    I32, I32, 0, 1, 2,  "sqabs s0, s1") \
    X(sqabs_d,    I64, I64, 0, 1, 2,  "sqabs d0, d1") \
    X(sqneg_b,    I8,  I8, 0, 1, 2,   "sqneg b0, b1") \
    X(sqneg_h,    I16, I16, 0, 1, 2,  "sqneg h0, h1") \
    X(sqneg_s,    I32, I32, 0, 1, 2,  "sqneg s0, s1") \
    X(sqneg_d,    I64, I64, 0, 1, 2,  "sqneg d0, d1") \
    X(fcvtxn_s,   F64, F64, 0, 1, 2,  "fcvtxn s0, d1") \
    X(fcmeq0_s,   F32, F32, 0, 1, 2,  "fcmeq s0, s1, #0.0") \
    X(fcmeq0_d,   F64, F64, 0, 1, 2,  "fcmeq d0, d1, #0.0") \
    X(fcmge0_s,   F32, F32, 0, 1, 2,  "fcmge s0, s1, #0.0") \
    X(fcmgt0_d,   F64, F64, 0, 1, 2,  "fcmgt d0, d1, #0.0") \
    X(fcmle0_s,   F32, F32, 0, 1, 2,  "fcmle s0, s1, #0.0") \
    X(fcmlt0_d,   F64, F64, 0, 1, 2,  "fcmlt d0, d1, #0.0") \
    /* three same, scalar */ \
    X(fcmeq_s,    F32, F32, 0, 1, 2,  "fcmeq s0, s1, s2") \
    X(fcmeq_d,    F64, F64, 31, 31, 30, "fcmeq d31, d31, d30") \
    X(fcmge_s,    F32, F32, 24, 0, 31, "fcmge s24, s0, s31") \
    X(fcmge_d,    F64, F64, 0, 1, 2,  "fcmge d0, d1, d2") \
    X(fcmgt_s,    F32, F32, 30, 31, 0, "fcmgt s30, s31, s0") \
    X(fcmgt_d,    F64, F64, 0, 1, 2,  "fcmgt d0, d1, d2") \
    X(facge_s,    F32, F32, 0, 1, 2,  "facge s0, s1, s2") \
    X(facgt_d,    F64, F64, 0, 1, 2,  "facgt d0, d1, d2") \
    X(sqadd_b,    I8,  I8, 0, 1, 2,   "sqadd b0, b1, b2") \
    X(sqadd_h,    I16, I16, 0, 1, 2,  "sqadd h0, h1, h2") \
    X(sqadd_s,    I32, I32, 0, 1, 2,  "sqadd s0, s1, s2") \
    X(sqadd_d,    I64, I64, 31, 31, 25, "sqadd d31, d31, d25") \
    X(uqadd_d,    I64, I64, 0, 1, 2,  "uqadd d0, d1, d2") \
    X(sqsub_s,    I32, I32, 0, 1, 2,  "sqsub s0, s1, s2") \
    X(uqsub_h,    I16, I16, 0, 1, 2,  "uqsub h0, h1, h2") \
    X(sqshl_b,    I8,  SH, 0, 1, 2,   "sqshl b0, b1, b2") \
    X(sqshl_h,    I16, SH, 0, 1, 2,   "sqshl h0, h1, h2") \
    X(sqshl_s,    I32, SH, 0, 1, 2,   "sqshl s0, s1, s2") \
    X(sqshl_d,    I64, SH, 0, 1, 2,   "sqshl d0, d1, d2") \
    X(uqshl_b,    I8,  SH, 0, 1, 2,   "uqshl b0, b1, b2") \
    X(uqshl_d,    I64, SH, 0, 1, 2,   "uqshl d0, d1, d2") \
    X(sqrshl_s,   I32, SH, 0, 1, 2,   "sqrshl s0, s1, s2") \
    X(uqrshl_h,   I16, SH, 0, 1, 2,   "uqrshl h0, h1, h2") \
    /* three same, vector (existing implementations, audited) */ \
    X(sqshl_v16b, I8,  SH, 0, 1, 2,   "sqshl v0.16b, v1.16b, v2.16b") \
    X(sqshl_v8h,  I16, SH, 0, 1, 2,   "sqshl v0.8h, v1.8h, v2.8h") \
    X(sqshl_v4s,  I32, SH, 0, 1, 2,   "sqshl v0.4s, v1.4s, v2.4s") \
    X(sqshl_v2d,  I64, SH, 0, 1, 2,   "sqshl v0.2d, v1.2d, v2.2d") \
    X(uqshl_v8b,  I8,  SH, 0, 1, 2,   "uqshl v0.8b, v1.8b, v2.8b") \
    X(uqshl_v4s,  I32, SH, 0, 1, 2,   "uqshl v0.4s, v1.4s, v2.4s") \
    X(uqshl_v2d,  I64, SH, 0, 1, 2,   "uqshl v0.2d, v1.2d, v2.2d") \
    X(fcmeq_v4s,  F32, F32, 0, 1, 2,  "fcmeq v0.4s, v1.4s, v2.4s") \
    X(fcmge_v2d,  F64, F64, 0, 1, 2,  "fcmge v0.2d, v1.2d, v2.2d") \
    /* FCVT (scalar) */ \
    X(fcvt_s_h,   F16, F16, 28, 28, 2, "fcvt s28, h28") \
    X(fcvt_d_h,   F16, F16, 0, 1, 2,  "fcvt d0, h1") \
    X(fcvt_h_s,   F32, F32, 0, 1, 2,  "fcvt h0, s1") \
    X(fcvt_d_s,   F32, F32, 0, 1, 2,  "fcvt d0, s1") \
    X(fcvt_h_d,   F64, F64, 0, 1, 2,  "fcvt h0, d1") \
    X(fcvt_s_d,   F64, F64, 0, 1, 2,  "fcvt s0, d1") \
    /* shift by immediate, saturating */ \
    X(sqshl_i8b0,  I8,  I8, 0, 1, 2,  "sqshl v0.8b, v1.8b, #0") \
    X(sqshl_i16b3, I8,  I8, 0, 1, 2,  "sqshl v0.16b, v1.16b, #3") \
    X(sqshl_i16b7, I8,  I8, 0, 1, 2,  "sqshl v0.16b, v1.16b, #7") \
    X(sqshl_i8h1,  I16, I16, 16, 16, 2, "sqshl v16.8h, v16.8h, #1") \
    X(sqshl_i4h15, I16, I16, 0, 1, 2, "sqshl v0.4h, v1.4h, #15") \
    X(sqshl_i4s9,  I32, I32, 0, 1, 2, "sqshl v0.4s, v1.4s, #9") \
    X(sqshl_i2s31, I32, I32, 0, 1, 2, "sqshl v0.2s, v1.2s, #31") \
    X(sqshl_i2d40, I64, I64, 0, 1, 2, "sqshl v0.2d, v1.2d, #40") \
    X(uqshl_i8b5,  I8,  I8, 0, 1, 2,  "uqshl v0.8b, v1.8b, #5") \
    X(uqshl_i8h12, I16, I16, 0, 1, 2, "uqshl v0.8h, v1.8h, #12") \
    X(uqshl_i4s1,  I32, I32, 0, 1, 2, "uqshl v0.4s, v1.4s, #1") \
    X(uqshl_i2d41, I64, I64, 1, 3, 2, "uqshl v1.2d, v3.2d, #41") \
    X(sqshlu_i8h0, I16, I16, 23, 23, 2, "sqshlu v23.8h, v23.8h, #0") \
    X(sqshlu_i16b2, I8, I8, 0, 1, 2,  "sqshlu v0.16b, v1.16b, #2") \
    X(sqshlu_i2s30, I32, I32, 0, 1, 2, "sqshlu v0.2s, v1.2s, #30") \
    X(sqshlu_i2d63, I64, I64, 0, 1, 2, "sqshlu v0.2d, v1.2d, #63") \
    X(sqshl_ib6,   I8,  I8, 0, 1, 2,  "sqshl b0, b1, #6") \
    X(sqshl_id1,   I64, I64, 0, 1, 2, "sqshl d0, d1, #1") \
    X(uqshl_ih3,   I16, I16, 0, 1, 2, "uqshl h0, h1, #3") \
    X(uqshl_is31,  I32, I32, 0, 1, 2, "uqshl s0, s1, #31") \
    X(sqshlu_ib1,  I8,  I8, 0, 1, 2,  "sqshlu b0, b1, #1") \
    X(sqshlu_id62, I64, I64, 0, 1, 2, "sqshlu d0, d1, #62") \
    /* fixed-point converts, vector */ \
    X(scvtf_4s24,  I32, I32, 7, 7, 2, "scvtf v7.4s, v7.4s, #24") \
    X(scvtf_2s1,   I32, I32, 0, 1, 2, "scvtf v0.2s, v1.2s, #1") \
    X(scvtf_4s32,  I32, I32, 0, 1, 2, "scvtf v0.4s, v1.4s, #32") \
    X(ucvtf_4s16,  I32, I32, 0, 1, 2, "ucvtf v0.4s, v1.4s, #16") \
    X(scvtf_2d33,  I64, I64, 0, 1, 2, "scvtf v0.2d, v1.2d, #33") \
    X(ucvtf_2d64,  I64, I64, 0, 1, 2, "ucvtf v0.2d, v1.2d, #64") \
    X(fcvtzs_2s6,  F32, F32, 2, 0, 3, "fcvtzs v2.2s, v0.2s, #6") \
    X(fcvtzs_4s1,  F32, F32, 0, 1, 2, "fcvtzs v0.4s, v1.4s, #1") \
    X(fcvtzs_4s32, F32, F32, 0, 1, 2, "fcvtzs v0.4s, v1.4s, #32") \
    X(fcvtzs_2d6,  F64, F64, 30, 30, 2, "fcvtzs v30.2d, v30.2d, #6") \
    X(fcvtzs_2d64, F64, F64, 0, 1, 2, "fcvtzs v0.2d, v1.2d, #64") \
    X(fcvtzu_4s1,  F32, F32, 30, 30, 2, "fcvtzu v30.4s, v30.4s, #1") \
    X(fcvtzu_2s20, F32, F32, 0, 1, 2, "fcvtzu v0.2s, v1.2s, #20") \
    X(fcvtzu_2d40, F64, F64, 0, 1, 2, "fcvtzu v0.2d, v1.2d, #40") \
    X(fcvtzs_4h3,  F16, F16, 0, 1, 2, "fcvtzs v0.4h, v1.4h, #3") \
    X(ucvtf_8h16,  I16, I16, 0, 1, 2, "ucvtf v0.8h, v1.8h, #16") \
    /* fixed-point converts, scalar SIMD&FP register */ \
    X(scvtf_s5,    I32, I32, 0, 1, 2, "scvtf s0, s1, #5") \
    X(ucvtf_d64,   I64, I64, 0, 1, 2, "ucvtf d0, d1, #64") \
    X(fcvtzs_s31,  F32, F32, 0, 1, 2, "fcvtzs s0, s1, #31") \
    X(fcvtzu_d1,   F64, F64, 0, 1, 2, "fcvtzu d0, d1, #1") \
    /* crypto (HWCAP AES+PMULL) and the permutes GHASH code uses */ \
    X(aese,        I8,  I8, 0, 1, 2,  "aese v0.16b, v1.16b") \
    X(aesd,        I8,  I8, 0, 1, 2,  "aesd v0.16b, v1.16b") \
    X(aesmc,       I8,  I8, 0, 1, 2,  "aesmc v0.16b, v1.16b") \
    X(aesimc,      I8,  I8, 3, 3, 2,  "aesimc v3.16b, v3.16b") \
    X(pmull_1q,    I64, I64, 0, 1, 2, "pmull v0.1q, v1.1d, v2.1d") \
    X(pmull2_1q,   I64, I64, 5, 17, 30, "pmull2 v5.1q, v17.2d, v30.2d") \
    X(pmull_8h,    I8,  I8, 0, 1, 2,  "pmull v0.8h, v1.8b, v2.8b") \
    X(pmull2_8h,   I8,  I8, 0, 1, 2,  "pmull2 v0.8h, v1.16b, v2.16b") \
    X(ext_16b8,    I8,  I8, 0, 1, 2,  "ext v0.16b, v1.16b, v2.16b, #8") \
    X(ext_16b3,    I8,  I8, 0, 1, 2,  "ext v0.16b, v1.16b, v2.16b, #3") \
    X(ext_8b5,     I8,  I8, 0, 1, 2,  "ext v0.8b, v1.8b, v2.8b, #5") \
    X(rbit_16b,    I8,  I8, 0, 1, 2,  "rbit v0.16b, v1.16b") \
    X(eor_16b,     I8,  I8, 0, 1, 2,  "eor v0.16b, v1.16b, v2.16b") \
    X(uzp1_2d,     I64, I64, 0, 1, 2, "uzp1 v0.2d, v1.2d, v2.2d") \
    X(zip2_2d,     I64, I64, 0, 1, 2, "zip2 v0.2d, v1.2d, v2.2d") \
    X(tbl_16b,     I8,  I8, 0, 1, 2,  "tbl v0.16b, {v1.16b}, v2.16b") \
    X(shl_2d63,    I64, I64, 0, 1, 2, "shl v0.2d, v1.2d, #63") \
    X(ushr_2d63,   I64, I64, 0, 1, 2, "ushr v0.2d, v1.2d, #63") \
    X(sshr_4s31,   I32, I32, 0, 1, 2, "sshr v0.4s, v1.4s, #31") \
    X(cmlt0_16b,   I8,  I8, 0, 1, 2,  "cmlt v0.16b, v1.16b, #0") \
    /* vector float<->int, existing implementations (audited) */ \
    X(fcvtzs_v4s,  F32, F32, 0, 1, 2, "fcvtzs v0.4s, v1.4s") \
    X(fcvtzu_v2d,  F64, F64, 0, 1, 2, "fcvtzu v0.2d, v1.2d") \
    X(scvtf_v4s,   I32, I32, 0, 1, 2, "scvtf v0.4s, v1.4s") \
    X(ucvtf_v2d,   I64, I64, 0, 1, 2, "ucvtf v0.2d, v1.2d")

struct test { const char *name; op_fn fn; enum kind kd, km; };

#define X(name, kd, km, D, N, M, insn) DEF(t_##name, D, N, M, insn)
OPS(X)
#undef X
#define X(name, kd, km, D, N, M, insn) { #name, t_##name, kd, km },
static const struct test tests[] = { OPS(X) };
#undef X

static const uint16_t f16_pat[] = {
    0x0000, 0x8000, 0x3c00, 0xbe00, 0x3800, 0x4100, 0xc100, 0x7bff, 0xfbff, 0x0001, 0x03ff, 0x8400,
    0x7c00, 0xfc00, 0x7e00, 0x7d00, 0xfe01, 0x3555, 0x0400, 0x5640, 0x7801, 0x4b00,
};
static const uint32_t f32_pat[] = {
    0x00000000, 0x80000000, 0x3f800000, 0xbfc00000, 0x3f000000, 0x40200000, 0xc0200000, 0x7f7fffff,
    0xff7fffff, 0x00000001, 0x007fffff, 0x80800000, 0x7f800000, 0xff800000, 0x7fc00000, 0x7fa00001,
    0xffc12345, 0x4f000000, 0xcf000001, 0x5f800000, 0x477fe000, 0x477ff000, 0x387fc000, 0x33000000,
    0x3f801000, 0x3f803000, 0x4b000001, 0x3effffff, 0xc7000000, 0x33800001,
};
static const uint64_t f64_pat[] = {
    0x0000000000000000, 0x8000000000000000, 0x3ff0000000000000, 0xbff8000000000000, 0x3fe0000000000000,
    0x4004000000000000, 0xc004000000000000, 0x7fefffffffffffff, 0x0000000000000001, 0x000fffffffffffff,
    0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000000, 0x7ff4000000000001, 0xfff8000000012345,
    0x41e0000000000000, 0xc1e0000000200000, 0x43e0000000000000, 0x43f0000000000000, 0xc3e0000000000001,
    0x47efffffefffffff, 0x47efffff00000000, 0x36a0000000000000, 0x3ff0000010000000, 0x3ff0000030000000,
    0x3ff0000010000001, 0x380fffffe0000000, 0x40f86a0000000000, 0xc0dfffe000000000, 0x3810000000000000,
};
static const uint64_t int_pat[] = {
    0x0000000000000000, 0x0000000000000001, 0xffffffffffffffff, 0x7fffffffffffffff, 0x8000000000000000,
    0x8000000000000001, 0x7ffffffffffffffe, 0x5555555555555555, 0xaaaaaaaaaaaaaaaa, 0x0000000000000003,
    0x7f7f7f7f7f7f7f7f, 0x8080808080808080, 0x0123456789abcdef, 0xfedcba9876543210, 0x00ff00ff00ff00ff,
    0x7fff80007fff8000, 0x80000000ffffffff, 0x00000000c0000000, 0x0000000100000000, 0x4000000000000000,
};
static const int8_t shift_pat[] = { 0, 1, -1, 2, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, -7, -8, -9, -16,
    -31, -32, -33, -63, -64, -65, 127, -128, 3, -3 };

#define NPAT(a) (sizeof(a) / sizeof((a)[0]))
#define NV 24

static void make_vec(enum kind k, int idx, v128 *out) {
    uint8_t b[16];
    switch (k) {
    case F16:
        for (int l = 0; l < 8; l++) {
            uint16_t v = f16_pat[(idx * 5 + l * 3) % NPAT(f16_pat)];
            memcpy(b + 2 * l, &v, 2);
        }
        break;
    case F32:
        for (int l = 0; l < 4; l++) {
            uint32_t v = f32_pat[(idx * 5 + l * 7) % NPAT(f32_pat)];
            memcpy(b + 4 * l, &v, 4);
        }
        break;
    case F64:
        for (int l = 0; l < 2; l++) {
            uint64_t v = f64_pat[(idx * 5 + l * 11) % NPAT(f64_pat)];
            memcpy(b + 8 * l, &v, 8);
        }
        break;
    case SH:
        for (int l = 0; l < 16; l++)
            b[l] = (uint8_t) shift_pat[(idx * 7 + l * 5) % NPAT(shift_pat)];
        break;
    default: {
        int esize = k == I8 ? 1 : k == I16 ? 2 : k == I32 ? 4 : 8;
        for (int l = 0; l < 16 / esize; l++) {
            uint64_t v = int_pat[(idx * 3 + l * 7) % NPAT(int_pat)];
            // rotate so narrow lanes also see each pattern's top byte (sign/saturation edges)
            v = (l & 1) ? (v >> (64 - 8 * esize)) : v;
            memcpy(b + esize * l, &v, esize);
        }
    }
    }
    memcpy(out, b, 16);
}

static const uint64_t fp_modes[] = {
    0,
    1u << 22,           // RP
    2u << 22,           // RM
    3u << 22,           // RZ
    1u << 24,           // FZ
    1u << 25,           // DN
    1u << 26,           // AHP
    (1u << 24) | (1u << 25) | (3u << 22),
};

int main(void) {
    for (size_t t = 0; t < sizeof(tests) / sizeof(tests[0]); t++) {
        const struct test *tc = &tests[t];
        int fp = tc->kd == F16 || tc->kd == F32 || tc->kd == F64 || strstr(tc->name, "cvtf");
        size_t nmodes = fp ? NPAT(fp_modes) : 1;
        for (size_t mode = 0; mode < nmodes; mode++) {
            for (int i = 0; i < NV; i++) {
                for (int jj = 0; jj < 4; jj++) {
                    int j = (i * 7 + jj * 5 + 3) % NV;
                    v128 d, n, m, o;
                    make_vec(tc->kd, (i + 11) % NV, &d);
                    make_vec(tc->kd, i, &n);
                    make_vec(tc->km, j, &m);
                    tc->fn(&d, &n, &m, &o, fp_modes[mode]);
                    printf("%s fpcr=%llx %d %d %016llx %016llx\n", tc->name,
                           (unsigned long long) fp_modes[mode], i, j,
                           (unsigned long long) o.hi, (unsigned long long) o.lo);
                }
            }
        }
    }
    return 0;
}
