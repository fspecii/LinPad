// Atomics and load/store-pair conformance test (CAS, CASP, LDXP/STXP, LDNP/STNP, LDPSW).
// Build natively and in the guest, diff the output:
//   cc -O1 -march=armv8.2-a -pthread -o mem mem.c && ./mem > native.txt
#include <inttypes.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define P(...) printf(__VA_ARGS__)

static uint64_t mem[8] __attribute__((aligned(64)));

static void reset(void) {
    for (int i = 0; i < 8; i++)
        mem[i] = 0x1111111111111111ull * (i + 1) ^ 0x8000000000000000ull;
}

static void dump(const char *tag) {
    P("%s mem", tag);
    for (int i = 0; i < 4; i++)
        P(" %016" PRIx64, mem[i]);
    P("\n");
}

#define CAS1(name, insn, expect, desired)                                          \
    do {                                                                           \
        reset();                                                                   \
        uint64_t rs = (expect), rt = (desired);                                    \
        __asm__ volatile(insn " %[rs], %[rt], [%[p]]"                              \
                         : [rs] "+r"(rs) : [rt] "r"(rt), [p] "r"(mem) : "memory"); \
        P("%s rs=%016" PRIx64 " ", name, rs);                                      \
        dump("");                                                                  \
    } while (0)

#define CAS1W(name, insn, expect, desired)                                         \
    do {                                                                           \
        reset();                                                                   \
        uint32_t rs = (expect), rt = (desired);                                    \
        __asm__ volatile(insn " %w[rs], %w[rt], [%[p]]"                            \
                         : [rs] "+r"(rs) : [rt] "r"(rt), [p] "r"(mem) : "memory"); \
        P("%s rs=%08" PRIx32 " ", name, rs);                                       \
        dump("");                                                                  \
    } while (0)

static void test_cas(void) {
    uint64_t m0 = 0x1111111111111111ull ^ 0x8000000000000000ull;
    CAS1("cas_x_ok", "cas", m0, 0xdeadbeefcafef00dull);
    CAS1("cas_x_fail", "cas", m0 + 1, 0xdeadbeefcafef00dull);
    CAS1("casa_x_ok", "casa", m0, 0x0123456789abcdefull);
    CAS1("casl_x_ok", "casl", m0, 0x0123456789abcdefull);
    CAS1("casal_x_fail", "casal", 5, 0x0123456789abcdefull);
    CAS1W("cas_w_ok", "cas", (uint32_t) m0, 0xcafef00d);
    CAS1W("casal_w_fail", "casal", 7, 0xcafef00d);
    CAS1W("casb_ok", "casb", (uint8_t) m0, 0xab);
    CAS1W("casab_fail", "casab", 0x12, 0xab);
    CAS1W("caslh_ok", "caslh", (uint16_t) m0, 0xabcd);
    CAS1W("casalh_fail", "casalh", 0x1234, 0xabcd);
}

// CASP with fixed even/odd pairs: Rs = x10:x11 (the register pair that used to be
// misdecoded), Rt = x4:x5.
#define CASPX(name, insn, e0, e1, n0, n1)                                            \
    do {                                                                             \
        reset();                                                                     \
        register uint64_t r10 __asm__("x10") = (e0);                                 \
        register uint64_t r11 __asm__("x11") = (e1);                                 \
        register uint64_t r4 __asm__("x4") = (n0);                                   \
        register uint64_t r5 __asm__("x5") = (n1);                                   \
        __asm__ volatile(insn " x10, x11, x4, x5, [%[p]]"                            \
                         : "+r"(r10), "+r"(r11) : "r"(r4), "r"(r5), [p] "r"(mem)     \
                         : "memory");                                                \
        P("%s rs=%016" PRIx64 ",%016" PRIx64 " ", name, r10, r11);                   \
        dump("");                                                                    \
    } while (0)

#define CASPW(name, insn, e0, e1, n0, n1)                                            \
    do {                                                                             \
        reset();                                                                     \
        register uint64_t r2 __asm__("x2") = (e0);                                   \
        register uint64_t r3 __asm__("x3") = (e1);                                   \
        register uint64_t r6 __asm__("x6") = (n0);                                   \
        register uint64_t r7 __asm__("x7") = (n1);                                   \
        __asm__ volatile(insn " w2, w3, w6, w7, [%[p]]"                              \
                         : "+r"(r2), "+r"(r3) : "r"(r6), "r"(r7), [p] "r"(mem)       \
                         : "memory");                                                \
        P("%s rs=%016" PRIx64 ",%016" PRIx64 " ", name, r2, r3);                     \
        dump("");                                                                    \
    } while (0)

static void test_casp(void) {
    uint64_t m0 = 0x1111111111111111ull ^ 0x8000000000000000ull;
    uint64_t m1 = 0x2222222222222222ull ^ 0x8000000000000000ull;
    CASPX("casp_x_ok", "casp", m0, m1, 0xa0a0a0a0a0a0a0a0ull, 0xb1b1b1b1b1b1b1b1ull);
    CASPX("casp_x_fail_lo", "casp", m0 ^ 1, m1, 1, 2);
    CASPX("casp_x_fail_hi", "caspa", m0, m1 ^ 1, 1, 2);
    CASPX("caspl_x_ok", "caspl", m0, m1, 3, 4);
    CASPX("caspal_x_ok", "caspal", m0, m1, 5, 6);
    CASPW("casp_w_ok", "casp", (uint32_t) m0, (uint32_t) (m0 >> 32), 0x11223344, 0x55667788);
    CASPW("casp_w_fail", "caspal", (uint32_t) m0, 0, 0x11223344, 0x55667788);
    CASPW("casp_w_dirty_hi", "caspa", 0xffffffff00000000ull | (uint32_t) m0,
          0xffffffff00000000ull | (uint32_t) (m0 >> 32), 9, 10);
}

static void test_excl_pair(void) {
    // ldxp x10, x11, [x20] (c87f2e8a) is the libpas encoding that used to run as CAS.
    reset();
    register uint64_t *p20 __asm__("x20") = mem;
    register uint64_t r10 __asm__("x10");
    register uint64_t r11 __asm__("x11");
    register uint64_t r12 __asm__("x12") = 0;
    __asm__ volatile(
        "1: ldxp x10, x11, [x20]\n\t"
        "add x13, x10, #1\n\t"
        "add x14, x11, #2\n\t"
        "stxp w12, x13, x14, [x20]\n\t"
        "cbnz w12, 1b\n\t"
        : "=&r"(r10), "=&r"(r11), "+r"(r12) : "r"(p20) : "x13", "x14", "memory");
    P("ldxp_stxp_x old=%016" PRIx64 ",%016" PRIx64 " status=%" PRIu64 " ", r10, r11, r12);
    dump("");

    reset();
    uint64_t a, b, st;
    __asm__ volatile(
        "1: ldaxp %w[a], %w[b], [%[p]]\n\t"
        "add %w[a], %w[a], #3\n\t"
        "stlxp %w[st], %w[b], %w[a], [%[p]]\n\t"
        "cbnz %w[st], 1b\n\t"
        : [a] "=&r"(a), [b] "=&r"(b), [st] "=&r"(st) : [p] "r"(mem) : "memory");
    P("ldaxp_stlxp_w a=%016" PRIx64 " b=%016" PRIx64 " ", a, b);
    dump("");

    // Rt2 = xzr (the other misdecoded case).
    reset();
    __asm__ volatile(
        "1: ldxp %[a], xzr, [%[p]]\n\t"
        "stxp %w[st], xzr, xzr, [%[p]]\n\t"
        "cbnz %w[st], 1b\n\t"
        : [a] "=&r"(a), [st] "=&r"(st) : [p] "r"(mem) : "memory");
    P("ldxp_xzr a=%016" PRIx64 " ", a);
    dump("");
}

// Contention: every thread adds 1 to both halves of a 128-bit pair atomically; a torn
// update would make the halves diverge.
#define NTHREADS 4
#define NITER 20000
static uint64_t pair128[2] __attribute__((aligned(16)));
static uint32_t pair64[2] __attribute__((aligned(8)));
static uint64_t casp128[2] __attribute__((aligned(16)));
static volatile int torn;

static void *worker(void *arg) {
    (void) arg;
    for (int i = 0; i < NITER; i++) {
        uint64_t a, b, st;
        __asm__ volatile(
            "1: ldaxp %[a], %[b], [%[p]]\n\t"
            "add %[a], %[a], #1\n\t"
            "add %[b], %[b], #1\n\t"
            "stlxp %w[st], %[a], %[b], [%[p]]\n\t"
            "cbnz %w[st], 1b\n\t"
            : [a] "=&r"(a), [b] "=&r"(b), [st] "=&r"(st) : [p] "r"(pair128) : "memory");
        if (a != b)
            torn = 1;
        uint32_t c, d;
        uint64_t st2;
        __asm__ volatile(
            "1: ldxp %w[c], %w[d], [%[p]]\n\t"
            "add %w[c], %w[c], #1\n\t"
            "add %w[d], %w[d], #1\n\t"
            "stxp %w[st], %w[c], %w[d], [%[p]]\n\t"
            "cbnz %w[st], 1b\n\t"
            : [c] "=&r"(c), [d] "=&r"(d), [st] "=&r"(st2) : [p] "r"(pair64) : "memory");
        register uint64_t e0 __asm__("x10");
        register uint64_t e1 __asm__("x11");
        register uint64_t n0 __asm__("x12");
        register uint64_t n1 __asm__("x13");
        __asm__ volatile(
            "ldp x10, x11, [%[p]]\n\t"
            "1: add x12, x10, #1\n\t"
            "add x13, x11, #1\n\t"
            "mov x14, x10\n\t"
            "mov x15, x11\n\t"
            "caspal x10, x11, x12, x13, [%[p]]\n\t"
            "cmp x10, x14\n\t"
            "ccmp x11, x15, #0, eq\n\t"
            "b.ne 1b\n\t"
            : "=&r"(e0), "=&r"(e1), "=&r"(n0), "=&r"(n1) : [p] "r"(casp128)
            : "x14", "x15", "cc", "memory");
    }
    return NULL;
}

static void test_contention(void) {
    pthread_t t[NTHREADS];
    for (int i = 0; i < NTHREADS; i++)
        pthread_create(&t[i], NULL, worker, NULL);
    for (int i = 0; i < NTHREADS; i++)
        pthread_join(t[i], NULL);
    P("contention ldxp128=%" PRIu64 ",%" PRIu64 " ldxp64=%u,%u casp128=%" PRIu64 ",%" PRIu64 " torn=%d\n",
      pair128[0], pair128[1], pair64[0], pair64[1], casp128[0], casp128[1], torn);
}

static void test_nonalloc_pair(void) {
    uint64_t a, b;
    uint32_t wa, wb;
    reset();
    __asm__ volatile("stnp xzr, xzr, [%[p], #8]" :: [p] "r"(mem) : "memory");
    dump("stnp_xzr");
    reset();
    __asm__ volatile("stnp %[a], %[b], [%[p], #-16]" :: [a] "r"(0x0102030405060708ull),
                     [b] "r"(0x1112131415161718ull), [p] "r"(mem + 3) : "memory");
    dump("stnp_x_neg");
    reset();
    __asm__ volatile("ldnp %[a], %[b], [%[p], #16]" : [a] "=r"(a), [b] "=r"(b) : [p] "r"(mem));
    P("ldnp_x %016" PRIx64 " %016" PRIx64 "\n", a, b);
    reset();
    __asm__ volatile("ldnp %w[a], %w[b], [%[p], #4]" : [a] "=r"(wa), [b] "=r"(wb) : [p] "r"(mem));
    P("ldnp_w %08x %08x\n", wa, wb);
    reset();
    __asm__ volatile("stnp %w[a], %w[b], [%[p], #-4]" :: [a] "r"(0xaabbccdd), [b] "r"(0x11223344),
                     [p] "r"(mem + 1) : "memory");
    dump("stnp_w");
    reset();
    __asm__ volatile(
        "ldnp s13, s29, [%[p], #8]\n\t"
        "stnp s29, s13, [%[p], #-16]\n\t"
        "ldnp d1, d2, [%[p]]\n\t"
        "stnp d2, d1, [%[p], #-32]\n\t"
        :: [p] "r"(mem + 4) : "v1", "v2", "v13", "v29", "memory");
    dump("ldnp_stnp_s_d");
    reset();
    __asm__ volatile(
        "ldnp q3, q4, [%[p]]\n\t"
        "stnp q4, q3, [%[p]]\n\t"
        :: [p] "r"(mem) : "v3", "v4", "memory");
    dump("ldnp_stnp_q");
}

static void test_ldpsw(void) {
    static int32_t w[6] = { -1, 0x7fffffff, (int32_t) 0x80000000, 5, -12345, 42 };
    int64_t a, b;
    const int32_t *p;
    __asm__ volatile("ldpsw %[a], %[b], [%[p]]" : [a] "=r"(a), [b] "=r"(b) : [p] "r"(w));
    P("ldpsw_off %016" PRIx64 " %016" PRIx64 "\n", (uint64_t) a, (uint64_t) b);
    p = w;
    __asm__ volatile("ldpsw %[a], %[b], [%[p], #8]!" : [a] "=r"(a), [b] "=r"(b), [p] "+r"(p));
    P("ldpsw_pre %016" PRIx64 " %016" PRIx64 " p+%d\n", (uint64_t) a, (uint64_t) b, (int) (p - w));
    p = w + 4;
    __asm__ volatile("ldpsw %[a], %[b], [%[p]], #-16" : [a] "=r"(a), [b] "=r"(b), [p] "+r"(p));
    P("ldpsw_post %016" PRIx64 " %016" PRIx64 " p+%d\n", (uint64_t) a, (uint64_t) b, (int) (p - w));
    __asm__ volatile("ldpsw %[a], xzr, [%[p], #16]" : [a] "=r"(a) : [p] "r"(w));
    P("ldpsw_xzr %016" PRIx64 "\n", (uint64_t) a);
}

int main(void) {
    test_cas();
    test_casp();
    test_excl_pair();
    test_nonalloc_pair();
    test_ldpsw();
    test_contention();
    return 0;
}
