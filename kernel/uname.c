#include <sys/utsname.h>
#include <string.h>
#include "kernel/calls.h"
#include "platform/platform.h"

#if __APPLE__
#include <sys/sysctl.h>
#elif __linux__
#include <sys/sysinfo.h>
#endif

#define SYSINFO_DEBUG 0

const char *uname_version = "SUPER AWESOME";
const char *uname_hostname_override = NULL;

void do_uname(struct uname *uts) {
    struct utsname real_uname;
    uname(&real_uname);
    const char *hostname = real_uname.nodename;
    if (uname_hostname_override)
        hostname = uname_hostname_override;

    memset(uts, 0, sizeof(struct uname));
    strcpy(uts->system, "Linux");
    strcpy(uts->hostname, hostname);
    strcpy(uts->release, "4.20.69-ish");
    snprintf(uts->version, sizeof(uts->version), "%s %s %s", uname_version, __DATE__, __TIME__);
#if defined(GUEST_ARM64)
    strcpy(uts->arch, "aarch64");
#else
    strcpy(uts->arch, "i686");
#endif
    strcpy(uts->domain, "(none)");
}

dword_t sys_uname(addr_t uts_addr) {
    struct uname uts;
    do_uname(&uts);
    if (user_put(uts_addr, uts))
        return _EFAULT;
    return 0;
}

dword_t sys_sethostname(addr_t UNUSED(hostname_addr), dword_t UNUSED(hostname_len)) {
    return _EPERM;
}

#if __APPLE__
static uint64_t get_total_ram() {
    uint64_t total_ram = 0;
    size_t len = sizeof(total_ram);
    sysctlbyname("hw.memsize", &total_ram, &len, NULL, 0);
    return total_ram;
}
static void sysinfo_specific(struct sys_info *info) {
    uint64_t total_ram = get_total_ram();
#if defined(GUEST_ARM64)
    // Cap totalram to 256MB for the emulated environment.
    // Reporting the full host RAM (e.g. 32GB) causes musl malloc to
    // allocate enormous mmap arenas, leading to multi-GB memory growth.
    #define GUEST_MAX_RAM (256ULL * 1024 * 1024)
    if (total_ram > GUEST_MAX_RAM)
        total_ram = GUEST_MAX_RAM;
    info->totalram = total_ram;
    info->mem_unit = 1;
#else
    // For x86, scale down to 32-bit with mem_unit
    if (total_ram > UINT32_MAX) {
        info->mem_unit = (uint32_t)(total_ram / UINT32_MAX) + 1;
        info->totalram = (uint32_t)(total_ram / info->mem_unit);
    } else {
        info->mem_unit = 1;
        info->totalram = (uint32_t)total_ram;
    }
#endif
    // TODO: freeram, sharedram, etc.
}
#elif __linux__
static void sysinfo_specific(struct sys_info *info) {
    struct sysinfo host_info;
    sysinfo(&host_info);
    info->totalram = host_info.totalram;
    info->freeram = host_info.freeram;
    info->sharedram = host_info.sharedram;
    info->totalswap = host_info.totalswap;
    info->freeswap = host_info.freeswap;
    info->procs = host_info.procs;
    info->totalhigh = host_info.totalhigh;
    info->freehigh = host_info.freehigh;
    info->mem_unit = host_info.mem_unit;
}
#endif

dword_t sys_sysinfo(addr_t info_addr) {
    struct sys_info info = {0};
    struct uptime_info uptime = get_uptime();
    info.uptime = uptime.uptime_ticks;
    info.loads[0] = uptime.load_1m;
    info.loads[1] = uptime.load_5m;
    info.loads[2] = uptime.load_15m;
    sysinfo_specific(&info);

#if defined(GUEST_ARM64)
    // glibc static binaries sometimes call sysinfo with the __stack_chk_guard address
    // as the buffer. This is a quirk of glibc's raise()/abort() implementation.
    // The canary address is typically in .data.rel.ro section.
    // We detect this by checking if the address is in that range and preserving
    // the first 8 bytes (the canary value).
    //
    // Known canary address: 0x613870 for busybox-static (glibc)
    // Check if this looks like a canary address by seeing if we'd overwrite
    // a value that looks like a canary (high entropy, low byte is 0)
    uint64_t existing_value = 0;
    if (user_get(info_addr, existing_value) == 0) {
        // Check if this looks like a canary: non-zero, low byte is 0
        if (existing_value != 0 && (existing_value & 0xFF) == 0) {
#if SYSINFO_DEBUG
            fprintf(stderr, "[SYSINFO] Preserving canary at 0x%x = 0x%llx\n",
                    info_addr, (unsigned long long)existing_value);
#endif
            // Write sysinfo data starting AFTER the canary (skip first 8 bytes)
            // This means info.uptime won't be written, which is acceptable
            if (user_write(info_addr + 8, ((char*)&info) + 8, sizeof(info) - 8))
                return _EFAULT;
            return 0;
        }
    }
#endif

    if (user_put(info_addr, info))
        return _EFAULT;
    return 0;
}
