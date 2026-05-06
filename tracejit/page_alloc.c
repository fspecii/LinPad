// See page_alloc.h for the seam contract.

#include "tracejit/page_alloc.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#if defined(__APPLE__)
#  include <pthread.h>
#  include <libkern/OSCacheControl.h>
#  ifndef MAP_JIT
#    define MAP_JIT 0x800
#  endif
#endif

size_t jit_page_size(void) {
    long sz = sysconf(_SC_PAGESIZE);
    return sz > 0 ? (size_t)sz : 4096;
}

void *jit_page_alloc(size_t size) {
    size_t page = jit_page_size();
    size = (size + page - 1) & ~(page - 1);

    int prot = PROT_READ | PROT_WRITE | PROT_EXEC;
    int flags = MAP_PRIVATE | MAP_ANON;
#if defined(__APPLE__)
    flags |= MAP_JIT;
#endif

    void *p = mmap(NULL, size, prot, flags, -1, 0);
    if (p == MAP_FAILED) return NULL;

    // Region is born in the W=off, X=on state on macOS. Caller must
    // call jit_page_writable_begin to mutate.
    return p;
}

void jit_page_free(void *p, size_t size) {
    if (!p) return;
    size_t page = jit_page_size();
    size = (size + page - 1) & ~(page - 1);
    munmap(p, size);
}

void jit_page_writable_begin(void) {
#if defined(__APPLE__)
    pthread_jit_write_protect_np(0);
#endif
}

void jit_page_writable_end(void) {
#if defined(__APPLE__)
    pthread_jit_write_protect_np(1);
#endif
}

void jit_icache_flush(void *addr, size_t size) {
#if defined(__APPLE__)
    sys_icache_invalidate(addr, size);
#elif defined(__GNUC__)
    __builtin___clear_cache((char *)addr, (char *)addr + size);
#endif
}

bool jit_page_alloc_self_test(int imm) {
    size_t page = jit_page_size();
    void *p = jit_page_alloc(page);
    if (!p) {
        fprintf(stderr, "[tracejit] jit_page_alloc failed: %s\n", strerror(errno));
        return false;
    }

    // ARM64: `movz w0, #imm` ; `ret`.
    // Encoding: 0x52800000 | (imm << 5) | rd
    uint32_t code[2];
    code[0] = 0x52800000u | ((uint32_t)(imm & 0xffff) << 5) | 0;
    code[1] = 0xd65f03c0u;  // ret

    jit_page_writable_begin();
    memcpy(p, code, sizeof code);
    jit_page_writable_end();
    jit_icache_flush(p, sizeof code);

    int (*fn)(void) = (int (*)(void))p;
    int r = fn();
    jit_page_free(p, page);

    if (r != imm) {
        fprintf(stderr, "[tracejit] self-test mismatch: got %d, expected %d\n", r, imm);
        return false;
    }
    return true;
}
