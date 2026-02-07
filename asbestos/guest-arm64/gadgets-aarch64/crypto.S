/*
 * ARM64 Cryptographic Extension Gadgets
 *
 * These gadgets implement the ARMv8 cryptographic instructions.
 * They call C helper functions for the actual crypto operations.
 */

#include "gadgets.h"

.text

/*
 * AESE - AES single round encryption
 * Performs AddRoundKey, SubBytes, and ShiftRows
 * Code stream: [gadget addr][rd | rn<<8]
 *
 * Vd = SubBytes(ShiftRows(Vd XOR Vn))
 */
.gadget aese
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn (key)

    add x11, _cpu, #CPU_fp
    lsl x12, x9, #4         // rd offset
    add x12, x11, x12       // &Vd
    lsl x13, x10, #4        // rn offset
    add x13, x11, x13       // &Vn (key)

    // Load Vd and Vn
    ldr q0, [x12]
    ldr q1, [x13]

    // XOR with round key (AddRoundKey)
    eor v0.16b, v0.16b, v1.16b

    // Save callee-saved registers and call C helper
    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    // Save x12 (&Vd) in callee-saved register
    mov x19, x12

    save_c
    // Store state to stack for C function
    sub sp, sp, #32
    str q0, [sp]
    mov x0, sp              // state pointer
    bl NAME(aes_subbytes_shiftrows)
    ldr q0, [sp]
    add sp, sp, #32
    restore_c

    // Restore x12 from callee-saved register before it gets popped
    mov x12, x19

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    // Store result
    str q0, [x12]

    gret

/*
 * AESD - AES single round decryption
 * Performs AddRoundKey, InvSubBytes, and InvShiftRows
 * Code stream: [gadget addr][rd | rn<<8]
 */
.gadget aesd
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5

    add x11, _cpu, #CPU_fp
    lsl x12, x9, #4
    add x12, x11, x12
    lsl x13, x10, #4
    add x13, x11, x13

    ldr q0, [x12]
    ldr q1, [x13]

    eor v0.16b, v0.16b, v1.16b

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    // Save x12 (&Vd) in callee-saved register
    mov x19, x12

    save_c
    sub sp, sp, #32
    str q0, [sp]
    mov x0, sp
    bl NAME(aes_inv_subbytes_shiftrows)
    ldr q0, [sp]
    add sp, sp, #32
    restore_c

    // Restore x12
    mov x12, x19

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    str q0, [x12]

    gret

/*
 * AESMC - AES MixColumns
 * Code stream: [gadget addr][rd | rn<<8]
 */
.gadget aesmc
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5

    add x11, _cpu, #CPU_fp
    lsl x12, x9, #4
    add x12, x11, x12
    lsl x13, x10, #4
    add x13, x11, x13

    ldr q0, [x13]   // load Vn

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    // Save x12 (&Vd) in callee-saved register
    mov x19, x12

    save_c
    sub sp, sp, #32
    str q0, [sp]
    mov x0, sp
    bl NAME(aes_mixcolumns)
    ldr q0, [sp]
    add sp, sp, #32
    restore_c

    // Restore x12
    mov x12, x19

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    str q0, [x12]

    gret

/*
 * AESIMC - AES Inverse MixColumns
 * Code stream: [gadget addr][rd | rn<<8]
 */
.gadget aesimc
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5

    add x11, _cpu, #CPU_fp
    lsl x12, x9, #4
    add x12, x11, x12
    lsl x13, x10, #4
    add x13, x11, x13

    ldr q0, [x13]

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    // Save x12 (&Vd) in callee-saved register
    mov x19, x12

    save_c
    sub sp, sp, #32
    str q0, [sp]
    mov x0, sp
    bl NAME(aes_inv_mixcolumns)
    ldr q0, [sp]
    add sp, sp, #32
    restore_c

    // Restore x12
    mov x12, x19

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    str q0, [x12]

    gret

/*
 * SHA1 instructions - these are complex, use C helpers
 */

// SHA1H Sd, Sn - SHA1 fixed rotate
// Code stream: [gadget addr][rd | rn<<8]
.gadget sha1h
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn

    // Load Sn (lower 32 bits of Vn)
    add x11, _cpu, #CPU_fp
    lsl x12, x10, #4
    ldr w13, [x11, x12]     // load 32-bit value

    // SHA1H performs a fixed rotate left by 30
    ror w13, w13, #2        // ror by 2 = rol by 30

    // Store to Sd and clear upper bits
    lsl x14, x9, #4
    add x14, x11, x14       // &Vd
    str w13, [x14]          // store 32-bit result
    str xzr, [x14, #4]      // clear bits 32-63 (use #4 offset)
    str xzr, [x14, #8]      // clear bits 64-127

    gret

// SHA1C Qd, Sn, Vm.4S - SHA1 hash update (Choose)
// Code stream: [gadget addr][rd | rn<<8 | rm<<16]
.gadget sha1c
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5
    ubfx x11, x8, #16, #5

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    // Call C helper: sha1c(rd_ptr, sn_val, vm_ptr)
    lsl x0, x9, #4
    add x0, x12, x0         // rd_ptr
    lsl x13, x10, #4
    ldr w1, [x12, x13]      // sn_val (32-bit)
    lsl x2, x11, #4
    add x2, x12, x2         // vm_ptr
    bl NAME(sha1c_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

// SHA1M Qd, Sn, Vm.4S - SHA1 hash update (Majority)
.gadget sha1m
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5
    ubfx x11, x8, #16, #5

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0
    lsl x13, x10, #4
    ldr w1, [x12, x13]
    lsl x2, x11, #4
    add x2, x12, x2
    bl NAME(sha1m_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

// SHA1P Qd, Sn, Vm.4S - SHA1 hash update (Parity)
.gadget sha1p
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5
    ubfx x11, x8, #16, #5

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0
    lsl x13, x10, #4
    ldr w1, [x12, x13]
    lsl x2, x11, #4
    add x2, x12, x2
    bl NAME(sha1p_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

// SHA1SU0 Vd.4S, Vn.4S, Vm.4S - SHA1 schedule update 0
.gadget sha1su0
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5
    ubfx x11, x8, #16, #5

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0
    lsl x1, x10, #4
    add x1, x12, x1
    lsl x2, x11, #4
    add x2, x12, x2
    bl NAME(sha1su0_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

// SHA1SU1 Vd.4S, Vn.4S - SHA1 schedule update 1
.gadget sha1su1
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0
    lsl x1, x10, #4
    add x1, x12, x1
    bl NAME(sha1su1_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

/*
 * SHA256 instructions
 */

// SHA256H Qd, Qn, Vm.4S
.gadget sha256h
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5
    ubfx x11, x8, #16, #5

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0
    lsl x1, x10, #4
    add x1, x12, x1
    lsl x2, x11, #4
    add x2, x12, x2
    bl NAME(sha256h_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

// SHA256H2 Qd, Qn, Vm.4S
.gadget sha256h2
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5
    ubfx x11, x8, #16, #5

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0
    lsl x1, x10, #4
    add x1, x12, x1
    lsl x2, x11, #4
    add x2, x12, x2
    bl NAME(sha256h2_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

// SHA256SU0 Vd.4S, Vn.4S
.gadget sha256su0
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0
    lsl x1, x10, #4
    add x1, x12, x1
    bl NAME(sha256su0_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

// SHA256SU1 Vd.4S, Vn.4S, Vm.4S
.gadget sha256su1
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5
    ubfx x11, x8, #16, #5

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0
    lsl x1, x10, #4
    add x1, x12, x1
    lsl x2, x11, #4
    add x2, x12, x2
    bl NAME(sha256su1_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

/*
 * SHA512SU0 Vd.2D, Vn.2D
 * Code stream: [gadget addr][rd | rn<<8]
 */
.gadget sha512su0
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn

    add x12, _cpu, #CPU_fp

    // Load Vd, Vn from emulated register file
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Vd
    lsl x14, x10, #4
    ldr q1, [x12, x14]      // q1 = Vn

    // Execute native SHA512SU0 instruction
    // SHA512SU0 V0.2D, V1.2D
    .inst 0xcec08020         // sha512su0 v0.2d, v1.2d

    // Store result back to Vd
    str q0, [x12, x13]

    gret

/*
 * SHA512SU1 Vd.2D, Vn.2D, Vm.2D
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16]
 */
.gadget sha512su1
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn
    ubfx x11, x8, #16, #5   // rm

    add x12, _cpu, #CPU_fp

    // Load Vd, Vn, Vm from emulated register file
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Vd
    lsl x14, x10, #4
    ldr q1, [x12, x14]      // q1 = Vn
    lsl x15, x11, #4
    ldr q2, [x12, x15]      // q2 = Vm

    // Execute native SHA512SU1 instruction
    // SHA512SU1 V0.2D, V1.2D, V2.2D
    .inst 0xce628820         // sha512su1 v0.2d, v1.2d, v2.2d

    // Store result back to Vd
    str q0, [x12, x13]

    gret

/*
 * SHA512H Qd, Qn, Vm.2D
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16]
 */
.gadget sha512h
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn
    ubfx x11, x8, #16, #5   // rm

    add x12, _cpu, #CPU_fp

    // Load Vd, Vn, Vm from emulated register file
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Vd
    lsl x14, x10, #4
    ldr q1, [x12, x14]      // q1 = Vn
    lsl x15, x11, #4
    ldr q2, [x12, x15]      // q2 = Vm

    // Execute native SHA512H instruction
    // SHA512H Qd, Qn, Vm.2D -> SHA512H Q0, Q1, V2.2D
    .inst 0xce628020         // sha512h q0, q1, v2.2d

    // Store result back to Vd
    str q0, [x12, x13]

    gret

/*
 * SHA512H2 Qd, Qn, Vm.2D
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16]
 */
.gadget sha512h2
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn
    ubfx x11, x8, #16, #5   // rm

    add x12, _cpu, #CPU_fp

    // Load Vd, Vn, Vm from emulated register file
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Vd
    lsl x14, x10, #4
    ldr q1, [x12, x14]      // q1 = Vn
    lsl x15, x11, #4
    ldr q2, [x12, x15]      // q2 = Vm

    // Execute native SHA512H2 instruction
    // SHA512H2 Q0, Q1, V2.2D
    .inst 0xce628420         // sha512h2 q0, q1, v2.2d

    // Store result back to Vd
    str q0, [x12, x13]

    gret

/*
 * EOR3 Vd.16B, Vn.16B, Vm.16B, Va.16B
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16 | ra<<24]
 */
.gadget eor3
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5
    ubfx x11, x8, #16, #5
    ubfx x12, x8, #24, #5

    add x13, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x13, x0         // rd_ptr
    lsl x1, x10, #4
    add x1, x13, x1         // rn_ptr
    lsl x2, x11, #4
    add x2, x13, x2         // rm_ptr
    lsl x3, x12, #4
    add x3, x13, x3         // ra_ptr
    bl NAME(eor3_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

/*
 * SM3PARTW1 Vd.4S, Vn.4S, Vm.4S
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16]
 */
.gadget sm3partw1
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5
    ubfx x11, x8, #16, #5

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0         // rd_ptr
    lsl x1, x10, #4
    add x1, x12, x1         // rn_ptr
    lsl x2, x11, #4
    add x2, x12, x2         // rm_ptr
    bl NAME(sm3partw1_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

/*
 * SM4E Vd.4S, Vn.4S
 * Code stream: [gadget addr][rd | rn<<8]
 */
.gadget sm4e
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0         // rd_ptr
    lsl x1, x10, #4
    add x1, x12, x1         // rn_ptr
    bl NAME(sm4e_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

/*
 * SVE EOR ZD.D, ZN.D, ZM.D (modeled as 128-bit vectors)
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16]
 */
.gadget sve_eor_d
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5
    ubfx x11, x8, #16, #5

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0         // rd_ptr
    lsl x1, x10, #4
    add x1, x12, x1         // rn_ptr
    lsl x2, x11, #4
    add x2, x12, x2         // rm_ptr
    bl NAME(sve_eor_d_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

/*
 * SVE XAR ZD.D, ZD.D, ZM.D, #imm (modeled as 128-bit vectors)
 * Code stream: [gadget addr][rd | rn<<8 | imm<<16]
 */
.gadget sve_xar_d
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5
    ubfx x11, x8, #16, #8   // imm

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0         // rd_ptr (also zn)
    lsl x1, x9, #4
    add x1, x12, x1         // zn_ptr (same as rd)
    lsl x2, x10, #4
    add x2, x12, x2         // zm_ptr
    mov w3, w11             // imm
    bl NAME(sve_xar_d_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

/*
 * PMULL - Polynomial Multiply Long
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16 | Q<<24 | size<<26]
 */
.gadget pmull
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn
    ubfx x11, x8, #16, #5   // rm
    ubfx x21, x8, #24, #1   // Q
    ubfx x22, x8, #26, #2   // size

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0         // rd_ptr
    lsl x1, x10, #4
    add x1, x12, x1         // rn_ptr
    lsl x2, x11, #4
    add x2, x12, x2         // rm_ptr
    mov w3, w21             // Q
    mov w4, w22             // size
    bl NAME(pmull_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

/*
 * TBL - Table lookup
 * TBL Vd.<Ta>, {Vn.16B...Vn+len.16B}, Vm.<Ta>
 *
 * Each byte of Vm is used as an index into the table formed by
 * Vn..Vn+len (concatenated). If index < table_size, the corresponding
 * byte is placed in Vd. Otherwise, 0 is placed in Vd.
 *
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16 | len<<24 | Q<<28]
 */
.gadget tbl
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn (first table register)
    ubfx x11, x8, #16, #5   // rm (indices)
    ubfx x20, x8, #24, #3   // len (0-3 means 1-4 registers)
    ubfx x21, x8, #28, #1   // Q (0=8B, 1=16B)

    add x12, _cpu, #CPU_fp

    // Save callee-saved registers
    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    // Recalculate from saved x8 (clobbered by saves)
    and x19, x8, #0x1f       // rd
    ubfx x20, x8, #8, #5     // rn
    ubfx x21, x8, #16, #5    // rm
    ubfx x22, x8, #24, #3    // len
    ubfx x23, x8, #28, #1    // Q

    save_c
    // tbl_helper(rd_ptr, rn_ptr, rm_ptr, len, Q, fp_base)
    lsl x0, x19, #4
    add x0, x12, x0         // rd_ptr
    lsl x1, x20, #4
    add x1, x12, x1         // rn_ptr (table start)
    lsl x2, x21, #4
    add x2, x12, x2         // rm_ptr (indices)
    mov w3, w22             // len
    mov w4, w23             // Q
    mov x5, x12             // fp_base (for register wrap)
    bl NAME(tbl_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

/*
 * TBX - Table lookup with extend
 * Same as TBL but out-of-range indices preserve the original Vd value
 * instead of being set to 0.
 *
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16 | len<<24 | Q<<28]
 */
.gadget tbx
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn (first table register)
    ubfx x11, x8, #16, #5   // rm (indices)
    ubfx x20, x8, #24, #3   // len (0-3 means 1-4 registers)
    ubfx x21, x8, #28, #1   // Q (0=8B, 1=16B)

    add x12, _cpu, #CPU_fp

    // Save callee-saved registers
    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    // Recalculate from saved x8 (clobbered by saves)
    and x19, x8, #0x1f       // rd
    ubfx x20, x8, #8, #5     // rn
    ubfx x21, x8, #16, #5    // rm
    ubfx x22, x8, #24, #3    // len
    ubfx x23, x8, #28, #1    // Q

    save_c
    // tbx_helper(rd_ptr, rn_ptr, rm_ptr, len, Q, fp_base)
    lsl x0, x19, #4
    add x0, x12, x0         // rd_ptr
    lsl x1, x20, #4
    add x1, x12, x1         // rn_ptr (table start)
    lsl x2, x21, #4
    add x2, x12, x2         // rm_ptr (indices)
    mov w3, w22             // len
    mov w4, w23             // Q
    mov x5, x12             // fp_base (for register wrap)
    bl NAME(tbx_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret
