#include <mach/mach.h>
#include <sys/sysctl.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif
#include <stdlib.h>
#include <sys/time.h>
#include "platform/platform.h"

uint64_t host_memory_footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t) &info, &count) != KERN_SUCCESS)
        return 0;
    return info.phys_footprint;
}

static uint64_t emulated_limit(void) {
    static uint64_t limit = UINT64_MAX;
    if (limit == UINT64_MAX) {
        const char *env = getenv("ISH_MEM_LIMIT_MB");
        limit = env ? (uint64_t) atoll(env) << 20 : 0;
    }
    return limit;
}

uint64_t host_memory_headroom(void) {
#if TARGET_OS_IPHONE
    if (emulated_limit() == 0)
        return os_proc_available_memory();
#endif
    uint64_t limit = emulated_limit();
    if (limit == 0)
        return 0;
    uint64_t used = host_memory_footprint();
    return used < limit ? limit - used : 1;
}

struct cpu_usage get_cpu_usage() {
    host_cpu_load_info_data_t load;
    mach_msg_type_number_t fuck = HOST_CPU_LOAD_INFO_COUNT;
    host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t) &load, &fuck);
    struct cpu_usage usage;
    usage.user_ticks = load.cpu_ticks[CPU_STATE_USER];
    usage.system_ticks = load.cpu_ticks[CPU_STATE_SYSTEM];
    usage.idle_ticks = load.cpu_ticks[CPU_STATE_IDLE];
    usage.nice_ticks = load.cpu_ticks[CPU_STATE_NICE];
    return usage;
}

struct mem_usage get_mem_usage() {
    host_basic_info_data_t basic = {};
    mach_msg_type_number_t fuck = HOST_BASIC_INFO_COUNT;
    kern_return_t status = host_info(mach_host_self(), HOST_BASIC_INFO, (host_info_t) &basic, &fuck);
    assert(status == KERN_SUCCESS);
    vm_statistics64_data_t vm = {};
    fuck = HOST_VM_INFO64_COUNT;
    status = host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info_t) &vm, &fuck);
    assert(status == KERN_SUCCESS);

    struct mem_usage usage;
    uint64_t memsize = 0;
    size_t size = sizeof(memsize);
    if (sysctlbyname("hw.memsize", &memsize, &size, NULL, 0) == 0 && memsize != 0)
        usage.total = memsize;
    else
        usage.total = basic.max_mem;
    usage.free = (uint64_t) vm.free_count * vm_page_size;
    usage.active = (uint64_t) vm.active_count * vm_page_size;
    usage.inactive = (uint64_t) vm.inactive_count * vm_page_size;
    usage.cached = (uint64_t) vm.external_page_count * vm_page_size;
    usage.available = (uint64_t) (vm.free_count + vm.inactive_count +
            vm.purgeable_count + vm.speculative_count) * vm_page_size;
    // An iOS app is killed by jetsam long before the device runs out of memory.
    // What limits the guest is this process's allowance, so MemTotal is that
    // allowance (footprint + headroom) and MemAvailable what is left of it:
    // Firefox, V8 and allocators size their caches and heaps from MemTotal, and
    // Firefox's low-memory watcher compares MemAvailable with it.
    uint64_t headroom = host_memory_headroom();
    if (headroom != 0) {
        uint64_t allowance = host_memory_footprint() + headroom;
        if (allowance < usage.total)
            usage.total = allowance;
        usage.available = headroom;
        usage.free = headroom;
        usage.cached = 0;   // the host's file cache is not part of this allowance
    }
    if (usage.available > usage.total)
        usage.available = usage.total;
    return usage;
}

struct uptime_info get_uptime() {
    uint64_t kern_boottime[2];
    size_t size = sizeof(kern_boottime);
    sysctlbyname("kern.boottime", &kern_boottime, &size, NULL, 0);
    struct timeval now;
    gettimeofday(&now, NULL);

    struct {
        uint32_t ldavg[3];
        long scale;
    } vm_loadavg;
    size = sizeof(vm_loadavg);
    sysctlbyname("vm.loadavg", &vm_loadavg, &size, NULL, 0);

    // linux wants the scale to be 16 bits
    for (int i = 0; i < 3; i++) {
        if (FSHIFT < 16)
            vm_loadavg.ldavg[i] <<= 16 - FSHIFT;
        else
            vm_loadavg.ldavg[i] >>= FSHIFT - 16;
    }

    struct uptime_info uptime = {
        // in clock ticks (1/100 s), as the name says and /proc/uptime expects
        .uptime_ticks = ((uint64_t) now.tv_sec * 1000000 + now.tv_usec -
                         (kern_boottime[0] * 1000000 + (uint32_t) kern_boottime[1])) / 10000,
        .load_1m = vm_loadavg.ldavg[0],
        .load_5m = vm_loadavg.ldavg[1],
        .load_15m = vm_loadavg.ldavg[2],
    };
    return uptime;
}
