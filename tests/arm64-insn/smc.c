// Self-modifying code in RWX memory, published with __builtin___clear_cache
// (DC CVAU + IC IVAU), the way sljit/PCRE2 JIT does it. Guest-only (Linux):
//   gcc -O1 -o smc smc.c && ./smc      expected: "smc ok"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

typedef uint64_t (*fn_t)(void);

static void emit(uint32_t *code, uint16_t value) {
    code[0] = 0xd2800000 | ((uint32_t) value << 5);   // movz x0, #value
    code[1] = 0xd65f03c0;                             // ret
    __builtin___clear_cache((char *) code, (char *) (code + 2));
}

int main(void) {
    uint32_t *code = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                          MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (code == MAP_FAILED)
        return 1;
    int bad = 0;
    for (uint16_t v = 1; v <= 200; v++) {
        emit(code, v);
        uint64_t got = ((fn_t) code)();
        if (got != v && bad++ < 5)
            printf("iteration %u: got %llu\n", v, (unsigned long long) got);
    }
    printf(bad ? "smc FAIL bad=%d\n" : "smc ok\n", bad);
    return bad != 0;
}
