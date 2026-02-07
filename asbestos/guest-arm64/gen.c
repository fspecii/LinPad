/*
 * ARM64 Guest Instruction Generator
 *
 * This file translates ARM64 guest instructions into gadget sequences
 * that can be executed by the asbestos JIT engine.
 *
 * ARM64 uses fixed-width 32-bit instructions, which makes decoding
 * much simpler than x86. The instruction encoding follows a consistent
 * pattern based on the top 4 bits (op0 field).
 *
 * Return value convention (same as x86):
 *   - return 1 (true): instruction compiled, continue with next instruction
 *   - return 0 (false): block ended (branch, syscall, or error)
 *
 * Gadget calling convention:
 *   - _cpu (x1) points to cpu_state
 *   - _tlb (x2) points to TLB
 *   - _pc (x28) is the gadget instruction pointer
 *   - Guest registers are accessed via memory at CPU_x0 + reg * 8
 */

#include <assert.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include "asbestos/gen.h"
#include "emu/arch/arm64/decode.h"
#include "emu/interrupt.h"

// Gadget declarations
extern void gadget_interrupt(void);
extern void gadget_exit(void);


// Data processing gadgets
extern void gadget_load_reg(void);
extern void gadget_store_reg(void);
extern void gadget_store_addr_to_reg(void);  // Store _addr to guest register
extern void gadget_movz(void);
extern void gadget_movk(void);
extern void gadget_movn(void);
extern void gadget_add_imm(void);
extern void gadget_sub_imm(void);
extern void gadget_add_reg(void);
extern void gadget_sub_reg(void);
extern void gadget_adc_reg(void);
extern void gadget_sbc_reg(void);
extern void gadget_and_reg(void);
extern void gadget_orr_reg(void);
extern void gadget_orr_reg_shifted(void);
extern void gadget_and_reg_shifted(void);
extern void gadget_eor_reg_shifted(void);
extern void gadget_eor_reg(void);
extern void gadget_and_imm(void);
extern void gadget_orr_imm(void);
extern void gadget_eor_imm(void);
extern void gadget_adr(void);
extern void gadget_adrp(void);
extern void gadget_sxtw(void);
extern void gadget_sxth(void);
extern void gadget_sxtb(void);
extern void gadget_uxtw(void);
extern void gadget_uxth(void);
extern void gadget_uxtb(void);
extern void gadget_ubfm(void);
extern void gadget_sbfm(void);
extern void gadget_bfm(void);
extern void gadget_extr(void);

// Branch gadgets
extern void gadget_branch(void);
extern void gadget_branch_link(void);
extern void gadget_branch_reg(void);
extern void gadget_branch_link_reg(void);
extern void gadget_ret(void);
extern void gadget_cbz(void);
extern void gadget_cbnz(void);
extern void gadget_tbz(void);
extern void gadget_tbnz(void);
extern void gadget_bcond(void);
extern void gadget_svc(void);

// Flag-setting gadgets
extern void gadget_subs_reg(void);
extern void gadget_adds_reg(void);

// Specialized ALU gadgets (64-bit fast paths)
extern void gadget_add_imm_64(void);
extern void gadget_sub_imm_64(void);
extern void gadget_adds_imm_64(void);
extern void gadget_subs_imm_64(void);
extern void gadget_adds_imm_64_sh(void);
extern void gadget_subs_imm_64_sh(void);
extern void gadget_add_imm_64_sh(void);
extern void gadget_sub_imm_64_sh(void);
extern void gadget_adds_reg_64_nshift(void);
extern void gadget_subs_reg_64_nshift(void);
extern void gadget_add_reg_64_nshift(void);
extern void gadget_sub_reg_64_nshift(void);

// Per-condition bcond gadgets
extern void gadget_bcond_eq(void);
extern void gadget_bcond_ne(void);
extern void gadget_bcond_cs(void);
extern void gadget_bcond_cc(void);
extern void gadget_bcond_mi(void);
extern void gadget_bcond_pl(void);
extern void gadget_bcond_vs(void);
extern void gadget_bcond_vc(void);
extern void gadget_bcond_hi(void);
extern void gadget_bcond_ls(void);
extern void gadget_bcond_ge(void);
extern void gadget_bcond_lt(void);
extern void gadget_bcond_gt(void);
extern void gadget_bcond_le(void);

// Fused CMP-imm + B.cond gadgets (rd=31, CMP only sets flags)
extern void gadget_fused_cmp_bcond_eq(void);
extern void gadget_fused_cmp_bcond_ne(void);
extern void gadget_fused_cmp_bcond_cs(void);
extern void gadget_fused_cmp_bcond_cc(void);
extern void gadget_fused_cmp_bcond_mi(void);
extern void gadget_fused_cmp_bcond_pl(void);
extern void gadget_fused_cmp_bcond_vs(void);
extern void gadget_fused_cmp_bcond_vc(void);
extern void gadget_fused_cmp_bcond_hi(void);
extern void gadget_fused_cmp_bcond_ls(void);
extern void gadget_fused_cmp_bcond_ge(void);
extern void gadget_fused_cmp_bcond_lt(void);
extern void gadget_fused_cmp_bcond_gt(void);
extern void gadget_fused_cmp_bcond_le(void);

// Fused SUBS-imm + B.cond gadgets (rd!=31, stores result AND sets flags)
extern void gadget_fused_subs_bcond_eq(void);
extern void gadget_fused_subs_bcond_ne(void);
extern void gadget_fused_subs_bcond_cs(void);
extern void gadget_fused_subs_bcond_cc(void);
extern void gadget_fused_subs_bcond_mi(void);
extern void gadget_fused_subs_bcond_pl(void);
extern void gadget_fused_subs_bcond_vs(void);
extern void gadget_fused_subs_bcond_vc(void);
extern void gadget_fused_subs_bcond_hi(void);
extern void gadget_fused_subs_bcond_ls(void);
extern void gadget_fused_subs_bcond_ge(void);
extern void gadget_fused_subs_bcond_lt(void);
extern void gadget_fused_subs_bcond_gt(void);
extern void gadget_fused_subs_bcond_le(void);

// Conditional select
extern void gadget_csel(void);
extern void gadget_csinc(void);
extern void gadget_csinv(void);
extern void gadget_csneg(void);

// Conditional compare
extern void gadget_ccmp_reg(void);
extern void gadget_ccmn_reg(void);
extern void gadget_ccmp_imm(void);
extern void gadget_ccmn_imm(void);

// SIMD gadgets (minimal set for memset)
extern void gadget_dup_gpr_to_v16b(void);  // DUP Vd.16B, Wn
extern void gadget_dup_gpr_to_vec(void);   // DUP Vd.<T>, Wn (general - all element sizes)
extern void gadget_dup_elem_vec(void);     // DUP Vd.<T>, Vn.<Ts>[idx] (element to vector)
extern void gadget_dup_elem_scalar(void);  // DUP <V>d, Vn.<T>[idx] (element to scalar)
extern void gadget_ins_elem_vec(void);     // INS Vd.<T>[idx1], Vn.<T>[idx2] (element to element)
extern void gadget_mov_v_to_gpr(void);     // MOV Xd, Vn.D[0]
extern void gadget_umov_vec_to_gpr(void);  // UMOV/MOV Wd, Vn.<T>[idx]
extern void gadget_ins_gpr_to_vec_s(void); // MOV Vd.S[idx], Wn (INS from GPR)
extern void gadget_ins_gpr_to_vec_d(void); // MOV Vd.D[idx], Xn (INS from GPR)
extern void gadget_str_q(void);            // STR Qn, [addr]
extern void gadget_stur_q(void);           // STUR Qn, [addr, #imm]
extern void gadget_stp_q(void);            // STP Qn, Qm, [addr]
extern void gadget_movi_v(void);           // MOVI/MVNI Vd, #imm
extern void gadget_set_vec_imm(void);      // Set vector immediate (raw 128-bit)
extern void gadget_orr_imm_vec(void);      // ORR Vd, #imm (vector)
extern void gadget_bic_imm_vec(void);      // BIC Vd, #imm (vector)
extern void gadget_ushl_vec(void);         // USHL Vd, Vn, Vm (vector shift left)
extern void gadget_sshl_vec(void);         // SSHL Vd, Vn, Vm (signed shift left)
extern void gadget_sshll_vec_s_to_d(void); // SSHLL Vd.2D, Vn.2S, #imm
extern void gadget_ushll_vec_s_to_d(void); // USHLL Vd.2D, Vn.2S, #imm
extern void gadget_shl_imm_vec(void);      // SHL Vd, Vn, #imm (shift left immediate)
extern void gadget_shl_imm_scalar(void);   // SHL Dd, Dn, #imm (scalar shift left immediate)
extern void gadget_sshr_imm_vec(void);     // SSHR Vd, Vn, #imm (signed shift right immediate)
extern void gadget_sshr_imm_scalar(void);  // SSHR Dd, Dn, #imm (scalar signed shift right)
extern void gadget_ushr_imm_vec(void);     // USHR Vd, Vn, #imm (unsigned shift right immediate)
extern void gadget_ushr_imm_scalar(void);  // USHR Dd, Dn, #imm (scalar unsigned shift right)
extern void gadget_ssra_imm_vec(void);     // SSRA Vd, Vn, #imm (signed shift right and accumulate)
extern void gadget_ssra_imm_scalar(void);  // SSRA Dd, Dn, #imm (scalar signed shift right and accumulate)
extern void gadget_usra_imm_vec(void);     // USRA Vd, Vn, #imm (unsigned shift right and accumulate)
extern void gadget_usra_imm_scalar(void);  // USRA Dd, Dn, #imm (scalar unsigned shift right and accumulate)
extern void gadget_sri_imm_vec(void);      // SRI Vd, Vn, #imm (shift right and insert)
extern void gadget_sli_imm_vec(void);      // SLI Vd, Vn, #imm (shift left and insert)
extern void gadget_cmhi_vec(void);         // CMHI Vd, Vn, Vm (unsigned compare greater)
extern void gadget_cmhs_vec(void);         // CMHS Vd, Vn, Vm (unsigned compare greater or equal)
extern void gadget_cmeq_vec(void);         // CMEQ Vd, Vn, Vm (compare equal)
extern void gadget_cmeq_zero_vec(void);    // CMEQ Vd, Vn, #0 (compare equal to zero)
extern void gadget_and_vec(void);          // AND Vd, Vn, Vm (bitwise AND)
extern void gadget_orr_vec(void);          // ORR Vd, Vn, Vm (bitwise OR)
extern void gadget_eor_vec(void);          // EOR Vd, Vn, Vm (bitwise XOR)
extern void gadget_bic_vec(void);          // BIC Vd, Vn, Vm (bit clear)
extern void gadget_bsl_vec(void);          // BSL Vd, Vn, Vm (bitwise select)
extern void gadget_bit_vec(void);          // BIT Vd, Vn, Vm (bitwise insert)
extern void gadget_bif_vec(void);          // BIF Vd, Vn, Vm (bitwise insert if false)
extern void gadget_addp_vec(void);         // ADDP Vd, Vn, Vm (add pairwise)
extern void gadget_umaxp_vec(void);        // UMAXP Vd, Vn, Vm (unsigned max pairwise)
extern void gadget_uminp_vec(void);        // UMINP Vd, Vn, Vm (unsigned min pairwise)
extern void gadget_aese(void);             // AESE Vd.16B, Vn.16B (AES encrypt)
extern void gadget_aesd(void);             // AESD Vd.16B, Vn.16B (AES decrypt)
extern void gadget_aesmc(void);            // AESMC Vd.16B, Vn.16B (AES mix columns)
extern void gadget_aesimc(void);           // AESIMC Vd.16B, Vn.16B (AES inverse mix columns)
extern void gadget_tbl(void);              // TBL Vd, {Vn..Vn+len}, Vm (table lookup)
extern void gadget_tbx(void);              // TBX Vd, {Vn..Vn+len}, Vm (table lookup extend)
extern void gadget_ext_vec(void);          // EXT Vd, Vn, Vm, #index (extract from pair)
extern void gadget_sha1c(void);            // SHA1C Qd, Sn, Vm.4S
extern void gadget_sha1h(void);            // SHA1H Sd, Sn
extern void gadget_sha1m(void);            // SHA1M Qd, Sn, Vm.4S
extern void gadget_sha1p(void);            // SHA1P Qd, Sn, Vm.4S
extern void gadget_sha1su0(void);          // SHA1SU0 Vd.4S, Vn.4S, Vm.4S
extern void gadget_sha1su1(void);          // SHA1SU1 Vd.4S, Vn.4S
extern void gadget_sha256h(void);          // SHA256H Qd, Qn, Vm.4S
extern void gadget_sha256h2(void);         // SHA256H2 Qd, Qn, Vm.4S
extern void gadget_sha256su0(void);        // SHA256SU0 Vd.4S, Vn.4S
extern void gadget_sha256su1(void);        // SHA256SU1 Vd.4S, Vn.4S, Vm.4S
extern void gadget_sha512su0(void);        // SHA512SU0 Vd.2D, Vn.2D
extern void gadget_sha512su1(void);        // SHA512SU1 Vd.2D, Vn.2D, Vm.2D
extern void gadget_sha512h(void);          // SHA512H Qd, Qn, Vm.2D
extern void gadget_sha512h2(void);         // SHA512H2 Qd, Qn, Vm.2D
extern void gadget_eor3(void);             // EOR3 Vd.16B, Vn.16B, Vm.16B, Va.16B
extern void gadget_sm3partw1(void);        // SM3PARTW1 Vd.4S, Vn.4S, Vm.4S
extern void gadget_sm4e(void);             // SM4E Vd.4S, Vn.4S
extern void gadget_sve_eor_d(void);        // SVE EOR Zd.D, Zn.D, Zm.D (128-bit modeled)
extern void gadget_sve_xar_d(void);        // SVE XAR Zd.D, Zd.D, Zm.D, #imm (128-bit modeled)
extern void gadget_pmull(void);            // PMULL Vd, Vn, Vm (polynomial multiply long)
extern void gadget_xtn_vec(void);          // XTN/XTN2 Vd, Vn (narrow)
extern void gadget_uzp1_vec(void);         // UZP1 Vd, Vn, Vm (unzip even elements)
extern void gadget_uzp2_vec(void);         // UZP2 Vd, Vn, Vm (unzip odd elements)
extern void gadget_trn1_vec(void);         // TRN1 Vd, Vn, Vm (transpose even)
extern void gadget_trn2_vec(void);         // TRN2 Vd, Vn, Vm (transpose odd)
extern void gadget_zip1_vec(void);         // ZIP1 Vd, Vn, Vm (zip lower halves)
extern void gadget_zip2_vec(void);         // ZIP2 Vd, Vn, Vm (zip upper halves)
extern void gadget_rev32_vec(void);        // REV32 Vd, Vn (reverse bytes in 32-bit elements)
extern void gadget_rev64_vec(void);        // REV64 Vd, Vn (reverse bytes in 64-bit elements)
extern void gadget_rbit_vec(void);         // RBIT Vd.xB, Vn.xB (reverse bits in each byte)
extern void gadget_add_vec(void);          // ADD Vd, Vn, Vm (vector add)
extern void gadget_sub_vec(void);          // SUB Vd, Vn, Vm (vector subtract)
extern void gadget_shadd_vec(void);        // SHADD Vd, Vn, Vm (signed halving add)
extern void gadget_uhadd_vec(void);        // UHADD Vd, Vn, Vm (unsigned halving add)
extern void gadget_srhadd_vec(void);       // SRHADD Vd, Vn, Vm (signed rounding halving add)
extern void gadget_urhadd_vec(void);       // URHADD Vd, Vn, Vm (unsigned rounding halving add)
extern void gadget_saddw_vec(void);        // SADDW Vd, Vn, Vm (signed add wide)
extern void gadget_uaddw_vec(void);        // UADDW Vd, Vn, Vm (unsigned add wide)

// Floating-point conversions
extern void gadget_ucvtf_scalar(void);     // UCVTF Sd, Wn / UCVTF Dd, Xn
extern void gadget_scvtf_scalar(void);     // SCVTF Sd, Wn / SCVTF Dd, Xn
extern void gadget_fcvtzu_scalar(void);    // FCVTZU Wd, Sn / FCVTZU Xd, Dn
extern void gadget_fcvtzs_scalar(void);    // FCVTZS Wd, Sn / FCVTZS Xd, Dn
extern void gadget_fcvtzs_simd_scalar(void); // FCVTZS Dd, Dn (SIMD scalar)
extern void gadget_fcvtzu_simd_scalar(void); // FCVTZU Dd, Dn (SIMD scalar)
extern void gadget_ucvtf_simd_scalar(void);  // UCVTF Sd, Sn / UCVTF Dd, Dn (SIMD scalar)
extern void gadget_scvtf_simd_scalar(void);  // SCVTF Sd, Sn / SCVTF Dd, Dn (SIMD scalar)
extern void gadget_fmov_gpr_to_fp(void);   // FMOV Sd, Wn / FMOV Dd, Xn
extern void gadget_fmov_gpr_to_fp_hi(void);   // FMOV Vd.D[1], Xn
extern void gadget_fmov_fp_to_gpr(void);   // FMOV Wd, Sn / FMOV Xd, Dn
extern void gadget_fmov_fp_to_gpr_hi(void);   // FMOV Xd, Vn.D[1]
extern void gadget_fmov_fp_to_fp(void);    // FMOV Sd, Sn / FMOV Dd, Dn (scalar reg copy)
extern void gadget_fcmp_scalar(void);      // FCMP/FCMPE Sn, Sm / Dn, Dm
extern void gadget_fcmp_zero_scalar(void); // FCMP/FCMPE Sn, #0.0 / Dn, #0.0
extern void gadget_fadd_scalar(void);      // FADD Sn, Sm, Sd / Dn, Dm, Dd
extern void gadget_fsub_scalar(void);      // FSUB Sn, Sm, Sd / Dn, Dm, Dd
extern void gadget_fmul_scalar(void);      // FMUL Sn, Sm, Sd / Dn, Dm, Dd
extern void gadget_fdiv_scalar(void);      // FDIV Sn, Sm, Sd / Dn, Dm, Dd
extern void gadget_fmadd_scalar(void);     // FMADD Fd, Fn, Fm, Fa
extern void gadget_fmsub_scalar(void);     // FMSUB Fd, Fn, Fm, Fa
extern void gadget_fnmadd_scalar(void);    // FNMADD Fd, Fn, Fm, Fa
extern void gadget_fnmsub_scalar(void);    // FNMSUB Fd, Fn, Fm, Fa

// SIMD load/store gadgets (V bit set)
extern void gadget_str_simd_b(void);       // STR Bt, [Xn, #imm]
extern void gadget_str_simd_h(void);       // STR Ht, [Xn, #imm]
extern void gadget_str_simd_s(void);       // STR St, [Xn, #imm]
extern void gadget_str_simd_d(void);       // STR Dt, [Xn, #imm]
extern void gadget_str_simd_q(void);       // STR Qt, [Xn, #imm]
extern void gadget_ldr_simd_b(void);       // LDR Bt, [Xn, #imm]
extern void gadget_ldr_simd_h(void);       // LDR Ht, [Xn, #imm]
extern void gadget_ldr_simd_s(void);       // LDR St, [Xn, #imm]
extern void gadget_ldr_simd_d(void);       // LDR Dt, [Xn, #imm]
extern void gadget_ldr_simd_q(void);       // LDR Qt, [Xn, #imm]
extern void gadget_stp_simd_s(void);       // STP St, St2, [Xn, #imm]
extern void gadget_stp_simd_d(void);       // STP Dt, Dt2, [Xn, #imm]
extern void gadget_stp_simd_q(void);       // STP Qt, Qt2, [Xn, #imm]
extern void gadget_ldp_simd_s(void);       // LDP St, St2, [Xn, #imm]
extern void gadget_ldp_simd_d(void);       // LDP Dt, Dt2, [Xn, #imm]
extern void gadget_ldp_simd_q(void);       // LDP Qt, Qt2, [Xn, #imm]
// LD1/ST1 single structure (single element to/from lane)
extern void gadget_ld1_single_b(void);     // LD1 {Vt.B}[lane], [Xn]
extern void gadget_ld1_single_h(void);     // LD1 {Vt.H}[lane], [Xn]
extern void gadget_ld1_single_s(void);     // LD1 {Vt.S}[lane], [Xn]
extern void gadget_ld1_single_d(void);     // LD1 {Vt.D}[lane], [Xn]
extern void gadget_st1_single_b(void);     // ST1 {Vt.B}[lane], [Xn]
extern void gadget_st1_single_h(void);     // ST1 {Vt.H}[lane], [Xn]
extern void gadget_st1_single_s(void);     // ST1 {Vt.S}[lane], [Xn]
extern void gadget_st1_single_d(void);     // ST1 {Vt.D}[lane], [Xn]

// Decode ARM64 FP immediate encoding to IEEE bits.
// Encoding uses imm8 with bit6 inverted in the instruction encoding.
// Value is: (-1)^sign * (16+frac) * 2^(exp-7)
static uint64_t arm64_fpimm_to_bits(bool is_double, uint8_t imm8) {
    int sign = (imm8 >> 7) & 1;
    int exp = (imm8 >> 4) & 0x7;
    int frac = imm8 & 0xf;
    double value = (double)(16 + frac) / (double)(1 << (7 - exp));
    if (sign)
        value = -value;
    if (is_double) {
        union { double d; uint64_t u; } conv;
        conv.d = value;
        return conv.u;
    } else {
        union { float f; uint32_t u; } conv;
        conv.f = (float)value;
        return (uint64_t)conv.u;
    }
}

// Address manipulation gadgets
extern void gadget_advance_addr(void);     // Add immediate to _addr
extern void gadget_update_base_reg(void);  // Update base register from Rm

// Multiply gadgets
extern void gadget_madd(void);
extern void gadget_msub(void);
extern void gadget_smaddl(void);
extern void gadget_smsubl(void);
extern void gadget_umaddl(void);
extern void gadget_umsubl(void);
extern void gadget_umulh(void);
extern void gadget_smulh(void);

// Data processing (2 source)
extern void gadget_udiv(void);
extern void gadget_sdiv(void);
extern void gadget_lslv(void);
extern void gadget_lsrv(void);
extern void gadget_asrv(void);
extern void gadget_rorv(void);

// Add/subtract extended register
extern void gadget_add_ext(void);
extern void gadget_sub_ext(void);
extern void gadget_adds_ext(void);
extern void gadget_subs_ext(void);

// System register gadgets
extern void gadget_msr_tpidr(void);
extern void gadget_mrs_tpidr(void);
extern void gadget_mrs_sysreg(void);

// Byte reverse and bit manipulation gadgets
extern void gadget_rev(void);
extern void gadget_rev16(void);
extern void gadget_rev32(void);
extern void gadget_clz(void);
extern void gadget_cls(void);
extern void gadget_rbit(void);

// System register IDs for gadget_mrs_sysreg
#define SYSREG_ID_TPIDR_EL0  0
#define SYSREG_ID_CTR_EL0    1
#define SYSREG_ID_DCZID_EL0  2
#define SYSREG_ID_FPCR       3
#define SYSREG_ID_FPSR       4
#define SYSREG_ID_RNDR       5   // Random Number (ARMv8.5-RNG)
#define SYSREG_ID_RNDRRS     6   // Reseeded Random Number (ARMv8.5-RNG)
#define SYSREG_ID_ID_AA64PFR0_EL1 7
#define SYSREG_ID_ID_AA64PFR1_EL1 8
#define SYSREG_ID_ID_AA64ISAR0_EL1 9
#define SYSREG_ID_ID_AA64ISAR1_EL1 10
#define SYSREG_ID_ID_AA64ZFR0_EL1 11

// Memory gadgets
extern void gadget_load64(void);
extern void gadget_load32(void);
extern void gadget_load16(void);
extern void gadget_load8(void);
extern void gadget_load32_sx(void);
extern void gadget_load16_sx32(void);
extern void gadget_load16_sx64(void);
extern void gadget_load8_sx32(void);
extern void gadget_load8_sx64(void);
extern void gadget_store64(void);
extern void gadget_store32(void);
extern void gadget_store16(void);
extern void gadget_store8(void);
extern void gadget_calc_addr_imm(void);
extern void gadget_calc_addr_reg(void);
extern void gadget_calc_addr_base(void);
extern void gadget_calc_addr_pc_rel(void);
// Fused load/store gadgets (calc_addr_imm + load/store + reg transfer in one dispatch)
extern void gadget_load64_imm(void);
extern void gadget_load32_imm(void);
extern void gadget_load16_imm(void);
extern void gadget_load8_imm(void);
extern void gadget_load32_sx_imm(void);
extern void gadget_store64_imm(void);
extern void gadget_store32_imm(void);
extern void gadget_store16_imm(void);
extern void gadget_store8_imm(void);
// Fused register-offset load/store gadgets (option=3/UXTX only)
extern void gadget_load64_reg(void);
extern void gadget_load32_reg(void);
extern void gadget_load16_reg(void);
extern void gadget_load8_reg(void);
extern void gadget_load32_sx_reg(void);
extern void gadget_store64_reg(void);
extern void gadget_store32_reg(void);
extern void gadget_store16_reg(void);
extern void gadget_store8_reg(void);
extern void gadget_update_base(void);
extern void gadget_writeback_addr(void);
// Atomic memory operation helpers
extern void gadget_atomic_rmw(void);
extern void gadget_atomic_cas(void);

// Load/store pair gadgets
extern void gadget_ldp64(void);
extern void gadget_ldp32(void);
extern void gadget_stp64(void);
extern void gadget_stp32(void);

static void gen(struct gen_state *state, unsigned long thing) {
    assert(state->size <= state->capacity);
    if (state->size >= state->capacity) {
        state->capacity *= 2;
        struct fiber_block *new_block = realloc(state->block,
                sizeof(*new_block) + state->capacity * sizeof(unsigned long));
        if (new_block == NULL) {
            abort();
        }
        state->block = new_block;
    }
    state->block->code[state->size++] = thing;
}

// Generate interrupt and end the block
static void gen_interrupt(struct gen_state *state, int interrupt_type) {
#if defined(GUEST_ARM64) && !defined(NDEBUG)
    static unsigned unimp_count = 0;
    extern uint32_t arm64_classify_insn(uint32_t insn);
    if (interrupt_type == INT_UNDEFINED && unimp_count++ < 200) {
        fprintf(stderr, "[UNIMP] ip=0x%08x insn=0x%08x class=%u\n",
                state->orig_ip, state->last_insn, arm64_classify_insn(state->last_insn));
    }
#endif
    gen(state, (unsigned long) gadget_interrupt);
    gen(state, interrupt_type);
}

void gen_start(addr_t addr, struct gen_state *state) {
    state->capacity = FIBER_BLOCK_INITIAL_CAPACITY;
    state->size = 0;
    state->ip = addr;
    state->last_insn = 0;
    for (int i = 0; i <= 1; i++) {
        state->jump_ip[i] = 0;
    }
    state->block_patch_ip = 0;

    struct fiber_block *block = malloc(sizeof(struct fiber_block) + state->capacity * sizeof(unsigned long));
    state->block = block;
    block->addr = addr;
}

void gen_end(struct gen_state *state) {
    struct fiber_block *block = state->block;
    for (int i = 0; i <= 1; i++) {
        if (state->jump_ip[i] != 0) {
            block->jump_ip[i] = &block->code[state->jump_ip[i]];
            block->old_jump_ip[i] = *block->jump_ip[i];
        } else {
            block->jump_ip[i] = NULL;
        }

        list_init(&block->jumps_from[i]);
        list_init(&block->jumps_from_links[i]);
    }
    if (state->block_patch_ip != 0) {
        block->code[state->block_patch_ip] = (unsigned long) block;
    }
    if (block->addr != state->ip)
        block->end_addr = state->ip - 1;
    else
        block->end_addr = block->addr;
    list_init(&block->chain);
    block->is_jetsam = false;
    for (int i = 0; i <= 1; i++) {
        list_init(&block->page[i]);
    }
}

void gen_exit(struct gen_state *state) {
    gen(state, (unsigned long) gadget_exit);
    gen(state, state->ip);
}

// Forward declarations
static int gen_dp_imm(struct gen_state *state, uint32_t insn);
static int gen_branch(struct gen_state *state, uint32_t insn);
static int gen_ldst(struct gen_state *state, uint32_t insn);
static int gen_dp_reg(struct gen_state *state, uint32_t insn);
static int gen_simd_fp(struct gen_state *state, uint32_t insn);

int gen_step(struct gen_state *state, struct tlb *tlb) {
    state->orig_ip = state->ip;
    state->orig_ip_extra = 0;
    state->tlb = tlb;

    uint32_t insn;
    if (!arm64_read_insn(&state->ip, tlb, &insn)) {
        gen_interrupt(state, INT_GPF);
        return 0;
    }
    state->last_insn = insn;

    // Handle a small subset of SVE/SVE2 instructions (modeled as 128-bit vectors)
    // SVE EOR Zd.D, Zn.D, Zm.D
    if ((insn & 0xffe0fc00) == 0x04a03000) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rm = (insn >> 16) & 0x1f;
        gen(state, (unsigned long) gadget_sve_eor_d);
        gen(state, rd | (rn << 8) | (rm << 16));
        return 1;
    }
    // SVE XAR Zd.D, Zd.D, Zm.D, #imm
    if ((insn & 0xffe0fc00) == 0x04e03400 || (insn & 0xffe0fc00) == 0x04a03400) {
        uint32_t rd = insn & 0x1f;
        uint32_t zm = (insn >> 5) & 0x1f;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t imm_low = (32 - rm) & 0x1f;
        if (imm_low == 0) {
            imm_low = 32;
        }
        uint32_t imm = imm_low + (((insn >> 22) & 1) ? 0 : 32);
        gen(state, (unsigned long) gadget_sve_xar_d);
        gen(state, rd | (zm << 8) | (imm << 16));
        return 1;
    }

    enum arm64_insn_type type = arm64_classify_insn(insn);

    switch (type) {
        case INSN_DP_IMM:
            return gen_dp_imm(state, insn);
        case INSN_BRANCH:
        case INSN_EXCEPTION:
        case INSN_SYSTEM:
            return gen_branch(state, insn);
        case INSN_LD_ST:
            return gen_ldst(state, insn);
        case INSN_DP_REG:
            return gen_dp_reg(state, insn);
        case INSN_SIMD_FP:
            return gen_simd_fp(state, insn);
        default:
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
    }
}

/*
 * Helper: Decode bitmask immediate
 * ARM64 uses a complex encoding for bitmask immediates.
 * Returns false if the encoding is invalid.
 */
static bool decode_bitmask_imm(uint32_t n, uint32_t imms, uint32_t immr, bool is64, uint64_t *result) {
    uint32_t len = 0;

    // Find the highest bit set in (n:~imms)
    uint32_t combined = (n << 6) | (~imms & 0x3f);
    for (int i = 6; i >= 0; i--) {
        if (combined & (1 << i)) {
            len = i;
            break;
        }
    }

    if (len < 1) return false;

    uint32_t size = 1 << len;
    uint32_t s = imms & (size - 1);
    uint32_t r = immr & (size - 1);

    if (s == size - 1) return false;

    // Create the base pattern
    uint64_t pattern = (1ULL << (s + 1)) - 1;

    // Rotate right (handle r=0 case to avoid shifting by size bits)
    if (r > 0) {
        pattern = (pattern >> r) | (pattern << (size - r));
        pattern &= (size < 64) ? ((1ULL << size) - 1) : ~0ULL;
    }

    // Replicate to 64 bits
    *result = 0;
    for (uint32_t i = 0; i < 64; i += size) {
        *result |= pattern << i;
    }

    if (!is64) {
        *result &= 0xFFFFFFFF;
    }

    return true;
}

// Expand Advanced SIMD modified immediate (integer) into a 64-bit pattern.
// Returns false if cmode is not supported.
static bool simd_modimm_pattern(uint32_t cmode, uint8_t imm8, uint64_t *pattern) {
    uint64_t elem;
    switch (cmode) {
        // 32-bit elements, shift 0/8/16/24
        case 0x0: case 0x2: case 0x4: case 0x6: {
            uint32_t shift = (cmode >> 1) * 8;
            elem = (uint64_t)imm8 << shift;
            *pattern = elem | (elem << 32);
            return true;
        }
        // 16-bit elements, shift 0/8
        case 0x8: case 0xa: {
            uint32_t shift = ((cmode >> 1) & 1) * 8;
            elem = (uint64_t)imm8 << shift;
            *pattern = elem | (elem << 16) | (elem << 32) | (elem << 48);
            return true;
        }
        // 8-bit elements
        case 0xe:
            elem = imm8;
            *pattern = elem * 0x0101010101010101ULL;
            return true;
        default:
            return false;
    }
}

/*
 * Peek at the next instruction without advancing state->ip.
 * Returns true if successful, false if read fails.
 */
static bool gen_peek_next_insn(struct gen_state *state, uint32_t *next_insn) {
    return tlb_read(state->tlb, state->ip, next_insn, sizeof(*next_insn));
}

/*
 * Fused CMP/SUBS + B.cond gadget tables (initialized lazily)
 */
static void *fused_cmp_bcond_gadgets[14];
static void *fused_subs_bcond_gadgets[14];
static bool fused_bcond_tables_init = false;

static void init_fused_bcond_tables(void) {
    if (fused_bcond_tables_init) return;
    fused_cmp_bcond_gadgets[0]  = gadget_fused_cmp_bcond_eq;
    fused_cmp_bcond_gadgets[1]  = gadget_fused_cmp_bcond_ne;
    fused_cmp_bcond_gadgets[2]  = gadget_fused_cmp_bcond_cs;
    fused_cmp_bcond_gadgets[3]  = gadget_fused_cmp_bcond_cc;
    fused_cmp_bcond_gadgets[4]  = gadget_fused_cmp_bcond_mi;
    fused_cmp_bcond_gadgets[5]  = gadget_fused_cmp_bcond_pl;
    fused_cmp_bcond_gadgets[6]  = gadget_fused_cmp_bcond_vs;
    fused_cmp_bcond_gadgets[7]  = gadget_fused_cmp_bcond_vc;
    fused_cmp_bcond_gadgets[8]  = gadget_fused_cmp_bcond_hi;
    fused_cmp_bcond_gadgets[9]  = gadget_fused_cmp_bcond_ls;
    fused_cmp_bcond_gadgets[10] = gadget_fused_cmp_bcond_ge;
    fused_cmp_bcond_gadgets[11] = gadget_fused_cmp_bcond_lt;
    fused_cmp_bcond_gadgets[12] = gadget_fused_cmp_bcond_gt;
    fused_cmp_bcond_gadgets[13] = gadget_fused_cmp_bcond_le;
    fused_subs_bcond_gadgets[0]  = gadget_fused_subs_bcond_eq;
    fused_subs_bcond_gadgets[1]  = gadget_fused_subs_bcond_ne;
    fused_subs_bcond_gadgets[2]  = gadget_fused_subs_bcond_cs;
    fused_subs_bcond_gadgets[3]  = gadget_fused_subs_bcond_cc;
    fused_subs_bcond_gadgets[4]  = gadget_fused_subs_bcond_mi;
    fused_subs_bcond_gadgets[5]  = gadget_fused_subs_bcond_pl;
    fused_subs_bcond_gadgets[6]  = gadget_fused_subs_bcond_vs;
    fused_subs_bcond_gadgets[7]  = gadget_fused_subs_bcond_vc;
    fused_subs_bcond_gadgets[8]  = gadget_fused_subs_bcond_hi;
    fused_subs_bcond_gadgets[9]  = gadget_fused_subs_bcond_ls;
    fused_subs_bcond_gadgets[10] = gadget_fused_subs_bcond_ge;
    fused_subs_bcond_gadgets[11] = gadget_fused_subs_bcond_lt;
    fused_subs_bcond_gadgets[12] = gadget_fused_subs_bcond_gt;
    fused_subs_bcond_gadgets[13] = gadget_fused_subs_bcond_le;
    fused_bcond_tables_init = true;
}

/*
 * Try to fuse SUBS/CMP imm with a following B.cond.
 * Returns 0 (block ended) if fused, -1 if not fuseable.
 * Only handles: op=SUB, sf=1, sh=0, rn!=31 (64-bit SUBS/CMP, no shift)
 */
static int try_fuse_subs_bcond(struct gen_state *state, uint32_t rd, uint32_t rn, uint32_t imm12) {
    uint32_t next_insn;
    if (!gen_peek_next_insn(state, &next_insn))
        return -1;
    // Check if next instruction is B.cond (encoding: 0101 0100 xxxx xxxx xxxx xxxx xxx0 xxxx)
    if ((next_insn & 0xff000010) != 0x54000000)
        return -1;
    uint32_t cond = next_insn & 0xf;
    if (cond >= 14)  // AL/NV — not worth fusing
        return -1;

    init_fused_bcond_tables();

    // Consume the B.cond instruction
    state->ip += 4;

    int64_t offset = arm64_branch_imm19(next_insn);
    addr_t target = (state->ip - 4) + offset;  // B.cond is relative to its own PC
    // Actually, the B.cond PC is (state->ip - 4) since we just consumed it.
    // But arm64_branch_imm19 gives offset from the B.cond instruction itself.
    // state->ip was at the B.cond start before we did += 4, so target = (state->ip - 4) + offset.
    unsigned long fake_target = (unsigned long)target | (1UL << 63);
    unsigned long fake_fallthrough = (unsigned long)state->ip | (1UL << 63);

    if (rd == 31) {
        // CMP: no result register, only flags
        gen(state, (unsigned long) fused_cmp_bcond_gadgets[cond]);
        gen(state, rn | ((uint64_t)imm12 << 8));
    } else {
        // SUBS: result register + flags
        gen(state, (unsigned long) fused_subs_bcond_gadgets[cond]);
        gen(state, rd | (rn << 8) | ((uint64_t)imm12 << 16));
    }
    gen(state, fake_target);
    gen(state, fake_fallthrough);
    state->jump_ip[0] = state->size - 2;  // target
    state->jump_ip[1] = state->size - 1;  // fallthrough
    return 0;  // block ended (branch)
}

/*
 * Data Processing (Immediate)
 */
static int gen_dp_imm(struct gen_state *state, uint32_t insn) {
    uint32_t op0 = (insn >> 23) & 0x7;

    // PC-relative addressing (ADR, ADRP)
    if ((insn & 0x1f000000) == 0x10000000) {
        uint32_t rd = insn & 0x1f;
        bool is_adrp = (insn >> 31) & 1;
        int64_t imm = arm64_adr_imm(insn);

        addr_t target;
        if (is_adrp) {
            target = (state->orig_ip & ~0xFFF) + (imm << 12);
        } else {
            target = state->orig_ip + imm;
        }

        // Generate: store immediate to register
        gen(state, (unsigned long) gadget_adr);
        gen(state, rd);
        gen(state, target);
        return 1;
    }

    // Add/subtract (immediate)
    if ((op0 & 0x6) == 0x2) {
        uint32_t sf = (insn >> 31) & 1;       // 0=32-bit, 1=64-bit
        uint32_t op = (insn >> 30) & 1;       // 0=ADD, 1=SUB
        uint32_t S = (insn >> 29) & 1;        // Set flags
        uint32_t sh = (insn >> 22) & 1;       // Shift (0=none, 1=LSL #12)
        uint32_t imm12 = (insn >> 10) & 0xfff;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        // Don't pre-shift imm12 - pass sh flag to gadget instead
        // This avoids overflow when imm12 << 12 > 12 bits

        // Try specialized 64-bit fast paths (no SP/XZR source)
        bool can_specialize_imm = sf && !sh && rn != 31;
        bool can_specialize_imm_sh = sf && sh && rn != 31;
        if (can_specialize_imm && S) {
            // Try fused SUBS/CMP + B.cond peephole (only for SUB, not ADD)
            if (op == 1) {
                int fused = try_fuse_subs_bcond(state, rd, rn, imm12);
                if (fused == 0) return 0;  // fused and block ended
            }
            // ADDS/SUBS imm 64-bit (rd=31 allowed for CMP/CMN)
            gen(state, (unsigned long)(op ? gadget_subs_imm_64 : gadget_adds_imm_64));
            gen(state, rd | (rn << 8) | ((uint64_t)imm12 << 16));
            return 1;
        }
        if (can_specialize_imm_sh && S) {
            // ADDS/SUBS imm 64-bit with LSL#12 (rd=31 allowed for CMP/CMN)
            gen(state, (unsigned long)(op ? gadget_subs_imm_64_sh : gadget_adds_imm_64_sh));
            gen(state, rd | (rn << 8) | ((uint64_t)imm12 << 16));
            return 1;
        }
        if (can_specialize_imm && !S && rd != 31) {
            // ADD/SUB imm 64-bit, no flags, no SP
            gen(state, (unsigned long)(op ? gadget_sub_imm_64 : gadget_add_imm_64));
            gen(state, rd | (rn << 8) | ((uint64_t)imm12 << 16));
            return 1;
        }
        if (can_specialize_imm_sh && !S && rd != 31) {
            // ADD/SUB imm 64-bit with LSL#12, no flags, no SP
            gen(state, (unsigned long)(op ? gadget_sub_imm_64_sh : gadget_add_imm_64_sh));
            gen(state, rd | (rn << 8) | ((uint64_t)imm12 << 16));
            return 1;
        }

        // Generic path: handles 32-bit, SP, and other cases
        if (op == 0) {
            gen(state, (unsigned long) gadget_add_imm);
        } else {
            gen(state, (unsigned long) gadget_sub_imm);
        }
        // Pack parameters: rd, rn, imm12, sf, S, sh
        // Layout: [0:4]=rd, [8:12]=rn, [16:27]=imm12, [28]=sf, [29]=S, [30]=sh
        uint64_t packed = rd | (rn << 8) | ((uint64_t)imm12 << 16) | ((uint64_t)sf << 28) | ((uint64_t)S << 29) | ((uint64_t)sh << 30);
        gen(state, packed);
        return 1;
    }

    // EXTR - Extract register (concatenate and shift)
    // Matches: 0b10010011110xxxxx (64-bit) / 0b00010011110xxxxx (32-bit)
    if ((insn & 0xffe00000) == 0x93c00000 || (insn & 0xffe00000) == 0x13800000) {
        uint32_t sf = (insn >> 31) & 1;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t imm = (insn >> 10) & 0x3f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        gen(state, (unsigned long) gadget_extr);
        gen(state, rd | (rn << 8) | (rm << 16) | ((uint64_t)imm << 24) | ((uint64_t)sf << 30));
        return 1;
    }

    // Logical (immediate) - only op0 == 0b100
    if (op0 == 0x4) {
        uint32_t sf = (insn >> 31) & 1;
        uint32_t opc = (insn >> 29) & 0x3;
        uint32_t N = (insn >> 22) & 1;
        uint32_t immr = (insn >> 16) & 0x3f;
        uint32_t imms = (insn >> 10) & 0x3f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        uint64_t imm;
        if (!decode_bitmask_imm(N, imms, immr, sf, &imm)) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        void *gadget;
        switch (opc) {
            case 0: gadget = gadget_and_imm; break;  // AND
            case 1: gadget = gadget_orr_imm; break;  // ORR
            case 2: gadget = gadget_eor_imm; break;  // EOR
            case 3: gadget = gadget_and_imm; break;  // ANDS (sets flags)
            default:
                gen_interrupt(state, INT_UNDEFINED);
                return 0;
        }

        gen(state, (unsigned long) gadget);
        gen(state, rd | (rn << 8) | ((uint64_t)sf << 16) | ((opc == 3) ? (1UL << 17) : 0));
        gen(state, imm);
        return 1;
    }

    // Move wide (immediate) - MOVN, MOVZ, MOVK
    // Pattern: x00x0101xxxxxxxxxxxxxxxxxxxxxxxx
    if ((insn & 0x1f800000) == 0x12800000) {
        uint32_t sf = (insn >> 31) & 1;
        uint32_t opc = (insn >> 29) & 0x3;
        uint32_t hw = (insn >> 21) & 0x3;
        uint32_t imm16 = (insn >> 5) & 0xffff;
        uint32_t rd = insn & 0x1f;


        if (!sf && hw >= 2) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        void *gadget;
        switch (opc) {
            case 0: gadget = gadget_movn; break;
            case 2: gadget = gadget_movz; break;
            case 3: gadget = gadget_movk; break;
            default:
                gen_interrupt(state, INT_UNDEFINED);
                return 0;
        }

        gen(state, (unsigned long) gadget);
        gen(state, rd | (hw << 8) | ((uint64_t)imm16 << 16) | ((uint64_t)sf << 32));
        return 1;
    }

    // Bitfield operations (SBFM, BFM, UBFM) - includes LSL, LSR, ASR, SXTB, SXTW, etc.
    // Pattern: x00x0110xxxxxxxxxxxxxxxxxxxxxxxx
    if ((insn & 0x1f800000) == 0x13000000) {
        uint32_t sf = (insn >> 31) & 1;
        uint32_t opc = (insn >> 29) & 0x3;
        // uint32_t N = (insn >> 22) & 1;  // Not used for common aliases
        uint32_t immr = (insn >> 16) & 0x3f;
        uint32_t imms = (insn >> 10) & 0x3f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        // Load source register
        gen(state, (unsigned long) gadget_load_reg);
        gen(state, rn);

        // Handle common sign-extend aliases (SBFM with opc=0)
        if (opc == 0) {
            if (immr == 0 && imms == 31 && sf == 1) {
                // SXTW Xd, Wn: sign-extend word to doubleword
                gen(state, (unsigned long) gadget_sxtw);
            } else if (immr == 0 && imms == 15) {
                // SXTH: sign-extend halfword
                gen(state, (unsigned long) gadget_sxth);
                gen(state, sf);
            } else if (immr == 0 && imms == 7) {
                // SXTB: sign-extend byte
                gen(state, (unsigned long) gadget_sxtb);
                gen(state, sf);
            } else {
                // General SBFM: handles ASR, SBFX, SBFIZ
                gen(state, (unsigned long) gadget_sbfm);
                // Pack: immr | imms<<8 | sf<<16
                gen(state, immr | (imms << 8) | ((uint64_t)sf << 16));
            }
        }
        // Handle zero-extend aliases (UBFM with opc=2)
        else if (opc == 2) {
            if (immr == 0 && imms == 31 && sf == 1) {
                // UXTW (or just MOV for 32-bit): zero-extend word
                gen(state, (unsigned long) gadget_uxtw);
            } else if (immr == 0 && imms == 15) {
                // UXTH: zero-extend halfword
                gen(state, (unsigned long) gadget_uxth);
                gen(state, sf);
            } else if (immr == 0 && imms == 7) {
                // UXTB: zero-extend byte
                gen(state, (unsigned long) gadget_uxtb);
                gen(state, sf);
            } else {
                // General UBFM: handles LSL, LSR, UBFX, UBFIZ
                gen(state, (unsigned long) gadget_ubfm);
                // Pack: immr | imms<<8 | sf<<16
                gen(state, immr | (imms << 8) | ((uint64_t)sf << 16));
            }
        }
        // BFM (opc=1) - Bitfield Move (preserves other bits in destination)
        else if (opc == 1) {
            // BFM needs both source (Rn) and destination (Rd) values
            // The source value is already in _tmp from gadget_load_reg above
            // Now we need to also load the destination register
            gen(state, (unsigned long) gadget_bfm);
            // Pack: immr | imms<<8 | sf<<16 | rd<<24
            gen(state, immr | (imms << 8) | ((uint64_t)sf << 16) | ((uint64_t)rd << 24));
        }
        else {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        // Store result to destination register
        gen(state, (unsigned long) gadget_store_reg);
        gen(state, rd);
        return 1;
    }

    gen_interrupt(state, INT_UNDEFINED);
    return 0;
}

/*
 * Branches, Exceptions, and System Instructions
 */
static int gen_branch(struct gen_state *state, uint32_t insn) {
    // SVC (system call)
    if ((insn & 0xffe0001f) == 0xd4000001) {
        gen(state, (unsigned long) gadget_svc);
        gen(state, state->ip);  // Next instruction address for resuming after syscall
        gen_interrupt(state, INT_SYSCALL);
        return 0;
    }

    // BRK (breakpoint) - 11010100 001 imm16 000 00
    // Encoding: 0xd4200000 with mask 0xffe0001f
    // This typically signals SIGTRAP. For now, treat as debug breakpoint.
    if ((insn & 0xffe0001f) == 0xd4200000) {
        gen_interrupt(state, INT_BREAKPOINT);
        return 0;
    }

    // Unconditional branch immediate (B, BL)
    if ((insn & 0x7c000000) == 0x14000000) {
        bool is_bl = (insn >> 31) & 1;
        int64_t offset = arm64_branch_imm26(insn);
        addr_t target = state->orig_ip + offset;
        // Use fake_ip (with bit 63 set) so fiber_ret_chain can detect unchained blocks
        unsigned long fake_target = (unsigned long)target | (1UL << 63);

        if (is_bl) {
            // BL: save return address to X30
            // Code stream: [gadget][block_self_ptr][return_addr][fake_return_cont][fake_target]
            unsigned long fake_return = (unsigned long)state->ip | (1UL << 63);
            gen(state, (unsigned long) gadget_branch_link);
            gen(state, 0);                  // block self-pointer (patched by gen_end)
            gen(state, state->ip);          // return address (next instruction)
            gen(state, fake_return);        // return continuation (patched to return-site block)
            gen(state, fake_target);        // call target (patched to callee block)
            state->block_patch_ip = state->size - 4; // patch slot for block self-pointer
            // jump_ip[0] = return continuation, jump_ip[1] = call target
            state->jump_ip[0] = state->size - 2;
            state->jump_ip[1] = state->size - 1;
        } else {
            gen(state, (unsigned long) gadget_branch);
            gen(state, fake_target);
            state->jump_ip[0] = state->size - 1;
        }

        return 0;
    }

    // Conditional branch (B.cond)
    if ((insn & 0xff000010) == 0x54000000) {
        uint32_t cond = insn & 0xf;
        int64_t offset = arm64_branch_imm19(insn);
        addr_t target = state->orig_ip + offset;
        unsigned long fake_target = (unsigned long)target | (1UL << 63);
        unsigned long fake_fallthrough = (unsigned long)state->ip | (1UL << 63);

        // Per-condition gadgets eliminate indirect branch through jump table
        static void *bcond_gadgets[16] = {
            [0]  = NULL, [1]  = NULL, [2]  = NULL, [3]  = NULL,
            [4]  = NULL, [5]  = NULL, [6]  = NULL, [7]  = NULL,
            [8]  = NULL, [9]  = NULL, [10] = NULL, [11] = NULL,
            [12] = NULL, [13] = NULL, [14] = NULL, [15] = NULL,
        };
        if (!bcond_gadgets[0]) {
            bcond_gadgets[0]  = gadget_bcond_eq;
            bcond_gadgets[1]  = gadget_bcond_ne;
            bcond_gadgets[2]  = gadget_bcond_cs;
            bcond_gadgets[3]  = gadget_bcond_cc;
            bcond_gadgets[4]  = gadget_bcond_mi;
            bcond_gadgets[5]  = gadget_bcond_pl;
            bcond_gadgets[6]  = gadget_bcond_vs;
            bcond_gadgets[7]  = gadget_bcond_vc;
            bcond_gadgets[8]  = gadget_bcond_hi;
            bcond_gadgets[9]  = gadget_bcond_ls;
            bcond_gadgets[10] = gadget_bcond_ge;
            bcond_gadgets[11] = gadget_bcond_lt;
            bcond_gadgets[12] = gadget_bcond_gt;
            bcond_gadgets[13] = gadget_bcond_le;
            bcond_gadgets[14] = NULL;  // AL
            bcond_gadgets[15] = NULL;  // NV (treat as AL)
        }

        if (cond >= 14) {
            // AL/NV: always taken — emit unconditional branch
            gen(state, (unsigned long) gadget_branch);
            gen(state, fake_target);
            state->jump_ip[0] = state->size - 1;
        } else {
            // Per-condition gadget: code stream is [gadget][target][fallthrough]
            gen(state, (unsigned long) bcond_gadgets[cond]);
            gen(state, fake_target);
            gen(state, fake_fallthrough);
            state->jump_ip[0] = state->size - 2;  // target
            state->jump_ip[1] = state->size - 1;  // fallthrough
        }
        return 0;
    }

    // Compare and branch (CBZ, CBNZ)
    if ((insn & 0x7e000000) == 0x34000000) {
        bool is_cbnz = (insn >> 24) & 1;
        bool sf = (insn >> 31) & 1;
        uint32_t rt = insn & 0x1f;
        int64_t offset = arm64_branch_imm19(insn);
        addr_t target = state->orig_ip + offset;
        // Use fake_ip for both target and fallthrough
        unsigned long fake_target = (unsigned long)target | (1UL << 63);
        unsigned long fake_fallthrough = (unsigned long)state->ip | (1UL << 63);

        if (is_cbnz) {
            gen(state, (unsigned long) gadget_cbnz);
        } else {
            gen(state, (unsigned long) gadget_cbz);
        }
        gen(state, rt | ((uint64_t)sf << 8));
        gen(state, fake_target);
        gen(state, fake_fallthrough);

        // Record both jump targets for potential block chaining
        state->jump_ip[0] = state->size - 2;  // target
        state->jump_ip[1] = state->size - 1;  // fallthrough
        return 0;
    }

    // Test and branch (TBZ, TBNZ)
    // Encoding: b5:011011:op:b40:imm14:Rt
    if ((insn & 0x7e000000) == 0x36000000) {
        bool is_tbnz = (insn >> 24) & 1;
        uint32_t b5 = (insn >> 31) & 1;
        uint32_t b40 = (insn >> 19) & 0x1f;
        uint32_t bit_pos = (b5 << 5) | b40;
        uint32_t rt = insn & 0x1f;
        int64_t imm14 = (insn >> 5) & 0x3fff;
        if (imm14 & 0x2000) imm14 |= ~0x3fffLL;  // sign-extend
        int64_t offset = imm14 * 4;
        addr_t target = state->orig_ip + offset;

        unsigned long fake_target = (unsigned long)target | (1UL << 63);
        unsigned long fake_fallthrough = (unsigned long)state->ip | (1UL << 63);

        if (is_tbnz) {
            gen(state, (unsigned long) gadget_tbnz);
        } else {
            gen(state, (unsigned long) gadget_tbz);
        }
        gen(state, rt | (bit_pos << 8));
        gen(state, fake_target);
        gen(state, fake_fallthrough);

        state->jump_ip[0] = state->size - 2;  // target
        state->jump_ip[1] = state->size - 1;  // fallthrough
        return 0;
    }

    // Unconditional branch register (BR, BLR, RET)
    if ((insn & 0xfe000000) == 0xd6000000) {
        uint32_t opc = (insn >> 21) & 0xf;
        uint32_t rn = (insn >> 5) & 0x1f;

        switch (opc) {
            case 0:  // BR
                gen(state, (unsigned long) gadget_branch_reg);
                gen(state, rn);
                break;
            case 1:  // BLR
                gen(state, (unsigned long) gadget_branch_link_reg);
                gen(state, rn);
                gen(state, state->ip);  // return address
                break;
            case 2:  // RET
                gen(state, (unsigned long) gadget_ret);
                gen(state, rn);  // usually X30
                break;
            default:
                gen_interrupt(state, INT_UNDEFINED);
                return 0;
        }
        return 0;
    }

    // System instructions (MSR, MRS, HINT, etc.)
    if ((insn & 0xffc00000) == 0xd5000000) {
        // HINT instructions (including NOP)
        // Encoding: 1101 0101 0000 0011 0010 xxxx xxx1 1111
        if ((insn & 0xfffff01f) == 0xd503201f) {
            // NOP, YIELD, WFE, WFI, SEV, SEVL, etc.
            // Just do nothing and continue to next instruction
            return 1;
        }

        // Barrier instructions (DMB, DSB, ISB)
        // DMB: 1101 0101 0000 0011 0011 CRm 1011 1111 = 0xd50330bf | (CRm << 8)
        // DSB: 1101 0101 0000 0011 0011 CRm 1001 1111 = 0xd503309f | (CRm << 8)
        // ISB: 1101 0101 0000 0011 0011 CRm 1101 1111 = 0xd50330df | (CRm << 8)
        if ((insn & 0xfffff0ff) == 0xd50330bf ||  // DMB
            (insn & 0xfffff0ff) == 0xd503309f ||  // DSB
            (insn & 0xfffff0ff) == 0xd50330df) {  // ISB
            // For emulation, barriers are essentially NOPs since we're single-threaded
            // and memory ordering is handled by the host
            return 1;
        }

        // MSR/MRS for TPIDR_EL0 (TLS pointer)
        // MSR: d51bd04t (write Xt to TPIDR_EL0)
        // MRS: d53bd04t (read TPIDR_EL0 to Xt)
        // Check for TPIDR_EL0 encoding: op0=3, op1=3, CRn=13, CRm=0, op2=2
        // Bits: L=0/1, op0=11, op1=011, CRn=1101, CRm=0000, op2=010
        if ((insn & 0xffffffe0) == 0xd51bd040) {
            // MSR TPIDR_EL0, Xt - write TLS pointer
            uint32_t rt = insn & 0x1f;
            gen(state, (unsigned long) gadget_msr_tpidr);
            gen(state, rt);
            return 1;
        }
        if ((insn & 0xffffffe0) == 0xd53bd040) {
            // MRS Xt, TPIDR_EL0 - read TLS pointer
            uint32_t rt = insn & 0x1f;
            gen(state, (unsigned long) gadget_mrs_tpidr);
            gen(state, rt);
            return 1;
        }

        // General MRS instruction: d53x xxxx
        // Format: 1101 0101 0011 op0 op1 CRn CRm op2 Rt
        if ((insn & 0xfff00000) == 0xd5300000) {
            uint32_t rt = insn & 0x1f;
            // Extract system register encoding
            // op0[20:19], op1[18:16], CRn[15:12], CRm[11:8], op2[7:5]
            uint32_t op0 = (insn >> 19) & 0x3;
            uint32_t op1 = (insn >> 16) & 0x7;
            uint32_t CRn = (insn >> 12) & 0xf;
            uint32_t CRm = (insn >> 8) & 0xf;
            uint32_t op2 = (insn >> 5) & 0x7;

            int sysreg_id = -1;

            // CTR_EL0: op0=3, op1=3, CRn=0, CRm=0, op2=1 (insn & 0xffffffe0 == 0xd53b00e0)
            if (op0 == 3 && op1 == 3 && CRn == 0 && CRm == 0 && op2 == 1) {
                sysreg_id = SYSREG_ID_CTR_EL0;
            }
            // DCZID_EL0: op0=3, op1=3, CRn=0, CRm=0, op2=7 (insn & 0xffffffe0 == 0xd53b00e0)
            else if (op0 == 3 && op1 == 3 && CRn == 0 && CRm == 0 && op2 == 7) {
                sysreg_id = SYSREG_ID_DCZID_EL0;
            }
            // FPCR: op0=3, op1=3, CRn=4, CRm=4, op2=0
            else if (op0 == 3 && op1 == 3 && CRn == 4 && CRm == 4 && op2 == 0) {
                sysreg_id = SYSREG_ID_FPCR;
            }
            // FPSR: op0=3, op1=3, CRn=4, CRm=4, op2=1
            else if (op0 == 3 && op1 == 3 && CRn == 4 && CRm == 4 && op2 == 1) {
                sysreg_id = SYSREG_ID_FPSR;
            }
            // RNDR: op0=3, op1=3, CRn=2, CRm=4, op2=0 (ARMv8.5-RNG Random Number)
            else if (op0 == 3 && op1 == 3 && CRn == 2 && CRm == 4 && op2 == 0) {
                sysreg_id = SYSREG_ID_RNDR;
            }
            // RNDRRS: op0=3, op1=3, CRn=2, CRm=4, op2=1 (ARMv8.5-RNG Reseeded Random Number)
            else if (op0 == 3 && op1 == 3 && CRn == 2 && CRm == 4 && op2 == 1) {
                sysreg_id = SYSREG_ID_RNDRRS;
            }
            // ID_AA64PFR0_EL1: op0=3, op1=0, CRn=0, CRm=4, op2=0
            else if (op0 == 3 && op1 == 0 && CRn == 0 && CRm == 4 && op2 == 0) {
                sysreg_id = SYSREG_ID_ID_AA64PFR0_EL1;
            }
            // ID_AA64PFR1_EL1: op0=3, op1=0, CRn=0, CRm=4, op2=1
            else if (op0 == 3 && op1 == 0 && CRn == 0 && CRm == 4 && op2 == 1) {
                sysreg_id = SYSREG_ID_ID_AA64PFR1_EL1;
            }
            // ID_AA64ZFR0_EL1: op0=3, op1=0, CRn=0, CRm=4, op2=4
            else if (op0 == 3 && op1 == 0 && CRn == 0 && CRm == 4 && op2 == 4) {
                sysreg_id = SYSREG_ID_ID_AA64ZFR0_EL1;
            }
            // ID_AA64ISAR0_EL1: op0=3, op1=0, CRn=0, CRm=6, op2=0
            else if (op0 == 3 && op1 == 0 && CRn == 0 && CRm == 6 && op2 == 0) {
                sysreg_id = SYSREG_ID_ID_AA64ISAR0_EL1;
            }
            // ID_AA64ISAR1_EL1: op0=3, op1=0, CRn=0, CRm=6, op2=1
            else if (op0 == 3 && op1 == 0 && CRn == 0 && CRm == 6 && op2 == 1) {
                sysreg_id = SYSREG_ID_ID_AA64ISAR1_EL1;
            }

            if (sysreg_id >= 0) {
                gen(state, (unsigned long) gadget_mrs_sysreg);
                gen(state, rt);
                gen(state, sysreg_id);
                return 1;
            }

        }

        gen_interrupt(state, INT_UNDEFINED);
        return 0;
    }

    gen_interrupt(state, INT_UNDEFINED);
    return 0;
}

/*
 * Loads and Stores
 */
static int gen_ldst(struct gen_state *state, uint32_t insn) {
    uint32_t op0 = (insn >> 28) & 0xf;

    // Atomic memory operations (LSE): LDADD/LDCLR/LDEOR/LDSET/LDUMAX/LDUMIN/LDSMAX/LDSMIN/SWP
    // Encoding: size:111000:A:R:1:Rs:op:Rn:Rt (bits29-24=111000, bit21=1, bits11-10=00)
    if ((insn & 0x3f200c00) == 0x38200000) {
        uint32_t size = (insn >> 30) & 0x3;
        uint32_t rs = (insn >> 16) & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rt = insn & 0x1f;
        uint32_t op = (insn >> 12) & 0xf;

        // Supported ops: 0-8 (LDADD, LDCLR, LDEOR, LDSET, LDSMAX, LDSMIN, LDUMAX, LDUMIN, SWP)
        if (op > 0x8) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        // Generate address from Rn
        gen(state, (unsigned long) gadget_calc_addr_imm);
        gen(state, rn | (0ULL << 8));  // offset = 0

        // Perform atomic RMW (returns old value in _tmp)
        gen(state, (unsigned long) gadget_atomic_rmw);
        gen(state, rs | ((uint64_t)size << 8) | ((uint64_t)op << 16));

        // Store old value to Rt
        gen(state, (unsigned long) gadget_store_reg);
        gen(state, rt);
        return 1;
    }

    // Atomic compare-and-swap (CAS/CASA/CASL/CASAL)
    // Encoding: size:001000:1:A:1:Rs:1:op(111):Rn:Rt (bits29-24=001000, bit21=1, bits11-10=11)
    if ((insn & 0x3f200c00) == 0x08200c00) {
        uint32_t size = (insn >> 30) & 0x3;
        uint32_t rs = (insn >> 16) & 0x1f;  // expected value (and result)
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rt = insn & 0x1f;          // new value

        // Generate address from Rn
        gen(state, (unsigned long) gadget_calc_addr_imm);
        gen(state, rn | (0ULL << 8));  // offset = 0

        // Perform CAS (returns old value in _tmp)
        gen(state, (unsigned long) gadget_atomic_cas);
        gen(state, rs | ((uint64_t)rt << 8) | ((uint64_t)size << 16));

        // Store old value back to Rs (CAS writes old value to expected register)
        gen(state, (unsigned long) gadget_store_reg);
        gen(state, rs);
        return 1;
    }

    // LDR (literal) - PC-relative load
    // Encoding: opc 011 V 00 imm19 Rt
    // opc=00: LDR Wt (32-bit) - mask 0xff000000, value 0x18000000
    // opc=01: LDR Xt (64-bit) - mask 0xff000000, value 0x58000000
    // opc=10: LDRSW Xt (signed word) - mask 0xff000000, value 0x98000000
    // V=1 means SIMD/FP register
    if ((insn & 0x3f000000) == 0x18000000) {
        uint32_t opc = (insn >> 30) & 0x3;
        uint32_t V = (insn >> 26) & 1;
        uint32_t rt = insn & 0x1f;
        int32_t imm19 = (insn >> 5) & 0x7ffff;
        // Sign-extend imm19 and multiply by 4
        if (imm19 & 0x40000) imm19 |= (int32_t)~0x7ffff;
        int32_t offset = imm19 << 2;
        // Keep target as 32-bit address (guest runs in 32-bit address space)
        uint32_t target = (uint32_t)state->orig_ip + offset;


        if (V) {
            // SIMD/FP literal load
            // opc=00: LDR St (32-bit float)
            // opc=01: LDR Dt (64-bit float)
            // opc=10: LDR Qt (128-bit)
            gen(state, (unsigned long) gadget_calc_addr_pc_rel);
            gen(state, (unsigned long) target);  // 32-bit guest address

            void *gadget;
            switch (opc) {
                case 0: gadget = gadget_ldr_simd_s; break;
                case 1: gadget = gadget_ldr_simd_d; break;
                case 2: gadget = gadget_ldr_simd_q; break;
                default:
                    gen_interrupt(state, INT_UNDEFINED);
                    return 0;
            }
            gen(state, (unsigned long) gadget);
            gen(state, rt);
            return 1;
        } else {
            // GPR literal load
            gen(state, (unsigned long) gadget_calc_addr_pc_rel);
            gen(state, (unsigned long) target);  // 32-bit guest address

            void *gadget;
            switch (opc) {
                case 0: gadget = gadget_load32; break;      // LDR Wt
                case 1: gadget = gadget_load64; break;      // LDR Xt
                case 2: gadget = gadget_load32_sx; break;   // LDRSW Xt
                default:
                    gen_interrupt(state, INT_UNDEFINED);
                    return 0;
            }
            gen(state, (unsigned long) gadget);
            gen(state, (unsigned long) gadget_store_reg);
            gen(state, rt);
            return 1;
        }
    }

    // Load/store register (unsigned immediate)
    if ((insn & 0x3b000000) == 0x39000000) {
        uint32_t size = (insn >> 30) & 0x3;
        uint32_t V = (insn >> 26) & 1;
        uint32_t opc = (insn >> 22) & 0x3;
        uint32_t imm12 = (insn >> 10) & 0xfff;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rt = insn & 0x1f;

        if (V) {
            // SIMD/FP load/store unsigned immediate
            // For SIMD, size encodes: 00=B, 01=H, 10=S, 11=D
            // But for Q (128-bit), size=00 and opc[1]=1
            uint32_t scale;
            if (size == 0 && (opc & 2)) {
                // 128-bit (Q register)
                scale = 4;  // 16 bytes = 2^4
            } else {
                scale = size;
            }
            uint64_t offset = imm12 << scale;

            // Generate address calculation
            gen(state, (unsigned long) gadget_calc_addr_imm);
            gen(state, rn | (offset << 8));

            bool is_load = (opc & 1) == 1;

            if (is_load) {
                // LDR Bt/Ht/St/Dt/Qt
                void *gadget;
                if (size == 0 && (opc & 2)) {
                    gadget = gadget_ldr_simd_q;
                } else {
                    switch (size) {
                        case 0: gadget = gadget_ldr_simd_b; break;
                        case 1: gadget = gadget_ldr_simd_h; break;
                        case 2: gadget = gadget_ldr_simd_s; break;
                        case 3: gadget = gadget_ldr_simd_d; break;
                        default: gen_interrupt(state, INT_UNDEFINED); return 0;
                    }
                }
                gen(state, (unsigned long) gadget);
                gen(state, rt);
            } else {
                // STR Bt/Ht/St/Dt/Qt
                void *gadget;
                if (size == 0 && (opc & 2)) {
                    gadget = gadget_str_simd_q;
                } else {
                    switch (size) {
                        case 0: gadget = gadget_str_simd_b; break;
                        case 1: gadget = gadget_str_simd_h; break;
                        case 2: gadget = gadget_str_simd_s; break;
                        case 3: gadget = gadget_str_simd_d; break;
                        default: gen_interrupt(state, INT_UNDEFINED); return 0;
                    }
                }
                gen(state, (unsigned long) gadget);
                gen(state, rt);
            }
            return 1;
        }

        // PRFM (prefetch memory) - treat as NOP
        if (size == 3 && opc == 2 && V == 0)
            return 1;

        // Calculate scaled offset
        uint64_t offset = imm12 << size;

        bool is_load = (opc & 1) == 1 || (opc & 2) == 2;
        bool sign_extend = (opc & 2) != 0;

        // Use fused gadgets for non-sign-extending loads and all stores
        // Sign-extending 8/16-bit loads are less common, keep as 3-gadget
        bool use_fused = true;
        if (is_load && sign_extend && size < 2)
            use_fused = false;

        if (use_fused) {
            // Fused gadget: [gadget addr][rd_or_rt | rn<<8 | offset<<16]
            uint64_t fused_param = (is_load ? rt : rt) | ((uint64_t)rn << 8) | ((uint64_t)offset << 16);

            if (is_load) {
                void *gadget;
                switch (size) {
                    case 0: gadget = gadget_load8_imm; break;
                    case 1: gadget = gadget_load16_imm; break;
                    case 2: gadget = sign_extend ? gadget_load32_sx_imm : gadget_load32_imm; break;
                    case 3: gadget = gadget_load64_imm; break;
                    default: gen_interrupt(state, INT_UNDEFINED); return 0;
                }
                gen(state, (unsigned long) gadget);
                gen(state, fused_param);
            } else {
                void *gadget;
                switch (size) {
                    case 0: gadget = gadget_store8_imm; break;
                    case 1: gadget = gadget_store16_imm; break;
                    case 2: gadget = gadget_store32_imm; break;
                    case 3: gadget = gadget_store64_imm; break;
                    default: gen_interrupt(state, INT_UNDEFINED); return 0;
                }
                gen(state, (unsigned long) gadget);
                gen(state, fused_param);
            }
        } else {
            // Fallback 3-gadget path for sign-extending 8/16-bit loads
            gen(state, (unsigned long) gadget_calc_addr_imm);
            uint64_t param = rn | ((uint64_t)offset << 8);
            gen(state, param);

            bool extend_to_64 = (opc == 2);
            void *gadget;
            switch (size) {
                case 0:
                    gadget = extend_to_64 ? gadget_load8_sx64 : gadget_load8_sx32;
                    break;
                case 1:
                    gadget = extend_to_64 ? gadget_load16_sx64 : gadget_load16_sx32;
                    break;
                default:
                    gen_interrupt(state, INT_UNDEFINED);
                    return 0;
            }
            gen(state, (unsigned long) gadget);
            gen(state, (unsigned long) gadget_store_reg);
            gen(state, rt);
        }
        return 1;
    }

    // Load/store register (register offset)
    // Pattern: xx111000xx1xxxxx1xx10xxxxxxxxxxx
    if ((insn & 0x3b200c00) == 0x38200800) {
        uint32_t size = (insn >> 30) & 0x3;
        uint32_t V = (insn >> 26) & 1;
        uint32_t opc = (insn >> 22) & 0x3;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t option = (insn >> 13) & 0x7;
        uint32_t S = (insn >> 12) & 1;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rt = insn & 0x1f;

        if (V) {
            // SIMD/FP load/store (register offset)
            bool is_load = (opc & 1);
            bool is_128bit = (size == 0 && (opc & 2));  // Q register
            uint32_t size_bytes = is_128bit ? 16 : (1u << size);
            uint32_t shift = S ? (is_128bit ? 4 : size) : 0;

            // Generate address calculation with register offset
            gen(state, (unsigned long) gadget_calc_addr_reg);
            gen(state, rn | (rm << 8) | (option << 16) | (shift << 24));

            void *gadget;
            if (is_load) {
                switch (size_bytes) {
                    case 1: gadget = gadget_ldr_simd_b; break;
                    case 2: gadget = gadget_ldr_simd_h; break;
                    case 4: gadget = gadget_ldr_simd_s; break;
                    case 8: gadget = gadget_ldr_simd_d; break;
                    case 16: gadget = gadget_ldr_simd_q; break;
                    default:
                        gen_interrupt(state, INT_UNDEFINED);
                        return 0;
                }
            } else {
                switch (size_bytes) {
                    case 1: gadget = gadget_str_simd_b; break;
                    case 2: gadget = gadget_str_simd_h; break;
                    case 4: gadget = gadget_str_simd_s; break;
                    case 8: gadget = gadget_str_simd_d; break;
                    case 16: gadget = gadget_str_simd_q; break;
                    default:
                        gen_interrupt(state, INT_UNDEFINED);
                        return 0;
                }
            }

            gen(state, (unsigned long) gadget);
            gen(state, rt);  // SIMD register number
            return 1;
        }

        // PRFM (prefetch memory, register offset) - treat as NOP
        if (size == 3 && opc == 2 && V == 0)
            return 1;

        // Calculate shift amount based on size and S bit
        uint32_t shift = S ? size : 0;

        bool is_load = (opc == 1) || (opc == 2) || (opc == 3);
        bool sign_extend = (opc >= 2);
        bool extend_to_64 = (opc == 2);

        // Use fused reg-offset gadgets for option==3 (UXTX/LSL, no extend)
        // Sign-extending 8/16-bit loads are rare with register offset, keep as 3-gadget
        bool use_fused_reg = (option == 3);
        if (is_load && sign_extend && size < 2)
            use_fused_reg = false;

        if (use_fused_reg) {
            uint64_t fused_param = rt | ((uint64_t)rn << 8) | ((uint64_t)rm << 16) | ((uint64_t)shift << 24);

            if (is_load) {
                void *gadget;
                switch (size) {
                    case 0: gadget = gadget_load8_reg; break;
                    case 1: gadget = gadget_load16_reg; break;
                    case 2: gadget = sign_extend ? gadget_load32_sx_reg : gadget_load32_reg; break;
                    case 3: gadget = gadget_load64_reg; break;
                    default: gen_interrupt(state, INT_UNDEFINED); return 0;
                }
                gen(state, (unsigned long) gadget);
                gen(state, fused_param);
            } else {
                void *gadget;
                switch (size) {
                    case 0: gadget = gadget_store8_reg; break;
                    case 1: gadget = gadget_store16_reg; break;
                    case 2: gadget = gadget_store32_reg; break;
                    case 3: gadget = gadget_store64_reg; break;
                    default: gen_interrupt(state, INT_UNDEFINED); return 0;
                }
                gen(state, (unsigned long) gadget);
                gen(state, fused_param);
            }
        } else {
            // Fallback 3-gadget path for extend types other than UXTX,
            // and for sign-extending 8/16-bit loads
            gen(state, (unsigned long) gadget_calc_addr_reg);
            gen(state, rn | (rm << 8) | (option << 16) | (shift << 24));

            if (is_load) {
                void *gadget;
                switch (size) {
                    case 0:
                        gadget = sign_extend ? (extend_to_64 ? gadget_load8_sx64 : gadget_load8_sx32) : gadget_load8;
                        break;
                    case 1:
                        gadget = sign_extend ? (extend_to_64 ? gadget_load16_sx64 : gadget_load16_sx32) : gadget_load16;
                        break;
                    case 2:
                        gadget = sign_extend ? gadget_load32_sx : gadget_load32;
                        break;
                    case 3:
                        gadget = gadget_load64;
                        break;
                    default:
                        gen_interrupt(state, INT_UNDEFINED);
                        return 0;
                }
                gen(state, (unsigned long) gadget);
                gen(state, (unsigned long) gadget_store_reg);
                gen(state, rt);
            } else {
                gen(state, (unsigned long) gadget_load_reg);
                gen(state, rt);

                void *gadget;
                switch (size) {
                    case 0: gadget = gadget_store8; break;
                    case 1: gadget = gadget_store16; break;
                    case 2: gadget = gadget_store32; break;
                    case 3: gadget = gadget_store64; break;
                    default:
                        gen_interrupt(state, INT_UNDEFINED);
                        return 0;
                }
                gen(state, (unsigned long) gadget);
            }
        }
        return 1;
    }

    // Load/store pair (LDP/STP)
    // Encoding: xx101xxx_xxxxxxxx_xxxxxxxx_xxxxxxxx
    if ((insn & 0x3a000000) == 0x28000000) {
        uint32_t opc = (insn >> 30) & 0x3;  // size: 00=32-bit, 10=64-bit
        uint32_t V = (insn >> 26) & 1;
        uint32_t mode = (insn >> 23) & 0x7;  // 001=post, 010=signed offset, 011=pre
        uint32_t L = (insn >> 22) & 1;       // 0=store, 1=load
        int32_t imm7 = (int32_t)((insn >> 15) & 0x7f);
        if (imm7 & 0x40) imm7 |= ~0x7f;  // sign-extend
        uint32_t rt2 = (insn >> 10) & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rt = insn & 0x1f;

        // Compute actual offset (scaled by 4 or 8 based on size)
        int64_t offset;
        bool is64 = (opc == 2 || (V && opc == 1));  // 64-bit for opc=10, or SIMD Q
        offset = imm7 * (is64 ? 8 : 4);


        if (V) {
            // SIMD/FP load/store pair
            // opc=00 -> 32-bit (S), opc=01 -> 64-bit (D), opc=10 -> 128-bit (Q)
            uint32_t size_bytes = (opc == 0) ? 4 : (opc == 1) ? 8 : 16;
            int64_t simd_offset = imm7 * size_bytes;

            bool is_pre = (mode == 3);
            bool is_post = (mode == 1);
            bool is_offset = (mode == 2);

            if (!is_pre && !is_post && !is_offset) {
                gen_interrupt(state, INT_UNDEFINED);
                return 0;
            }

            // Calculate address
            if (is_post) {
                gen(state, (unsigned long) gadget_calc_addr_base);
                gen(state, rn);
            } else {
                gen(state, (unsigned long) gadget_calc_addr_imm);
                gen(state, rn | ((uint64_t)simd_offset << 8));
            }

            // Perform load/store
            void *gadget;
            if (L) {
                switch (opc) {
                    case 0: gadget = gadget_ldp_simd_s; break;
                    case 1: gadget = gadget_ldp_simd_d; break;
                    case 2: gadget = gadget_ldp_simd_q; break;
                    default: gen_interrupt(state, INT_UNDEFINED); return 0;
                }
            } else {
                switch (opc) {
                    case 0: gadget = gadget_stp_simd_s; break;
                    case 1: gadget = gadget_stp_simd_d; break;
                    case 2: gadget = gadget_stp_simd_q; break;
                    default: gen_interrupt(state, INT_UNDEFINED); return 0;
                }
            }
            gen(state, (unsigned long) gadget);
            gen(state, rt | (rt2 << 8));

            // Writeback for pre/post-indexed
            if (is_pre || is_post) {
                if (is_post) {
                    gen(state, (unsigned long) gadget_update_base);
                    gen(state, rn | ((uint64_t)simd_offset << 8));
                } else {
                    gen(state, (unsigned long) gadget_writeback_addr);
                    gen(state, rn);
                }
            }

            return 1;
        }

        // For signed offset mode (010), just calculate address
        // For post-indexed (001), use base first, then update
        // For pre-indexed (011), calculate address first, then use and update

        bool is_pre = (mode == 3);
        bool is_post = (mode == 1);
        bool is_offset = (mode == 2);

        if (!is_pre && !is_post && !is_offset) {
            // Unsupported mode
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        // Step 1: Calculate address
        if (is_post) {
            // Post-indexed: use base register directly
            gen(state, (unsigned long) gadget_calc_addr_base);
            gen(state, rn);
        } else {
            // Pre-indexed or signed offset: add offset to base
            gen(state, (unsigned long) gadget_calc_addr_imm);
            gen(state, rn | ((uint64_t)offset << 8));
        }

        // Step 2: Perform the load/store pair
        if (L) {
            // LDP: load pair
            gen(state, (unsigned long) (is64 ? gadget_ldp64 : gadget_ldp32));
        } else {
            // STP: store pair
            gen(state, (unsigned long) (is64 ? gadget_stp64 : gadget_stp32));
        }
        gen(state, rt | (rt2 << 8));

        // Step 3: Writeback for pre/post-indexed
        if (is_pre || is_post) {
            if (is_post) {
                // Post-indexed: update base with offset
                gen(state, (unsigned long) gadget_update_base);
                gen(state, rn | ((uint64_t)offset << 8));
            } else {
                // Pre-indexed: writeback calculated address
                gen(state, (unsigned long) gadget_writeback_addr);
                gen(state, rn);
            }
        }

        return 1;
    }

    // Load/store register (immediate pre/post-indexed)
    // Pattern: xx111000xx0xxxxxxxxx[01|11]xxxxxxxxxx
    if ((insn & 0x3b200000) == 0x38000000) {
        uint32_t size = (insn >> 30) & 0x3;
        uint32_t V = (insn >> 26) & 1;
        uint32_t opc = (insn >> 22) & 0x3;
        int32_t imm9 = (int32_t)((insn >> 12) & 0x1ff);
        // Sign-extend imm9 from 9 bits
        if (imm9 & 0x100) imm9 |= ~0x1ff;
        uint32_t mode = (insn >> 10) & 0x3;  // 01=post-indexed, 11=pre-indexed
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rt = insn & 0x1f;


        if (V) {
            // SIMD/FP load/store with unscaled immediate or pre/post-indexed
            // size: 00=B, 01=H, 10=S, 11=D
            // opc: 00=store, 01=load, 10=store (128-bit if size=00), 11=load (128-bit if size=00)
            bool is_load = (opc & 1);
            bool is_128bit = (size == 0 && (opc & 2));  // Q register

            uint32_t size_bytes;
            if (is_128bit) {
                size_bytes = 16;
            } else {
                size_bytes = (1 << size);  // 1, 2, 4, or 8 bytes
            }

            // Calculate address (same as GPR case)
            bool is_unscaled = (mode == 0);
            bool is_pre = (mode == 3);

            if (is_pre || is_unscaled) {
                gen(state, (unsigned long) gadget_calc_addr_imm);
                gen(state, rn | ((uint64_t)(uint32_t)imm9 << 8));
            } else if (mode == 1) {
                // Post-indexed
                gen(state, (unsigned long) gadget_calc_addr_base);
                gen(state, rn);
            } else {
                gen_interrupt(state, INT_UNDEFINED);
                return 0;
            }

            void *gadget;
            if (is_load) {
                switch (size_bytes) {
                    case 1: gadget = gadget_ldr_simd_b; break;
                    case 2: gadget = gadget_ldr_simd_h; break;
                    case 4: gadget = gadget_ldr_simd_s; break;
                    case 8: gadget = gadget_ldr_simd_d; break;
                    case 16: gadget = gadget_ldr_simd_q; break;
                    default:
                        gen_interrupt(state, INT_UNDEFINED);
                        return 0;
                }
            } else {
                switch (size_bytes) {
                    case 1: gadget = gadget_str_simd_b; break;
                    case 2: gadget = gadget_str_simd_h; break;
                    case 4: gadget = gadget_str_simd_s; break;
                    case 8: gadget = gadget_str_simd_d; break;
                    case 16: gadget = gadget_str_simd_q; break;
                    default:
                        gen_interrupt(state, INT_UNDEFINED);
                        return 0;
                }
            }

            gen(state, (unsigned long) gadget);
            gen(state, rt);  // SIMD register number

            // Handle writeback for pre/post-indexed modes
            if (mode == 1 || mode == 3) {
                // Writeback base register: store computed address to base register
                // For pre-indexed: address = base + offset, already computed
                // For post-indexed: address = base, need to add offset
                if (mode == 1) {
                    // Post-indexed: need to compute base + offset
                    gen(state, (unsigned long) gadget_calc_addr_imm);
                    gen(state, rn | ((uint64_t)(uint32_t)imm9 << 8));
                }
                // Store _addr to rn
                gen(state, (unsigned long) gadget_store_addr_to_reg);
                gen(state, rn);
            }

            return 1;
        }

        // mode: 0=unscaled(STUR/LDUR), 1=post-indexed, 2=unprivileged, 3=pre-indexed

        // PRFM (prefetch memory, unscaled/pre/post) - treat as NOP
        if (size == 3 && opc == 2 && V == 0)
            return 1;

        if (mode == 2) {
            // Unprivileged access - not implemented
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        bool is_pre_indexed = (mode == 3);
        bool is_unscaled = (mode == 0);  // STUR/LDUR - offset applied, no writeback
        bool is_load = (opc == 1) || (opc == 2) || (opc == 3);

        // Calculate address:
        // - mode=0 (unscaled): address = base + offset (no writeback)
        // - mode=1 (post-indexed): address = base (base+offset for writeback)
        // - mode=3 (pre-indexed): address = base + offset (same for writeback)
        if (is_pre_indexed || is_unscaled) {
            // Pre-indexed or unscaled: address = base + offset
            gen(state, (unsigned long) gadget_calc_addr_imm);
            gen(state, rn | ((uint64_t)(uint32_t)imm9 << 8));
        } else {
            // Post-indexed: address = base only
            gen(state, (unsigned long) gadget_calc_addr_base);
            gen(state, rn);
        }

        if (is_load) {
            void *gadget;
            bool sign_extend = (opc >= 2);
            bool extend_to_64 = (opc == 2);

            switch (size) {
                case 0:  // Byte
                    gadget = sign_extend ? (extend_to_64 ? gadget_load8_sx64 : gadget_load8_sx32) : gadget_load8;
                    break;
                case 1:  // Halfword
                    gadget = sign_extend ? (extend_to_64 ? gadget_load16_sx64 : gadget_load16_sx32) : gadget_load16;
                    break;
                case 2:  // Word
                    gadget = sign_extend ? gadget_load32_sx : gadget_load32;
                    break;
                case 3:  // Doubleword
                    gadget = gadget_load64;
                    break;
                default:
                    gen_interrupt(state, INT_UNDEFINED);
                    return 0;
            }
            gen(state, (unsigned long) gadget);
            gen(state, (unsigned long) gadget_store_reg);
            gen(state, rt);
        } else {
            // Store
            gen(state, (unsigned long) gadget_load_reg);
            gen(state, rt);

            void *gadget;
            switch (size) {
                case 0: gadget = gadget_store8; break;
                case 1: gadget = gadget_store16; break;
                case 2: gadget = gadget_store32; break;
                case 3: gadget = gadget_store64; break;
                default:
                    gen_interrupt(state, INT_UNDEFINED);
                    return 0;
            }
            gen(state, (unsigned long) gadget);
        }

        // Writeback to base register (only for pre/post-indexed, not unscaled)
        if (!is_unscaled) {
            if (is_pre_indexed) {
                // Pre-indexed: base = address (which is base + offset)
                // The address is still in _addr, so just write it back
                gen(state, (unsigned long) gadget_writeback_addr);
                gen(state, rn);
            } else {
                // Post-indexed: base = base + offset
                gen(state, (unsigned long) gadget_update_base);
                gen(state, rn | ((uint64_t)(uint32_t)imm9 << 8));
            }
        }

        return 1;
    }

    // Load/store exclusive (LDXR, STXR, LDAXR, STLXR, etc.)
    // Encoding: size:001000:o2:L:o1:Rs:o0:Rt2:Rn:Rt
    // For single-threaded emulation, we can treat these as simple loads/stores
    if ((insn & 0x3f000000) == 0x08000000) {
        uint32_t size = (insn >> 30) & 0x3;
        uint32_t o2 = (insn >> 23) & 1;
        uint32_t L = (insn >> 22) & 1;
        uint32_t o1 = (insn >> 21) & 1;
        uint32_t rs = (insn >> 16) & 0x1f;
        uint32_t o0 = (insn >> 15) & 1;
        uint32_t rt2 = (insn >> 10) & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rt = insn & 0x1f;

        (void)o1; (void)o0;  // Acquire/release semantics ignored for single-threaded

        // Handle pair exclusives (LDXP/STXP/LDAXP/STLXP)
        if (o2 == 1) {
            // Generate address from Rn
            gen(state, (unsigned long) gadget_calc_addr_imm);
            gen(state, rn | (0ULL << 8));  // offset = 0

            if (L) {
                // LDXP/LDAXP - Load pair
                void (*ldp_gadget)(void) = NULL;
                switch (size) {
                case 2: ldp_gadget = gadget_ldp32; break;
                case 3: ldp_gadget = gadget_ldp64; break;
                default:
                    gen_interrupt(state, INT_UNDEFINED);
                    return 0;
                }
                gen(state, (unsigned long) ldp_gadget);
                gen(state, rt | ((uint64_t)rt2 << 8));
            } else {
                // STXP/STLXP - Store pair
                void (*stp_gadget)(void) = NULL;
                switch (size) {
                case 2: stp_gadget = gadget_stp32; break;
                case 3: stp_gadget = gadget_stp64; break;
                default:
                    gen_interrupt(state, INT_UNDEFINED);
                    return 0;
                }
                gen(state, (unsigned long) stp_gadget);
                gen(state, rt | ((uint64_t)rt2 << 8));

                // Set Rs = 0 to indicate success
                if (rs != 31) {
                    gen(state, (unsigned long) gadget_movz);
                    gen(state, rs | (0 << 8) | (0ULL << 16) | (0ULL << 32));
                }
            }
            return 1;
        }

        // For now, only handle non-pair operations (o2=0, rt2=11111)
        if (rt2 != 31) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        if (L) {
            // LDXR, LDAXR, LDLAR - Load exclusive/acquire
            // Generate address from Rn
            gen(state, (unsigned long) gadget_calc_addr_imm);
            gen(state, rn | (0ULL << 8));  // offset = 0

            // Generate load
            void (*load_gadget)(void) = NULL;
            switch (size) {
            case 0: load_gadget = gadget_load8; break;
            case 1: load_gadget = gadget_load16; break;
            case 2: load_gadget = gadget_load32; break;
            case 3: load_gadget = gadget_load64; break;
            }
            gen(state, (unsigned long) load_gadget);

            // Store result to Rt
            gen(state, (unsigned long) gadget_store_reg);
            gen(state, rt);
        } else {
            // STXR, STLXR, STLLR - Store exclusive/release
            // Note: For single-threaded emulation, store always succeeds (Rs = 0)

            // Load value from Rt
            gen(state, (unsigned long) gadget_load_reg);
            gen(state, rt);

            // Generate address from Rn
            gen(state, (unsigned long) gadget_calc_addr_imm);
            gen(state, rn | (0ULL << 8));  // offset = 0

            // Generate store
            void (*store_gadget)(void) = NULL;
            switch (size) {
            case 0: store_gadget = gadget_store8; break;
            case 1: store_gadget = gadget_store16; break;
            case 2: store_gadget = gadget_store32; break;
            case 3: store_gadget = gadget_store64; break;
            }
            gen(state, (unsigned long) store_gadget);

            // Set Rs = 0 to indicate success
            if (rs != 31) {
                gen(state, (unsigned long) gadget_movz);
                gen(state, rs | (0 << 8) | (0ULL << 16) | (0ULL << 32));  // movz rs, #0
            }
        }
        return 1;
    }

    // LD1/ST1 (SIMD multiple structures) - Advanced SIMD load/store
    // Pattern: 0 Q 00 1100 0 L 0 00000 opcode size Rn Rt (no post-index)
    // Pattern: 0 Q 00 1100 1 L 0 Rm opcode size Rn Rt (post-indexed)
    // op0 bits 28:25 = 0100 or 0110 for these
    if ((insn & 0xbfbf0000) == 0x0c000000) {
        // No post-index variant
        uint32_t Q = (insn >> 30) & 1;
        uint32_t L = (insn >> 22) & 1;
        uint32_t opcode = (insn >> 12) & 0xf;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rt = insn & 0x1f;

        int num_regs = 0;
        if (opcode == 0x7) num_regs = 1;
        else if (opcode == 0xa) num_regs = 2;
        else if (opcode == 0x6) num_regs = 3;
        else if (opcode == 0x2) num_regs = 4;

        if (num_regs == 0) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        int bytes_per_reg = Q ? 16 : 8;

        gen(state, (unsigned long) gadget_calc_addr_imm);
        gen(state, rn | (0ULL << 8));

        for (int i = 0; i < num_regs; i++) {
            uint32_t vt = (rt + i) & 0x1f;
            if (L) {
                gen(state, (unsigned long) (Q ? gadget_ldr_simd_q : gadget_ldr_simd_d));
                gen(state, vt);
            } else {
                gen(state, (unsigned long) (Q ? gadget_str_simd_q : gadget_str_simd_d));
                gen(state, vt);
            }
            if (i < num_regs - 1) {
                gen(state, (unsigned long) gadget_advance_addr);
                gen(state, bytes_per_reg);
            }
        }
        return 1;
    }

    // LD1/ST1 post-indexed variant
    if ((insn & 0xbfa00000) == 0x0c800000) {
        uint32_t Q = (insn >> 30) & 1;
        uint32_t L = (insn >> 22) & 1;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t opcode = (insn >> 12) & 0xf;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rt = insn & 0x1f;

        int num_regs = 0;
        if (opcode == 0x7) num_regs = 1;
        else if (opcode == 0xa) num_regs = 2;
        else if (opcode == 0x6) num_regs = 3;
        else if (opcode == 0x2) num_regs = 4;

        if (num_regs == 0) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        int bytes_per_reg = Q ? 16 : 8;
        int total_bytes = bytes_per_reg * num_regs;

        gen(state, (unsigned long) gadget_calc_addr_imm);
        gen(state, rn | (0ULL << 8));

        for (int i = 0; i < num_regs; i++) {
            uint32_t vt = (rt + i) & 0x1f;
            if (L) {
                gen(state, (unsigned long) (Q ? gadget_ldr_simd_q : gadget_ldr_simd_d));
                gen(state, vt);
            } else {
                gen(state, (unsigned long) (Q ? gadget_str_simd_q : gadget_str_simd_d));
                gen(state, vt);
            }
            if (i < num_regs - 1) {
                gen(state, (unsigned long) gadget_advance_addr);
                gen(state, bytes_per_reg);
            }
        }

        // Post-index writeback
        if (rm == 31) {
            gen(state, (unsigned long) gadget_update_base);
            gen(state, rn | ((uint64_t)total_bytes << 8));
        } else {
            gen(state, (unsigned long) gadget_update_base_reg);
            gen(state, rn | (rm << 8));
        }
        return 1;
    }

    // LD1/ST1 (single structure) - Advanced SIMD load/store single element
    // Pattern: 0 Q 001101 0 L R 0 size2 opcode S size Rn Rt
    // Encoding: 0x0d000000 to 0x0dffffff (and 0x4d000000 for Q=1)
    // Fixed bits: bit[31]=0, bits[29:24]=001101, bit[21]=0
    // Mask: 0xbf9f0000, expected: 0x0d000000
    if ((insn & 0xbf9f0000) == 0x0d000000) {
        uint32_t Q = (insn >> 30) & 1;
        uint32_t L = (insn >> 22) & 1;
        uint32_t R = (insn >> 21) & 1;  // should be 0 for no post-index
        uint32_t opcode = (insn >> 13) & 0x7;
        uint32_t S = (insn >> 12) & 1;
        uint32_t size = (insn >> 10) & 0x3;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rt = insn & 0x1f;

        // Determine element size and lane index
        // opcode determines element size:
        // 0xx: byte (B) - index in Q:S:size
        // 10x: halfword (H) - index in Q:S:size[0]
        // 100: word (S) - index in Q:S
        // 100, size=01: doubleword (D) - index in Q
        int elem_size = 0; // bytes
        int lane = 0;

        if ((opcode & 0x4) == 0) {
            // Byte (opcode = 0xx)
            elem_size = 1;
            lane = (Q << 3) | (S << 2) | size;
        } else if ((opcode & 0x6) == 0x4) {
            // Halfword (opcode = 10x)
            elem_size = 2;
            lane = (Q << 2) | (S << 1) | (size & 1);
        } else if (opcode == 0x4 && size == 0) {
            // Word (opcode = 100, size = 00)
            elem_size = 4;
            lane = (Q << 1) | S;
        } else if (opcode == 0x4 && size == 1) {
            // Doubleword (opcode = 100, size = 01)
            elem_size = 8;
            lane = Q;
        } else {
            // Unsupported encoding
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        // Calculate offset within vector register
        int lane_offset = lane * elem_size;

        // Generate address calculation
        gen(state, (unsigned long) gadget_calc_addr_imm);
        gen(state, rn | (0ULL << 8));

        // Generate load/store of single element
        if (L) {
            // Load: read from memory, write to vector lane
            // Use appropriate size gadget
            if (elem_size == 1) {
                gen(state, (unsigned long) gadget_ld1_single_b);
            } else if (elem_size == 2) {
                gen(state, (unsigned long) gadget_ld1_single_h);
            } else if (elem_size == 4) {
                gen(state, (unsigned long) gadget_ld1_single_s);
            } else {
                gen(state, (unsigned long) gadget_ld1_single_d);
            }
        } else {
            // Store: read from vector lane, write to memory
            if (elem_size == 1) {
                gen(state, (unsigned long) gadget_st1_single_b);
            } else if (elem_size == 2) {
                gen(state, (unsigned long) gadget_st1_single_h);
            } else if (elem_size == 4) {
                gen(state, (unsigned long) gadget_st1_single_s);
            } else {
                gen(state, (unsigned long) gadget_st1_single_d);
            }
        }
        gen(state, rt | (lane_offset << 8));
        return 1;
    }

    (void)op0;
    gen_interrupt(state, INT_UNDEFINED);
    return 0;
}

/*
 * Data Processing (Register)
 */
static int gen_dp_reg(struct gen_state *state, uint32_t insn) {
    uint32_t op0 = (insn >> 30) & 1;
    uint32_t op1 = (insn >> 28) & 1;
    uint32_t op2 = (insn >> 21) & 0xf;

    // Logical (shifted register)
    if (op1 == 0 && (op2 & 0x8) == 0) {
        uint32_t sf = (insn >> 31) & 1;
        uint32_t opc = (insn >> 29) & 0x3;
        uint32_t shift = (insn >> 22) & 0x3;
        uint32_t N = (insn >> 21) & 1;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t imm6 = (insn >> 10) & 0x3f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        if (!sf && imm6 >= 32) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        // Handle shifted case for logical ops
        if (shift != 0 || imm6 != 0) {
            void *gadget = NULL;
            switch (opc) {
                case 0: gadget = gadget_and_reg_shifted; break; // AND/BIC
                case 1: gadget = gadget_orr_reg_shifted; break; // ORR/ORN
                case 2: gadget = gadget_eor_reg_shifted; break; // EOR/EON
                case 3: gadget = gadget_and_reg_shifted; break; // ANDS/BICS
                default:
                    gen_interrupt(state, INT_UNDEFINED);
                    return 0;
            }

            gen(state, (unsigned long) gadget);
            // Pack: rd(0-4), rn(8-12), rm(16-20), sf(24), S(25), N(26), shift_type(27-28)
            uint64_t param = rd | (rn << 8) | (rm << 16) | ((uint64_t)sf << 24)
                | ((opc == 3) ? (1UL << 25) : 0) | ((uint64_t)N << 26) | ((uint64_t)shift << 27);
            gen(state, param);
            gen(state, imm6);  // shift amount as second parameter
            return 1;
        }

        void *gadget;
        switch (opc) {
            case 0: gadget = N ? gadget_and_reg : gadget_and_reg; break;  // AND/BIC
            case 1: gadget = N ? gadget_orr_reg : gadget_orr_reg; break;  // ORR/ORN
            case 2: gadget = N ? gadget_eor_reg : gadget_eor_reg; break;  // EOR/EON
            case 3: gadget = N ? gadget_and_reg : gadget_and_reg; break;  // ANDS/BICS
            default:
                gen_interrupt(state, INT_UNDEFINED);
                return 0;
        }

        gen(state, (unsigned long) gadget);
        // Pack: rd(0-4), rn(8-12), rm(16-20), sf(24), S(25), N(26)
        uint64_t param = rd | (rn << 8) | (rm << 16) | ((uint64_t)sf << 24) | ((opc == 3) ? (1UL << 25) : 0) | ((uint64_t)N << 26);
        gen(state, param);
        return 1;
    }

    // Add/subtract (shifted register)
    if (op1 == 0 && (op2 & 0x9) == 0x8) {
        uint32_t sf = (insn >> 31) & 1;
        uint32_t op = (insn >> 30) & 1;
        uint32_t S = (insn >> 29) & 1;
        uint32_t shift = (insn >> 22) & 0x3;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t imm6 = (insn >> 10) & 0x3f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        if (shift == 3) {
            // shift == 3 is reserved for ADD/SUB shifted register
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        // imm6 validation: for 32-bit, imm6 must be < 32
        if (!sf && imm6 >= 32) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        // Try specialized 64-bit fast paths (no shift, no XZR operands)
        bool can_spec_reg = sf && imm6 == 0 && rn != 31 && rm != 31;
        if (can_spec_reg && S) {
            gen(state, (unsigned long)(op ? gadget_subs_reg_64_nshift : gadget_adds_reg_64_nshift));
            gen(state, rd | (rn << 8) | (rm << 16));
            return 1;
        }
        if (can_spec_reg && !S && rd != 31) {
            gen(state, (unsigned long)(op ? gadget_sub_reg_64_nshift : gadget_add_reg_64_nshift));
            gen(state, rd | (rn << 8) | (rm << 16));
            return 1;
        }

        // Generic path: handles 32-bit, shifted, XZR/SP cases
        void *gadget;
        if (S) {
            // Flag-setting versions (ADDS, SUBS, CMP, CMN)
            gadget = op ? gadget_subs_reg : gadget_adds_reg;
        } else {
            gadget = op ? gadget_sub_reg : gadget_add_reg;
        }
        gen(state, (unsigned long) gadget);
        // Pack: rd | rn<<8 | rm<<16 | sf<<24 | S<<25 | shift_type<<26 | imm6<<32
        gen(state, rd | (rn << 8) | (rm << 16) | ((uint64_t)sf << 24) | ((uint64_t)S << 25) | ((uint64_t)shift << 26) | ((uint64_t)imm6 << 32));
        return 1;
    }

    // Add/subtract (extended register)
    // Pattern: sf:op:S:01011:00:1:Rm:option:imm3:Rn:Rd
    if ((insn & 0x1f200000) == 0x0b200000) {
        uint32_t sf = (insn >> 31) & 1;
        uint32_t op = (insn >> 30) & 1;  // 0=ADD, 1=SUB
        uint32_t S = (insn >> 29) & 1;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t option = (insn >> 13) & 0x7;
        uint32_t imm3 = (insn >> 10) & 0x7;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        // Select gadget based on op and S bits
        void *gadget;
        if (S) {
            // Flag-setting versions (ADDS_ext, SUBS_ext, CMN_ext, CMP_ext)
            gadget = op ? gadget_subs_ext : gadget_adds_ext;
        } else {
            gadget = op ? gadget_sub_ext : gadget_add_ext;
        }
        gen(state, (unsigned long) gadget);
        // Pack: rd | rn<<8 | rm<<16 | option<<24 | imm3<<27 | sf<<30
        gen(state, rd | (rn << 8) | (rm << 16) | ((uint64_t)option << 24) | ((uint64_t)imm3 << 27) | ((uint64_t)sf << 30));
        return 1;
    }

    // Add/subtract with carry (ADC/ADCS/SBC/SBCS)
    // Pattern: sf:op:S:11010000:Rm:000000:Rn:Rd
    // Mask: bits[28:21]=0xd0 and bits[15:10]=0x00 -> (insn & 0x1fe0fc00) == 0x1a000000
    if ((insn & 0x1fe0fc00) == 0x1a000000) {
        uint32_t sf = (insn >> 31) & 1;
        uint32_t op = (insn >> 30) & 1;  // 0=ADC/ADCS, 1=SBC/SBCS
        uint32_t S = (insn >> 29) & 1;   // 1=update flags
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        void *gadget = op ? gadget_sbc_reg : gadget_adc_reg;
        gen(state, (unsigned long) gadget);
        // Pack: rd | rn<<8 | rm<<16 | sf<<24 | S<<25
        gen(state, rd | (rn << 8) | (rm << 16) | ((uint64_t)sf << 24) | ((uint64_t)S << 25));
        return 1;
    }

    // Conditional compare (CCMP, CCMN) register/immediate
    // Pattern: sf:op:S:11010010:Rm/imm5:cond:o2:0:Rn:0:nzcv
    // bits[28:21]=0xd2, bit[29]=1 (S), bit[10]=0, bit[4]=0
    // bit 11 distinguishes register (0) vs immediate (1) form
    if ((insn & 0x3fe00410) == 0x3a400000) {
        uint32_t sf = (insn >> 31) & 1;
        uint32_t op = (insn >> 30) & 1;  // 0=CCMN, 1=CCMP
        uint32_t is_imm = (insn >> 11) & 1;
        uint32_t rm_or_imm5 = (insn >> 16) & 0x1f;
        uint32_t cond = (insn >> 12) & 0xf;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t nzcv = insn & 0xf;

        void *gadget = NULL;
        if (is_imm) {
            gadget = op ? gadget_ccmp_imm : gadget_ccmn_imm;
        } else {
            gadget = op ? gadget_ccmp_reg : gadget_ccmn_reg;
        }
        gen(state, (unsigned long) gadget);
        // Pack: rn | (rm/imm5)<<8 | cond<<16 | nzcv<<20 | sf<<24
        gen(state, rn | (rm_or_imm5 << 8) | (cond << 16) | (nzcv << 20) | ((uint64_t)sf << 24));
        return 1;
    }

    // Conditional select (CSEL, CSINC, CSINV, CSNEG)
    // Pattern: sf:op:S:11010100:Rm:cond:op2:Rn:Rd
    // Mask out: sf, op, Rm, cond, op2, Rn, Rd - only check S=0 and fixed bits
    if ((insn & 0x1fe00000) == 0x1a800000) {
        uint32_t sf = (insn >> 31) & 1;
        uint32_t op = (insn >> 30) & 1;
        uint32_t S = (insn >> 29) & 1;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t cond = (insn >> 12) & 0xf;
        uint32_t op2_sel = (insn >> 10) & 0x3;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        if (S != 0) {
            // S must be 0 for conditional select
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        void *gadget = NULL;
        uint32_t variant = (op << 1) | op2_sel;
        switch (variant) {
            case 0: gadget = gadget_csel; break;   // op=0, op2=0: CSEL
            case 1: gadget = gadget_csinc; break;  // op=0, op2=1: CSINC
            case 2: gadget = gadget_csinv; break;  // op=1, op2=0: CSINV
            case 3: gadget = gadget_csneg; break;  // op=1, op2=1: CSNEG
        }

        gen(state, (unsigned long) gadget);
        gen(state, rd | (rn << 8) | (rm << 16) | (cond << 24) | ((uint64_t)sf << 28));
        return 1;
    }

    // Data-processing (2 source)
    // Pattern: sf:0:S:11010110:Rm:opcode[5:0]:Rn:Rd
    if ((insn & 0x5fe00000) == 0x1ac00000) {
        uint32_t sf = (insn >> 31) & 1;
        uint32_t S = (insn >> 29) & 1;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t opcode = (insn >> 10) & 0x3f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        if (S != 0) {
            // S must be 0 for these instructions
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        void *gadget = NULL;
        switch (opcode) {
            case 0x02: gadget = gadget_udiv; break;  // UDIV
            case 0x03: gadget = gadget_sdiv; break;  // SDIV
            case 0x08: gadget = gadget_lslv; break;  // LSLV (LSL register)
            case 0x09: gadget = gadget_lsrv; break;  // LSRV (LSR register)
            case 0x0a: gadget = gadget_asrv; break;  // ASRV (ASR register)
            case 0x0b: gadget = gadget_rorv; break;  // RORV (ROR register)
            default:
                gen_interrupt(state, INT_UNDEFINED);
                return 0;
        }

        gen(state, (unsigned long) gadget);
        // Pack: rd | rn<<8 | rm<<16 | sf<<24
        gen(state, rd | (rn << 8) | (rm << 16) | ((uint64_t)sf << 24));
        return 1;
    }

    // Data-processing (1 source)
    // Encoding: sf:1:S:11010110:opcode2:opcode:rn:rd
    // op0 (bit 30) = 1 distinguishes from 2-source (op0=0)
    // bits 28:21 = 11010110 = 0xd6, so op2 (bits 24:21) = 0x6
    if (op0 == 1 && op1 == 1 && op2 == 0x6) {
        uint32_t sf = (insn >> 31) & 1;
        uint32_t S = (insn >> 29) & 1;
        uint32_t opcode2 = (insn >> 16) & 0x1f;
        uint32_t opcode = (insn >> 10) & 0x3f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        // S must be 0 for valid 1-source instructions
        if (S != 0 || opcode2 != 0) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        void (*gadget)(void) = NULL;

        switch (opcode) {
        case 0x00:  // RBIT
            gadget = gadget_rbit;
            break;
        case 0x01:  // REV16
            gadget = gadget_rev16;
            break;
        case 0x02:  // REV (32-bit) / REV32 (64-bit)
            if (sf == 0)
                gadget = gadget_rev;  // REV for 32-bit
            else
                gadget = gadget_rev32; // REV32 for 64-bit (reverses 32-bit halves)
            break;
        case 0x03:  // REV (64-bit only)
            if (sf == 1)
                gadget = gadget_rev;
            break;
        case 0x04:  // CLZ
            gadget = gadget_clz;
            break;
        case 0x05:  // CLS
            gadget = gadget_cls;
            break;
        default:
            break;
        }

        if (gadget == NULL) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        gen(state, (unsigned long) gadget);
        // Pack: rd | rn<<8 | sf<<24
        gen(state, rd | (rn << 8) | ((uint64_t)sf << 24));
        return 1;
    }

    // Data-processing (3 source) - MUL, MADD, MSUB, SMULL, UMULL, etc.
    // Encoding: sf:0:op54:11011:op31:rm:o0:Ra:rn:rd
    if (op1 == 1 && (op2 & 0x8) == 0x8) {
        uint32_t sf = (insn >> 31) & 1;
        uint32_t op54 = (insn >> 29) & 0x3;
        uint32_t op31 = (insn >> 21) & 0x7;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t o0 = (insn >> 15) & 1;
        uint32_t ra = (insn >> 10) & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        void *gadget = NULL;

        if (op54 == 0) {
            if (sf == 1 && op31 == 0) {
                // 64-bit MADD/MSUB
                gadget = o0 ? gadget_msub : gadget_madd;
            } else if (sf == 0 && op31 == 0) {
                // 32-bit MADD/MSUB
                gadget = o0 ? gadget_msub : gadget_madd;
            } else if (sf == 1 && op31 == 1) {
                // SMADDL/SMSUBL (signed 32x32->64)
                gadget = o0 ? gadget_smsubl : gadget_smaddl;
            } else if (sf == 1 && op31 == 2) {
                // SMULH (signed high multiply)
                gadget = gadget_smulh;
                // For SMULH, ra is not used but we still pack rd, rn, rm
            } else if (sf == 1 && op31 == 5) {
                // UMADDL/UMSUBL (unsigned 32x32->64)
                gadget = o0 ? gadget_umsubl : gadget_umaddl;
            } else if (sf == 1 && op31 == 6) {
                // UMULH (unsigned high multiply)
                gadget = gadget_umulh;
                // For UMULH, ra is not used but we still pack rd, rn, rm
            }
        }

        if (gadget == NULL) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        gen(state, (unsigned long) gadget);
        // Pack: rd | rn<<8 | rm<<16 | ra<<24 | sf<<29
        gen(state, rd | (rn << 8) | (rm << 16) | ((uint64_t)ra << 24) | ((uint64_t)sf << 29));
        return 1;
    }

    (void)op0;
    gen_interrupt(state, INT_UNDEFINED);
    return 0;
}

/*
 * SIMD and Floating-Point
 *
 * This implements a minimal subset needed for musl's memset:
 * - DUP Vd.16B, Wn (or Xn)
 * - MOV Xd, Vn.D[0]
 * - STR Qn, [Xbase, #imm]
 * - STUR Qn, [Xbase, #imm]
 * - STP Qn, Qm, [Xbase, #imm]
 */
static int gen_simd_fp(struct gen_state *state, uint32_t insn) {
    // FMOV (immediate) - scalar floating-point immediate
    // Pattern: 0b00011110 0/1 1 0 imm8 10000 Rd
    // Mask 0xffa07fe0 ignores imm8 (bits 20-13), Rd (bits 4-0), and type (bit 22)
    if ((insn & 0xffa07fe0) == 0x1e201000) {
        uint32_t rd = insn & 0x1f;
        bool is_double = (insn & 0x00400000) != 0;  // type bit: 1=double, 0=single
        uint8_t imm8_raw = (insn >> 13) & 0xff;
        uint8_t imm8 = imm8_raw ^ 0x40;  // Invert bit6 per ARM FP immediate encoding
        uint64_t bits = arm64_fpimm_to_bits(is_double, imm8);
        uint64_t lo = is_double ? bits : (uint64_t)(uint32_t)bits;

        gen(state, (unsigned long) gadget_set_vec_imm);
        gen(state, rd);
        gen(state, lo);
        gen(state, 0);
        return 1;
    }

    // FMOV (register) - scalar FP register copy
    // Matches: 0b00011110 type 1 00 0 0 0 0 0 Rn Rd (FMOV scalar)
    // Mask 0xffbffc00 ignores Rn/Rd and type
    if ((insn & 0xffbffc00) == 0x1e204000) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        bool is_double = (insn & 0x00400000) != 0;  // type bit: 1=double, 0=single
        gen(state, (unsigned long) gadget_fmov_fp_to_fp);
        gen(state, rd | (rn << 8) | ((uint64_t)is_double << 16));
        return 1;
    }

    // MOV/INS (element) - insert GPR into vector element (D size)
    // Encoding: 0100_1110_000x_1000_0001_1100_Rn_Rd (MOV Vd.D[idx], Xn)
    // imm5 = x1000 for D elements (bit 3 set, bits 2:0 clear), x = index
    // Mask 0xffe0fc00 keeps bits 31:21 and 15:10
    // Also check bits 19:16 = 1000 (0x8) for D size
    if ((insn & 0xffe0fc00) == 0x4e001c00 && ((insn >> 16) & 0xf) == 0x8) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t idx = (insn >> 20) & 0x1;  // D element index (0 or 1)
        gen(state, (unsigned long) gadget_ins_gpr_to_vec_d);
        gen(state, rd | (rn << 8) | (idx << 16));
        return 1;
    }

    // MOV/INS (element) - insert GPR into vector element (S size)
    // Matches: 0b01001110 0001 1xx0 0001 1100 Rn Rd (MOV Vd.S[idx], Wn)
    // Mask 0xffe7fc00 ignores Rd/Rn/index bits
    if ((insn & 0xffe7fc00) == 0x4e041c00) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t idx = (insn >> 19) & 0x3;  // S element index
        gen(state, (unsigned long) gadget_ins_gpr_to_vec_s);
        gen(state, rd | (rn << 8) | (idx << 16));
        return 1;
    }

    // SHL (vector, immediate) - shift left immediate
    // 0 Q U 0 1 1 1 1 0 immh immb 0 1 0 1 0 1 Rn Rd  (U=0 for SHL)
    // immh:immb encodes the shift and element size
    // For 16B/8B (bytes): immh=0001, shift = immh:immb - 8 (0-7)
    // For 8H/4H (halfwords): immh=001x, shift = immh:immb - 16 (0-15)
    // For 4S/2S (words): immh=01xx, shift = immh:immb - 32 (0-31)
    // For 2D/1D (doublewords): immh=1xxx, shift = immh:immb - 64 (0-63)
    // Mask: 0xbf80fc00 keeps bit 31, U, bits 28-23, and opcode; Value: 0x0f005400
    if ((insn & 0xbf80fc00) == 0x0f005400) {
        uint32_t Q = (insn >> 30) & 1;
        uint32_t immh = (insn >> 19) & 0xf;
        uint32_t immb = (insn >> 16) & 0x7;
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;

        // Determine element size and shift from immh
        uint32_t esize, shift;
        if (immh & 0x8) {           // 64-bit
            esize = 3;
            shift = ((immh << 3) | immb) - 64;
        } else if (immh & 0x4) {    // 32-bit
            esize = 2;
            shift = ((immh << 3) | immb) - 32;
        } else if (immh & 0x2) {    // 16-bit
            esize = 1;
            shift = ((immh << 3) | immb) - 16;
        } else {                    // 8-bit (immh & 0x1)
            esize = 0;
            shift = ((immh << 3) | immb) - 8;
        }

        gen(state, (unsigned long) gadget_shl_imm_vec);
        // Pack: rd | rn<<8 | shift<<16 | esize<<24 | Q<<28
        gen(state, rd | (rn << 8) | (shift << 16) | (esize << 24) | (Q << 28));
        return 1;
    }

    // USHR (vector, immediate) - unsigned shift right immediate
    // 0 Q U 0 1 1 1 1 0 immh immb 0 0 0 0 0 1 Rn Rd  (U=1 for USHR)
    // Mask: 0xbf80fc00, Value: 0x2f000400
    if ((insn & 0xbf80fc00) == 0x2f000400) {
        uint32_t Q = (insn >> 30) & 1;
        uint32_t immh = (insn >> 19) & 0xf;
        uint32_t immb = (insn >> 16) & 0x7;
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;

        uint32_t esize, shift;
        if (immh & 0x8) {
            esize = 3;
            shift = 128 - ((immh << 3) | immb);  // USHR: shift = 2*esize - imm
        } else if (immh & 0x4) {
            esize = 2;
            shift = 64 - ((immh << 3) | immb);
        } else if (immh & 0x2) {
            esize = 1;
            shift = 32 - ((immh << 3) | immb);
        } else {
            esize = 0;
            shift = 16 - ((immh << 3) | immb);
        }

        gen(state, (unsigned long) gadget_ushr_imm_vec);
        gen(state, rd | (rn << 8) | (shift << 16) | (esize << 24) | (Q << 28));
        return 1;
    }

    // SSHR (vector, immediate) - signed shift right immediate
    // 0 Q U 0 1 1 1 1 0 immh immb 0 0 0 0 0 1 Rn Rd  (U=0 for SSHR)
    // Mask: 0xbf80fc00, Value: 0x0f000400
    // IMPORTANT: immh must be non-zero for SSHR; immh=0 encodes MOVI/MVNI instead
    if ((insn & 0xbf80fc00) == 0x0f000400) {
        uint32_t immh = (insn >> 19) & 0xf;
        // immh=0 is not a valid shift encoding - this is MOVI/MVNI, not SSHR
        if (immh != 0) {
            uint32_t Q = (insn >> 30) & 1;
            uint32_t immb = (insn >> 16) & 0x7;
            uint32_t rd = insn & 0x1f;
            uint32_t rn = (insn >> 5) & 0x1f;

            uint32_t esize, shift;
            if (immh & 0x8) {
                esize = 3;
                shift = 128 - ((immh << 3) | immb);
            } else if (immh & 0x4) {
                esize = 2;
                shift = 64 - ((immh << 3) | immb);
            } else if (immh & 0x2) {
                esize = 1;
                shift = 32 - ((immh << 3) | immb);
            } else {
                esize = 0;
                shift = 16 - ((immh << 3) | immb);
            }

            gen(state, (unsigned long) gadget_sshr_imm_vec);
            gen(state, rd | (rn << 8) | (shift << 16) | (esize << 24) | (Q << 28));
            return 1;
        }
        // Fall through to MOVI/MVNI handler when immh=0
    }

    // USRA (vector, immediate) - unsigned shift right and accumulate
    // 0 Q 1 0 1 1 1 1 0 immh immb 0 0 0 1 0 1 Rn Rd  (U=1, opcode=00010)
    // Mask: 0xbf80fc00, Value: 0x2f001400
    // NOTE: immh must be non-zero (immh=0 encodes other instructions)
    if ((insn & 0xbf80fc00) == 0x2f001400) {
        uint32_t immh = (insn >> 19) & 0xf;
        if (immh != 0) {
            uint32_t Q = (insn >> 30) & 1;
            uint32_t immb = (insn >> 16) & 0x7;
            uint32_t rd = insn & 0x1f;
            uint32_t rn = (insn >> 5) & 0x1f;

            uint32_t esize, shift;
            if (immh & 0x8) {
                esize = 3;
                shift = 128 - ((immh << 3) | immb);
            } else if (immh & 0x4) {
                esize = 2;
                shift = 64 - ((immh << 3) | immb);
            } else if (immh & 0x2) {
                esize = 1;
                shift = 32 - ((immh << 3) | immb);
            } else {
                esize = 0;
                shift = 16 - ((immh << 3) | immb);
            }

            gen(state, (unsigned long) gadget_usra_imm_vec);
            gen(state, rd | (rn << 8) | (shift << 16) | (esize << 24) | (Q << 28));
            return 1;
        }
        // Fall through when immh=0 - might be another instruction
    }

    // SSRA (vector, immediate) - signed shift right and accumulate
    // 0 Q 0 0 1 1 1 1 0 immh immb 0 0 0 1 0 1 Rn Rd  (U=0, opcode=00010)
    // Mask: 0xbf80fc00, Value: 0x0f001400
    // NOTE: Like SSHR, immh must be non-zero (immh=0 encodes other instructions)
    if ((insn & 0xbf80fc00) == 0x0f001400) {
        uint32_t immh = (insn >> 19) & 0xf;
        if (immh != 0) {
            uint32_t Q = (insn >> 30) & 1;
            uint32_t immb = (insn >> 16) & 0x7;
            uint32_t rd = insn & 0x1f;
            uint32_t rn = (insn >> 5) & 0x1f;

            uint32_t esize, shift;
            if (immh & 0x8) {
                esize = 3;
                shift = 128 - ((immh << 3) | immb);
            } else if (immh & 0x4) {
                esize = 2;
                shift = 64 - ((immh << 3) | immb);
            } else if (immh & 0x2) {
                esize = 1;
                shift = 32 - ((immh << 3) | immb);
            } else {
                esize = 0;
                shift = 16 - ((immh << 3) | immb);
            }

            gen(state, (unsigned long) gadget_ssra_imm_vec);
            gen(state, rd | (rn << 8) | (shift << 16) | (esize << 24) | (Q << 28));
            return 1;
        }
    }

    // SRI (vector, immediate) - shift right and insert
    // 0 Q 1 01111 0 immh immb 01000 1 Rn Rd  (U=1, opcode=01000)
    // Mask: 0xbf80fc00, Value: 0x2f004400
    if ((insn & 0xbf80fc00) == 0x2f004400) {
        uint32_t immh = (insn >> 19) & 0xf;
        if (immh != 0) {
            uint32_t Q = (insn >> 30) & 1;
            uint32_t immb = (insn >> 16) & 0x7;
            uint32_t rd = insn & 0x1f;
            uint32_t rn = (insn >> 5) & 0x1f;

            uint32_t esize, shift;
            if (immh & 0x8) {
                esize = 3;
                shift = 128 - ((immh << 3) | immb);
            } else if (immh & 0x4) {
                esize = 2;
                shift = 64 - ((immh << 3) | immb);
            } else if (immh & 0x2) {
                esize = 1;
                shift = 32 - ((immh << 3) | immb);
            } else {
                esize = 0;
                shift = 16 - ((immh << 3) | immb);
            }

            gen(state, (unsigned long) gadget_sri_imm_vec);
            gen(state, rd | (rn << 8) | (shift << 16) | (esize << 24) | (Q << 28));
            return 1;
        }
    }

    // SLI (vector, immediate) - shift left and insert
    // 0 Q 1 01111 0 immh immb 01010 1 Rn Rd  (U=1, opcode=01010)
    // Mask: 0xbf80fc00, Value: 0x2f005400
    if ((insn & 0xbf80fc00) == 0x2f005400) {
        uint32_t immh = (insn >> 19) & 0xf;
        if (immh != 0) {
            uint32_t Q = (insn >> 30) & 1;
            uint32_t immb = (insn >> 16) & 0x7;
            uint32_t rd = insn & 0x1f;
            uint32_t rn = (insn >> 5) & 0x1f;

            uint32_t esize, shift;
            if (immh & 0x8) {
                esize = 3;
                shift = ((immh << 3) | immb) - 64;
            } else if (immh & 0x4) {
                esize = 2;
                shift = ((immh << 3) | immb) - 32;
            } else if (immh & 0x2) {
                esize = 1;
                shift = ((immh << 3) | immb) - 16;
            } else {
                esize = 0;
                shift = ((immh << 3) | immb) - 8;
            }

            gen(state, (unsigned long) gadget_sli_imm_vec);
            gen(state, rd | (rn << 8) | (shift << 16) | (esize << 24) | (Q << 28));
            return 1;
        }
    }

    // SSHLL (vector, immediate) - signed shift left long (S->D)
    // Matches: SSHLL Vd.2D, Vn.2S, #imm (shift 0..31)
    // Mask 0xffe0fc00 ignores Rd/Rn and shift bits [20:16]
    if ((insn & 0xffe0fc00) == 0x0f20a400) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t sh = (insn >> 16) & 0x1f;
        gen(state, (unsigned long) gadget_sshll_vec_s_to_d);
        gen(state, rd | (rn << 8) | (sh << 16));
        return 1;
    }

    // USHLL (vector, immediate) - unsigned shift left long (S->D)
    // Matches: USHLL Vd.2D, Vn.2S, #imm (shift 0..31)
    // Mask 0xffe0fc00 ignores Rd/Rn and shift bits [20:16]
    if ((insn & 0xffe0fc00) == 0x2f20a400) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t sh = (insn >> 16) & 0x1f;
        gen(state, (unsigned long) gadget_ushll_vec_s_to_d);
        gen(state, rd | (rn << 8) | (sh << 16));
        return 1;
    }

    // DUP (element) - duplicate vector element to vector
    // Pattern: 0 Q 0 0 1 1 1 0 0 0 0 imm5 0 0 0 0 0 1 Rn Rd
    // imm5[4:0] determines element size and index:
    //   xxxx1 = B, index = imm5[4:1]
    //   xxx10 = H, index = imm5[4:2]
    //   xx100 = S, index = imm5[4:3]
    //   x1000 = D, index = imm5[4]
    if ((insn & 0xbfe0fc00) == 0x0e000400) {
        uint32_t Q = (insn >> 30) & 1;
        uint32_t imm5 = (insn >> 16) & 0x1f;
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;

        // Determine element size and index from imm5
        int elem_size = -1;
        int index = 0;
        if (imm5 & 0x1) {
            elem_size = 0;  // B
            index = (imm5 >> 1) & 0xf;
        } else if (imm5 & 0x2) {
            elem_size = 1;  // H
            index = (imm5 >> 2) & 0x7;
        } else if (imm5 & 0x4) {
            elem_size = 2;  // S
            index = (imm5 >> 3) & 0x3;
        } else if (imm5 & 0x8) {
            elem_size = 3;  // D
            index = (imm5 >> 4) & 0x1;
        }

        if (elem_size < 0) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        gen(state, (unsigned long) gadget_dup_elem_vec);
        // Pack: rd | rn<<8 | elem_size<<16 | index<<20 | Q<<24
        gen(state, rd | (rn << 8) | (elem_size << 16) | (index << 20) | (Q << 24));
        return 1;
    }

    // DUP (element, scalar) - duplicate vector element to scalar register
    // Pattern: 01 0 11110 000 imm5 0 00001 Rn Rd
    // Mask 0xffe0fc00 checks fixed bits, ignores imm5, Rn, Rd
    if ((insn & 0xffe0fc00) == 0x5e000400) {
        uint32_t imm5 = (insn >> 16) & 0x1f;
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;

        // Determine element size and index from imm5
        int elem_size = -1;
        int index = 0;
        if (imm5 & 0x1) {
            elem_size = 0;  // B
            index = (imm5 >> 1) & 0xf;
        } else if (imm5 & 0x2) {
            elem_size = 1;  // H
            index = (imm5 >> 2) & 0x7;
        } else if (imm5 & 0x4) {
            elem_size = 2;  // S
            index = (imm5 >> 3) & 0x3;
        } else if (imm5 & 0x8) {
            elem_size = 3;  // D
            index = (imm5 >> 4) & 0x1;
        }

        if (elem_size < 0) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        gen(state, (unsigned long) gadget_dup_elem_scalar);
        // Pack: rd | rn<<8 | elem_size<<16 | index<<20
        gen(state, rd | (rn << 8) | (elem_size << 16) | (index << 20));
        return 1;
    }

    // INS (element) - insert vector element into another vector element
    // Pattern: 0 1 1 0 1 1 1 0 0 0 0 imm5 0 imm4 1 Rn Rd
    // imm5 determines dst element size and index
    // imm4 determines src element index
    if ((insn & 0xffe08400) == 0x6e000400) {
        uint32_t imm5 = (insn >> 16) & 0x1f;
        uint32_t imm4 = (insn >> 11) & 0xf;
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;

        // Determine element size and indices
        int elem_size = -1;
        int dst_idx = 0;
        int src_idx = 0;
        if (imm5 & 0x1) {
            elem_size = 0;  // B
            dst_idx = (imm5 >> 1) & 0xf;
            src_idx = imm4 & 0xf;
        } else if (imm5 & 0x2) {
            elem_size = 1;  // H
            dst_idx = (imm5 >> 2) & 0x7;
            src_idx = (imm4 >> 1) & 0x7;
        } else if (imm5 & 0x4) {
            elem_size = 2;  // S
            dst_idx = (imm5 >> 3) & 0x3;
            src_idx = (imm4 >> 2) & 0x3;
        } else if (imm5 & 0x8) {
            elem_size = 3;  // D
            dst_idx = (imm5 >> 4) & 0x1;
            src_idx = (imm4 >> 3) & 0x1;
        }

        if (elem_size < 0) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        gen(state, (unsigned long) gadget_ins_elem_vec);
        // Pack: rd | rn<<8 | elem_size<<16 | dst_idx<<20 | src_idx<<24
        gen(state, rd | (rn << 8) | (elem_size << 16) | (dst_idx << 20) | (src_idx << 24));
        return 1;
    }

    // DUP (general) - duplicate general-purpose register to vector
    // Pattern: 0 Q 0 0 1 1 1 0 0 0 0 imm5 0 0 0 0 1 1 Rn Rd
    // imm5[4:0] determines element size:
    //   xxxxx1 = B (byte)
    //   xxxx10 = H (halfword)
    //   xxx100 = S (word)
    //   xx1000 = D (doubleword)
    if ((insn & 0xbfe0fc00) == 0x0e000c00) {
        uint32_t Q = (insn >> 30) & 1;
        uint32_t imm5 = (insn >> 16) & 0x1f;
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;

        // Determine element size from imm5
        int elem_size = -1;
        if (imm5 & 0x1) elem_size = 0;       // B (byte)
        else if (imm5 & 0x2) elem_size = 1;  // H (halfword)
        else if (imm5 & 0x4) elem_size = 2;  // S (word)
        else if (imm5 & 0x8) elem_size = 3;  // D (doubleword)

        if (elem_size < 0) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        // Generate a general DUP gadget that takes element size as parameter
        gen(state, (unsigned long) gadget_dup_gpr_to_vec);
        gen(state, rd | (rn << 8) | (elem_size << 16) | (Q << 24));
        return 1;
    }

    // UMOV/MOV (to general) - extract vector element to GPR
    // For MOV Xd, Vn.D[0]: 0x4e083c00 | (Rn << 5) | Rd
    // Pattern: 0Q001110 imm5 0 01111 Rn Rd
    // Q=1, imm5[4:0]=01000 means D[0]
    if ((insn & 0xffe0fc00) == 0x4e083c00) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        gen(state, (unsigned long) gadget_mov_v_to_gpr);
        gen(state, rd | (rn << 8));
        return 1;
    }

    // UMOV/MOV (to general) - extract vector element to GPR
    // Matches: 0Q001110 0imm5 0 01111 Rn Rd (UMOV/MOV scalar from vector)
    if ((insn & 0xbfe0fc00) == 0x0e003c00) {
        uint32_t imm5 = (insn >> 16) & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        int elem_size = -1;
        if (imm5 & 0x1) elem_size = 0;       // B
        else if (imm5 & 0x2) elem_size = 1;  // H
        else if (imm5 & 0x4) elem_size = 2;  // S
        else if (imm5 & 0x8) elem_size = 3;  // D

        if (elem_size < 0) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        uint32_t index = imm5 >> (elem_size + 1);
        uint32_t max_elems = 16u >> elem_size;
        if (index >= max_elems) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        gen(state, (unsigned long) gadget_umov_vec_to_gpr);
        // Pack: rd | rn<<8 | elem_size<<16 | index<<20
        gen(state, rd | (rn << 8) | (elem_size << 16) | (index << 20));
        return 1;
    }

    // STR (vector, immediate) - store 128-bit
    // Pattern: 00111101 10 imm12 Rn Rt (scaled offset)
    // Mask: check bits 31:30=00, 29:22=0x3d8 for Q variant
    if ((insn & 0xffc00000) == 0x3d800000) {
        uint32_t rt = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t imm12 = (insn >> 10) & 0xfff;
        // Offset is imm12 * 16 for Q register
        int64_t offset = (int64_t)imm12 * 16;
        gen(state, (unsigned long) gadget_calc_addr_imm);
        gen(state, rn | (offset << 8));
        gen(state, (unsigned long) gadget_str_q);
        gen(state, rt);
        return 1;
    }

    // STUR (vector, unscaled) - store 128-bit with unscaled offset
    // Pattern: 00111100 10 0 imm9 00 Rn Rt
    if ((insn & 0xffe00c00) == 0x3c800000) {
        uint32_t rt = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        int32_t imm9 = ((int32_t)(insn >> 12) << 23) >> 23;  // Sign-extend
        gen(state, (unsigned long) gadget_calc_addr_imm);
        gen(state, rn | ((int64_t)imm9 << 8));
        gen(state, (unsigned long) gadget_str_q);
        gen(state, rt);
        return 1;
    }

    // STP (vector, signed offset) - store pair of 128-bit
    // Pattern: 10101101 opc imm7 Rt2 Rn Rt
    // opc=01 for signed offset
    if ((insn & 0xffc00000) == 0xad000000) {
        uint32_t rt = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rt2 = (insn >> 10) & 0x1f;
        int32_t imm7 = ((int32_t)(insn >> 15) << 25) >> 25;  // Sign-extend
        // Offset is imm7 * 16 for Q registers
        int64_t offset = (int64_t)imm7 * 16;
        gen(state, (unsigned long) gadget_calc_addr_imm);
        gen(state, rn | (offset << 8));
        gen(state, (unsigned long) gadget_stp_q);
        gen(state, rt | (rt2 << 8));
        return 1;
    }

    // MOVI/MVNI - Modified immediate (for zeroing vectors)
    // Pattern: 0 Q op 0111100000 a b c cmode 01 d e f g h Rd
    // For MOVI/MVNI with imm=0: the main variants are:
    // Advanced SIMD modified immediate (MOVI/MVNI/ORR/BIC)
    // Mask: 0x9ff80c00 - preserves bit 31, 28-19, 11-10; ignores Q(30), op(29), abc(18-16), cmode(15-12), defgh(9-5), Rd(4-0)
    if ((insn & 0x9ff80c00) == 0x0f000400) {
        uint32_t Q = (insn >> 30) & 1;
        uint32_t op = (insn >> 29) & 1;  // 0=MOVI/ORR, 1=MVNI/BIC (except for cmode=0xe/0xf)
        uint32_t cmode = (insn >> 12) & 0xf;
        uint32_t rd = insn & 0x1f;

        // Extract immediate from abc:defgh
        uint32_t a = (insn >> 18) & 1;
        uint32_t b = (insn >> 17) & 1;
        uint32_t c = (insn >> 16) & 1;
        uint32_t d = (insn >> 9) & 1;
        uint32_t e = (insn >> 8) & 1;
        uint32_t f = (insn >> 7) & 1;
        uint32_t g = (insn >> 6) & 1;
        uint32_t h = (insn >> 5) & 1;
        uint8_t imm8 = (a << 7) | (b << 6) | (c << 5) | (d << 4) | (e << 3) | (f << 2) | (g << 1) | h;

        // Special handling for cmode=0xe/0xf with op=1:
        // - cmode=0xe, op=1: MOVI with 64-bit element (byte expansion)
        // - cmode=0xf, op=0: FMOV (immediate)
        // - cmode=0xf, op=1: Reserved
        if (cmode == 0xe && op == 1) {
            // MOVI (64-bit scalar): Each bit of imm8 is expanded to a byte
            // imm8 bit i (0-7) -> result byte i is 0xFF if set, 0x00 if clear
            uint64_t elem64 = 0;
            for (int i = 0; i < 8; i++) {
                if (imm8 & (1 << i)) {
                    elem64 |= (0xFFULL << (i * 8));
                }
            }
            gen(state, (unsigned long) gadget_set_vec_imm);
            gen(state, rd);
            gen(state, elem64);           // lo = expanded 64-bit value
            gen(state, Q ? elem64 : 0);   // hi = same if Q=1, else 0
            return 1;
        }

        if (cmode == 0xf) {
            // cmode=0xf: FMOV (immediate) for floating-point
            if (op == 1) {
                // Reserved
                gen_interrupt(state, INT_UNDEFINED);
                return 0;
            }
            // FMOV (immediate) - interpret imm8 as FP immediate
            // For now, treat as undefined (complex FP immediate expansion)
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        // ORR/BIC use odd cmode values for integer immediates (e.g., 0x1/0x3/0x5/0x7/0x9/0xb).
        // MVNI with msl uses cmode=0xd, which should stay in the MOVI/MVNI path.
        bool is_orr_bic = ((cmode & 1) != 0) && (cmode != 0xd);
        uint32_t base_cmode = is_orr_bic ? (cmode - 1) : cmode;

        uint64_t pattern = 0;
        bool ok = false;
        if (cmode == 0xd) {
            // MVNI (msl #16) - mask shift left: imm8 in bits[23:16], low 16 bits set.
            // This form only exists for MVNI.
            if (op != 1) {
                gen_interrupt(state, INT_UNDEFINED);
                return 0;
            }
            uint64_t elem = ((uint64_t)imm8 << 16) | 0xffff;
            pattern = elem | (elem << 32);
            ok = true;
        } else {
            ok = simd_modimm_pattern(base_cmode, imm8, &pattern);
        }
        if (!ok) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        uint64_t lo = pattern;
        uint64_t hi = Q ? pattern : 0;

        if (!is_orr_bic) {
            if (op) {
                // MVNI: invert the pattern
                lo = ~lo;
                if (Q) hi = ~hi;
            }
            gen(state, (unsigned long) gadget_set_vec_imm);
            gen(state, rd);
            gen(state, lo);
            gen(state, hi);
        } else {
            gen(state, (unsigned long) (op ? gadget_bic_imm_vec : gadget_orr_imm_vec));
            gen(state, rd | (Q << 8));
            gen(state, lo);
            gen(state, hi);
        }
        return 1;
    }

    // Note: LD1/ST1 instructions are now handled in gen_ldst() since they
    // are classified as load/store instructions by arm64_classify_insn()

    // Advanced SIMD three same - vector arithmetic operations
    // Pattern: 0 Q U 0 1 1 1 0 size 1 Rm opcode 1 Rn Rd
    // Fixed bits: bit[31]=0, bits[28:24]=01110, bit[21]=1, bit[10]=1
    // Mask 0x9f200400 checks only fixed bits (excludes Q, U, size, Rm, opcode, Rn, Rd)
    if ((insn & 0x9f200400) == 0x0e200400) {
        uint32_t Q = (insn >> 30) & 1;
        uint32_t U = (insn >> 29) & 1;
        uint32_t size = (insn >> 22) & 0x3;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t opcode = (insn >> 11) & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        void *gadget = NULL;
        if (U == 0 && opcode == 0x00) {
            // SHADD - Signed halving add
            gadget = gadget_shadd_vec;
        } else if (U == 1 && opcode == 0x00) {
            // UHADD - Unsigned halving add
            gadget = gadget_uhadd_vec;
        } else if (U == 0 && opcode == 0x02) {
            // SRHADD - Signed rounding halving add
            gadget = gadget_srhadd_vec;
        } else if (U == 1 && opcode == 0x02) {
            // URHADD - Unsigned rounding halving add
            gadget = gadget_urhadd_vec;
        } else if (U == 0 && opcode == 0x08) {
            // SSHL - Signed shift left (by register)
            gadget = gadget_sshl_vec;
        } else if (U == 1 && opcode == 0x08) {
            // USHL - Unsigned shift left (by register)
            gadget = gadget_ushl_vec;
        } else if (U == 0 && opcode == 0x10) {
            // ADD - Vector add
            if (size == 3 && Q == 0) {
                gen_interrupt(state, INT_UNDEFINED);
                return 0;
            }
            gadget = gadget_add_vec;
        } else if (U == 1 && opcode == 0x10) {
            // SUB - Vector subtract
            if (size == 3 && Q == 0) {
                gen_interrupt(state, INT_UNDEFINED);
                return 0;
            }
            gadget = gadget_sub_vec;
        } else if (U == 1 && opcode == 0x06) {
            // CMHI - Compare higher (unsigned >)
            gadget = gadget_cmhi_vec;
        } else if (U == 1 && opcode == 0x07) {
            // CMHS - Compare higher or same (unsigned >=)
            gadget = gadget_cmhs_vec;
        } else if (U == 1 && opcode == 0x11) {
            // CMEQ - Compare equal
            gadget = gadget_cmeq_vec;
        } else if (U == 0 && opcode == 0x03) {
            // AND - Bitwise AND
            gadget = gadget_and_vec;
        } else if (U == 0 && opcode == 0x07) {
            // ORR - Bitwise OR
            gadget = gadget_orr_vec;
        } else if (U == 1 && opcode == 0x03) {
            // EOR / BSL / BIT / BIF share opcode, distinguished by size
            if (size == 0) {
                // EOR - Bitwise exclusive OR
                gadget = gadget_eor_vec;
            } else if (size == 1) {
                // BSL - Bitwise select
                gadget = gadget_bsl_vec;
            } else if (size == 2) {
                // BIT - Bitwise insert
                gadget = gadget_bit_vec;
            } else if (size == 3) {
                // BIF - Bitwise insert if false
                gadget = gadget_bif_vec;
            }
        } else if (U == 0 && opcode == 0x01) {
            // BIC - Bit clear (Vn AND NOT Vm)
            gadget = gadget_bic_vec;
        } else if (U == 0 && opcode == 0x17) {
            // ADDP - Add pairwise
            gadget = gadget_addp_vec;
        } else if (U == 1 && opcode == 0x14) {
            // UMAXP - Unsigned maximum pairwise
            gadget = gadget_umaxp_vec;
        } else if (U == 1 && opcode == 0x15) {
            // UMINP - Unsigned minimum pairwise
            gadget = gadget_uminp_vec;
        }

        if (gadget) {
            gen(state, (unsigned long) gadget);
            // Pack: rd | rn<<8 | rm<<16 | size<<24 | Q<<26
            gen(state, rd | (rn << 8) | (rm << 16) | (size << 24) | (Q << 26));
            return 1;
        }
        // Unimplemented three-same NEON instruction — must not silently fall through
        gen_interrupt(state, INT_UNDEFINED);
        return 0;
    }

    // AdvSIMD three different - widening/narrowing operations
    // Pattern: 0 Q U 01110 size 1 Rm opcode 00 Rn Rd
    // Fixed bits: bit[31]=0, bits[28:24]=01110, bit[21]=1, bits[11:10]=00
    // Mask: 0x9f200c00 checks fixed bits
    if ((insn & 0x9f200c00) == 0x0e200000) {
        uint32_t Q = (insn >> 30) & 1;
        uint32_t U = (insn >> 29) & 1;
        uint32_t size = (insn >> 22) & 0x3;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t opcode = (insn >> 12) & 0xf;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        void *gadget = NULL;

        // Size 3 is reserved for most three-different instructions
        // EXCEPT: PMULL uses size=3 with opcode=14 (0xe)
        if (size == 3) {
            // Check for PMULL: opcode=14 (0xe), U=0
            if (opcode == 0xe && U == 0) {
                // This is PMULL - let it fall through to the PMULL handler below
                // (don't generate undefined, don't match as three-different)
                goto skip_three_different;
            }
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        if (U == 0) {
            switch (opcode) {
                case 0x1:  // SADDW - Signed add wide
                    gadget = gadget_saddw_vec;
                    break;
                // TODO: Add more signed widening instructions as needed
                // case 0x0: SADDL
                // case 0x2: SSUBL
                // case 0x3: SSUBW
            }
        } else {
            switch (opcode) {
                case 0x1:  // UADDW - Unsigned add wide
                    gadget = gadget_uaddw_vec;
                    break;
                // TODO: Add more unsigned widening instructions as needed
                // case 0x0: UADDL
                // case 0x2: USUBL
                // case 0x3: USUBW
            }
        }

        if (gadget) {
            gen(state, (unsigned long) gadget);
            // Pack: rd | rn<<8 | rm<<16 | size<<24 | Q<<26
            gen(state, rd | (rn << 8) | (rm << 16) | (size << 24) | (Q << 26));
            return 1;
        }
        // Unimplemented three-different NEON instruction — must not silently fall through
        gen_interrupt(state, INT_UNDEFINED);
        return 0;
    }
skip_three_different:

    // XTN/XTN2 - narrow (vector)
    // Matches: 0Q0011100ss10000 101000 Rn Rd (XTN/XTN2)
    // Mask ignores Q to cover both XTN and XTN2.
    if ((insn & 0xbf3ffd09) == 0x0e212800) {
        uint32_t Q = (insn >> 30) & 1;
        uint32_t size = (insn >> 22) & 0x3;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;
        if (size == 3) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }
        gen(state, (unsigned long) gadget_xtn_vec);
        // Pack: rd | rn<<8 | size<<16 | hi<<18 (hi=Q for XTN2)
        gen(state, rd | (rn << 8) | (size << 16) | (Q << 18));
        return 1;
    }

    // Permute instructions: UZP1, UZP2, TRN1, TRN2, ZIP1, ZIP2
    // Format: 0 Q 0 01110 size 0 Rm 0 op2 10 Rn Rd
    // op2: 001=UZP1, 101=UZP2, 010=TRN1, 110=TRN2, 011=ZIP1, 111=ZIP2
    // Mask: 0xbf208c00, Value: 0x0e000800
    if ((insn & 0xbf208c00) == 0x0e000800) {
        uint32_t Q = (insn >> 30) & 1;
        uint32_t size = (insn >> 22) & 0x3;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t op2 = (insn >> 12) & 0x7;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        // size == 3 (64-bit elements) requires Q == 1
        if (size == 3 && Q == 0) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        void *gadget = NULL;
        switch (op2) {
            case 1: gadget = gadget_uzp1_vec; break;  // UZP1
            case 5: gadget = gadget_uzp2_vec; break;  // UZP2
            case 2: gadget = gadget_trn1_vec; break;  // TRN1
            case 6: gadget = gadget_trn2_vec; break;  // TRN2
            case 3: gadget = gadget_zip1_vec; break;  // ZIP1
            case 7: gadget = gadget_zip2_vec; break;  // ZIP2
        }

        if (gadget) {
            gen(state, (unsigned long) gadget);
            // Pack: rd | rn<<8 | rm<<16 | size<<24 | Q<<26
            gen(state, rd | (rn << 8) | (rm << 16) | (size << 24) | (Q << 26));
            return 1;
        }
    }

    // CMEQ with zero - pattern: 0 Q 0 0 1 1 1 0 size 1 0 0 0 0 0 10011 1 Rn Rd
    // Binary: 0Q0_0111_0ss1_0000_0100_11Rn_nnRd_dddd
    if ((insn & 0xbf3ffc00) == 0x0e209800) {
        uint32_t Q = (insn >> 30) & 1;
        uint32_t size = (insn >> 22) & 0x3;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;
        gen(state, (unsigned long) gadget_cmeq_zero_vec);
        gen(state, rd | (rn << 8) | (size << 16) | (Q << 24));
        return 1;
    }

    // REV32/REV64 (vector) - AdvSIMD two-register misc
    // REV64: 0 Q 0 01110 size 10000 00000 10 Rn Rd (U=0, opcode=00000)
    // REV32: 0 Q 1 01110 size 10000 00000 10 Rn Rd (U=1, opcode=00000)
    // Binary: 0QuU_0111_0ss1_0000_0000_010R_nnnn_dddd
    // Mask: 0xbf3ffc00 checks Q, U, fixed bits, size, opcode fields
    // REV64: 0x0e200800 (U=0)
    // REV32: 0x2e200800 (U=1)
    if ((insn & 0xbf3ffc00) == 0x0e200800 || (insn & 0xbf3ffc00) == 0x2e200800) {
        uint32_t Q = (insn >> 30) & 1;
        uint32_t U = (insn >> 29) & 1;
        uint32_t size = (insn >> 22) & 0x3;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        void *gadget = NULL;
        if (U == 0) {
            // REV64 - reverses bytes in 64-bit elements
            // size must be < 3 (64-bit elements don't need REV64)
            if (size >= 3) {
                gen_interrupt(state, INT_UNDEFINED);
                return 0;
            }
            gadget = gadget_rev64_vec;
        } else {
            // REV32 - reverses bytes in 32-bit elements
            // size must be < 2 (32-bit elements need byte or halfword reversal)
            if (size >= 2) {
                gen_interrupt(state, INT_UNDEFINED);
                return 0;
            }
            gadget = gadget_rev32_vec;
        }
        gen(state, (unsigned long) gadget);
        gen(state, rd | (rn << 8) | (size << 16) | (Q << 24));
        return 1;
    }

    // RBIT (vector) - reverse bits in each byte
    // 0 Q 1 01110 sz 10000 00101 10 Rn Rd
    // Mask 0xbf3ffc00 checks fixed bits, ignores Q, sz, Rn, Rd
    // Value: sz must be 00 for .8B/.16B
    if ((insn & 0xbf3ffc00) == 0x2e205800) {
        uint32_t Q = (insn >> 30) & 1;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        gen(state, (unsigned long) gadget_rbit_vec);
        gen(state, rd | (rn << 8) | (Q << 16));
        return 1;
    }

    // Floating-point/integer conversion (scalar)
    // UCVTF/SCVTF/FCVTZU/FCVTZS
    // Pattern: sf 0 0 1 1 1 1 0 type 1 rmode opcode 0 0 0 0 0 0 Rn Rd
    // Fixed bits: 30-29=00, 28-24=11110, 21=1, 15-10=000000
    // Mask: 0x7f20fc00 checks fixed bits
    if ((insn & 0x7f20fc00) == 0x1e200000) {
        uint32_t sf = (insn >> 31) & 1;
        uint32_t type = (insn >> 22) & 3;
        uint32_t rmode = (insn >> 19) & 3;
        uint32_t opcode = (insn >> 16) & 7;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;


        void *gadget = NULL;
        if (rmode == 0 && opcode == 3) {
            // UCVTF - unsigned int to float
            gadget = gadget_ucvtf_scalar;
        } else if (rmode == 0 && opcode == 2) {
            // SCVTF - signed int to float
            gadget = gadget_scvtf_scalar;
        } else if (rmode == 3 && opcode == 1) {
            // FCVTZU - float to unsigned int (round toward zero)
            gadget = gadget_fcvtzu_scalar;
        } else if (rmode == 3 && opcode == 0) {
            // FCVTZS - float to signed int (round toward zero)
            gadget = gadget_fcvtzs_scalar;
        } else if (rmode == 0 && opcode == 6) {
            // FMOV - move bits from FP register to GPR (opcode bit 0 = 0)
            gadget = gadget_fmov_fp_to_gpr;
        } else if (rmode == 0 && opcode == 7) {
            // FMOV - move bits from GPR to FP register (opcode bit 0 = 1)
            gadget = gadget_fmov_gpr_to_fp;
        } else if (rmode == 1 && opcode == 6 && type == 2 && sf == 1) {
            // FMOV - move bits from vector upper D lane to GPR (Vn.D[1] -> Xd)
            gadget = gadget_fmov_fp_to_gpr_hi;
        } else if (rmode == 1 && opcode == 7 && type == 2 && sf == 1) {
            // FMOV - move bits from GPR to vector upper D lane (Xd -> Vd.D[1])
            gadget = gadget_fmov_gpr_to_fp_hi;
        }

        if (gadget) {
            gen(state, (unsigned long) gadget);
            // Pack: rd | rn<<8 | type<<16 | sf<<18
            gen(state, rd | (rn << 8) | (type << 16) | (sf << 18));
            return 1;
        }
    }

    // FCMP/FCMPE (scalar, register)
    // Encoding: 000 11110 type 1 Rm 00 1000 Rn opc 000
    // type = bits 23:22 (00=S, 01=D), Rm = bits 20:16, Rn = bits 9:5
    // opc = bits 4:3 (00=FCMP, 10=FCMPE)
    // Mask 0xff20fc07 ignores type, Rm, Rn, and opc bits
    if ((insn & 0xff20fc07) == 0x1e202000) {
        uint32_t type = (insn >> 22) & 3;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        if (type > 1) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }
        gen(state, (unsigned long) gadget_fcmp_scalar);
        // Pack: rn | rm<<8 | type<<16
        gen(state, rn | (rm << 8) | (type << 16));
        return 1;
    }

    // FCMP/FCMPE (scalar, compare with zero)
    // Encoding: 000 11110 type 1 00001 00 1000 Rn opc 000
    // type = bits 23:22, Rm = bits 20:16 (must be 00001), Rn = bits 9:5
    // opc = bits 4:3 (00=FCMP, 01=FCMPE)
    // Mask 0xff20fc07 ignores type, Rn, and opc bits; check Rm=1 separately
    if ((insn & 0xff20fc07) == 0x1e202000 && ((insn >> 16) & 0x1f) == 1) {
        uint32_t type = (insn >> 22) & 3;
        uint32_t rn = (insn >> 5) & 0x1f;
        if (type > 1) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }
        gen(state, (unsigned long) gadget_fcmp_zero_scalar);
        // Pack: rn | type<<16
        gen(state, rn | (type << 16));
        return 1;
    }

    // Floating-point data-processing (2 source), scalar
    // FADD/FSUB/FMUL/FDIV
    if ((insn & 0xff20fc00) == 0x1e200800 ||
        (insn & 0xff20fc00) == 0x1e201800 ||
        (insn & 0xff20fc00) == 0x1e202800 ||
        (insn & 0xff20fc00) == 0x1e203800) {
        uint32_t op = insn & 0xff20fc00;
        uint32_t type = (insn >> 22) & 3;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;
        if (type > 1) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        void *gadget = NULL;
        switch (op) {
            case 0x1e200800: // FMUL
                gadget = gadget_fmul_scalar;
                break;
            case 0x1e201800: // FDIV
                gadget = gadget_fdiv_scalar;
                break;
            case 0x1e202800: // FADD
                gadget = gadget_fadd_scalar;
                break;
            case 0x1e203800: // FSUB
                gadget = gadget_fsub_scalar;
                break;
            default:
                break;
        }

        if (gadget) {
            gen(state, (unsigned long) gadget);
            // Pack: rd | rn<<8 | rm<<16 | type<<24
            gen(state, rd | (rn << 8) | (rm << 16) | (type << 24));
            return 1;
        }
    }

    // Floating-point data-processing (3 source) - FMADD/FMSUB/FNMADD/FNMSUB
    // Pattern: M=0 S=0 1 1 1 1 1 ftype o1 Rm o0 Ra Rn Rd
    // ftype: 00=single, 01=double
    // o1:o0 = 00: FMADD  (Fd = Fn * Fm + Fa)
    //       = 01: FMSUB  (Fd = Fn * Fm - Fa)
    //       = 10: FNMADD (Fd = -(Fn * Fm) - Fa)
    //       = 11: FNMSUB (Fd = -(Fn * Fm) + Fa)
    if ((insn & 0x5f000000) == 0x1f000000) {
        uint32_t M = (insn >> 31) & 1;
        uint32_t S = (insn >> 29) & 1;
        uint32_t ftype = (insn >> 22) & 3;
        uint32_t o1 = (insn >> 21) & 1;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t o0 = (insn >> 15) & 1;
        uint32_t ra = (insn >> 10) & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rd = insn & 0x1f;

        // M and S must be 0 for scalar FP data-processing (3 source)
        if (M != 0 || S != 0) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        // Only single (ftype=0) and double (ftype=1) precision supported
        if (ftype > 1) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        uint32_t op = (o1 << 1) | o0;
        void *gadget = NULL;
        switch (op) {
            case 0: gadget = gadget_fmadd_scalar; break;
            case 1: gadget = gadget_fmsub_scalar; break;
            case 2: gadget = gadget_fnmadd_scalar; break;
            case 3: gadget = gadget_fnmsub_scalar; break;
        }

        gen(state, (unsigned long) gadget);
        // Pack: rd | rn<<8 | rm<<16 | ra<<24
        gen(state, rd | (rn << 8) | (rm << 16) | (ra << 24));
        // ftype as second word
        gen(state, ftype);
        return 1;
    }

    // TBL/TBX - Table lookup
    // TBL: 0 Q 00 1110 000 Rm 0 len 0 0 Rn Rd
    // TBX: 0 Q 00 1110 000 Rm 0 len 1 0 Rn Rd
    // Mask: 0xbfe08c00 = 1011_1111_1110_0000_1000_1100_0000_0000
    // Value: 0x0e000000
    if ((insn & 0xbfe08c00) == 0x0e000000) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t op = (insn >> 12) & 0x1;  // 0=TBL, 1=TBX
        uint32_t len = (insn >> 13) & 0x3; // table size: 0=1reg, 1=2reg, 2=3reg, 3=4reg
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t Q = (insn >> 30) & 0x1;   // 0=64-bit, 1=128-bit

        void *gadget = op ? gadget_tbx : gadget_tbl;
        gen(state, (unsigned long) gadget);
        // Pack: rd | rn<<8 | rm<<16 | len<<24 | Q<<28
        gen(state, rd | (rn << 8) | (rm << 16) | (len << 24) | (Q << 28));
        return 1;
    }

    // EXT - Extract from pair of vectors
    // 0 Q 10 1110 00 0 Rm 0 imm4 0 Rn Rd
    // Mask: 0xbfe08400 Value: 0x2e000000
    if ((insn & 0xbfe08400) == 0x2e000000) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t imm4 = (insn >> 11) & 0xf;  // byte index
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t Q = (insn >> 30) & 0x1;     // 0=8B, 1=16B

        gen(state, (unsigned long) gadget_ext_vec);
        // Pack: rd | rn<<8 | rm<<16 | imm4<<24 | Q<<28
        gen(state, rd | (rn << 8) | (rm << 16) | (imm4 << 24) | (Q << 28));
        return 1;
    }

    // Cryptographic AES instructions
    // AESE/AESD/AESMC/AESIMC: 0100_1110_0010_1000_opcode_10_Rn_Rd
    // AESE:   0x4e284800 (opcode=0100)
    // AESD:   0x4e285800 (opcode=0101)
    // AESMC:  0x4e286800 (opcode=0110)
    // AESIMC: 0x4e287800 (opcode=0111)
    // Mask 0xff3f0c00 keeps bits 31:22, 11:10, ignores opcode (15:12), Rn, Rd
    if ((insn & 0xff3f0c00) == 0x4e280800) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t opcode = (insn >> 12) & 0xf;

        void *gadget = NULL;
        switch (opcode) {
            case 4: gadget = gadget_aese; break;   // 0100 -> AESE
            case 5: gadget = gadget_aesd; break;   // 0101 -> AESD
            case 6: gadget = gadget_aesmc; break;  // 0110 -> AESMC
            case 7: gadget = gadget_aesimc; break; // 0111 -> AESIMC
        }
        if (gadget) {
            gen(state, (unsigned long) gadget);
            gen(state, rd | (rn << 8));
            return 1;
        }
    }

    // SHA1 and SHA256 two-register crypto
    // SHA1H:     0101 1110 0010 1000 0000 10 Rn Rd (0x5e280800)
    // SHA1SU1:   0101 1110 0010 1000 0001 10 Rn Rd (0x5e281800)
    // SHA256SU0: 0101 1110 0010 1000 0010 10 Rn Rd (0x5e282800)
    // Mask 0xffffcc00 keeps bits 31:14 and 11:10, ignores opcode (13:12), Rn, Rd
    if ((insn & 0xffffcc00) == 0x5e280800) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t opcode = (insn >> 12) & 0x3;

        void *gadget = NULL;
        switch (opcode) {
            case 0: gadget = gadget_sha1h; break;      // SHA1H
            case 1: gadget = gadget_sha1su1; break;    // SHA1SU1
            case 2: gadget = gadget_sha256su0; break;  // SHA256SU0
        }
        if (gadget) {
            gen(state, (unsigned long) gadget);
            gen(state, rd | (rn << 8));
            return 1;
        }
    }

    // SHA1 three-register: SHA1C, SHA1M, SHA1P, SHA1SU0
    // Pattern: 0101 1110 000 Rm 0 opcode 00 Rn Rd (bit 14=0 for SHA1)
    // SHA1C:   0x5e000000  (opcode=00)
    // SHA1P:   0x5e001000  (opcode=01)
    // SHA1M:   0x5e002000  (opcode=10)
    // SHA1SU0: 0x5e003000  (opcode=11)
    // Mask 0xffe04c00 includes bit 14 to distinguish from SHA256 (bit14=1)
    if ((insn & 0xffe04c00) == 0x5e000000) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t opcode = (insn >> 12) & 0x3;

        void *gadget = NULL;
        switch (opcode) {
            case 0: gadget = gadget_sha1c; break;
            case 1: gadget = gadget_sha1p; break;
            case 2: gadget = gadget_sha1m; break;
            case 3: gadget = gadget_sha1su0; break;
        }
        if (gadget) {
            gen(state, (unsigned long) gadget);
            gen(state, rd | (rn << 8) | (rm << 16));
            return 1;
        }
    }

    // SHA256 three-register: SHA256H, SHA256H2, SHA256SU1
    // Pattern: 0101 1110 000 Rm 0 opcode 00 Rn Rd (opcode in bits 13-12, bit 14=1 for SHA256)
    // SHA256H:   0x5e004000  (opcode=00)
    // SHA256H2:  0x5e005000  (opcode=01)
    // SHA256SU1: 0x5e006000  (opcode=10)
    // Mask 0xffe04c00 includes bit 14 to distinguish from SHA1 (bit14=0)
    if ((insn & 0xffe04c00) == 0x5e004000) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t opcode = (insn >> 12) & 0x3;

        void *gadget = NULL;
        switch (opcode) {
            case 0: gadget = gadget_sha256h; break;
            case 1: gadget = gadget_sha256h2; break;
            case 2: gadget = gadget_sha256su1; break;
        }
        if (gadget) {
            gen(state, (unsigned long) gadget);
            gen(state, rd | (rn << 8) | (rm << 16));
            return 1;
        }
    }

    // SHA512SU0: SHA512 schedule update 0 (two-register)
    // Pattern: 1100 1110 1100 0000 1000 0 Rn Rd (0xcec08000)
    if ((insn & 0xfffffc00) == 0xcec08000) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        gen(state, (unsigned long) gadget_sha512su0);
        gen(state, rd | (rn << 8));
        return 1;
    }

    // SHA512H: SHA512 hash update part 1 (three-register)
    // Pattern: 1100 1110 011 Rm 1000 00 Rn Rd (0xce608000)
    if ((insn & 0xffe0fc00) == 0xce608000) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rm = (insn >> 16) & 0x1f;
        gen(state, (unsigned long) gadget_sha512h);
        gen(state, rd | (rn << 8) | (rm << 16));
        return 1;
    }

    // SHA512H2: SHA512 hash update part 2 (three-register)
    // Pattern: 1100 1110 011 Rm 1000 01 Rn Rd (0xce608400)
    if ((insn & 0xffe0fc00) == 0xce608400) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rm = (insn >> 16) & 0x1f;
        gen(state, (unsigned long) gadget_sha512h2);
        gen(state, rd | (rn << 8) | (rm << 16));
        return 1;
    }

    // SHA512SU1: SHA512 schedule update 1 (three-register)
    // Pattern: 1100 1110 011 Rm 1000 10 Rn Rd (0xce608800)
    if ((insn & 0xffe0fc00) == 0xce608800) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rm = (insn >> 16) & 0x1f;
        gen(state, (unsigned long) gadget_sha512su1);
        gen(state, rd | (rn << 8) | (rm << 16));
        return 1;
    }

    // SM4E: SM4 round (two-register)
    // Pattern: 1100 1110 1100 0000 1000 01 Rn Rd (0xcec08400)
    if ((insn & 0xfffffc00) == 0xcec08400) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        gen(state, (unsigned long) gadget_sm4e);
        gen(state, rd | (rn << 8));
        return 1;
    }

    // SM3PARTW1: SM3 message schedule update (three-register)
    // Pattern: 1100 1110 0110 0000 1100 00 Rm Rn Rd (0xce60c000)
    if ((insn & 0xffe0fc00) == 0xce60c000) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rm = (insn >> 16) & 0x1f;
        gen(state, (unsigned long) gadget_sm3partw1);
        gen(state, rd | (rn << 8) | (rm << 16));
        return 1;
    }

    // EOR3: XOR of three vectors (four-register)
    // Pattern: 1100 1110 0000 0000 1000 00 Rm Ra Rn Rd (0xce000000)
    if ((insn & 0xffe08000) == 0xce000000) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t ra = (insn >> 10) & 0x1f;
        uint32_t rm = (insn >> 16) & 0x1f;
        gen(state, (unsigned long) gadget_eor3);
        gen(state, rd | (rn << 8) | (rm << 16) | (ra << 24));
        return 1;
    }

    // PMULL: Polynomial Multiply Long
    // Pattern: 0 Q 00 1110 size 1 Rm 1110 00 Rn Rd
    // PMULL (8B):  0x0e20e000  (Q=0, size=00)
    // PMULL2 (16B): 0x4e20e000 (Q=1, size=00)
    // PMULL (1D):  0x0ee0e000  (Q=0, size=11)
    // PMULL2 (2D): 0x4ee0e000  (Q=1, size=11)
    if ((insn & 0xbf20fc00) == 0x0e20e000) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t rm = (insn >> 16) & 0x1f;
        uint32_t Q = (insn >> 30) & 1;
        uint32_t size = (insn >> 22) & 0x3;


        gen(state, (unsigned long) gadget_pmull);
        gen(state, rd | (rn << 8) | (rm << 16) | (Q << 24) | (size << 26));
        return 1;
    }

    // FCVTZS/FCVTZU (scalar, integer) - SIMD scalar form
    // Convert floating-point to integer (result in SIMD register)
    // Encoding: 01 U 11110 1 sz 100001 opcode Rn Rd
    // FCVTZS: U=0, opcode=101110 (0x2e)
    // FCVTZU: U=1, opcode=101110 (0x2e)
    // sz=0: single (S), sz=1: double (D)
    // Mask 0xdfbffc00 checks fixed bits, ignores U (bit29), sz (bit22), Rn, Rd
    if ((insn & 0xdfbffc00) == 0x5ea1b800) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t sz = (insn >> 22) & 1;
        uint32_t U = (insn >> 29) & 1;

        void *gadget = U ? gadget_fcvtzu_simd_scalar : gadget_fcvtzs_simd_scalar;
        gen(state, (unsigned long) gadget);
        gen(state, rd | (rn << 8) | (sz << 16));
        return 1;
    }

    // UCVTF/SCVTF (scalar, integer) - SIMD scalar form
    // Convert integer to floating-point (result in SIMD register)
    // Encoding: 01 U 11110 0 sz 1 00001 110110 Rn Rd
    // SCVTF: U=0 (signed)
    // UCVTF: U=1 (unsigned)
    // sz=0: single (S), sz=1: double (D)
    // Mask 0xdfbffc00 checks fixed bits, ignores U (bit29), sz (bit22), Rn, Rd
    if ((insn & 0xdfbffc00) == 0x5e21d800) {
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;
        uint32_t sz = (insn >> 22) & 1;
        uint32_t U = (insn >> 29) & 1;

        void *gadget = U ? gadget_ucvtf_simd_scalar : gadget_scvtf_simd_scalar;
        gen(state, (unsigned long) gadget);
        gen(state, rd | (rn << 8) | (sz << 16));
        return 1;
    }

    // SHL/SSHR/USHR (scalar, immediate) - Scalar shift by immediate
    // Encoding: 01 U 11111 0 immh immb opcode Rn Rd
    // SHL:  U=0, opcode=01010 (0x0a)
    // SSHR: U=0, opcode=00000 (0x00)
    // USHR: U=1, opcode=00000 (0x00)
    // immh determines element size: 1xxx=64-bit, 01xx=32-bit, 001x=16-bit, 0001=8-bit
    // Mask 0xdf800400 checks bits 31:30, 28:24, 23, 10 (fixed bits)
    if ((insn & 0xdf800400) == 0x5f000400) {
        uint32_t U = (insn >> 29) & 1;
        uint32_t immh = (insn >> 19) & 0xf;
        uint32_t immb = (insn >> 16) & 0x7;
        uint32_t opcode = (insn >> 11) & 0x1f;
        uint32_t rd = insn & 0x1f;
        uint32_t rn = (insn >> 5) & 0x1f;

        // Determine element size and shift amount from immh:immb
        int esize = -1;
        int shift = 0;
        int immhb = (immh << 3) | immb;

        if (immh & 0x8) {
            esize = 3;  // 64-bit
            shift = immhb - 64;  // For SHL: shift = immh:immb - 64
        } else if (immh & 0x4) {
            esize = 2;  // 32-bit
            shift = immhb - 32;
        } else if (immh & 0x2) {
            esize = 1;  // 16-bit
            shift = immhb - 16;
        } else if (immh & 0x1) {
            esize = 0;  // 8-bit
            shift = immhb - 8;
        }

        if (esize < 0) {
            gen_interrupt(state, INT_UNDEFINED);
            return 0;
        }

        void *gadget = NULL;
        if (U == 0 && opcode == 0x0a) {
            // SHL (scalar)
            gadget = gadget_shl_imm_scalar;
        } else if (U == 0 && opcode == 0x00) {
            // SSHR (scalar) - for SSHR, shift = (esize*8*2) - immh:immb
            if (esize == 3) shift = 128 - immhb;
            else if (esize == 2) shift = 64 - immhb;
            else if (esize == 1) shift = 32 - immhb;
            else shift = 16 - immhb;
            gadget = gadget_sshr_imm_scalar;
        } else if (U == 1 && opcode == 0x00) {
            // USHR (scalar)
            if (esize == 3) shift = 128 - immhb;
            else if (esize == 2) shift = 64 - immhb;
            else if (esize == 1) shift = 32 - immhb;
            else shift = 16 - immhb;
            gadget = gadget_ushr_imm_scalar;
        } else if (U == 0 && opcode == 0x02) {
            // SSRA (scalar) - signed shift right and accumulate
            if (esize == 3) shift = 128 - immhb;
            else if (esize == 2) shift = 64 - immhb;
            else if (esize == 1) shift = 32 - immhb;
            else shift = 16 - immhb;
            gadget = gadget_ssra_imm_scalar;
        } else if (U == 1 && opcode == 0x02) {
            // USRA (scalar) - unsigned shift right and accumulate
            if (esize == 3) shift = 128 - immhb;
            else if (esize == 2) shift = 64 - immhb;
            else if (esize == 1) shift = 32 - immhb;
            else shift = 16 - immhb;
            gadget = gadget_usra_imm_scalar;
        }

        if (gadget) {
            gen(state, (unsigned long) gadget);
            gen(state, rd | (rn << 8) | (shift << 16) | (esize << 24));
            return 1;
        }
    }

    // SIMD/FP instructions not implemented yet
    gen_interrupt(state, INT_UNDEFINED);
    return 0;
}
