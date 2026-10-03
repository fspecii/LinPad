#ifndef PLATFORM_H
#define PLATFORM_H
#include "misc.h"

// for some reason a tick is always 10ms
struct cpu_usage {
    uint64_t user_ticks;
    uint64_t system_ticks;
    uint64_t idle_ticks;
    uint64_t nice_ticks;
};
struct cpu_usage get_cpu_usage(void);

struct mem_usage {
    uint64_t total;     // physical memory
    uint64_t free;
    uint64_t active;
    uint64_t inactive;
    uint64_t available; // what can still be allocated (iOS: this app's jetsam headroom)
    uint64_t cached;    // file-backed pages
};
struct mem_usage get_mem_usage(void);

// How much more memory this process may use before the host kills it, or 0 when there
// is no such limit. iOS: os_proc_available_memory(). Elsewhere ISH_MEM_LIMIT_MB=<n>
// emulates an iOS per-process limit of n MB (n minus this process's phys_footprint),
// so the iPad's low-memory behaviour can be tested on the Mac.
uint64_t host_memory_headroom(void);
// What the host charges this process for (Darwin: phys_footprint, the number jetsam
// compares with the limit), or 0 when unknown.
uint64_t host_memory_footprint(void);

struct uptime_info {
    uint64_t uptime_ticks;
    uint64_t load_1m, load_5m, load_15m;
};
struct uptime_info get_uptime(void);

#endif
