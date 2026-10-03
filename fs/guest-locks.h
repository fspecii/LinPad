#ifndef FS_GUEST_LOCKS_H
#define FS_GUEST_LOCKS_H

#include <stdbool.h>

// Whether a guest process holds a flock() lock on the file at this guest path, e.g. a
// program's "I am running" lock. Guest flock locks are emulated in memory (fs/lock.c)
// and never take a host lock, so the host must ask here instead of probing the file
// with flock itself. Callable from any host thread.
bool ish_guest_path_flocked(const char *path);

#endif
