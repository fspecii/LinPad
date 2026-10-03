// Differential test of arbitrary register-only instructions (AdvSIMD/FP data
// processing, which never touch memory). Reads hex instruction words on stdin,
// runs each one from a generated trampoline against fixed register states, and
// prints all 32 V registers, X0-X30 and NZCV afterwards. Run natively and in the
// guest on the same input and diff. "ILL" means the CPU raised SIGILL, "SEGV" a
// memory fault (SIGSEGV or SIGBUS).
//   cc -O1 -o difffuzz difffuzz.c && ./difffuzz < words.txt > out.txt
// With -m (loads, stores, atomics): X registers hold small values, the base
// register (bits 9:5) points into a 128 KB buffer mapped at the same address
// natively and in the guest, and the buffer is part of the hash.
#include <inttypes.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#ifdef __APPLE__
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#endif

struct state {
    uint8_t v[32][16];   // 0
    uint64_t x[31];      // 512
    uint64_t nzcv;       // 760
};

static uint32_t *code;
static sigjmp_buf jb;
static int mem_mode;
#define MEM_BUF_ADDR 0x7e00000000ull
#define MEM_BUF_SIZE (128 * 1024)
static uint8_t *mem_buf;

static void on_ill(int sig) {
    siglongjmp(jb, sig == SIGILL ? 1 : 2);
}

static void emit_trampoline(uint32_t insn) {
    uint32_t *p = code;
    // stp x29, x30, [sp, #-112]!; save x19-x28; str x0, [sp, #96]
    *p++ = 0xa9b97bfd;
    *p++ = 0xa90153f3; *p++ = 0xa9025bf5; *p++ = 0xa90363f7; *p++ = 0xa9046bf9; *p++ = 0xa90573fb;
    *p++ = 0xf90033e0;
    // ldp q(2i), q(2i+1), [x0, #32*i]
    for (uint32_t i = 0; i < 16; i++)
        *p++ = 0xad400000 | ((2 * i + 1) << 10) | (2 * i) | (((i * 32 / 16) & 0x7f) << 15);
    // ldr x1, [x0, #760]; msr nzcv, x1
    *p++ = 0xf9417c01; *p++ = 0xd51b4201;
    // ldr xi, [x0, #512 + 8*i] for i = 1..30 except 18 (x18 stays as the OS left it)
    for (uint32_t i = 1; i <= 30; i++)
        if (i != 18)
            *p++ = 0xf9400000 | (((512 + 8 * i) / 8) << 10) | i;
    *p++ = 0xf9410000;                       // ldr x0, [x0, #512]
    *p++ = insn;
    // str x0, [sp, #104]; ldr x0, [sp, #96]
    *p++ = 0xf90037e0; *p++ = 0xf94033e0;
    for (uint32_t i = 1; i <= 30; i++)
        if (i != 18)
            *p++ = 0xf9000000 | (((512 + 8 * i) / 8) << 10) | i;
    for (uint32_t i = 0; i < 16; i++)
        *p++ = 0xad000000 | ((2 * i + 1) << 10) | (2 * i) | (((i * 32 / 16) & 0x7f) << 15);
    *p++ = 0xd53b4201; *p++ = 0xf9017c01;    // mrs x1, nzcv; str x1, [x0, #760]
    *p++ = 0xf94037e1; *p++ = 0xf9010001;    // ldr x1, [sp, #104]; str x1, [x0, #512]
    // restore callee-saved and return
    *p++ = 0xa94153f3; *p++ = 0xa9425bf5; *p++ = 0xa94363f7; *p++ = 0xa9446bf9; *p++ = 0xa94573fb;
    *p++ = 0xa8c77bfd;
    *p++ = 0xd65f03c0;
#ifdef __APPLE__
    sys_icache_invalidate(code, (char *) p - (char *) code);
#else
    __builtin___clear_cache((char *) code, (char *) p);
#endif
}

static const uint64_t seeds[][4] = {
    { 0x3ff0000000000000, 0xc004000000000000, 0x7ff8000000000001, 0x0000000000000001 },
    { 0x3f800000bfc00000, 0x7f8000007fc00000, 0x8000000000000001, 0x00ff7f80807f0001 },
    { 0x0123456789abcdef, 0xfedcba9876543210, 0x5555aaaa3c003c00, 0x7bfffc0003ff8001 },
};

static void fill(struct state *s, int k, uint32_t insn) {
    for (int r = 0; r < 32; r++)
        for (int h = 0; h < 2; h++) {
            uint64_t v = seeds[k][(r + h) & 3] ^ ((uint64_t) r << (8 * ((r + h) & 7)));
            memcpy(&s->v[r][8 * h], &v, 8);
        }
    for (int r = 0; r < 31; r++)
        s->x[r] = seeds[k][r & 3] + (uint64_t) r * 0x0101010101010101ull;
    if (mem_mode) {
        for (int r = 0; r < 31; r++)
            s->x[r] = (s->x[r] >> (8 * (r & 3))) & 0x3f8;
        unsigned rn = (insn >> 5) & 0x1f;
        if (rn != 31)
            s->x[rn] = MEM_BUF_ADDR + MEM_BUF_SIZE / 2;
        for (unsigned i = 0; i < MEM_BUF_SIZE; i++)
            mem_buf[i] = (uint8_t) ((i * 131 + k * 17) ^ (i >> 7));
    }
    s->x[18] = 0;
    s->nzcv = (uint64_t) (k & 3) << 29;
}

int main(int argc, char **argv) {
    mem_mode = argc > 1 && strcmp(argv[1], "-m") == 0;
    if (mem_mode) {
        mem_buf = mmap((void *) MEM_BUF_ADDR, MEM_BUF_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
        if (mem_buf != (uint8_t *) MEM_BUF_ADDR)
            return 2;
    }
    size_t sz = 1 << 14;
#ifdef __APPLE__
    code = mmap(NULL, sz, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
#else
    code = mmap(NULL, sz, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
#endif
    if (code == MAP_FAILED)
        return 1;
    struct sigaction sa = { 0 };
    sa.sa_handler = on_ill;
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    unsigned w;
    while (scanf("%x", &w) == 1) {
#ifdef __APPLE__
        pthread_jit_write_protect_np(0);
#endif
        emit_trampoline(w);
#ifdef __APPLE__
        pthread_jit_write_protect_np(1);
#endif
        for (int k = 0; k < 3; k++) {
            static struct state s;
            fill(&s, k, w);
            int sig = sigsetjmp(jb, 1);
            if (sig) {
                printf("%08x %d %s\n", w, k, sig == 1 ? "ILL" : "SEGV");
                break;
            }
            ((void (*)(struct state *)) code)(&s);
            uint32_t h = 2166136261u;
            const uint8_t *b = (const uint8_t *) &s;
            for (size_t i = 0; i < sizeof s; i++)
                h = (h ^ b[i]) * 16777619u;
            for (size_t i = 0; mem_mode && i < MEM_BUF_SIZE; i++)
                h = (h ^ mem_buf[i]) * 16777619u;
            printf("%08x %d %08x\n", w, k, h);
        }
    }
    return 0;
}
