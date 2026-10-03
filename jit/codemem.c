// Executable memory for the JIT.
//
// One arena per process, carved into fixed-size chunks that are handed to
// address spaces. Three ways to get the arena:
//
//  * MAP_JIT (macOS default): one RWX-capable mapping, toggled per thread
//    with pthread_jit_write_protect_np. rw == rx.
//  * Dual mapping (iOS/simulator, or ISH_JIT_DUALMAP=1 on macOS): an RX view
//    for execution and an RW alias (mach_vm_remap) for writing.
//  * Named chunks (ISH_JIT_NAMED=1, prototype; not on TXM devices): both views
//    are reserved PROT_NONE and each chunk is its own named memory object
//    mapped into both. A vm_remap alias is charged twice in phys_footprint
//    once both views have touched a page (and MADV_FREE_REUSABLE on it
//    confuses the ledger); a named object mapped twice is charged once, and a
//    freed chunk is unmapped, so its memory really goes back.
//  * TXM devices (iOS 26+): the RX region is created by the debugger.
//    StikDebug's universal.js protocol: `brk #0xf00d` with x16 = 1,
//    x0 = 0 (let debugserver allocate), x1 = size; the address comes back in
//    x0. Then we make the RW alias the same way as in the dual mapping.
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <pthread.h>
#include <TargetConditionals.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <libkern/OSCacheControl.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif
#include "jit/jit_internal.h"

#define CHUNK_SIZE (2u << 20)

static uint8_t *arena_rx, *arena_rw;
static size_t arena_size;
static ptrdiff_t rw_delta;
static bool txm_arena;
static bool named_chunks;
static size_t budget, used, min_budget;   // chunks (see jit_codemem_alloc_chunk)
static const uintptr_t line = 64;   // NOT hw.cachelinesize (128): with a 128-byte stride stale instructions were executed
static const char *mode = "none";
static bool use_map_jit __attribute__((unused));
static struct jit_chunk **chunk_owner;
static uint8_t *chunk_used;
static size_t nchunks;
static pthread_mutex_t chunk_lock = PTHREAD_MUTEX_INITIALIZER;

static size_t env_size(const char *name, size_t def) {
    const char *e = getenv(name);
    return e ? (size_t) atol(e) << 20 : def;
}

bool jit_debugger_attached(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc info;
    size_t size = sizeof(info);
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0)
        return false;
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

// CS_DEBUGGED: set once a debugger has attached (and stays after it detaches).
// Without TXM that is all executable memory needs.
#define JIT_CS_OPS_STATUS 0
#define JIT_CS_DEBUGGED 0x10000000
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

bool jit_cs_debugged(void) {
    uint32_t flags = 0;
    if (csops(getpid(), JIT_CS_OPS_STATUS, &flags, sizeof(flags)) != 0)
        return false;
    return (flags & JIT_CS_DEBUGGED) != 0;
}

// Whether the device has TXM (iOS 26+), where executable memory must also be
// prepared by the debugger through the universal.js breakpoint protocol.
// Same rule as StikDebug's ProcessInfo.hasTXM: on iOS 27 every device except
// iPad8,11/12; on iOS 26 iPhone >= 14,2 and iPad >= 14,5 (A15/M2 and later).
bool jit_txm_present(void) {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    char os[32] = "", hw[64] = "";
    size_t len = sizeof(os);
    if (sysctlbyname("kern.osproductversion", os, &len, NULL, 0) != 0)
        return false;
    len = sizeof(hw);
    if (sysctlbyname("hw.machine", hw, &len, NULL, 0) != 0)
        return false;
    int major = atoi(os);
    if (major >= 27)
        return strcmp(hw, "iPad8,11") != 0 && strcmp(hw, "iPad8,12") != 0;
    if (major < 26)
        return false;
    bool ipad = strncmp(hw, "iPad", 4) == 0;
    const char *num = hw + (ipad ? 4 : strncmp(hw, "iPhone", 6) == 0 ? 6 : 0);
    if (num == hw)
        return false;
    int a = 0, b = 0;
    if (sscanf(num, "%d,%d", &a, &b) != 2)
        return false;
    // "14,5" compares as 14.5 and "14,10" as 14.10 (StikDebug's decimal reading)
    double ver = a, div = 1;
    for (int t = b; t > 0; t /= 10)
        div *= 10;
    ver += b / div;
    return ver >= (ipad ? 14.5 : 14.2);
#else
    return false;
#endif
}

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
// StikDebug universal.js protocol
__attribute__((naked, noinline)) static void *jit26_prepare_region(void *addr, size_t len) {
    __asm__("mov x16, #1\n brk #0xf00d\n ret");
}
__attribute__((naked, noinline)) static void jit26_detach(void) {
    __asm__("mov x16, #0\n brk #0xf00d\n ret");
}

// Only call with the universal.js script attached: a brk without it kills
// the process (jit_debug_ready checks P_TRACED and CS_DEBUGGED first).
static bool acquire_txm(size_t size) {
    void *rx = jit26_prepare_region(NULL, size);
    if (rx == NULL || ((uintptr_t) rx & 0x3fff) || (uintptr_t) rx == 0xE0000069 ||
        (uintptr_t) rx >= 0x1000000000ull)
        return false;
    arena_rx = rx;
    return true;
}
#endif

// Named chunks: reserve both views; chunks are mapped in by map_named_chunk.
static bool reserve_named_arena(void) {
    void *rx = mmap(NULL, arena_size, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    void *rw = mmap(NULL, arena_size, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (rx == MAP_FAILED || rw == MAP_FAILED) {
        if (rx != MAP_FAILED)
            munmap(rx, arena_size);
        if (rw != MAP_FAILED)
            munmap(rw, arena_size);
        return false;
    }
    arena_rx = rx;
    arena_rw = rw;
    rw_delta = arena_rw - arena_rx;
    named_chunks = true;
    return true;
}

static void unmap_named_chunk(size_t i) {
    mmap(arena_rw + i * CHUNK_SIZE, CHUNK_SIZE, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    mmap(arena_rx + i * CHUNK_SIZE, CHUNK_SIZE, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
}

static bool map_named_chunk(size_t i) {
    memory_object_size_t size = CHUNK_SIZE;
    mach_port_t entry = MACH_PORT_NULL;
    if (mach_make_memory_entry_64(mach_task_self(), &size, 0,
                                  MAP_MEM_NAMED_CREATE | VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE,
                                  &entry, MACH_PORT_NULL) != KERN_SUCCESS)
        return false;
    vm_address_t rw = (vm_address_t) (arena_rw + i * CHUNK_SIZE);
    vm_address_t rx = (vm_address_t) (arena_rx + i * CHUNK_SIZE);
    kern_return_t kr = vm_map(mach_task_self(), &rw, CHUNK_SIZE, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                              entry, 0, false, VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE,
                              VM_INHERIT_NONE);
    if (kr == KERN_SUCCESS)
        kr = vm_map(mach_task_self(), &rx, CHUNK_SIZE, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                    entry, 0, false, VM_PROT_READ | VM_PROT_EXECUTE, VM_PROT_READ | VM_PROT_EXECUTE,
                    VM_INHERIT_NONE);
    mach_port_deallocate(mach_task_self(), entry);
    if (kr != KERN_SUCCESS) {
        unmap_named_chunk(i);
        return false;
    }
    return true;
}

static bool want_named(void) {
    const char *e = getenv("ISH_JIT_NAMED");
    return e && e[0] == '1';
}

static bool make_rw_alias(void) {
    vm_address_t rw = 0;
    vm_prot_t cur, max;
    // vm_remap: mach_vm.h is unavailable in the iOS SDK; same call on arm64.
    kern_return_t kr = vm_remap(mach_task_self(), &rw, arena_size, 0, VM_FLAGS_ANYWHERE,
                                mach_task_self(), (vm_address_t) arena_rx, false,
                                &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS)
        return false;
    if (mprotect((void *) rw, arena_size, PROT_READ | PROT_WRITE) != 0)
        return false;
    arena_rw = (uint8_t *) rw;
    rw_delta = arena_rw - arena_rx;
    return true;
}

bool jit_codemem_init(void) {
    // Chains between chunks more than 128 MB apart go through veneers or
    // far_chain (jit.c chain()); exits stay inside their chunk.
#if TARGET_OS_IPHONE
    // On TXM devices the whole region becomes resident (the debugger writes
    // every page), so ask for less when the app is short of memory. Firefox
    // needs about 350 MB of translations over its processes (180 MB in the
    // main one): at 128 MB it retranslates all the time (1 fps scrolling,
    // 1 s typing latency on the Mac at that size), at 256 MB it mostly fits.
    // The app sets ISH_JIT_CACHE_MB from its "code cache" setting.
    uint64_t avail = os_proc_available_memory();
    arena_size = env_size("ISH_JIT_CACHE_MB", avail > (3ull << 30) ? 256u << 20 : avail > (3ull << 29) ? 128u << 20 : 64u << 20);
#else
    arena_size = env_size("ISH_JIT_CACHE_MB", 512u << 20);
#endif
    arena_size &= ~(size_t) (CHUNK_SIZE - 1);

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    if (jit_txm_present()) {
        // universal.js order: prepare every RX region, create the writable
        // alias, then detach. The script stays attached until the detach, so
        // detach even when a step failed.
        if (!jit_debugger_attached())
            return false;
        mode = "txm (StikDebug universal.js)";
        txm_arena = true;
        bool ok = acquire_txm(arena_size) && make_rw_alias();
        jit26_detach();
        if (!ok) {
            txm_arena = false;
            return false;
        }
    } else {
        // No TXM: CS_DEBUGGED alone lets RW -> remap -> RX work. No breakpoint
        // calls here: no script is attached.
        mode = "cs_debugged dual mapping";
        if (want_named() && reserve_named_arena()) {
            mode = "cs_debugged named chunks";
            goto done_ios;
        }
        void *p = mmap(NULL, arena_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p == MAP_FAILED)
            return false;
        arena_rx = p;
        if (!make_rw_alias() || mprotect(arena_rx, arena_size, PROT_READ | PROT_EXEC) != 0)
            return false;
    }
done_ios:
#else
    // Default: dual mapping (same scheme as iOS; also avoids the per-thread
    // W^X toggles). ISH_JIT_MAPJIT=1 selects a single MAP_JIT mapping instead.
    const char *mj = getenv("ISH_JIT_MAPJIT");
    bool want_dual = !(mj && mj[0] == '1');
#if TARGET_OS_IPHONE
    want_dual = true;
#endif
    if (want_dual && want_named() && reserve_named_arena()) {
        mode = "named chunks";
        goto done;
    }
    if (want_dual) {
        void *p = mmap(NULL, arena_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p != MAP_FAILED) {
            arena_rx = p;
            if (make_rw_alias() && mprotect(arena_rx, arena_size, PROT_READ | PROT_EXEC) == 0) {
                mode = "dual mapping";
                goto done;
            }
            munmap(p, arena_size);
            arena_rx = arena_rw = NULL;
        }
    }
    {
        void *p = mmap(NULL, arena_size, PROT_READ | PROT_WRITE | PROT_EXEC,
                       MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
        if (p == MAP_FAILED)
            return false;
        arena_rx = arena_rw = p;
        rw_delta = 0;
        use_map_jit = true;
        mode = "MAP_JIT";
    }
done:
#endif
    nchunks = arena_size / CHUNK_SIZE;
#if TARGET_OS_IPHONE
    min_budget = nchunks < 16 ? nchunks : 16;   // 32 MB
#else
    min_budget = nchunks;
#endif
    const char *mb = getenv("ISH_JIT_BUDGET_MB");   // minimum budget, e.g. to test the iOS policy
    if (mb && atol(mb) >= 2 && (size_t) atol(mb) / 2 < nchunks)
        min_budget = atol(mb) / 2;
    budget = min_budget;
    chunk_owner = calloc(nchunks, sizeof(*chunk_owner));
    chunk_used = calloc(nchunks, 1);
    if (chunk_owner == NULL || chunk_used == NULL)
        return false;   // the JIT stays off; the arena is left reserved
    return true;
}

// Adaptive budget: the arena is reserved up front, but only `budget`
// chunks may be in use. On iOS the budget starts at 32 MB and grows in 16 MB
// steps while os_proc_available_memory() leaves at least 768 MB; a memory
// warning (jit_codemem_trim) drops it back. Elsewhere it is the whole arena.

static bool may_grow(void) {
#if TARGET_OS_IPHONE
    return os_proc_available_memory() > (768ull << 20);
#else
    return true;
#endif
}

// anchor: the address space's first chunk (or NULL). Chunks of one address
// space are taken within +-JIT_WINDOW_CHUNKS/2 of it when possible, so blocks
// can branch to each other with a plain b (+-128 MB); farther chunks are
// reached through veneers. Either way chains never need an exit, which
// LDXR/STXR loops spanning blocks rely on.
uint32_t *jit_codemem_alloc_chunk(size_t *size, uint32_t *anchor) {
    pthread_mutex_lock(&chunk_lock);
    if (used >= budget) {
        if (budget < nchunks && may_grow())
            budget = budget + 8 < nchunks ? budget + 8 : nchunks;
        if (used >= budget) {
            pthread_mutex_unlock(&chunk_lock);
            return NULL;   // the caller retires its oldest chunk (FIFO)
        }
    }
    size_t lo = 0, hi = nchunks;
    if (anchor) {
        size_t a = ((uint8_t *) anchor - arena_rx) / CHUNK_SIZE;
        lo = a > JIT_WINDOW_CHUNKS / 2 ? a - JIT_WINDOW_CHUNKS / 2 : 0;
        hi = a + JIT_WINDOW_CHUNKS / 2 + 1 < nchunks ? a + JIT_WINDOW_CHUNKS / 2 + 1 : nchunks;
    }
    // Other address spaces can fill the window. Then take any free chunk:
    // chains to it go through far-jump veneers. Returning NULL instead made
    // the caller retire its own code, again and again (Firefox, many
    // processes: 70 s instead of 6 s).
    for (int pass = 0; pass < 2; pass++) {
        size_t from = pass ? 0 : lo, to = pass ? nchunks : hi;
        for (size_t i = from; i < to; i++) {
            if (!chunk_used[i]) {
                if (named_chunks && !map_named_chunk(i)) {
                    pthread_mutex_unlock(&chunk_lock);
                    return NULL;   // out of host memory
                }
                chunk_used[i] = 1;
                used++;
                pthread_mutex_unlock(&chunk_lock);
                *size = CHUNK_SIZE;
                return (uint32_t *) (arena_rx + i * CHUNK_SIZE);
            }
        }
        if (!anchor)
            break;
    }
    pthread_mutex_unlock(&chunk_lock);
    return NULL;
}

void jit_codemem_free_chunk(uint32_t *rx, size_t size) {
    (void) size;
    size_t i = ((uint8_t *) rx - arena_rx) / CHUNK_SIZE;
    // Give the pages back to the system (both views). Not on TXM devices:
    // there a page is executable only because the debugger wrote it, and a
    // discarded page would come back as a fresh, non-executable one.
    if (named_chunks) {
        unmap_named_chunk(i);
    } else if (!txm_arena) {
        madvise(arena_rw + i * CHUNK_SIZE, CHUNK_SIZE, MADV_FREE_REUSABLE);
        if (arena_rw != arena_rx)
            madvise(arena_rx + i * CHUNK_SIZE, CHUNK_SIZE, MADV_FREE_REUSABLE);
    }
    pthread_mutex_lock(&chunk_lock);
    chunk_used[i] = 0;
    chunk_owner[i] = NULL;
    used--;
    pthread_mutex_unlock(&chunk_lock);
}

size_t jit_codemem_trim(void) {
    pthread_mutex_lock(&chunk_lock);
    budget = min_budget;
    size_t over = used > budget ? used - budget : 0;
    pthread_mutex_unlock(&chunk_lock);
    return over;
}

void jit_codemem_usage(size_t *used_bytes, size_t *budget_bytes) {
    *used_bytes = used * CHUNK_SIZE;
    *budget_bytes = budget * CHUNK_SIZE;
}

void jit_chunk_register(struct jit_chunk *c) {
    size_t i = ((uint8_t *) c->rx - arena_rx) / CHUNK_SIZE;
    __atomic_store_n(&chunk_owner[i], c, __ATOMIC_RELEASE);
}
void jit_chunk_unregister(struct jit_chunk *c) {
    size_t i = ((uint8_t *) c->rx - arena_rx) / CHUNK_SIZE;
    __atomic_store_n(&chunk_owner[i], NULL, __ATOMIC_RELEASE);
}
struct jit_chunk *jit_chunk_of(uintptr_t pc) {
    if (!jit_in_code(pc))
        return NULL;
    return __atomic_load_n(&chunk_owner[(pc - (uintptr_t) arena_rx) / CHUNK_SIZE], __ATOMIC_ACQUIRE);
}

uint32_t *jit_rw(uint32_t *rx) {
    return (uint32_t *) ((uint8_t *) rx + rw_delta);
}

// Nested write sections are counted per thread (patching can happen while
// a translation is being written on the same thread).
static __thread int write_depth __attribute__((unused));

void jit_write_begin(void) {
#if !TARGET_OS_IPHONE
    if (use_map_jit && write_depth++ == 0)
        pthread_jit_write_protect_np(0);
#endif
}

// Make freshly written code visible to instruction fetch: clean the data
// lines (through the RW view) and invalidate the instruction lines (through
// the RX view). 64 bytes is a safe stride (lines are >= 64 bytes). The
// barrier is separate so a batch of 4-byte patches pays for it once.
void jit_icache_lines(void *rx, size_t len) {
    uintptr_t start = (uintptr_t) rx & ~(line - 1), end = (uintptr_t) rx + len;
    for (uintptr_t a = start; a < end; a += line)
        __asm__ volatile("dc cvau, %0" :: "r"(a + rw_delta) : "memory");
    __asm__ volatile("dsb ish" ::: "memory");
    for (uintptr_t a = start; a < end; a += line)
        __asm__ volatile("ic ivau, %0" :: "r"(a) : "memory");
}
void jit_icache_sync(void) {
    __asm__ volatile("dsb ish\n isb" ::: "memory");
}

void jit_write_finish(void) {
#if !TARGET_OS_IPHONE
    if (use_map_jit && --write_depth == 0)
        pthread_jit_write_protect_np(1);
#endif
}

void jit_write_end(void *rx, size_t len) {
    jit_write_finish();
    jit_icache_lines(rx, len);
    jit_icache_sync();
}

const char *jit_codemem_mode(void) { return mode; }

bool jit_in_code(uintptr_t pc) {
    return pc >= (uintptr_t) arena_rx && pc < (uintptr_t) arena_rx + arena_size;
}
uintptr_t jit_code_base(void) { return (uintptr_t) arena_rx; }
size_t jit_code_size(void) { return arena_size; }
