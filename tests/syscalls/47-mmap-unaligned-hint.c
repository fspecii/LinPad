// Checks: mmap without MAP_FIXED takes an address that is not page aligned as a hint, as Linux
// does (rounded down), and still maps; with MAP_FIXED such an address is EINVAL.
// Observed: any unaligned address was EINVAL. Dart hints with an address inside a page when it
// reserves memory near its code, and the Flutter tool's snapshot step aborted ("mmap failed:
// 22 (Invalid argument)").
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <sys/mman.h>

static int failed;
static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
    failed |= !ok;
}

int main(void) {
    void *hint = (void *) ((uintptr_t) &check + 0x144);
    unsigned char *p = mmap(hint, 0xff000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    check(p != MAP_FAILED && ((uintptr_t) p & 0xfff) == 0, "an unaligned hint still maps, page aligned");
    if (p != MAP_FAILED) {
        memset(p, 0x42, 0xff000);
        check(p[0xff000 - 1] == 0x42, "and the mapping is usable");
    }
    errno = 0;
    void *q = mmap((void *) 0x7000000123, 4096, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    check(q == MAP_FAILED && errno == EINVAL, "an unaligned MAP_FIXED address is EINVAL");
    return failed;
}
