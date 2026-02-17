#ifndef ISH_INTERNAL
#error "for internal use only"
#endif

#ifndef FS_FAKE_H
#define FS_FAKE_H

#include <stdbool.h>
#include <stddef.h>
#include "kernel/fs.h"
#include "fs/fake-db.h"
#include "misc.h"

struct fd *fakefs_open_inode(struct mount *mount, ino_t inode);

/* Bind mount API — redirect a fakefs path to an external host directory.
 * Creates a symlink in data/ and auto-creates meta.db entries on access.
 * Can be called from Swift/ObjC after the kernel has booted. */
int fakefs_bind_mount(const char *linux_path, const char *host_path);
int fakefs_bind_unmount(const char *linux_path);

/* Translate a resolved host path back to a Linux path via bind mount table.
 * Returns true and writes to out_path if a match was found. */
bool fakefs_bind_mount_resolve_path(const char *resolved, char *out_path, size_t out_size);

#endif
