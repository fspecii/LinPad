/*
 * ARM64 Guest Memory Access Gadgets
 *
 * These gadgets handle memory load and store operations for ARM64 guest code.
 * Address is calculated and stored in _addr (x7) before load/store gadgets.
 *
 * Most operations use inline TLB lookup for fast-path performance.
 * Cross-page accesses and TLB misses fall through to C helpers.
 */

#include "gadgets.h"

.text

/*
 * Address calculation gadgets
 */

// Calculate address from base register + immediate offset
// Code stream: [gadget addr][rn | offset<<8]
// offset is a signed immediate starting at bit 8
// The width varies: imm9 for pre/post-indexed, larger for LDP/STP
// Using 16-bit signed extraction to handle all cases (max ±32K)
.gadget calc_addr_imm
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rn
    // Extract offset (16-bit signed) from bits 8-23 and sign-extend
    sbfx x10, x8, #8, #16   // sign-extend 16 bits from position 8

    // Load base register (or SP if rn == 31)
    add x11, _cpu, #CPU_x0
    cmp x9, #31
    b.eq 1f
    ldr x12, [x11, x9, lsl #3]
    and x12, x12, #0xffffffff   // truncate to 32-bit guest address
    b 2f
1:  ldr x12, [_cpu, #CPU_sp]
    and x12, x12, #0xffffffff
2:
    // Calculate address (32-bit base + signed offset)
    add _addr, x12, x10

    gret

// Calculate address for PC-relative literal loads
// Code stream: [gadget addr][64-bit target address]
// Used for LDR (literal) instructions
.gadget calc_addr_pc_rel
    ldr _addr, [_pc]
    add _pc, _pc, #8
    gret

// Calculate address from base register + register offset
// Code stream: [gadget addr][rn | rm<<8 | extend<<16 | shift<<24]
.gadget calc_addr_reg
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rn
    ubfx x10, x8, #8, #5    // rm
    ubfx x11, x8, #16, #3   // extend type
    ubfx x12, x8, #24, #3   // shift amount

    // Load base (truncate to 32-bit: guest addresses are 32-bit)
    add x13, _cpu, #CPU_x0
    cmp x9, #31
    b.eq 1f
    ldr x14, [x13, x9, lsl #3]
    and x14, x14, #0xffffffff
    b 2f
1:  ldr x14, [_cpu, #CPU_sp]
    and x14, x14, #0xffffffff
2:
    // Load index (truncate to 32-bit: guest register values used as index)
    cmp x10, #31
    b.eq 3f
    ldr x15, [x13, x10, lsl #3]
    and x15, x15, #0xffffffff
    b 4f
3:  mov x15, #0
4:
    // Apply extend based on option
    // option values: 0=UXTB,1=UXTH,2=UXTW,3=UXTX,4=SXTB,5=SXTH,6=SXTW,7=SXTX
    cmp x11, #4
    b.ge 6f
    cmp x11, #0
    b.eq 5f
    cmp x11, #1
    b.eq 7f
    cmp x11, #2
    b.eq 8f
    b 9f        // option==3 (UXTX) no-op
5:  and x15, x15, #0xff
    b 9f
7:  and x15, x15, #0xffff
    b 9f
8:  and x15, x15, #0xffffffff
    b 9f
6:  cmp x11, #4
    b.eq 10f
    cmp x11, #5
    b.eq 11f
    cmp x11, #6
    b.eq 12f
    b 9f        // option==7 (SXTX) no-op
10: sxtb x15, w15
    b 9f
11: sxth x15, w15
    b 9f
12: sxtw x15, w15
9:
    // Apply shift
    lsl x15, x15, x12

    // Calculate address (full 64-bit for ARM64 guest)
    add _addr, x14, x15
    gret

/*
 * Load gadgets with inline TLB lookup
 * Address should be in _addr (x7)
 * Result goes to _tmp (x0)
 *
 * Fast path: inline TLB lookup (~12 instructions on TLB hit)
 * Slow path: call handle_read_miss on TLB miss, crosspage_load on page crossing
 */

// LDR Xn, [addr] - 64-bit load (inline TLB)
.gadget load64
    mov x24, _addr
    read_prep 64, load64_1
    ldr _tmp, [_addr]
    mov _addr, x24
    gret
    read_bullshit 64, load64_1

// LDR Wn, [addr] - 32-bit load (inline TLB)
.gadget load32
    mov x24, _addr
    read_prep 32, load32_1
    ldr w0, [_addr]
    mov _addr, x24
    gret
    read_bullshit 32, load32_1

// LDRH Wn, [addr] - 16-bit load (inline TLB)
.gadget load16
    mov x24, _addr
    read_prep 16, load16_1
    ldrh w0, [_addr]
    mov _addr, x24
    gret
    read_bullshit 16, load16_1

// LDRB Wn, [addr] - 8-bit load (inline TLB)
.gadget load8
    mov x24, _addr
    read_prep 8, load8_1
    ldrb w0, [_addr]
    mov _addr, x24
    gret
    read_bullshit 8, load8_1

// LDRSW Xn, [addr] - 32-bit load with sign-extend to 64 (inline TLB)
.gadget load32_sx
    mov x24, _addr
    read_prep 32, load32_sx_1
    ldrsw _tmp, [_addr]
    mov _addr, x24
    gret
    read_bullshit 32, load32_sx_1

// LDRSH Wn, [addr] - 16-bit load with sign-extend to 32 (inline TLB)
.gadget load16_sx32
    mov x24, _addr
    read_prep 16, load16_sx32_1
    ldrsh w0, [_addr]
    mov _addr, x24
    gret
    read_bullshit 16, load16_sx32_1

// LDRSH Xn, [addr] - 16-bit load with sign-extend to 64 (inline TLB)
.gadget load16_sx64
    mov x24, _addr
    read_prep 16, load16_sx64_1
    ldrsh _tmp, [_addr]
    mov _addr, x24
    gret
    read_bullshit 16, load16_sx64_1

// LDRSB Wn, [addr] - 8-bit load with sign-extend to 32 (inline TLB)
.gadget load8_sx32
    mov x24, _addr
    read_prep 8, load8_sx32_1
    ldrsb w0, [_addr]
    mov _addr, x24
    gret
    read_bullshit 8, load8_sx32_1

// LDRSB Xn, [addr] - 8-bit load with sign-extend to 64 (inline TLB)
.gadget load8_sx64
    mov x24, _addr
    read_prep 8, load8_sx64_1
    ldrsb _tmp, [_addr]
    mov _addr, x24
    gret
    read_bullshit 8, load8_sx64_1

/*
 * Store gadgets with inline TLB lookup
 * Address should be in _addr (x7), value in _tmp (x0)
 * write_prep uses x8-x10, preserving x0 (the value) and x11+
 */

// STR Xn, [addr] - 64-bit store (inline TLB)
.gadget store64
    mov x24, _addr
    mov x11, x0              // save 64-bit value (x11 not clobbered by write_prep)
    write_prep 64, store64_1
    str x11, [_addr]
    write_done 64, store64_1
    mov _addr, x24
    gret
    write_bullshit 64, store64_1

// STR Wn, [addr] - 32-bit store (inline TLB)
.gadget store32
    mov x24, _addr
    mov w11, w0
    write_prep 32, store32_1
    str w11, [_addr]
    write_done 32, store32_1
    mov _addr, x24
    gret
    write_bullshit 32, store32_1

// STRH Wn, [addr] - 16-bit store (inline TLB)
.gadget store16
    mov x24, _addr
    mov w11, w0
    write_prep 16, store16_1
    strh w11, [_addr]
    write_done 16, store16_1
    mov _addr, x24
    gret
    write_bullshit 16, store16_1

// STRB Wn, [addr] - 8-bit store (inline TLB)
.gadget store8
    mov x24, _addr
    mov w11, w0
    write_prep 8, store8_1
    strb w11, [_addr]
    write_done 8, store8_1
    mov _addr, x24
    gret
    write_bullshit 8, store8_1

/*
 * Fused load/store gadgets for unsigned-offset addressing
 *
 * These combine calc_addr_imm + load/store + store_reg/load_reg into a single
 * gadget dispatch, eliminating 2 gret calls (4 host instructions) per operation.
 *
 * Code stream: [gadget addr][rd_or_rt | rn<<8 | offset<<16]
 *   bits 0-4:   rd (load dest) or rt (store source)
 *   bits 8-12:  rn (base register)
 *   bits 16-31: offset (unsigned, already scaled by gen.c)
 *
 * Register usage:
 *   x22: packed parameter (callee-saved, survives TLB miss)
 *   x23: store value (callee-saved, survives TLB miss)
 *   x24: saved guest _addr (callee-saved, survives TLB miss)
 *   x11: _cpu + CPU_x0 (scratch, used before TLB macros)
 *   x8-x10, x12: scratch (used before TLB macros)
 */

// LDR Xd, [Xn, #imm] - fused 64-bit load with unsigned offset
.gadget load64_imm
    ldr x22, [_pc]
    add _pc, _pc, #8
    ubfx x9, x22, #8, #5       // rn
    lsr x10, x22, #16           // offset (unsigned)
    add x11, _cpu, #CPU_x0
    cmp x9, #31
    b.eq 1f
    ldr x12, [x11, x9, lsl #3]
    and x12, x12, #0xffffffff
    b 2f
1:  ldr x12, [_cpu, #CPU_sp]
2:  add _addr, x12, x10
    mov x24, _addr
    read_prep 64, load64_imm_1
    ldr _tmp, [_addr]
    and x8, x22, #0x1f          // rd
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 3f
    str _tmp, [x11, x8, lsl #3]
3:  mov _addr, x24
    gret
    read_bullshit 64, load64_imm_1

// LDR Wd, [Xn, #imm] - fused 32-bit load with unsigned offset
.gadget load32_imm
    ldr x22, [_pc]
    add _pc, _pc, #8
    ubfx x9, x22, #8, #5
    lsr x10, x22, #16
    add x11, _cpu, #CPU_x0
    cmp x9, #31
    b.eq 1f
    ldr x12, [x11, x9, lsl #3]
    and x12, x12, #0xffffffff
    b 2f
1:  ldr x12, [_cpu, #CPU_sp]
2:  add _addr, x12, x10
    mov x24, _addr
    read_prep 32, load32_imm_1
    ldr w0, [_addr]
    and x8, x22, #0x1f
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 3f
    str x0, [x11, x8, lsl #3]   // zero-extended 32→64
3:  mov _addr, x24
    gret
    read_bullshit 32, load32_imm_1

// LDRH Wd, [Xn, #imm] - fused 16-bit load with unsigned offset
.gadget load16_imm
    ldr x22, [_pc]
    add _pc, _pc, #8
    ubfx x9, x22, #8, #5
    lsr x10, x22, #16
    add x11, _cpu, #CPU_x0
    cmp x9, #31
    b.eq 1f
    ldr x12, [x11, x9, lsl #3]
    and x12, x12, #0xffffffff
    b 2f
1:  ldr x12, [_cpu, #CPU_sp]
2:  add _addr, x12, x10
    mov x24, _addr
    read_prep 16, load16_imm_1
    ldrh w0, [_addr]
    and x8, x22, #0x1f
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 3f
    str x0, [x11, x8, lsl #3]   // zero-extended 16→64
3:  mov _addr, x24
    gret
    read_bullshit 16, load16_imm_1

// LDRB Wd, [Xn, #imm] - fused 8-bit load with unsigned offset
.gadget load8_imm
    ldr x22, [_pc]
    add _pc, _pc, #8
    ubfx x9, x22, #8, #5
    lsr x10, x22, #16
    add x11, _cpu, #CPU_x0
    cmp x9, #31
    b.eq 1f
    ldr x12, [x11, x9, lsl #3]
    and x12, x12, #0xffffffff  // 32-bit load: truncates to guest address
    b 2f
1:  ldr w12, [_cpu, #CPU_sp]
2:  add _addr, x12, x10
    mov x24, _addr
    read_prep 8, load8_imm_1
    ldrb w0, [_addr]
    and x8, x22, #0x1f
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 3f
    str x0, [x11, x8, lsl #3]   // zero-extended 8→64
3:  mov _addr, x24
    gret
    read_bullshit 8, load8_imm_1

// LDRSW Xd, [Xn, #imm] - fused 32-bit sign-extending load with unsigned offset
.gadget load32_sx_imm
    ldr x22, [_pc]
    add _pc, _pc, #8
    ubfx x9, x22, #8, #5
    lsr x10, x22, #16
    add x11, _cpu, #CPU_x0
    cmp x9, #31
    b.eq 1f
    ldr x12, [x11, x9, lsl #3]
    and x12, x12, #0xffffffff
    b 2f
1:  ldr x12, [_cpu, #CPU_sp]
2:  add _addr, x12, x10
    mov x24, _addr
    read_prep 32, load32_sx_imm_1
    ldrsw _tmp, [_addr]
    and x8, x22, #0x1f
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 3f
    str _tmp, [x11, x8, lsl #3]
3:  mov _addr, x24
    gret
    read_bullshit 32, load32_sx_imm_1

// STR Xt, [Xn, #imm] - fused 64-bit store with unsigned offset
.gadget store64_imm
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x8, x22, #0x1f          // rt (source register)
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 1f
    ldr x23, [x11, x8, lsl #3]
    b 2f
1:  mov x23, #0                 // XZR
2:  ubfx x9, x22, #8, #5       // rn
    lsr x10, x22, #16           // offset
    cmp x9, #31
    b.eq 3f
    ldr x12, [x11, x9, lsl #3]
    and x12, x12, #0xffffffff
    b 4f
3:  ldr x12, [_cpu, #CPU_sp]
4:  add _addr, x12, x10
    mov x24, _addr
    write_prep 64, store64_imm_1
    str x23, [_addr]
    write_done 64, store64_imm_1
    mov _addr, x24
    gret
    write_bullshit 64, store64_imm_1

// STR Wt, [Xn, #imm] - fused 32-bit store with unsigned offset
.gadget store32_imm
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x8, x22, #0x1f
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 1f
    ldr x23, [x11, x8, lsl #3]
    b 2f
1:  mov x23, #0
2:  ubfx x9, x22, #8, #5
    lsr x10, x22, #16
    cmp x9, #31
    b.eq 3f
    ldr x12, [x11, x9, lsl #3]
    and x12, x12, #0xffffffff
    b 4f
3:  ldr x12, [_cpu, #CPU_sp]
4:  add _addr, x12, x10
    mov x24, _addr
    write_prep 32, store32_imm_1
    str w23, [_addr]
    write_done 32, store32_imm_1
    mov _addr, x24
    gret
    write_bullshit 32, store32_imm_1

// STRH Wt, [Xn, #imm] - fused 16-bit store with unsigned offset
.gadget store16_imm
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x8, x22, #0x1f
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 1f
    ldr x23, [x11, x8, lsl #3]
    b 2f
1:  mov x23, #0
2:  ubfx x9, x22, #8, #5
    lsr x10, x22, #16
    cmp x9, #31
    b.eq 3f
    ldr x12, [x11, x9, lsl #3]
    and x12, x12, #0xffffffff
    b 4f
3:  ldr x12, [_cpu, #CPU_sp]
4:  add _addr, x12, x10
    mov x24, _addr
    write_prep 16, store16_imm_1
    strh w23, [_addr]
    write_done 16, store16_imm_1
    mov _addr, x24
    gret
    write_bullshit 16, store16_imm_1

// STRB Wt, [Xn, #imm] - fused 8-bit store with unsigned offset
.gadget store8_imm
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x8, x22, #0x1f
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 1f
    ldr x23, [x11, x8, lsl #3]
    b 2f
1:  mov x23, #0
2:  ubfx x9, x22, #8, #5
    lsr x10, x22, #16
    cmp x9, #31
    b.eq 3f
    ldr x12, [x11, x9, lsl #3]
    and x12, x12, #0xffffffff
    b 4f
3:  ldr x12, [_cpu, #CPU_sp]
4:  add _addr, x12, x10
    mov x24, _addr
    write_prep 8, store8_imm_1
    strb w23, [_addr]
    write_done 8, store8_imm_1
    mov _addr, x24
    gret
    write_bullshit 8, store8_imm_1

/*
 * Fused register-offset load/store gadgets
 *
 * Combine calc_addr_reg + load/store + store_reg/load_reg into a single dispatch
 * for the common case: option=3 (UXTX/LSL, no extend on index register).
 *
 * Code stream: [gadget addr][rd_or_rt | rn<<8 | rm<<16 | shift<<24]
 *   bits 0-4:   rd (load dest) or rt (store source)
 *   bits 8-12:  rn (base register)
 *   bits 16-20: rm (index register)
 *   bits 24-26: shift amount (0-4)
 *
 * Register usage:
 *   x22: packed parameter (callee-saved)
 *   x23: store value (callee-saved)
 *   x24: saved guest _addr (callee-saved)
 *   x11: scratch (base of CPU_x0), used before TLB macros
 *   x8-x10, x12-x15: scratch, used before TLB macros
 */

// LDRSW Xd, [Xn, Xm{, LSL #shift}] - fused sign-extending 32-bit load, register offset
.gadget load32_sx_reg
    ldr x22, [_pc]
    add _pc, _pc, #8
    ubfx x9, x22, #8, #5        // rn
    ubfx x10, x22, #16, #5      // rm
    ubfx x12, x22, #24, #3      // shift
    add x11, _cpu, #CPU_x0
    // Load base
    cmp x9, #31
    b.eq 1f
    ldr x14, [x11, x9, lsl #3]
    and x14, x14, #0xffffffff
    b 2f
1:  ldr x14, [_cpu, #CPU_sp]
    and x14, x14, #0xffffffff
2:  // Load index
    cmp x10, #31
    b.eq 3f
    ldr x15, [x11, x10, lsl #3]
    and x15, x15, #0xffffffff
    b 4f
3:  mov x15, #0
4:  lsl x15, x15, x12           // apply shift
    add _addr, x14, x15
    mov x24, _addr
    read_prep 32, load32_sx_reg_1
    ldrsw _tmp, [_addr]
    and x8, x22, #0x1f          // rd
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 5f
    str _tmp, [x11, x8, lsl #3]
5:  mov _addr, x24
    gret
    read_bullshit 32, load32_sx_reg_1

// LDR Xd, [Xn, Xm{, LSL #shift}] - fused 64-bit load, register offset
.gadget load64_reg
    ldr x22, [_pc]
    add _pc, _pc, #8
    ubfx x9, x22, #8, #5
    ubfx x10, x22, #16, #5
    ubfx x12, x22, #24, #3
    add x11, _cpu, #CPU_x0
    cmp x9, #31
    b.eq 1f
    ldr x14, [x11, x9, lsl #3]
    and x14, x14, #0xffffffff
    b 2f
1:  ldr x14, [_cpu, #CPU_sp]
    and x14, x14, #0xffffffff
2:  cmp x10, #31
    b.eq 3f
    ldr x15, [x11, x10, lsl #3]
    and x15, x15, #0xffffffff
    b 4f
3:  mov x15, #0
4:  lsl x15, x15, x12
    add _addr, x14, x15
    mov x24, _addr
    read_prep 64, load64_reg_1
    ldr _tmp, [_addr]
    and x8, x22, #0x1f
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 5f
    str _tmp, [x11, x8, lsl #3]
5:  mov _addr, x24
    gret
    read_bullshit 64, load64_reg_1

// LDR Wd, [Xn, Xm{, LSL #shift}] - fused 32-bit load, register offset
.gadget load32_reg
    ldr x22, [_pc]
    add _pc, _pc, #8
    ubfx x9, x22, #8, #5
    ubfx x10, x22, #16, #5
    ubfx x12, x22, #24, #3
    add x11, _cpu, #CPU_x0
    cmp x9, #31
    b.eq 1f
    ldr x14, [x11, x9, lsl #3]
    and x14, x14, #0xffffffff
    b 2f
1:  ldr x14, [_cpu, #CPU_sp]
    and x14, x14, #0xffffffff
2:  cmp x10, #31
    b.eq 3f
    ldr x15, [x11, x10, lsl #3]
    and x15, x15, #0xffffffff
    b 4f
3:  mov x15, #0
4:  lsl x15, x15, x12
    add _addr, x14, x15
    mov x24, _addr
    read_prep 32, load32_reg_1
    ldr w0, [_addr]
    and x8, x22, #0x1f
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 5f
    str x0, [x11, x8, lsl #3]   // zero-extended 32→64
5:  mov _addr, x24
    gret
    read_bullshit 32, load32_reg_1

// LDRH Wd, [Xn, Xm{, LSL #shift}] - fused 16-bit load, register offset
.gadget load16_reg
    ldr x22, [_pc]
    add _pc, _pc, #8
    ubfx x9, x22, #8, #5
    ubfx x10, x22, #16, #5
    ubfx x12, x22, #24, #3
    add x11, _cpu, #CPU_x0
    cmp x9, #31
    b.eq 1f
    ldr x14, [x11, x9, lsl #3]
    and x14, x14, #0xffffffff
    b 2f
1:  ldr x14, [_cpu, #CPU_sp]
    and x14, x14, #0xffffffff
2:  cmp x10, #31
    b.eq 3f
    ldr x15, [x11, x10, lsl #3]
    and x15, x15, #0xffffffff
    b 4f
3:  mov x15, #0
4:  lsl x15, x15, x12
    add _addr, x14, x15
    mov x24, _addr
    read_prep 16, load16_reg_1
    ldrh w0, [_addr]
    and x8, x22, #0x1f
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 5f
    str x0, [x11, x8, lsl #3]
5:  mov _addr, x24
    gret
    read_bullshit 16, load16_reg_1

// LDRB Wd, [Xn, Xm{, LSL #shift}] - fused 8-bit load, register offset
.gadget load8_reg
    ldr x22, [_pc]
    add _pc, _pc, #8
    ubfx x9, x22, #8, #5
    ubfx x10, x22, #16, #5
    ubfx x12, x22, #24, #3
    add x11, _cpu, #CPU_x0
    cmp x9, #31
    b.eq 1f
    ldr x14, [x11, x9, lsl #3]
    and x14, x14, #0xffffffff
    b 2f
1:  ldr x14, [_cpu, #CPU_sp]
    and x14, x14, #0xffffffff
2:  cmp x10, #31
    b.eq 3f
    ldr x15, [x11, x10, lsl #3]
    and x15, x15, #0xffffffff
    b 4f
3:  mov x15, #0
4:  lsl x15, x15, x12
    add _addr, x14, x15
    mov x24, _addr
    read_prep 8, load8_reg_1
    ldrb w0, [_addr]
    and x8, x22, #0x1f
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 5f
    str x0, [x11, x8, lsl #3]
5:  mov _addr, x24
    gret
    read_bullshit 8, load8_reg_1

// STR Xt, [Xn, Xm{, LSL #shift}] - fused 64-bit store, register offset
.gadget store64_reg
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x8, x22, #0x1f          // rt (source register)
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 1f
    ldr x23, [x11, x8, lsl #3]
    b 2f
1:  mov x23, #0
2:  ubfx x9, x22, #8, #5       // rn
    ubfx x10, x22, #16, #5      // rm
    ubfx x12, x22, #24, #3      // shift
    cmp x9, #31
    b.eq 3f
    ldr x14, [x11, x9, lsl #3]
    and x14, x14, #0xffffffff
    b 4f
3:  ldr x14, [_cpu, #CPU_sp]
    and x14, x14, #0xffffffff
4:  cmp x10, #31
    b.eq 5f
    ldr x15, [x11, x10, lsl #3]
    and x15, x15, #0xffffffff
    b 6f
5:  mov x15, #0
6:  lsl x15, x15, x12
    add _addr, x14, x15
    mov x24, _addr
    write_prep 64, store64_reg_1
    str x23, [_addr]
    write_done 64, store64_reg_1
    mov _addr, x24
    gret
    write_bullshit 64, store64_reg_1

// STR Wt, [Xn, Xm{, LSL #shift}] - fused 32-bit store, register offset
.gadget store32_reg
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x8, x22, #0x1f
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 1f
    ldr x23, [x11, x8, lsl #3]
    b 2f
1:  mov x23, #0
2:  ubfx x9, x22, #8, #5
    ubfx x10, x22, #16, #5
    ubfx x12, x22, #24, #3
    cmp x9, #31
    b.eq 3f
    ldr x14, [x11, x9, lsl #3]
    and x14, x14, #0xffffffff
    b 4f
3:  ldr x14, [_cpu, #CPU_sp]
    and x14, x14, #0xffffffff
4:  cmp x10, #31
    b.eq 5f
    ldr x15, [x11, x10, lsl #3]
    and x15, x15, #0xffffffff
    b 6f
5:  mov x15, #0
6:  lsl x15, x15, x12
    add _addr, x14, x15
    mov x24, _addr
    write_prep 32, store32_reg_1
    str w23, [_addr]
    write_done 32, store32_reg_1
    mov _addr, x24
    gret
    write_bullshit 32, store32_reg_1

// STRH Wt, [Xn, Xm{, LSL #shift}] - fused 16-bit store, register offset
.gadget store16_reg
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x8, x22, #0x1f
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 1f
    ldr x23, [x11, x8, lsl #3]
    b 2f
1:  mov x23, #0
2:  ubfx x9, x22, #8, #5
    ubfx x10, x22, #16, #5
    ubfx x12, x22, #24, #3
    cmp x9, #31
    b.eq 3f
    ldr x14, [x11, x9, lsl #3]
    and x14, x14, #0xffffffff
    b 4f
3:  ldr x14, [_cpu, #CPU_sp]
    and x14, x14, #0xffffffff
4:  cmp x10, #31
    b.eq 5f
    ldr x15, [x11, x10, lsl #3]
    and x15, x15, #0xffffffff
    b 6f
5:  mov x15, #0
6:  lsl x15, x15, x12
    add _addr, x14, x15
    mov x24, _addr
    write_prep 16, store16_reg_1
    strh w23, [_addr]
    write_done 16, store16_reg_1
    mov _addr, x24
    gret
    write_bullshit 16, store16_reg_1

// STRB Wt, [Xn, Xm{, LSL #shift}] - fused 8-bit store, register offset
.gadget store8_reg
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x8, x22, #0x1f
    add x11, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 1f
    ldr x23, [x11, x8, lsl #3]
    b 2f
1:  mov x23, #0
2:  ubfx x9, x22, #8, #5
    ubfx x10, x22, #16, #5
    ubfx x12, x22, #24, #3
    cmp x9, #31
    b.eq 3f
    ldr x14, [x11, x9, lsl #3]
    and x14, x14, #0xffffffff
    b 4f
3:  ldr x14, [_cpu, #CPU_sp]
    and x14, x14, #0xffffffff
4:  cmp x10, #31
    b.eq 5f
    ldr x15, [x11, x10, lsl #3]
    and x15, x15, #0xffffffff
    b 6f
5:  mov x15, #0
6:  lsl x15, x15, x12
    add _addr, x14, x15
    mov x24, _addr
    write_prep 8, store8_reg_1
    strb w23, [_addr]
    write_done 8, store8_reg_1
    mov _addr, x24
    gret
    write_bullshit 8, store8_reg_1

/*
 * Atomic memory operations (LSE)
 * Address should be in _addr (x7)
 *
 * atomic_rmw code stream: [gadget addr][rs | size<<8 | op<<16]
 *   size: 0=8-bit, 1=16-bit, 2=32-bit, 3=64-bit
 *   op:   0=LDADD, 1=LDCLR, 2=LDEOR, 3=LDSET, 4=LDSMAX, 5=LDSMIN, 6=LDUMAX, 7=LDUMIN, 8=SWP
 *
 * atomic_cas code stream: [gadget addr][rs | rt<<8 | size<<16]
 *   rs: expected (and result) register
 *   rt: new value register
 */

.gadget atomic_rmw
    mov x23, _addr              // save address
    ldr x22, [_pc]              // load params
    add _pc, _pc, #8

    and x9, x22, #0x1f          // rs
    ubfx x10, x22, #8, #2       // size
    ubfx x11, x22, #16, #4      // op

    // Load Rs value (or zero for XZR)
    add x12, _cpu, #CPU_x0
    cmp x9, #31
    b.eq 1f
    ldr x13, [x12, x9, lsl #3]
    b 2f
1:  mov x13, #0
2:
    // Call C helper: c_atomic_rmw(tlb, addr, value, size, op, &old)
    sub sp, sp, #16
    save_c
    sub x0, _tlb, #TLB_entries
    mov x1, x23                 // address (64-bit)
    mov x2, x13                 // value
    mov w3, w10                 // size
    mov w4, w11                 // op
    add x5, sp, #0xa0           // &old (adjust for save_c)
    bl NAME(c_atomic_rmw)
    mov w19, w0
    restore_c
    mov _addr, x23              // restore _addr (restore_c clobbers x7)

    cbnz w19, atomic_rmw_segfault
    ldr _tmp, [sp]              // old value
    add sp, sp, #16
    gret

atomic_rmw_segfault:
    add sp, sp, #16
    str x23, [_cpu, #CPU_segfault_addr]  // 64-bit address for ARM64 guest
    mov w8, #1
    strb w8, [_cpu, #CPU_segfault_was_write]
    mov w0, #INT_GPF
    b fiber_exit

.gadget atomic_cas
    mov x23, _addr              // save address
    ldr x22, [_pc]              // load params
    add _pc, _pc, #8

    and x9, x22, #0x1f          // rs (expected/result)
    ubfx x10, x22, #8, #5       // rt (new value)
    ubfx x11, x22, #16, #2      // size

    add x12, _cpu, #CPU_x0
    // Load expected value (rs)
    cmp x9, #31
    b.eq 3f
    ldr x13, [x12, x9, lsl #3]
    b 4f
3:  mov x13, #0
4:
    // Load desired value (rt)
    cmp x10, #31
    b.eq 5f
    ldr x14, [x12, x10, lsl #3]
    b 6f
5:  mov x14, #0
6:
    // Call C helper: c_atomic_cas(tlb, addr, expected, desired, size, &old)
    sub sp, sp, #16
    save_c
    sub x0, _tlb, #TLB_entries
    mov x1, x23                 // address (64-bit)
    mov x2, x13                 // expected
    mov x3, x14                 // desired
    mov w4, w11                 // size
    add x5, sp, #0xa0           // &old
    bl NAME(c_atomic_cas)
    mov w19, w0
    restore_c
    mov _addr, x23              // restore _addr (restore_c clobbers x7)

    cbnz w19, atomic_cas_segfault
    ldr _tmp, [sp]              // old value
    add sp, sp, #16
    gret

atomic_cas_segfault:
    add sp, sp, #16
    str x23, [_cpu, #CPU_segfault_addr]  // 64-bit address for ARM64 guest
    mov w8, #1
    strb w8, [_cpu, #CPU_segfault_was_write]
    mov w0, #INT_GPF
    b fiber_exit

/*
 * Base register update gadget for post/pre-indexed addressing
 * Code stream: [gadget addr][rn | offset<<8]
 * Updates: Rn = Rn + offset
 * The offset can be imm9 for pre/post load/store or imm7*scale for LDP/STP
 * Using 16-bit signed extraction to handle all cases
 */
.gadget update_base
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rn
    sbfx x10, x8, #8, #16   // offset (16-bit signed from bit 8)

    // Load current base register
    add x11, _cpu, #CPU_x0
    cmp x9, #31
    b.eq 1f
    ldr x12, [x11, x9, lsl #3]
    and x12, x12, #0xffffffff
    // Update and store back (64-bit for ARM64 guest)
    add x12, x12, x10
    str x12, [x11, x9, lsl #3]
    gret
1:  // SP update (64-bit for ARM64 guest)
    ldr x12, [_cpu, #CPU_sp]
    and x12, x12, #0xffffffff
    add x12, x12, x10
    // DEBUG: validate updated SP
    lsr x13, x12, #32
    cbnz x13, sp_update_bad
    str x12, [_cpu, #CPU_sp]
    gret

sp_update_bad:
    str x12, [_cpu, #CPU_segfault_addr]
    str x12, [_cpu, #CPU_sp]
    mov w8, #1
    strb w8, [_cpu, #CPU_segfault_was_write]
    mov w0, #INT_GPF
    b fiber_exit

/*
 * Writeback address to base register (for pre-indexed)
 * Code stream: [gadget addr][rn]
 */
.gadget writeback_addr
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rn

    // Store 64-bit address to register (ARM64 guest)
    add x11, _cpu, #CPU_x0
    cmp x9, #31
    b.eq 1f
    str _addr, [x11, x9, lsl #3]
    gret
1:  // SP writeback
    // DEBUG: validate addr before writing to SP
    lsr x10, _addr, #32
    cbnz x10, sp_write_bad_addr
    str _addr, [_cpu, #CPU_sp]
    gret

/*
 * Calculate address from base register only (for pre/post-indexed)
 * Code stream: [gadget addr][rn]
 */
.gadget calc_addr_base
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rn

    // Load base register (or SP if rn == 31)
    // Truncate to 32-bit: guest addresses are always 32-bit
    add x11, _cpu, #CPU_x0
    cmp x9, #31
    b.eq 1f
    ldr _addr, [x11, x9, lsl #3]
    and _addr, _addr, #0xffffffff   // truncate to 32-bit guest address
    gret
1:  ldr _addr, [_cpu, #CPU_sp]
    and _addr, _addr, #0xffffffff
    gret

/*
 * Load/Store Pair gadgets (LDP/STP) with inline TLB lookup
 * Address should be in _addr (x7)
 * Code stream: [gadget addr][rt | rt2<<8]
 * Single TLB lookup covers both values when on same page.
 */

// LDP Xn, Xm, [addr] - 64-bit load pair (inline TLB)
.gadget ldp64
    ldr x22, [_pc]              // rt | rt2<<8
    add _pc, _pc, #8
    mov x24, _addr
    read_prep 128, ldp64_1      // 16 bytes: cross-page if offset > 0xff0
    ldr x23, [_addr]            // val1
    ldr x25, [_addr, #8]        // val2
    and x8, x22, #0x1f          // rt
    ubfx x9, x22, #8, #5        // rt2
    add x10, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 1f
    str x23, [x10, x8, lsl #3]
1:  cmp x9, #31
    b.eq 2f
    str x25, [x10, x9, lsl #3]
2:  mov _addr, x24
    gret
    read_bullshit 128, ldp64_1

// LDP Wn, Wm, [addr] - 32-bit load pair (inline TLB)
.gadget ldp32
    ldr x22, [_pc]
    add _pc, _pc, #8
    mov x24, _addr
    read_prep 64, ldp32_1       // 8 bytes total (2x4): cross-page if offset > 0xff8
    ldr w23, [_addr]            // val1 (32-bit, zero-extended to x23)
    ldr w25, [_addr, #4]        // val2 (32-bit, zero-extended to x25)
    and x8, x22, #0x1f          // rt
    ubfx x9, x22, #8, #5        // rt2
    add x10, _cpu, #CPU_x0
    cmp x8, #31
    b.eq 1f
    str x23, [x10, x8, lsl #3]  // store zero-extended 64-bit
1:  cmp x9, #31
    b.eq 2f
    str x25, [x10, x9, lsl #3]
2:  mov _addr, x24
    gret
    read_bullshit 64, ldp32_1

// STP Xn, Xm, [addr] - 64-bit store pair (inline TLB)
.gadget stp64
    ldr x22, [_pc]
    add _pc, _pc, #8
    // Load register values before write_prep (which clobbers x8-x10)
    and x8, x22, #0x1f          // rt
    ubfx x9, x22, #8, #5        // rt2
    add x10, _cpu, #CPU_x0
    mov x23, #0
    cmp x8, #31
    b.eq 1f
    ldr x23, [x10, x8, lsl #3]
1:  mov x25, #0
    cmp x9, #31
    b.eq 2f
    ldr x25, [x10, x9, lsl #3]
2:  mov x24, _addr
    write_prep 128, stp64_1     // 16 bytes
    str x23, [_addr]
    str x25, [_addr, #8]
    write_done 128, stp64_1
    mov _addr, x24
    gret
    write_bullshit 128, stp64_1

// STP Wn, Wm, [addr] - 32-bit store pair (inline TLB)
.gadget stp32
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x8, x22, #0x1f          // rt
    ubfx x9, x22, #8, #5        // rt2
    add x10, _cpu, #CPU_x0
    mov x23, #0
    cmp x8, #31
    b.eq 1f
    ldr x23, [x10, x8, lsl #3]  // load full 64-bit (upper 32 bits zero for W-reg ops)
1:  mov x25, #0
    cmp x9, #31
    b.eq 2f
    ldr x25, [x10, x9, lsl #3]
2:  mov x24, _addr
    write_prep 64, stp32_1      // 8 bytes total (2x4)
    str w23, [_addr]             // store only low 32 bits
    str w25, [_addr, #4]
    write_done 64, stp32_1
    mov _addr, x24
    gret
    write_bullshit 64, stp32_1

/*
 * Interleaved SIMD load/store gadgets (LD2/LD3/LD4, ST2/ST3/ST4)
 * These call C helper functions for the deinterleaving/interleaving logic.
 * Code stream: [gadget addr][rt | (num_regs<<8) | (elem_size<<16) | (Q<<24)]
 * _addr must contain the guest base address.
 */

.gadget simd_load_interleaved
    ldr x22, [_pc]
    add _pc, _pc, #8
    mov x23, _addr              // save address

    save_c
    mov x0, _cpu                // cpu
    sub x1, _tlb, #TLB_entries  // tlb (base pointer)
    mov x2, x23                 // addr
    and w3, w22, #0xff          // rt
    ubfx w4, w22, #8, #8        // num_regs
    ubfx w5, w22, #16, #8       // elem_size
    ubfx w6, w22, #24, #8       // Q
    bl NAME(c_simd_load_interleaved)
    mov w19, w0
    restore_c
    mov _addr, x23              // restore _addr

    cbnz w19, simd_interleaved_read_segfault
    gret

simd_interleaved_read_segfault:
    str x23, [_cpu, #CPU_segfault_addr]
    strb wzr, [_cpu, #CPU_segfault_was_write]
    mov w0, #INT_GPF
    b fiber_exit

.gadget simd_store_interleaved
    ldr x22, [_pc]
    add _pc, _pc, #8
    mov x23, _addr              // save address

    save_c
    mov x0, _cpu                // cpu
    sub x1, _tlb, #TLB_entries  // tlb (base pointer)
    mov x2, x23                 // addr
    and w3, w22, #0xff          // rt
    ubfx w4, w22, #8, #8        // num_regs
    ubfx w5, w22, #16, #8       // elem_size
    ubfx w6, w22, #24, #8       // Q
    bl NAME(c_simd_store_interleaved)
    mov w19, w0
    restore_c
    mov _addr, x23              // restore _addr

    cbnz w19, simd_interleaved_write_segfault
    gret

simd_interleaved_write_segfault:
    str x23, [_cpu, #CPU_segfault_addr]
    mov w8, #1
    strb w8, [_cpu, #CPU_segfault_was_write]
    mov w0, #INT_GPF
    b fiber_exit

/*
 * Address manipulation gadgets
 */

// Advance _addr by immediate value
// Code stream: [gadget addr][imm]
.gadget advance_addr
    ldr x8, [_pc]
    add _pc, _pc, #8
    add _addr, _addr, x8
    gret

// Update base register from another register (for post-indexed addressing)
// Code stream: [gadget addr][rn | rm<<8]
.gadget update_base_reg
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rn (base register to update)
    ubfx x10, x8, #8, #5    // rm (offset register)

    // Load offset from Rm (truncate to 32-bit)
    add x11, _cpu, #CPU_x0
    cmp x10, #31
    b.eq 1f
    ldr x12, [x11, x10, lsl #3]
    and x12, x12, #0xffffffff
    b 2f
1:  mov x12, #0
2:
    // Load current base (truncate to 32-bit guest address)
    cmp x9, #31
    b.eq 3f
    ldr x13, [x11, x9, lsl #3]
    and x13, x13, #0xffffffff
    add x13, x13, x12
    str x13, [x11, x9, lsl #3]
    gret
3:  // Update SP (32-bit guest address)
    ldr x13, [_cpu, #CPU_sp]
    and x13, x13, #0xffffffff
    add x13, x13, x12
    str x13, [_cpu, #CPU_sp]
    gret

/*
 * LD1/ST1 Single Structure Gadgets
 *
 * These load/store a single element from memory to/from a specific lane
 * within a vector register.
 *
 * Code stream: [gadget addr][rt | (lane_offset << 8)]
 *   rt: vector register index (0-31)
 *   lane_offset: byte offset within the vector (0-15)
 *
 * Address should already be in _addr (x7)
 */

/*
 * LD1 {Vt.B}[lane], [Xn] - Load single byte to vector lane
 */
.gadget ld1_single_b
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x23, x22, #0x1f         // rt (vector reg index)
    ubfx x25, x22, #8, #8       // lane_offset (byte offset)

    mov x24, _addr              // Save guest address
    read_prep 8, ld1_single_b_1
    ldrb w11, [_addr]

    // Calculate address of byte within vector
    add x9, _cpu, #CPU_fp
    lsl x10, x23, #4            // each V reg is 16 bytes
    add x9, x9, x10             // base of vector
    add x9, x9, x25             // add lane offset
    strb w11, [x9]              // store byte to lane
    mov _addr, x24
    gret
    read_bullshit 8, ld1_single_b_1

/*
 * LD1 {Vt.H}[lane], [Xn] - Load single halfword to vector lane
 */
.gadget ld1_single_h
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x23, x22, #0x1f
    ubfx x25, x22, #8, #8

    mov x24, _addr
    read_prep 16, ld1_single_h_1
    ldrh w11, [_addr]

    add x9, _cpu, #CPU_fp
    lsl x10, x23, #4
    add x9, x9, x10
    add x9, x9, x25
    strh w11, [x9]
    mov _addr, x24
    gret
    read_bullshit 16, ld1_single_h_1

/*
 * LD1 {Vt.S}[lane], [Xn] - Load single word to vector lane
 */
.gadget ld1_single_s
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x23, x22, #0x1f
    ubfx x25, x22, #8, #8

    mov x24, _addr
    read_prep 32, ld1_single_s_1
    ldr w11, [_addr]

    add x9, _cpu, #CPU_fp
    lsl x10, x23, #4
    add x9, x9, x10
    add x9, x9, x25
    str w11, [x9]
    mov _addr, x24
    gret
    read_bullshit 32, ld1_single_s_1

/*
 * LD1 {Vt.D}[lane], [Xn] - Load single doubleword to vector lane
 */
.gadget ld1_single_d
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x23, x22, #0x1f
    ubfx x25, x22, #8, #8

    mov x24, _addr
    read_prep 64, ld1_single_d_1
    ldr x11, [_addr]

    add x9, _cpu, #CPU_fp
    lsl x10, x23, #4
    add x9, x9, x10
    add x9, x9, x25
    str x11, [x9]
    mov _addr, x24
    gret
    read_bullshit 64, ld1_single_d_1

/*
 * LD1R {Vt.T}, [Xn] - Load single element and replicate to all lanes
 *
 * Code stream: [gadget addr][rt | (size << 8) | (Q << 16)]
 *   rt: vector register index (0-31)
 *   size: element size (0=B, 1=H, 2=S, 3=D)
 *   Q: 0=64-bit (lower half), 1=128-bit (full vector)
 *
 * Address should already be in _addr (x7) from calc_addr_imm
 */
.gadget ld1r_vec
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x23, x22, #0x1f         // rt (vector reg index)
    ubfx x25, x22, #8, #8       // size (0=B, 1=H, 2=S, 3=D)
    ubfx x26, x22, #16, #8      // Q

    mov x24, _addr              // Save guest address

    // Dispatch on element size for read_prep and load
    cmp x25, #0
    b.eq ld1r_byte
    cmp x25, #1
    b.eq ld1r_half
    cmp x25, #2
    b.eq ld1r_word
    // else: doubleword

ld1r_dword:
    read_prep 64, ld1r_dword_1
    ldr x11, [_addr]
    dup v0.2d, x11
    b ld1r_store

    read_bullshit 64, ld1r_dword_1

ld1r_word:
    read_prep 32, ld1r_word_1
    ldr w11, [_addr]
    dup v0.4s, w11
    b ld1r_store

    read_bullshit 32, ld1r_word_1

ld1r_half:
    read_prep 16, ld1r_half_1
    ldrh w11, [_addr]
    dup v0.8h, w11
    b ld1r_store

    read_bullshit 16, ld1r_half_1

ld1r_byte:
    read_prep 8, ld1r_byte_1
    ldrb w11, [_addr]
    dup v0.16b, w11
    b ld1r_store

    read_bullshit 8, ld1r_byte_1

ld1r_store:
    // Store replicated vector to cpu->fp[rt]
    add x9, _cpu, #CPU_fp
    lsl x10, x23, #4            // each V reg is 16 bytes
    add x9, x9, x10

    cbz x26, ld1r_store_64
    // Q=1: store full 128-bit vector
    str q0, [x9]
    mov _addr, x24
    gret

ld1r_store_64:
    // Q=0: store lower 64 bits, zero upper 64 bits
    str d0, [x9]
    str xzr, [x9, #8]           // zero upper 64 bits
    mov _addr, x24
    gret

/*
 * ST1 {Vt.B}[lane], [Xn] - Store single byte from vector lane
 */
.gadget st1_single_b
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x23, x22, #0x1f         // rt
    ubfx x25, x22, #8, #8       // lane_offset

    // Load byte from vector lane
    add x9, _cpu, #CPU_fp
    lsl x10, x23, #4
    add x9, x9, x10
    add x9, x9, x25
    ldrb w11, [x9]

    mov x24, _addr
    write_prep 8, st1_single_b_1
    strb w11, [_addr]
    write_done 8, st1_single_b_1
    mov _addr, x24
    gret
    write_bullshit 8, st1_single_b_1

/*
 * ST1 {Vt.H}[lane], [Xn] - Store single halfword from vector lane
 */
.gadget st1_single_h
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x23, x22, #0x1f
    ubfx x25, x22, #8, #8

    add x9, _cpu, #CPU_fp
    lsl x10, x23, #4
    add x9, x9, x10
    add x9, x9, x25
    ldrh w11, [x9]

    mov x24, _addr
    write_prep 16, st1_single_h_1
    strh w11, [_addr]
    write_done 16, st1_single_h_1
    mov _addr, x24
    gret
    write_bullshit 16, st1_single_h_1

/*
 * ST1 {Vt.S}[lane], [Xn] - Store single word from vector lane
 */
.gadget st1_single_s
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x23, x22, #0x1f
    ubfx x25, x22, #8, #8

    add x9, _cpu, #CPU_fp
    lsl x10, x23, #4
    add x9, x9, x10
    add x9, x9, x25
    ldr w11, [x9]

    mov x24, _addr
    write_prep 32, st1_single_s_1
    str w11, [_addr]
    write_done 32, st1_single_s_1
    mov _addr, x24
    gret
    write_bullshit 32, st1_single_s_1

/*
 * ST1 {Vt.D}[lane], [Xn] - Store single doubleword from vector lane
 */
.gadget st1_single_d
    ldr x22, [_pc]
    add _pc, _pc, #8
    and x23, x22, #0x1f
    ubfx x25, x22, #8, #8

    add x9, _cpu, #CPU_fp
    lsl x10, x23, #4
    add x9, x9, x10
    add x9, x9, x25
    ldr x11, [x9]

    mov x24, _addr
    write_prep 64, st1_single_d_1
    str x11, [_addr]
    write_done 64, st1_single_d_1
    mov _addr, x24
    gret
    write_bullshit 64, st1_single_d_1

/*
 * SP corruption detected within a block (during calc_addr_imm with rn=31)
 * x12 = corrupted SP value
 * Reports via page fault with the corrupted SP value
 */
sp_corrupted_in_block:
    // x12 has the bad SP value
    str x12, [_cpu, #CPU_segfault_addr]
    str x12, [_cpu, #CPU_sp]  // write it so page fault handler can dump it
    mov w8, #0
    strb w8, [_cpu, #CPU_segfault_was_write]
    mov w0, #INT_GPF
    b fiber_exit

/*
 * LDXR — Load exclusive with exclusive monitor save
 * Code stream: [gadget addr][rt | (size << 8)]
 * Expects _addr = guest address (from calc_addr_imm)
 * Loads value, saves addr+value to cpu excl_addr/excl_val, stores to Rt
 */
.gadget ldxr
    ldr x22, [_pc]
    add _pc, _pc, #8

    and x23, x22, #0x1f        // rt
    ubfx x11, x22, #8, #2      // size (0=8b, 1=16b, 2=32b, 3=64b)

    // Inline TLB read - use read_prep for size 32 (we'll handle actual size in load)
    mov x24, _addr
    read_prep 32, ldxr_1

    // Load based on size
    cmp x11, #3
    b.eq ldxr_load64
    cmp x11, #2
    b.eq ldxr_load32
    cmp x11, #1
    b.eq ldxr_load16
    // size 0: 8-bit
    ldrb w0, [_addr]
    b ldxr_done
ldxr_load16:
    ldrh w0, [_addr]
    b ldxr_done
ldxr_load32:
    ldr w0, [_addr]
    b ldxr_done
ldxr_load64:
    ldr x0, [_addr]

ldxr_done:
    mov _addr, x24              // restore _addr

    // Save to exclusive monitor
    str _addr, [_cpu, #CPU_excl_addr]
    str _tmp, [_cpu, #CPU_excl_val]    // _tmp = x0 = loaded value

    // Store to Rt (unless Rt == 31 / XZR)
    cmp x23, #31
    b.eq 1f
    add x9, _cpu, #CPU_x0
    str _tmp, [x9, x23, lsl #3]
1:  gret

    read_bullshit 32, ldxr_1

/*
 * STXR — Store exclusive via atomic CAS
 * Code stream: [gadget addr][rt | (rs << 8) | (size << 16)]
 * Expects _addr = guest address (from calc_addr_imm)
 * Checks excl_addr match, does atomic CAS, stores result to Rs
 */
.gadget stxr
    ldr x22, [_pc]
    add _pc, _pc, #8

    and x23, x22, #0x1f         // rt (new value register)
    ubfx x25, x22, #8, #5       // rs (status result register)
    ubfx x26, x22, #16, #2      // size

    mov x24, _addr               // save guest address

    // Check exclusive monitor: does excl_addr match current address?
    ldr x8, [_cpu, #CPU_excl_addr]
    cmp x8, _addr
    b.ne stxr_fail               // mismatch -> fail

    // Load the new value from Rt
    add x12, _cpu, #CPU_x0
    cmp x23, #31
    b.eq 1f
    ldr x13, [x12, x23, lsl #3]
    b 2f
1:  mov x13, #0                  // XZR
2:
    // Load expected value from exclusive monitor
    ldr x14, [_cpu, #CPU_excl_val]

    // Call C helper: c_stxr_cas(tlb, addr, expected_val, new_val, size)
    save_c
    sub x0, _tlb, #TLB_entries   // tlb struct pointer
    mov x1, x24                  // guest address
    mov x2, x14                  // expected value (from LDXR)
    mov x3, x13                  // new value (from Rt)
    mov w4, w26                  // size
    bl NAME(c_stxr_cas)
    mov w19, w0                  // save result (0=success, 1=fail, -1=segfault)
    restore_c
    mov _addr, x24               // restore _addr

    // Check for segfault
    cmn w19, #1
    b.eq stxr_segfault

    // Invalidate exclusive monitor
    movn x8, #0
    str x8, [_cpu, #CPU_excl_addr]

    // Store result to Rs (w19 = 0 or 1)
    cmp x25, #31
    b.eq 3f                      // Rs == XZR, discard
    add x9, _cpu, #CPU_x0
    and x8, x19, #0xff          // zero-extend w19 to 64-bit
    str x8, [x9, x25, lsl #3]   // store to Rs
3:  gret

stxr_fail:
    // Exclusive monitor mismatch — store failed
    movn x8, #0
    str x8, [_cpu, #CPU_excl_addr]
    cmp x25, #31
    b.eq 4f
    add x9, _cpu, #CPU_x0
    mov x8, #1
    str x8, [x9, x25, lsl #3]   // Rs = 1 (failure)
4:  gret

stxr_segfault:
    // Invalidate exclusive monitor
    movn x8, #0
    str x8, [_cpu, #CPU_excl_addr]
    str x24, [_cpu, #CPU_segfault_addr]
    mov w8, #1
    strb w8, [_cpu, #CPU_segfault_was_write]
    mov w0, #INT_GPF
    b fiber_exit

/*
 * Bad address being written to SP via writeback_addr
 * _addr has the bad value
 */
sp_write_bad_addr:
    str _addr, [_cpu, #CPU_segfault_addr]
    str _addr, [_cpu, #CPU_sp]
    mov w8, #1
    strb w8, [_cpu, #CPU_segfault_was_write]
    mov w0, #INT_GPF
    b fiber_exit
