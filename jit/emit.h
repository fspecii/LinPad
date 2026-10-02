// AArch64 instruction encoders used by the JIT. Register numbers are host
// registers; 31 is XZR or SP depending on the instruction (as in the ISA).
#ifndef ISH_JIT_EMIT_H
#define ISH_JIT_EMIT_H

#include <stdint.h>
#include <stdbool.h>

static inline uint32_t e_movz(int rd, uint16_t imm, int hw) { return 0xd2800000u | (hw << 21) | ((uint32_t)imm << 5) | rd; }
static inline uint32_t e_movk(int rd, uint16_t imm, int hw) { return 0xf2800000u | (hw << 21) | ((uint32_t)imm << 5) | rd; }
static inline uint32_t e_movn(int rd, uint16_t imm, int hw) { return 0x92800000u | (hw << 21) | ((uint32_t)imm << 5) | rd; }
// ADD/SUB Xd|SP, Xn|SP, #imm12 {, lsl #12}
static inline uint32_t e_add_imm(int rd, int rn, uint32_t imm12, int sh) { return 0x91000000u | (sh << 22) | (imm12 << 10) | (rn << 5) | rd; }
static inline uint32_t e_sub_imm(int rd, int rn, uint32_t imm12, int sh) { return 0xd1000000u | (sh << 22) | (imm12 << 10) | (rn << 5) | rd; }
// ADD Xd, Xn, Xm, <shift> #amt (shift: 0 lsl, 1 lsr, 2 asr)
static inline uint32_t e_add_sh(int rd, int rn, int rm, int shift, int amt) { return 0x8b000000u | (shift << 22) | (rm << 16) | (amt << 10) | (rn << 5) | rd; }
static inline uint32_t e_sub_sh(int rd, int rn, int rm, int shift, int amt) { return 0xcb000000u | (shift << 22) | (rm << 16) | (amt << 10) | (rn << 5) | rd; }
static inline uint32_t e_eor_sh(int rd, int rn, int rm, int shift, int amt) { return 0xca000000u | (shift << 22) | (rm << 16) | (amt << 10) | (rn << 5) | rd; }
// ADD Xd|SP, Xn|SP, Rm, <extend> #amt (option: 2 uxtw, 3 uxtx/lsl, 6 sxtw, 7 sxtx)
static inline uint32_t e_add_ext(int rd, int rn, int rm, int option, int amt) { return 0x8b200000u | (rm << 16) | (option << 13) | (amt << 10) | (rn << 5) | rd; }
static inline uint32_t e_mov(int rd, int rm) { return 0xaa0003e0u | (rm << 16) | rd; }
// UBFM Xd, Xn, #immr, #imms
static inline uint32_t e_ubfm(int rd, int rn, int immr, int imms) { return 0xd3400000u | (immr << 16) | (imms << 10) | (rn << 5) | rd; }
static inline uint32_t e_ubfx(int rd, int rn, int lsb, int width) { return e_ubfm(rd, rn, lsb, lsb + width - 1); }
static inline uint32_t e_lsr(int rd, int rn, int sh) { return e_ubfm(rd, rn, sh, 63); }
// Loads/stores, unsigned scaled offset (offset in bytes)
static inline uint32_t e_ldr_x(int rt, int rn, uint32_t off) { return 0xf9400000u | ((off / 8) << 10) | (rn << 5) | rt; }
static inline uint32_t e_str_x(int rt, int rn, uint32_t off) { return 0xf9000000u | ((off / 8) << 10) | (rn << 5) | rt; }
static inline uint32_t e_ldr_w(int rt, int rn, uint32_t off) { return 0xb9400000u | ((off / 4) << 10) | (rn << 5) | rt; }
static inline uint32_t e_str_w(int rt, int rn, uint32_t off) { return 0xb9000000u | ((off / 4) << 10) | (rn << 5) | rt; }
static inline uint32_t e_ldrb(int rt, int rn, uint32_t off) { return 0x39400000u | (off << 10) | (rn << 5) | rt; }
static inline uint32_t e_strb(int rt, int rn, uint32_t off) { return 0x39000000u | (off << 10) | (rn << 5) | rt; }
// LDP/STP X signed offset
static inline uint32_t e_ldp_x(int rt, int rt2, int rn, int off) { return 0xa9400000u | (((off / 8) & 0x7f) << 15) | (rt2 << 10) | (rn << 5) | rt; }
static inline uint32_t e_stp_x(int rt, int rt2, int rn, int off) { return 0xa9000000u | (((off / 8) & 0x7f) << 15) | (rt2 << 10) | (rn << 5) | rt; }
static inline uint32_t e_ldp_q(int rt, int rt2, int rn, int off) { return 0xad400000u | (((off / 16) & 0x7f) << 15) | (rt2 << 10) | (rn << 5) | rt; }
static inline uint32_t e_stp_q(int rt, int rt2, int rn, int off) { return 0xad000000u | (((off / 16) & 0x7f) << 15) | (rt2 << 10) | (rn << 5) | rt; }
static inline uint32_t e_stp_d_pre(int rt, int rt2, int rn, int off) { return 0x6d800000u | (((off / 8) & 0x7f) << 15) | (rt2 << 10) | (rn << 5) | rt; }
static inline uint32_t e_stp_d(int rt, int rt2, int rn, int off) { return 0x6d000000u | (((off / 8) & 0x7f) << 15) | (rt2 << 10) | (rn << 5) | rt; }
static inline uint32_t e_ldp_d(int rt, int rt2, int rn, int off) { return 0x6d400000u | (((off / 8) & 0x7f) << 15) | (rt2 << 10) | (rn << 5) | rt; }
// Branches (offset in words, filled by fixups when 0)
static inline uint32_t e_b(int32_t woff) { return 0x14000000u | ((uint32_t)woff & 0x3ffffff); }
static inline uint32_t e_bl(int32_t woff) { return 0x94000000u | ((uint32_t)woff & 0x3ffffff); }
static inline uint32_t e_bcond(int cond, int32_t woff) { return 0x54000000u | (((uint32_t)woff & 0x7ffff) << 5) | cond; }
static inline uint32_t e_cbz_x(int rt, int32_t woff) { return 0xb4000000u | (((uint32_t)woff & 0x7ffff) << 5) | rt; }
static inline uint32_t e_cbnz_x(int rt, int32_t woff) { return 0xb5000000u | (((uint32_t)woff & 0x7ffff) << 5) | rt; }
static inline uint32_t e_cbz_w(int rt, int32_t woff) { return 0x34000000u | (((uint32_t)woff & 0x7ffff) << 5) | rt; }
static inline uint32_t e_cbnz_w(int rt, int32_t woff) { return 0x35000000u | (((uint32_t)woff & 0x7ffff) << 5) | rt; }
static inline uint32_t e_br(int rn) { return 0xd61f0000u | (rn << 5); }
static inline uint32_t e_blr(int rn) { return 0xd63f0000u | (rn << 5); }
static inline uint32_t e_ret(void) { return 0xd65f03c0u; }
static inline uint32_t e_adr(int rd, int32_t boff) { return 0x10000000u | (((uint32_t)boff & 3) << 29) | ((((uint32_t)boff >> 2) & 0x7ffff) << 5) | rd; }
static inline uint32_t e_nop(void) { return 0xd503201fu; }
static inline uint32_t e_mrs_nzcv(int rt) { return 0xd53b4200u | rt; }
static inline uint32_t e_msr_nzcv(int rt) { return 0xd51b4200u | rt; }
static inline uint32_t e_mrs_fpcr(int rt) { return 0xd53b4400u | rt; }
static inline uint32_t e_msr_fpcr(int rt) { return 0xd51b4400u | rt; }
static inline uint32_t e_mrs_fpsr(int rt) { return 0xd53b4420u | rt; }
static inline uint32_t e_msr_fpsr(int rt) { return 0xd51b4420u | rt; }
static inline uint32_t e_mov_sp_from(int rn) { return e_add_imm(31, rn, 0, 0); }   // mov sp, xn
static inline uint32_t e_mov_from_sp(int rd) { return e_add_imm(rd, 31, 0, 0); }   // mov xd, sp

// Branch-field patching helpers (word offsets)
static inline uint32_t fix_b26(uint32_t insn, int32_t woff) { return (insn & 0xfc000000u) | ((uint32_t)woff & 0x3ffffff); }
static inline uint32_t fix_b19(uint32_t insn, int32_t woff) { return (insn & 0xff00001fu) | (((uint32_t)woff & 0x7ffff) << 5); }
static inline uint32_t fix_b14(uint32_t insn, int32_t woff) { return (insn & 0xfff8001fu) | (((uint32_t)woff & 0x3fff) << 5); }
static inline uint32_t fix_adr(uint32_t insn, int32_t boff) { return (insn & 0x9f00001fu) | (((uint32_t)boff & 3) << 29) | ((((uint32_t)boff >> 2) & 0x7ffff) << 5); }

#endif
