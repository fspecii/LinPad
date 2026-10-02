// Native same-architecture JIT backend (AArch64 guest on AArch64 host).
// Public interface used by asbestos/asbestos.c. Everything here is compiled
// only with -Djit=enabled (ISH_JIT=1); the default build never sees it.
#ifndef ISH_JIT_H
#define ISH_JIT_H

#include <stdbool.h>
#include "emu/mmu.h"

struct cpu_state;
struct tlb;
struct jit_mm;

// True once code memory has been acquired and ISH_JIT is not set to 0.
// Cheap after the first call.
bool jit_enabled(void);

struct jit_mm *jit_mm_new(struct mmu *mmu);
void jit_mm_free(struct jit_mm *mm);

// Called from the asbestos invalidation entry points (same semantics: the
// guest bytes of these pages may have changed).
void jit_invalidate_range(struct jit_mm *mm, page_t start, page_t end);
void jit_invalidate_all(struct jit_mm *mm);

// Memory pressure: shrink the code cache to its minimum (32 MB on iOS),
// retiring the oldest translations, and write out the persistent cache.
// Also called automatically on a dispatch memory-pressure event.
void ish_jit_trim(void);

// Fast mode on iOS (StikDebug URL handoff, app/AppDelegate.m). The app looks
// these up with dlsym, since only -Djit=enabled builds have them.
// Whether this device needs StikDebug's universal.js script (TXM, iOS 26+).
bool ish_jit_txm_present(void);
// Whether a debugger has made this process able to run generated code (and,
// with TXM, the script is still attached for the handshake).
bool ish_jit_debug_ready(void);
// Start the JIT now if it is off and ish_jit_debug_ready(): runs the
// universal.js handshake (prepare region, writable alias, detach). Address
// spaces created afterwards (new processes, exec) use the JIT; running ones
// stay on the gadget engine. True if the JIT is on.
bool ish_jit_try_enable(void);

// Run guest code until an interrupt. Same contract as the gadget
// cpu_step_to_interrupt: cpu is copied in, run, and copied back (except _poked).
int jit_run(struct cpu_state *cpu, struct tlb *tlb, struct jit_mm *mm);

#endif
