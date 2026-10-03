#ifndef KERNEL_SWAPFILE_H
#define KERNEL_SWAPFILE_H

#include <stdbool.h>
#include <stddef.h>

// Guest anonymous memory backed by a host file ("swap file").
//
// On Darwin, phys_footprint (what jetsam compares with the app's limit) counts only
// "internal" memory: anonymous pages, resident or compressed. Pages of a MAP_SHARED
// file mapping are "external" even when dirty, and the kernel can write them back
// to the file and drop them under pressure, as swap does for anonymous memory on
// Linux. So guest memory placed in such a mapping is not charged to the app.
//
// The file is one unlinked sparse file in $TMPDIR (ISH_SWAPFILE_DIR overrides).
// Each allocation is a range of it at a new offset, mapped MAP_SHARED; freeing or
// discarding punches the range out (F_PUNCHHOLE), so the disk space goes back too.
//
// ISH_SWAPFILE: 0 off; 1 every anonymous mapping (prototype, for measuring);
// "pressure" (the default when set to anything else) only while the headroom is
// below the out-of-memory monitor's soft limit, so the file is written only when
// the alternative would be closing apps.

// Host memory for `size` bytes of guest anonymous memory, or NULL to use ordinary
// anonymous memory instead.
void *swap_alloc(size_t size, int prot);
// If [addr, addr+size) came from swap_alloc, unmap it, give the range back and
// return true; false for any other memory.
bool swap_free(void *addr, size_t size);
// Zero [addr, addr+size), which lies in memory from swap_alloc, and drop its pages
// (MADV_DONTNEED). False if it is not swap memory.
bool swap_discard(void *addr, size_t size);
// Bytes of guest memory currently in the file, and allocated on disk.
size_t swap_mapped_bytes(void);
size_t swap_disk_bytes(void);
// "off", "all" or "pressure"
const char *swap_mode(void);

#endif
