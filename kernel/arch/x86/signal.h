#ifndef KERNEL_ARCH_X86_SIGNAL_H
#define KERNEL_ARCH_X86_SIGNAL_H

/*
 * x86 Signal Frame Structures
 *
 * These structures match the Linux kernel's x86-32 signal frame layout.
 * The main definitions are in kernel/signal.h - this file provides
 * architecture-specific helpers and documentation.
 *
 * See arch/x86/include/asm/sigframe.h in the Linux kernel.
 */

#include "kernel/signal.h"
#include "emu/cpu.h"

// Setup x86 sigcontext from CPU state
static inline void x86_setup_sigcontext(struct sigcontext_ *sc, struct cpu_state *cpu) {
#if defined(GUEST_X86) || !defined(GUEST_ARM64)
    sc->gs = cpu->gs;
    sc->fs = 0;  // Not used in iSH
    sc->es = 0;
    sc->ds = 0;
    sc->di = cpu->edi;
    sc->si = cpu->esi;
    sc->bp = cpu->ebp;
    sc->sp = cpu->esp;
    sc->bx = cpu->ebx;
    sc->dx = cpu->edx;
    sc->cx = cpu->ecx;
    sc->ax = cpu->eax;
    sc->trapno = cpu->trapno;
    sc->err = 0;
    sc->ip = cpu->eip;
    sc->cs = 0;
    collapse_flags(cpu);
    sc->flags = cpu->eflags;
    sc->sp_at_signal = cpu->esp;
    sc->ss = 0;
    sc->fpstate = 0;  // No FPU state pointer (handled separately)
    sc->oldmask = 0;
    sc->cr2 = cpu->segfault_addr;
#else
    (void)sc;
    (void)cpu;
#endif
}

// Restore x86 CPU state from sigcontext
static inline void x86_restore_sigcontext(struct cpu_state *cpu, struct sigcontext_ *sc) {
#if defined(GUEST_X86) || !defined(GUEST_ARM64)
    cpu->gs = sc->gs;
    cpu->edi = sc->di;
    cpu->esi = sc->si;
    cpu->ebp = sc->bp;
    cpu->esp = sc->sp;
    cpu->ebx = sc->bx;
    cpu->edx = sc->dx;
    cpu->ecx = sc->cx;
    cpu->eax = sc->ax;
    cpu->eip = sc->ip;
    cpu->eflags = sc->flags;
    expand_flags(cpu);
#else
    (void)sc;
    (void)cpu;
#endif
}

#endif
