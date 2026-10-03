#if __APPLE__
#include <sys/sysctl.h>
#endif
#include <unistd.h>
#include <string.h>
#include <stdatomic.h>
#include "debug.h"
#include "kernel/calls.h"
#include "platform/platform.h"
#include "kernel/errno.h"
#include "kernel/task.h"
#include "fs/fd.h"
#include "kernel/memory.h"
#include "kernel/mm.h"

#if ANON_MMAP_LIMIT_PAGES > 0
_Atomic long anon_page_count;

// On iOS the app is killed (jetsam) when it passes its memory limit, long before
// anon_page_limit() is reached on an 8 GB iPad. Refuse new anonymous memory with
// ENOMEM while less than this headroom is left, so the guest program fails (a
// browser tab, a decoder) instead of the whole app.
#define HOST_MEMORY_HEADROOM (192ull << 20)
static bool host_memory_low(pages_t pages) {
    uint64_t headroom = host_memory_headroom();
    return headroom != 0 && headroom < HOST_MEMORY_HEADROOM + (uint64_t) pages * PAGE_SIZE;
}

long anon_page_limit(void) {
    static long limit;
    if (limit == 0) {
        uint64_t ram = 0;
#if __APPLE__
        size_t len = sizeof(ram);
        sysctlbyname("hw.memsize", &ram, &len, NULL, 0);
#else
        ram = (uint64_t) sysconf(_SC_PHYS_PAGES) * (uint64_t) sysconf(_SC_PAGESIZE);
#endif
        long pages = (long) (ram * 2 / PAGE_SIZE);
        limit = pages > ANON_MMAP_LIMIT_PAGES ? pages : ANON_MMAP_LIMIT_PAGES;
    }
    return limit;
}
#endif

struct mm *mm_new() {
    struct mm *mm = malloc(sizeof(struct mm));
    if (mm == NULL)
        return NULL;
    if (mem_init(&mm->mem) < 0) {
        free(mm);
        return NULL;
    }
    mm->start_brk = mm->brk = 0; // should get overwritten by exec
    mm->exefile = NULL;
    mm->refcount = 1;
    return mm;
}

struct mm *mm_copy(struct mm *mm) {
    struct mm *new_mm = malloc(sizeof(struct mm));
    if (new_mm == NULL)
        return NULL;
    *new_mm = *mm;
    // Fix wrlock_init failing because it thinks it's reinitializing the same lock
    memset(&new_mm->mem.lock, 0, sizeof(new_mm->mem.lock));
    new_mm->refcount = 1;
    if (mem_init(&new_mm->mem) < 0) {
        free(new_mm);
        return NULL;
    }
    fd_retain(new_mm->exefile);
    write_wrlock(&mm->mem.lock);
    int err = pt_copy_on_write(&mm->mem, &new_mm->mem, 0, MEM_PAGES);
    write_wrunlock(&mm->mem.lock);
    if (err < 0) {
        mm_release(new_mm);
        return NULL;
    }
    return new_mm;
}

void mm_retain(struct mm *mm) {
    mm->refcount++;
}

void mm_release(struct mm *mm) {
    if (--mm->refcount == 0) {
        if (mm->exefile != NULL)
            fd_close(mm->exefile);
        mem_destroy(&mm->mem);
        free(mm);
    }
}

// file: map this open file description instead of fd_no (SysV shared memory).
static addr_t do_mmap(addr_t addr, uint64_t len, dword_t prot, dword_t flags, fd_t fd_no, struct fd *file,
        dword_t offset) {
    int err;
    pages_t pages = (len + PAGE_SIZE - 1) / PAGE_SIZE;
    if (!pages) return _EINVAL;
    extern bool ish_exec_trace(void);
    if (ish_exec_trace() && len >= 0x200000ULL) {
        fprintf(stderr, "MMAP: pid=%d addr=0x%llx len=0x%llx prot=0x%x flags=0x%x fd=%d\n",
                current->pid,
                (unsigned long long)addr,
                (unsigned long long)len,
                prot, flags, fd_no);
    }
    page_t page;
    if (addr != 0) {
        if (PGOFFSET(addr) != 0)
            return _EINVAL;
        page = PAGE(addr);
#ifdef GUEST_ARM64
        // Reject hints that would overlap the stack region in low 4GB
        // or exceed the 48-bit user address limit.
        // Hints within low 4GB (up to the stack) are unchanged — V8
        // Wasm guard regions use those. Hints above 4GB are now
        // honoured (Go's arena hints at 0x4000000000, 0x14000000000…
        // need to be placed where asked so the runtime's scavengeIndex
        // metadata is consistent with the actual arena layout).
        bool low_hint = (page < 0x100000);  // < 4GB
        if (low_hint) {
            if (page + pages > STACK_TOP_PAGE) {
                if (flags & MMAP_FIXED)
                    return _ENOMEM;
                addr = 0;
                page = 0;
            }
            // Keep hints out of the main stack's growth area (RLIMIT_STACK
            // below the stack top, at most 128 MB), as Linux keeps mmap_base
            // below it. A hinted mapping placed just under the stack stops
            // the stack from growing past it (Chromium's extension host
            // segfaulted ~290 KB down).
            rlim_t_ stack_limit = rlimit(RLIMIT_STACK_);
            pages_t stack_gap = stack_limit == RLIM_INFINITY_ || stack_limit > (128ull << 20) ?
                (128ull << 20) / PAGE_SIZE : stack_limit / PAGE_SIZE;
            if (page != 0 && !(flags & MMAP_FIXED) && page + pages > STACK_TOP_PAGE - stack_gap) {
                addr = 0;
                page = 0;
            }
        } else {
            if (page + pages > USER_ADDR_MAX_PAGE) {
                if (flags & MMAP_FIXED)
                    return _ENOMEM;
                addr = 0;
                page = 0;
            }
        }
#endif
        if (addr != 0 && !(flags & MMAP_FIXED) && !pt_is_hole(current->mem, page, pages))
            addr = 0;
    }
    if (addr == 0) {
#ifdef GUEST_ARM64
        // V8 reserves its heap cage with:
        //     mmap(NULL, chunk_size, PROT_NONE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)
        //     (typical chunk_size: 128MB, reserved before mprotect'ing
        //      sub-regions RW as it allocates).
        // Node 22 is built without pointer compression, so V8 stores
        // full 64-bit tagged pointers into heap slots. If the cage
        // lives in low 4GB (0xc0000000..0xd0000000), a slot that
        // accidentally holds a small integer 0x00c36a73 looks like a
        // valid heap pointer and V8 derefs it into unmapped memory.
        // Placing the cage above 4GB makes such stray values obviously
        // non-canonical so V8's own `ptr & kHeapObjectTagMask` checks
        // catch them before deref.
        //
        // Match criteria (conservative, only V8-cage shape):
        //  * PROT_NONE reservation
        //  * private + anonymous
        //  * ≥ 128MB (0x8000 pages). V8 reserves 128MB+ chunks; Go
        //    arenas default to 64MB and need to stay in low 4GB
        //    because the Go runtime's arenaIndex / scavengeIndex
        //    metadata is laid out with that assumption.
        bool is_v8_cage_reservation =
            prot == 0 &&
            (flags & (MMAP_PRIVATE | MMAP_ANONYMOUS))
                == (MMAP_PRIVATE | MMAP_ANONYMOUS) &&
            !(flags & MMAP_SHARED) &&
            pages >= 0x8000;  // 128MB
        if (is_v8_cage_reservation)
            page = pt_find_hole_for_reservation(current->mem, pages);
        else
            page = pt_find_hole(current->mem, pages);
#else
        page = pt_find_hole(current->mem, pages);
#endif
        if (page == BAD_PAGE)
            return _ENOMEM;
    }

    if (flags & MMAP_SHARED)
        prot |= P_SHARED;

    if (flags & MMAP_ANONYMOUS) {
        // PROT_NONE mappings (guard regions) don't consume real memory,
        // so don't count them against the anonymous page limit.
        bool is_prot_none = !(prot & P_READ) && !(prot & P_WRITE) && !(prot & P_EXEC);
#ifdef GUEST_ARM64
        if ((flags & MMAP_NORESERVE) && pages > 0x10000) {
            if (flags & MMAP_FIXED) {
                // MAP_FIXED replaces whatever was there, reservations included
                pt_unmap_always(current->mem, page, pages);
            } else {
                pages_t align_pages = pages;
                if (align_pages > 0x40000) align_pages = 0x40000;
                page_t aligned = (page / align_pages) * align_pages;
                if (aligned >= MMAP_HOLE_END && pt_is_hole(current->mem, aligned, pages))
                    page = aligned;
            }
            if ((err = pt_map_lazy(current->mem, page, pages, prot)) < 0)
                return err;
            return page << PAGE_BITS;
        }
        // Large PROT_NONE reservations (V8 heap cage chunks) use lazy
        // mapping even without MAP_NORESERVE. V8 reserves 128MB
        // chunks with PROT_NONE then mprotect's sub-regions RW as it
        // allocates. Allocating all 128MB of host memory up front
        // would waste ~640MB per node process; track the region as a
        // mem_reservation instead and demand-map each page on first
        // mprotect/touch. The INT_GPF write-fault demand-map path
        // uses mem_find_reservation to detect cage pages.
        if (is_prot_none && pages >= 0x8000) {
            if ((err = pt_map_lazy(current->mem, page, pages, prot)) < 0)
                return err;
            return page << PAGE_BITS;
        }
#endif
#if ANON_MMAP_LIMIT_PAGES > 0
        if (!is_prot_none && (atomic_load(&anon_page_count) + (long)pages > anon_page_limit() ||
                    host_memory_low(pages)))
            return _ENOMEM;
        if (!is_prot_none)
            atomic_fetch_add(&anon_page_count, (long)pages);
#endif
        if ((err = pt_map_nothing(current->mem, page, pages, prot)) < 0) {
#if ANON_MMAP_LIMIT_PAGES > 0
            if (!is_prot_none)
                atomic_fetch_sub(&anon_page_count, (long)pages);
#endif
            return err;
        }
    } else {
        // fd must be valid
        struct fd *fd = file != NULL ? file : f_get(fd_no);
        if (fd == NULL)
            return _EBADF;
        if (fd->ops->mmap == NULL)
            return _ENODEV;
        if ((err = fd->ops->mmap(fd, current->mem, page, pages, offset, prot, flags)) < 0)
            return err;
        mem_pt(current->mem, page)->data->fd = fd_retain(fd);
        mem_pt(current->mem, page)->data->file_offset = offset;
    }
    return page << PAGE_BITS;
}

addr_t mmap_file(addr_t addr, uint64_t len, dword_t prot, dword_t flags, struct fd *file) {
    return do_mmap(addr, len, prot, flags, -1, file, 0);
}

static addr_t mmap_common(addr_t addr, dword_t len, dword_t prot, dword_t flags, fd_t fd_no, dword_t offset) {
    STRACE("mmap(0x%x, 0x%x, 0x%x, 0x%x, %d, %d)", addr, len, prot, flags, fd_no, offset);
    if (len == 0)
        return _EINVAL;
    if (prot & ~P_RWX)
        return _EINVAL;
    if ((flags & MMAP_PRIVATE) && (flags & MMAP_SHARED))
        return _EINVAL;

    write_wrlock(&current->mem->lock);
    addr_t res = do_mmap(addr, len, prot, flags, fd_no, NULL, offset);
    write_wrunlock(&current->mem->lock);
    return res;
}

addr_t sys_mmap2(addr_t addr, dword_t len, dword_t prot, dword_t flags, fd_t fd_no, dword_t offset) {
    return mmap_common(addr, len, prot, flags, fd_no, offset << PAGE_BITS);
}

#if defined(GUEST_ARM64)
// ARM64 mmap syscall: offset is passed directly (not shifted like mmap2)
// and takes 6 direct arguments (not a pointer to a struct like x86 mmap)
addr_t sys_mmap64(addr_t addr, addr_t len, dword_t prot, dword_t flags, fd_t fd_no, qword_t offset) {
    STRACE("mmap64(0x%llx, 0x%llx, 0x%x, 0x%x, %d, 0x%llx)", (unsigned long long)addr, (unsigned long long)len, prot, flags, fd_no, (unsigned long long)offset);
    if (len == 0)
        return _EINVAL;
    if (prot & ~P_RWX)
        return _EINVAL;
    if ((flags & MMAP_PRIVATE) && (flags & MMAP_SHARED))
        return _EINVAL;

    write_wrlock(&current->mem->lock);
    addr_t res = do_mmap(addr, len, prot, flags, fd_no, NULL, (dword_t)offset);
    write_wrunlock(&current->mem->lock);
    return res;
}
#endif

struct mmap_arg_struct {
    dword_t addr, len, prot, flags, fd, offset;
};

addr_t sys_mmap(addr_t args_addr) {
    struct mmap_arg_struct args;
    if (user_get(args_addr, args))
        return _EFAULT;
    return mmap_common(args.addr, args.len, args.prot, args.flags, args.fd, args.offset);
}

int_t sys_munmap(addr_t addr, addr_t len) {
    STRACE("munmap(0x%llx, 0x%llx)", (unsigned long long)addr, (unsigned long long)len);
    if (getenv("ISH_PROT_TRACE")) {
        addr_t end = addr + len;
        if (end > 0xed000000ULL && addr < 0xf0000000ULL) {
            fprintf(stderr, "[PROT_TRACE] munmap(0x%llx, 0x%llx)\n",
                    (unsigned long long)addr, (unsigned long long)len);
        }
    }
    pages_t pages = (len + PAGE_SIZE - 1) / PAGE_SIZE;
    if (PGOFFSET(addr) != 0)
        return _EINVAL;
    if (len == 0)
        return _EINVAL;
    write_wrlock(&current->mem->lock);
    int err = pt_unmap_always(current->mem, PAGE(addr), pages);
    write_wrunlock(&current->mem->lock);
    if (err < 0)
        return _EINVAL;
    return 0;
}

#define MREMAP_MAYMOVE_ 1
#define MREMAP_FIXED_ 2

// Map [start, start + pages) from the same file as the mapping at src_entry,
// continuing at file offset file_off.
static int mremap_map_file(struct pt_entry *src_entry, page_t start, pages_t pages, size_t file_off) {
    struct fd *fd = src_entry->data->fd;
    unsigned prot = src_entry->flags & (P_RWX | P_SHARED);
    int mmap_flags = src_entry->flags & P_SHARED ? MMAP_SHARED : MMAP_PRIVATE;
    int err = fd->ops->mmap(fd, current->mem, start, pages, file_off, prot, mmap_flags);
    if (err < 0)
        return err;
    mem_pt(current->mem, start)->data->fd = fd_retain(fd);
    mem_pt(current->mem, start)->data->file_offset = file_off;
    return 0;
}

static addr_t do_mremap_grow(addr_t addr, pages_t old_pages, pages_t new_pages, dword_t flags) {
    struct pt_entry *entry = mem_pt(current->mem, PAGE(addr));
    if (entry == NULL)
        return _EFAULT;
    dword_t pt_flags = entry->flags;
    for (page_t page = PAGE(addr); page < PAGE(addr) + old_pages; page++) {
        struct pt_entry *e = mem_pt(current->mem, page);
        if (e == NULL || e->flags != pt_flags)
            return _EFAULT;
    }
    page_t extra_start = PAGE(addr) + old_pages;
    pages_t extra_pages = new_pages - old_pages;
    bool in_place = pt_is_hole(current->mem, extra_start, extra_pages);

    if (pt_flags & P_ANONYMOUS) {
        if (!in_place)
            return _ENOMEM;
        int err = pt_map_nothing(current->mem, extra_start, extra_pages, pt_flags);
        if (err < 0)
            return err;
        return addr;
    }

    // File mapping: extend (or re-create) it from the backing file.
    struct data *data = entry->data;
    if (data->fd == NULL || data->fd->ops->mmap == NULL)
        return _EFAULT;
    // pt offsets are relative to the host-page-aligned start of the file mapping
    size_t file_off = data->file_offset - data->file_offset % real_page_size + entry->offset;
    if (in_place) {
        int err = mremap_map_file(entry, extra_start, extra_pages, file_off + (old_pages << PAGE_BITS));
        if (err < 0)
            return err;
        return addr;
    }
    // Moving a private file mapping would drop its private modifications.
    if (!(flags & MREMAP_MAYMOVE_) || !(pt_flags & P_SHARED))
        return _ENOMEM;
    page_t new_start = pt_find_hole(current->mem, new_pages);
    if (new_start == BAD_PAGE)
        return _ENOMEM;
    int err = mremap_map_file(entry, new_start, new_pages, file_off);
    if (err < 0)
        return err;
    pt_unmap_always(current->mem, PAGE(addr), old_pages);
    return new_start << PAGE_BITS;
}

addr_t sys_mremap(addr_t addr, dword_t old_len, dword_t new_len, dword_t flags) {
    STRACE("mremap(%#x, %#x, %#x, %d)", addr, old_len, new_len, flags);
    if (PGOFFSET(addr) != 0)
        return _EINVAL;
    if (flags & ~(MREMAP_MAYMOVE_ | MREMAP_FIXED_))
        return _EINVAL;
    if (flags & MREMAP_FIXED_) {
        FIXME("missing MREMAP_FIXED");
        return _EINVAL;
    }
    pages_t old_pages = PAGE(old_len);
    pages_t new_pages = PAGE(new_len);

    // shrinking always works
    if (new_pages <= old_pages) {
        int err = pt_unmap(current->mem, PAGE(addr) + new_pages, old_pages - new_pages);
        if (err < 0)
            return _EFAULT;
        return addr;
    }

    write_wrlock(&current->mem->lock);
    addr_t res = do_mremap_grow(addr, old_pages, new_pages, flags);
    write_wrunlock(&current->mem->lock);
    return res;
}

int_t sys_mprotect(addr_t addr, addr_t len, int_t prot) {
    STRACE("mprotect(0x%llx, 0x%llx, 0x%x)", (unsigned long long)addr, (unsigned long long)len, prot);
    if (getenv("ISH_PROT_TRACE")) {
        // Trace mprotect that touches the node binary range (V8 codespace candidate).
        addr_t end = addr + len;
        if (end > 0xed000000ULL && addr < 0xf0000000ULL) {
            fprintf(stderr, "[PROT_TRACE] mprotect(0x%llx, 0x%llx, prot=0x%x)\n",
                    (unsigned long long)addr, (unsigned long long)len, prot);
        }
    }
    if (PGOFFSET(addr) != 0)
        return _EINVAL;
    if (prot & ~P_RWX)
        return _EINVAL;
    pages_t pages = PAGE_ROUND_UP(len);
    write_wrlock(&current->mem->lock);
    int err = pt_set_flags(current->mem, PAGE(addr), pages, prot);
    write_wrunlock(&current->mem->lock);
    return err;
}

dword_t sys_madvise(addr_t addr, dword_t len, dword_t advice) {
    STRACE("madvise(0x%llx, 0x%x, %d)", (unsigned long long)addr, len, advice);
    if ((advice == 4 /* MADV_DONTNEED */ || advice == 8 /* MADV_FREE */) && len > 0)
        mem_discard(current->mem, PAGE(addr), PAGE(addr + len - 1) - PAGE(addr) + 1);
    return 0;
}

dword_t sys_mbind(addr_t UNUSED(addr), dword_t UNUSED(len), int_t UNUSED(mode),
        addr_t UNUSED(nodemask), dword_t UNUSED(maxnode), uint_t UNUSED(flags)) {
    return 0;
}

int_t sys_mlock(addr_t UNUSED(addr), dword_t UNUSED(len)) {
    return 0;
}

int_t sys_msync(addr_t UNUSED(addr), dword_t UNUSED(len), int_t UNUSED(flags)) {
    return 0;
}

addr_t sys_brk(addr_t new_brk) {
    STRACE("brk(0x%x)", new_brk);
    struct mm *mm = current->mm;
    write_wrlock(&mm->mem.lock);
    if (new_brk < mm->start_brk)
        goto out;
    addr_t old_brk = mm->brk;

    if (new_brk > old_brk) {
        // expand heap: map region from old_brk to new_brk
        // round up because of the definition of brk: "the first location after the end of the uninitialized data segment." (brk(2))
        // if the brk is 0x2000, page 0x2000 shouldn't be mapped, but it should be if the brk is 0x2001.
        page_t start = PAGE_ROUND_UP(old_brk);
        pages_t size = PAGE_ROUND_UP(new_brk) - PAGE_ROUND_UP(old_brk);
        if (!pt_is_hole(&mm->mem, start, size))
            goto out;
#if ANON_MMAP_LIMIT_PAGES > 0
        if (atomic_load(&anon_page_count) + (long)size > anon_page_limit() || host_memory_low(size))
            goto out;
        atomic_fetch_add(&anon_page_count, (long)size);
#endif
        int err = pt_map_nothing(&mm->mem, start, size, P_WRITE);
        if (err < 0) {
#if ANON_MMAP_LIMIT_PAGES > 0
            atomic_fetch_sub(&anon_page_count, (long)size);
#endif
            goto out;
        }
    } else if (new_brk < old_brk) {
        // shrink heap: unmap pages that are entirely above new_brk
        // PAGE_ROUND_UP(new_brk) is the first page we can safely unmap
        // (the page containing new_brk may still have live data below new_brk)
        page_t first_unmap = PAGE_ROUND_UP(new_brk);
        page_t last_unmap = PAGE_ROUND_UP(old_brk);
        if (first_unmap < last_unmap)
            pt_unmap_always(&mm->mem, first_unmap, last_unmap - first_unmap);
    }

    mm->brk = new_brk;
out:;
    addr_t brk = mm->brk;
    write_wrunlock(&mm->mem.lock);
    return brk;
}
