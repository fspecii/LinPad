#ifndef ASBESTOS_GUEST_ARM64_HWCAP_H
#define ASBESTOS_GUEST_ARM64_HWCAP_H

#include <stddef.h>
#include <stdint.h>

// What the guest CPU implements: the base ARMv8.0 set plus each optional feature
// the emulator executes and the host CPU has (both engines run these natively).
uint64_t arm64_guest_hwcap(void);   // AT_HWCAP
uint64_t arm64_guest_hwcap2(void);  // AT_HWCAP2
// Space-separated /proc/cpuinfo "Features" names, in Linux's order.
void arm64_guest_cpu_features(char *buf, size_t size);

#endif
