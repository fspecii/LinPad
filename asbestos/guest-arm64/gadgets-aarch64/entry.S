/*
 * ARM64 Guest Entry/Exit Code
 *
 * This file contains the entry and exit points for transitioning between
 * the host (native) code and the emulated ARM64 guest code.
 *
 * Calling convention matches x86 guest:
 *   fiber_enter(block, frame, tlb)
 *   - x0 = block (pointer to fiber_block)
 *   - x1 = frame (pointer to fiber_frame, contains cpu_state)
 *   - x2 = tlb
 *
 * Register assignments during gadget execution:
 *   _cpu (x1) = pointer to cpu_state within fiber_frame
 *   _tlb (x2) = pointer to tlb entries
 *   _pc (x28) = instruction pointer (gadget stream)
 *   _tmp (x0) = return value / scratch
 */

#include "gadgets.h"
#include "emu/interrupt.h"

.text

/*
 * fiber_enter - Enter the fiber (guest) execution context
 *
 * Arguments:
 *   x0 - Pointer to fiber_block
 *   x1 - Pointer to fiber_frame (contains cpu_state at offset 0)
 *   x2 - Pointer to tlb
 *
 * Returns (in x0):
 *   Interrupt number (reason for returning to caller)
 */
.global NAME(fiber_enter)
.type_compat fiber_enter,function
NAME(fiber_enter):
    // Save callee-saved registers
    stp x18, x19, [sp, #-0x80]!      // 0x80 to make room for original _cpu
    stp x20, x21, [sp, #0x10]
    stp x22, x23, [sp, #0x20]
    stp x24, x25, [sp, #0x30]
    stp x26, x27, [sp, #0x40]
    stp x28, x29, [sp, #0x50]
    str lr, [sp, #0x60]
    str x1, [sp, #0x70]              // Save original _cpu for verification

    // Setup gadget instruction pointer from block
    add _pc, x0, #FIBER_BLOCK_code

    // _cpu is already x1 (frame pointer, cpu_state is at offset 0)
    // _tlb needs to point to TLB_entries
    add _tlb, x2, #TLB_entries

    // Jump to first gadget (gret equivalent)
    gret

/*
 * fiber_ret_chain - Return from a block that wants to chain to another
 *
 * _pc contains either:
 *   - A fake_ip (bit 63 set): unchained, must return to main loop for dispatch
 *   - A block->code pointer (bit 63 clear): chained, can continue in JIT
 *
 * This is the hot path for block transitions. Staying in JIT avoids the
 * expensive fiber_exit → main loop → fiber_enter round-trip.
 */
.global fiber_ret_chain
fiber_ret_chain:
    // Check bit 63: if set, it's a fake_ip (unchained) → return to main loop
    tbnz _pc, #63, fiber_ret
    // Check if we've been poked (timer interrupt pending)
    ldr x8, [_cpu, #CPU_poked_ptr]
    ldrb w8, [x8]
    cbnz w8, poke
    // Record last_block for block chaining in main loop
    sub x8, _pc, #FIBER_BLOCK_code
    str x8, [_cpu, #LOCAL_last_block]
    // Continue executing in JIT — this is the fast path
    gret

poke:
    // Timer interrupt pending — load guest PC from block->addr and return
    ldr w8, [_pc, #(-FIBER_BLOCK_code + FIBER_BLOCK_addr)]
    str x8, [_cpu, #CPU_pc]
    sub x8, _pc, #FIBER_BLOCK_code
    str x8, [_cpu, #LOCAL_last_block]
    // fallthrough to fiber_ret

/*
 * fiber_ret - Return from fiber with INT_NONE
 */
.global fiber_ret
fiber_ret:
    mvn w0, wzr       // w0 = -1 (INT_NONE)
    // fallthrough to fiber_exit

/*
 * fiber_exit - Exit the fiber execution context
 *
 * Expected state:
 *   _tmp (x0) = interrupt number to return
 *   _cpu = pointer to cpu_state (already saved if needed)
 *
 * DEBUG: Store a marker value to help debug PC issues
 * We store the _pc value (from control flow gadgets) to LOCAL_value
 * so we can see what _pc was when we returned
 */
.global fiber_exit
fiber_exit:
    // Restore callee-saved registers
    ldr lr, [sp, #0x60]
    ldp x28, x29, [sp, #0x50]
    ldp x26, x27, [sp, #0x40]
    ldp x24, x25, [sp, #0x30]
    ldp x22, x23, [sp, #0x20]
    ldp x20, x21, [sp, #0x10]
    ldp x18, x19, [sp], #0x80       // 0x80 to match fiber_enter (includes saved _cpu)

    // x0 (_tmp) already contains return value
    ret

/*
 * handle_read_miss - Handle a TLB read miss
 * Returns: translated host address in x0 (0 = segfault)
 *
 * IMPORTANT: Save and restore callee-saved registers x19-x28 because
 * the C code we call might use them. Our gadget code uses these registers
 * to hold data across the TLB miss call.
 */
.global NAME(handle_read_miss)
NAME(handle_read_miss):
    // Save callee-saved registers that gadgets might be using
    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    sub x0, _tlb, #TLB_entries   // pass tlb base, not tlb+entries
    mov x1, x7                    // guest address (64-bit) from _addr (x7)
    mov x2, #0                    // MEM_READ
    bl NAME(tlb_handle_miss)
    mov x20, x0                   // save result in a callee-saved register
    restore_c
    mov x0, x20                   // return result in x0

    // Restore callee-saved registers
    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60
    ret

/*
 * handle_write_miss - Handle a TLB write miss
 * Returns: translated host address in x0 (0 = segfault)
 *
 * IMPORTANT: Save and restore callee-saved registers x19-x28 because
 * the C code we call might use them. Our gadget code uses these registers
 * to hold data across the TLB miss call.
 */
.global NAME(handle_write_miss)
NAME(handle_write_miss):
    // Save callee-saved registers that gadgets might be using
    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    sub x0, _tlb, #TLB_entries   // pass tlb base, not tlb+entries
    mov x1, x7                    // guest address (64-bit) from _addr (x7)
    mov x2, #1                    // MEM_WRITE
    bl NAME(tlb_handle_miss)
    mov x20, x0                   // save result in a callee-saved register
    restore_c
    mov x0, x20                   // return result

    // Restore callee-saved registers
    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60
    ret

/*
 * crosspage_load - Handle a load that crosses a page boundary
 *
 * Entry: x19 = size in bytes, _addr (x7) = guest address
 * Exit: _addr (x7) points to LOCAL_value buffer with data loaded
 *
 * Calls __tlb_read_cross_page(tlb, addr, buf, size) to do the actual work.
 *
 * IMPORTANT: Save and restore callee-saved registers.
 */
.global NAME(crosspage_load)
NAME(crosspage_load):
    // Save callee-saved registers (x19 has size, save it first to temp)
    mov x8, x19                      // save size to temp
    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    sub x0, _tlb, #TLB_entries       // x0 = tlb base
    add x2, _cpu, #LOCAL_value       // x2 = buffer for data
    mov x1, x7                        // x1 = guest address (64-bit)
    mov x3, x8                        // x3 = size (from temp)
    bl NAME(__tlb_read_cross_page)
    mov x20, x0                       // save result
    restore_c

    cbz x20, segfault_read_cp
    str x7, [_cpu, #LOCAL_value_addr] // save guest address (64-bit)
    add _addr, _cpu, #LOCAL_value    // _addr points to buffer

    // Restore callee-saved registers
    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60
    ret

segfault_read_cp:
    // Handle segfault for cross-page read
    // First restore callee-saved registers
    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    ldr w8, [_tlb, #(-TLB_entries+TLB_segfault_addr)]
    str w8, [_cpu, #CPU_segfault_addr]
    strb wzr, [_cpu, #CPU_segfault_was_write]
    mov w0, #INT_GPF
    b fiber_exit

/*
 * crosspage_store - Handle a store that crosses a page boundary
 *
 * Entry: x19 = size in bytes, _addr (x7) = LOCAL_value buffer
 * Exit: data from LOCAL_value written to guest memory
 *
 * Note: The guest address is in LOCAL_value_addr (saved earlier)
 *
 * IMPORTANT: Save and restore callee-saved registers.
 */
.global NAME(crosspage_store)
NAME(crosspage_store):
    // Save callee-saved registers (x19 has size, save it first to temp)
    mov x8, x19                      // save size to temp
    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    sub x0, _tlb, #TLB_entries       // x0 = tlb base
    add x2, _cpu, #LOCAL_value       // x2 = buffer with data
    ldr x1, [_cpu, #LOCAL_value_addr] // x1 = guest address (64-bit, saved earlier)
    mov x3, x8                        // x3 = size (from temp)
    bl NAME(__tlb_write_cross_page)
    mov x20, x0
    restore_c

    cbz x20, segfault_write_cp

    // Restore callee-saved registers
    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60
    ret

segfault_write_cp:
    // Handle segfault for cross-page write
    // First restore callee-saved registers
    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    ldr w8, [_tlb, #(-TLB_entries+TLB_segfault_addr)]
    str w8, [_cpu, #CPU_segfault_addr]
    mov w9, #1
    strb w9, [_cpu, #CPU_segfault_was_write]
    mov w0, #INT_GPF
    b fiber_exit

/*
 * Debug gadget: record guest PC for crash diagnosis
 * Code stream: [gadget_set_pc addr][guest_pc (32-bit in 64-bit slot)]
 */
.gadget set_pc
    ldr w8, [_pc]
    str x8, [_cpu, #CPU_pc]
    add _pc, _pc, #8
    gret

/*
 * Gadgets for block termination
 */

// gadget_interrupt - Generate an interrupt and exit
// Code stream: [gadget_interrupt addr][interrupt type (32-bit)]
.gadget interrupt
    ldr w0, [_pc]          // Load interrupt type from code stream
    b fiber_exit

// gadget_exit - Exit the block and return to dispatcher
// Code stream: [gadget_exit addr][next IP (32-bit)]
.gadget exit
    ldr w8, [_pc]          // Load next IP from code stream
    str x8, [_cpu, #CPU_pc] // Store as guest PC
    mvn w0, wzr            // Return INT_NONE (-1)
    b fiber_exit

// Convenience gadgets for specific interrupts
.gadget syscall
    mov w0, #INT_SYSCALL
    b fiber_exit

.gadget undefined
    mov w0, #INT_UNDEFINED
    b fiber_exit
