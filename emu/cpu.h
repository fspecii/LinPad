#ifndef EMU_CPU_H
#define EMU_CPU_H

#include "misc.h"
#include "emu/mmu.h"

#ifdef __KERNEL__
#include <linux/stddef.h>
#else
#include <stddef.h>
#endif

// Include architecture-specific CPU state definition
#if defined(GUEST_X86)
#include "emu/arch/x86/cpu.h"
#elif defined(GUEST_ARM64)
#include "emu/arch/arm64/cpu.h"
#else
// Default to x86 for backward compatibility
#include "emu/arch/x86/cpu.h"
#endif

// Common CPU interface
struct cpu_state;
struct tlb;
int cpu_run_to_interrupt(struct cpu_state *cpu, struct tlb *tlb);
void cpu_poke(struct cpu_state *cpu);

#define CPU_OFFSET(field) offsetof(struct cpu_state, field)

#endif
