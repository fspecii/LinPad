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

#if defined(GUEST_ARM64)
// Debug helper for FP instructions
void helper_debug_fp(uint64_t op, uint64_t rd, uint64_t rn, uint64_t rm, uint64_t val1, uint64_t val2) {
    const char *opname;
    switch (op) {
        case 0: opname = "SCVTF"; break;
        case 1: opname = "UCVTF"; break;
        case 2: opname = "FADD"; break;
        case 3: opname = "FSUB"; break;
        case 4: opname = "FMUL"; break;
        case 5: opname = "FDIV"; break;
        case 6: opname = "FMOV_G2F"; break;
        case 7: opname = "FMOV_F2G"; break;
        default: opname = "FP_OP"; break;
    }
    fprintf(stderr, "[FP RT] %s rd=%llu rn=%llu rm=%llu val1=0x%llx val2=0x%llx\n",
            opname, rd, rn, rm, val1, val2);
    fflush(stderr);
}

// Debug helper to trace suspicious 64-bit loads
void helper_debug_load64(uint64_t addr, uint64_t value, uint64_t pc) {
    fprintf(stderr, "[WATCH] load64 pc=0x%llx addr=0x%llx value=0x%llx\n",
            (unsigned long long)pc, (unsigned long long)addr, (unsigned long long)value);
    fflush(stderr);
}


// Debug helper to detect when a SIMD register is set to all 1s
// Returns 1 if the value is all 1s (both lo and hi), 0 otherwise
static int all_ones_count = 0;
void helper_check_all_ones(uint64_t rd, uint64_t lo, uint64_t hi, uint64_t op_type) {
    // Only log if both halves are all 1s (the problematic pattern)
    if (lo == 0xffffffffffffffff && hi == 0xffffffffffffffff) {
        const char *opname;
        switch (op_type) {
            case 1: opname = "SET_VEC_IMM"; break;
            case 2: opname = "ORR_IMM_VEC"; break;
            case 3: opname = "LDR_Q"; break;
            case 4: opname = "LDP_Q"; break;
            case 5: opname = "CMEQ"; break;
            case 6: opname = "MOVI/MVNI"; break;
            default: opname = "UNKNOWN"; break;
        }
        all_ones_count++;
        // Only print first 5 occurrences to avoid spam
        if (all_ones_count <= 5) {
            fprintf(stderr, "[ALL_ONES #%d] v%llu = lo=0x%llx hi=0x%llx set by %s\n",
                    all_ones_count, rd, lo, hi, opname);
            fflush(stderr);
        }
    }
}
#endif
