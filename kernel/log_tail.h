#ifndef KERNEL_LOG_TAIL_H
#define KERNEL_LOG_TAIL_H
#include <stddef.h>
#include <stdint.h>

// The emulator's in-memory logs, for the app's diagnostics export (Settings ›
// Maintenance › Export Diagnostics). Plain C so Swift can import it.

// The kernel log ring buffer that the guest's dmesg reads (every printk).
#define ISH_LOG_RING_KERNEL 0
// Messages that are only printed with ISH_LOG=1 (NETDIAG socket waits, stub
// syscalls), kept here even without it.
#define ISH_LOG_RING_DIAGNOSTIC 1

// Copies up to `max` of the newest bytes of a ring into `out` and returns how
// many were copied. `total` (optional) receives how many bytes were ever
// appended to the ring, so a caller can tell whether anything changed.
size_t ish_log_copy_tail(int ring, char *out, size_t max, uint64_t *total);

// Where a fatal emulator error (die(), abort()) writes the tail of both rings.
// Installs a SIGABRT handler that chains to the previous one. SIGSEGV, SIGBUS
// and SIGILL are left alone: the JIT handles guest faults through them.
void ish_log_set_crash_path(const char *path);

// Writes `reason` and the tail of both rings to the crash path, without locks
// or allocation, so it is usable from a signal handler or a dying thread.
void ish_log_write_crash(const char *reason);

#endif
