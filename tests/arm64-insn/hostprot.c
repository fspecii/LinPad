// Guest pages share a 16 KB host page on Apple hosts. Raising one guest page
// NONE->READ must not make a writable neighbour read-only on the host; and if a
// host fault does happen inside a C helper (atomic CAS), the emulator must not
// crash. Mirrors .NET's double-mapped memfd code heap (vsce-sign).
// Guest-only:  gcc -O1 -o hostprot hostprot.c && ./hostprot    expected: "hostprot ok"
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

static int run(int shared) {
    char *m;
    if (shared) {
        int fd = memfd_create("hp", 0);
        if (fd < 0 || ftruncate(fd, 65536) < 0) return 1;
        m = mmap(NULL, 65536, PROT_NONE, MAP_SHARED, fd, 0);
    } else {
        m = mmap(NULL, 65536, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    }
    if (m == MAP_FAILED) return 1;
    char *base = (char *) (((uintptr_t) m + 16383) & ~(uintptr_t) 16383);
    if (mprotect(base, 4096, PROT_READ | PROT_WRITE)) return 2;   // page 0 RW
    base[0] = 1;
    if (mprotect(base + 4096, 4096, PROT_READ)) return 3;          // page 1 NONE->READ
    uint64_t *p = (uint64_t *) (base + 64), old = 0;
    // CAS first: before the fixes this faulted inside c_atomic_cas on the host.
    __asm__ volatile("mov %0, #0\n\tmov x9, #5\n\tcasal %0, x9, [%1]" : "+r"(old) : "r"(p) : "x9", "memory");
    if (old != 0 || *p != 5) return 4;
    *p = 7;                                                        // plain store
    uint64_t v = __atomic_add_fetch(p, 1, __ATOMIC_SEQ_CST);       // LDADD / LDXR-STXR
    return v == 8 ? 0 : 5;
}

int main(void) {
    int a = run(0), b = run(1);
    if (a || b) { printf("hostprot FAIL private=%d shared=%d\n", a, b); return 1; }
    printf("hostprot ok\n");
    return 0;
}
