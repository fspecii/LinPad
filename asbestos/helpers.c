#include <time.h>
#include <stdio.h>
#include "emu/cpu.h"

#if defined(GUEST_X86) || !defined(GUEST_ARM64)
#include "emu/arch/x86/cpuid.h"

void helper_cpuid(dword_t *a, dword_t *b, dword_t *c, dword_t *d) {
    do_cpuid(a, b, c, d);
}

void helper_rdtsc(struct cpu_state *cpu) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    uint64_t tsc = now.tv_sec * 1000000000l + now.tv_nsec;
    cpu->eax = tsc & 0xffffffff;
    cpu->edx = tsc >> 32;
}

#elif defined(GUEST_ARM64)

// ARM64 doesn't have CPUID - this is a stub for compatibility
void helper_cpuid(dword_t *a, dword_t *b, dword_t *c, dword_t *d) {
    (void)a; (void)b; (void)c; (void)d;
}

// ARM64 counter register access
void helper_rdtsc(struct cpu_state *cpu) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    uint64_t tsc = now.tv_sec * 1000000000l + now.tv_nsec;
    // Store in x0 for ARM64
    cpu->regs[0] = tsc;
}

#endif

void helper_expand_flags(struct cpu_state *cpu) {
    expand_flags(cpu);
}

void helper_collapse_flags(struct cpu_state *cpu) {
    collapse_flags(cpu);
}
