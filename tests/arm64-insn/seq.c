// Multi-instruction sequences the translator fuses (MOVZ/MOVN+MOVK constants,
// MOV pairs, CMP+B.cond). Prints register results; diff native vs guest.
//   cc -O1 -o seq seq.c && ./seq
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

#define SEQ(name, body)                                                          \
    do {                                                                         \
        uint64_t r[6] = {0x1111111111111111, 0x2222222222222222, 0x8000000180000001, 3, 4, 5}; \
        __asm__ volatile("ldp x0, x1, [%0]\n\tldp x2, x3, [%0, #16]\n\tldp x4, x5, [%0, #32]\n\t" \
                         body "\n\t"                                             \
                         "stp x0, x1, [%0]\n\tstp x2, x3, [%0, #16]\n\tstp x4, x5, [%0, #32]\n\t" \
                         :: "r"(r) : "x0", "x1", "x2", "x3", "x4", "x5", "memory", "cc"); \
        printf("%-14s", name);                                                   \
        for (int i = 0; i < 6; i++) printf(" %016" PRIx64, r[i]);                \
        printf("\n");                                                            \
    } while (0)

int main(void) {
    SEQ("movz_movk4", "movz x0, #0x1234, lsl #48\n\tmovk x0, #0x5678, lsl #32\n\tmovk x0, #0x9abc, lsl #16\n\tmovk x0, #0xdef0");
    SEQ("movz_w_movk", "movz w1, #0xffff\n\tmovk w1, #0x8000, lsl #16");
    SEQ("movn_movk", "movn x2, #0\n\tmovk x2, #0, lsl #32");
    SEQ("movn_w", "movn w3, #5, lsl #16");
    SEQ("movz_other", "movz x4, #7\n\tmovk x5, #9");
    SEQ("movz_xzr", "movz xzr, #7\n\tmovk x4, #1, lsl #16");
    SEQ("movz_movk_w_hi", "movz x1, #1\n\tmovk w1, #2, lsl #16");
    SEQ("mov_pair", "mov x3, x2\n\tmov x4, x3");
    SEQ("mov_pair_w", "mov w3, w2\n\tmov x5, x3");
    SEQ("mov_pair_mix", "mov x0, x1\n\tmov w1, w2");
    SEQ("mov_swap", "mov x4, x0\n\tmov x0, x1\n\tmov x1, x4");
    SEQ("cmp32_b", "cmp w2, w3\n\tb.lo 1f\n\tmov x5, #1\n1:\n\tsubs w4, w2, w0\n\tb.mi 2f\n\tmov x0, #9\n2:");
    return 0;
}
