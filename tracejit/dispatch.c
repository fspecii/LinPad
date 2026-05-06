#include "tracejit/dispatch.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

static uint64_t g_base  = TRACEJIT_V8_BASE_DEFAULT;
static uint64_t g_limit = TRACEJIT_V8_LIMIT_DEFAULT;
static void **g_table;
static pthread_mutex_t g_table_mu = PTHREAD_MUTEX_INITIALIZER;

void tracejit_set_range(uint64_t base, uint64_t limit) {
    pthread_mutex_lock(&g_table_mu);
    if (g_table != NULL) {
        // Already allocated against old range; ignore reconfigure.
        // (We could re-allocate, but the env override is set at process
        // start so this path shouldn't fire in practice.)
    } else {
        g_base = base;
        g_limit = limit;
    }
    pthread_mutex_unlock(&g_table_mu);
}

uint64_t tracejit_range_base(void)  { return g_base; }
uint64_t tracejit_range_limit(void) { return g_limit; }

void **tracejit_dispatch_table(void) {
    if (g_table) return g_table;
    pthread_mutex_lock(&g_table_mu);
    if (!g_table) {
        size_t entries = (g_limit - g_base) >> 2;
        size_t bytes = entries * sizeof(void *);
        void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p == MAP_FAILED) {
            fprintf(stderr, "[tracejit] dispatch table mmap(%zu) failed\n", bytes);
        } else {
            g_table = p;
        }
    }
    pthread_mutex_unlock(&g_table_mu);
    return g_table;
}

void tracejit_table_publish(uint64_t pc, void *fn) {
    if (!tracejit_pc_in_table(pc)) return;
    void **t = tracejit_dispatch_table();
    if (!t) return;
    uint64_t idx = tracejit_pc_to_idx(pc);
    __atomic_store_n(&t[idx], fn, __ATOMIC_RELEASE);
}

void *tracejit_table_lookup(uint64_t pc) {
    if (!tracejit_pc_in_table(pc)) return NULL;
    void **t = tracejit_dispatch_table();
    if (!t) return NULL;
    return __atomic_load_n(&t[tracejit_pc_to_idx(pc)], __ATOMIC_ACQUIRE);
}
