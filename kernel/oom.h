#ifndef KERNEL_OOM_H
#define KERNEL_OOM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Guest out-of-memory policy (earlyoom / systemd-oomd style, inside the emulator).
//
// Guest RAM is this app's own memory, and iPadOS kills the whole app (jetsam) once
// its footprint reaches the per-app limit. A monitor thread watches the headroom
// (platform host_memory_headroom(): os_proc_available_memory() on iOS,
// ISH_MEM_LIMIT_MB on the Mac) and:
//   - below the soft limit, reports memory pressure (/proc/pressure/memory, and
//     MemAvailable in /proc/meminfo drops, which Firefox's low-memory watcher reads);
//   - below the hard limit, SIGKILLs the guest process with the highest badness
//     (estimated footprint + oom_score_adj, as Linux's oom_badness does), never
//     pid 1, a process with a negative oom_score_adj, or one on the protect list,
//     and tells the desktop which app was closed.
// The hard limit is above the 192 MB at which new anonymous mmaps start failing
// (kernel/mmap.c), so a victim is picked before some unrelated process (often the
// Firefox parent) gets ENOMEM and aborts.
//
// Environment, read once at start: ISH_OOM=0 turns the killer off (pressure is still
// reported), ISH_OOM_PROTECT="name,name" adds process names to the protect list.
// /proc/ish/oom changes both at run time.

void oom_start(void);

void oom_set_enabled(bool enabled);
bool oom_enabled(void);
// Comma- or newline-separated process names (comm or argv[0] basename). Replaces
// the user part of the list; the built-in names stay.
void oom_set_protect(const char *names);

// Called (from the monitor thread) after each kill with a one-line description for
// the user. The iOS app turns it into a desktop notification.
extern void (*oom_kill_hook)(const char *app, const char *message);

// Wake the monitor now (an allocation is about to fail for lack of headroom).
void oom_poke(void);
// Wait (up to 2 s) for the monitor to free memory until at least `bytes` of headroom
// are left. False if the killer is off or nothing could be freed in time.
bool oom_wait_for_headroom(uint64_t bytes);

// Text for /proc/ish/memory, /proc/ish/oom and /proc/pressure/memory.
struct proc_data;
void oom_show_memory(struct proc_data *buf);
void oom_show_policy(struct proc_data *buf);
int oom_update_policy(const char *text, size_t size);
void oom_show_pressure(struct proc_data *buf);
// /proc/PID/oom_score: 0..2000, like Linux.
int oom_score_of_pid(int pid);

#endif
