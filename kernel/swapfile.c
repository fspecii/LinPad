#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "debug.h"
#include "kernel/memory.h"
#include "kernel/swapfile.h"
#include "platform/platform.h"

enum { MODE_OFF, MODE_ALL, MODE_PRESSURE };

static pthread_mutex_t swap_lock = PTHREAD_MUTEX_INITIALIZER;
static int mode = -1;
static int swap_fd = -1;
static off_t file_size;
static off_t next_offset;
static size_t mapped;

// Live allocations sorted by address, for swap_free and swap_discard.
static struct extent {
    uintptr_t addr;
    size_t size;
    off_t offset;
} *extents;
static size_t extent_count, extent_cap;

#define FILE_GROW (1ll << 30)

static void punch(off_t offset, size_t size) {
#ifdef F_PUNCHHOLE
    struct fpunchhole hole = {0, 0, offset, (off_t) size};
    fcntl(swap_fd, F_PUNCHHOLE, &hole);
#elif defined(FALLOC_FL_PUNCH_HOLE)
    fallocate(swap_fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, offset, (off_t) size);
#else
    (void) offset;
    (void) size;
#endif
}

static int read_mode(void) {
    const char *env = getenv("ISH_SWAPFILE");
    if (env == NULL || strcmp(env, "0") == 0 || env[0] == '\0')
        return MODE_OFF;
    if (strcmp(env, "1") == 0 || strcmp(env, "all") == 0)
        return MODE_ALL;
    return MODE_PRESSURE;
}

// Called with swap_lock held.
static bool open_file(void) {
    if (swap_fd >= 0)
        return true;
    const char *dir = getenv("ISH_SWAPFILE_DIR");
    if (dir == NULL)
        dir = getenv("TMPDIR");
    if (dir == NULL)
        dir = "/tmp";
    char path[1024];
    snprintf(path, sizeof(path), "%s/ish-swap-XXXXXX", dir);
    int fd = mkstemp(path);
    if (fd < 0) {
        printk("swapfile: can't create %s: %s; using anonymous memory\n", path, strerror(errno));
        mode = MODE_OFF;
        return false;
    }
    unlink(path);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
#ifdef F_RDAHEAD
    // Pages are only reached through the mappings; reading ahead brings in nothing useful.
    fcntl(fd, F_RDAHEAD, 0);
#endif
    swap_fd = fd;
    return true;
}

static bool want_swap(void) {
    if (mode == MODE_ALL)
        return true;
    // MODE_PRESSURE: only below the soft limit, where the alternative is the
    // out-of-memory monitor closing apps.
    uint64_t headroom = host_memory_headroom();
    if (headroom == 0)
        return false;
    uint64_t allowance = host_memory_footprint() + headroom;
    return headroom < allowance / 5;
}

void *swap_alloc(size_t size, int prot) {
    if (mode < 0) {
        pthread_mutex_lock(&swap_lock);
        if (mode < 0)
            mode = read_mode();
        pthread_mutex_unlock(&swap_lock);
    }
    if (mode == MODE_OFF || prot == PROT_NONE || !want_swap())
        return NULL;
    pthread_mutex_lock(&swap_lock);
    if (!open_file()) {
        pthread_mutex_unlock(&swap_lock);
        return NULL;
    }
    if (extent_count == extent_cap) {
        size_t cap = extent_cap ? extent_cap * 2 : 1024;
        struct extent *bigger = realloc(extents, cap * sizeof(*extents));
        if (bigger == NULL) {
            pthread_mutex_unlock(&swap_lock);
            return NULL;
        }
        extents = bigger;
        extent_cap = cap;
    }
    // Offsets are never reused: freed ranges are punched out of the sparse file, so
    // they cost nothing, and a fresh range is always zero.
    off_t offset = next_offset;
    if (offset + (off_t) size > file_size) {
        off_t new_size = (offset + (off_t) size + FILE_GROW - 1) / FILE_GROW * FILE_GROW;
        if (ftruncate(swap_fd, new_size) != 0) {
            pthread_mutex_unlock(&swap_lock);
            return NULL;
        }
        file_size = new_size;
    }
    void *addr = mmap(NULL, size, prot, MAP_SHARED, swap_fd, offset);
    if (addr == MAP_FAILED) {
        pthread_mutex_unlock(&swap_lock);
        return NULL;
    }
    next_offset = offset + (off_t) ((size + real_page_size - 1) & ~(real_page_size - 1));
    size_t lo = 0, hi = extent_count;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (extents[mid].addr < (uintptr_t) addr)
            lo = mid + 1;
        else
            hi = mid;
    }
    memmove(&extents[lo + 1], &extents[lo], (extent_count - lo) * sizeof(*extents));
    extents[lo] = (struct extent) {(uintptr_t) addr, size, offset};
    extent_count++;
    mapped += size;
    pthread_mutex_unlock(&swap_lock);
    return addr;
}

// Called with swap_lock held: the extent containing addr, or -1.
static long find_extent(uintptr_t addr) {
    size_t lo = 0, hi = extent_count;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (extents[mid].addr <= addr)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo == 0)
        return -1;
    struct extent *e = &extents[lo - 1];
    return addr < e->addr + e->size ? (long) (lo - 1) : -1;
}

bool swap_free(void *addr, size_t size) {
    if (swap_fd < 0)
        return false;
    pthread_mutex_lock(&swap_lock);
    long i = find_extent((uintptr_t) addr);
    if (i < 0 || extents[i].addr != (uintptr_t) addr) {
        pthread_mutex_unlock(&swap_lock);
        return false;
    }
    struct extent e = extents[i];
    memmove(&extents[i], &extents[i + 1], (extent_count - i - 1) * sizeof(*extents));
    extent_count--;
    mapped -= e.size;
    munmap(addr, size > e.size ? size : e.size);
    punch(e.offset, (e.size + real_page_size - 1) & ~(real_page_size - 1));
    pthread_mutex_unlock(&swap_lock);
    return true;
}

bool swap_discard(void *addr, size_t size) {
    if (swap_fd < 0)
        return false;
    pthread_mutex_lock(&swap_lock);
    long i = find_extent((uintptr_t) addr);
    bool found = i >= 0 && (uintptr_t) addr + size <= extents[i].addr + extents[i].size;
    if (found) {
        // A punched range reads as zeros at once, through every mapping of it.
        off_t offset = extents[i].offset + (off_t) ((uintptr_t) addr - extents[i].addr);
        punch(offset, size);
    }
    pthread_mutex_unlock(&swap_lock);
    return found;
}

size_t swap_mapped_bytes(void) {
    pthread_mutex_lock(&swap_lock);
    size_t n = mapped;
    pthread_mutex_unlock(&swap_lock);
    return n;
}

size_t swap_disk_bytes(void) {
    struct stat st;
    if (swap_fd < 0 || fstat(swap_fd, &st) != 0)
        return 0;
    return (size_t) st.st_blocks * 512;
}

const char *swap_mode(void) {
    if (mode < 0)
        mode = read_mode();
    return mode == MODE_ALL ? "all" : mode == MODE_PRESSURE ? "pressure" : "off";
}
