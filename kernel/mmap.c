#include <string.h>
#include <stdatomic.h>
#include "debug.h"
#include "kernel/calls.h"
#include "kernel/errno.h"
#include "kernel/task.h"
#include "fs/fd.h"
#include "kernel/memory.h"
#include "kernel/mm.h"

#if ANON_MMAP_LIMIT_PAGES > 0
_Atomic long anon_page_count;
#endif

struct mm *mm_new() {
    struct mm *mm = malloc(sizeof(struct mm));
    if (mm == NULL)
        return NULL;
    mem_init(&mm->mem);
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
    mem_init(&new_mm->mem);
    fd_retain(new_mm->exefile);
    write_wrlock(&mm->mem.lock);
    pt_copy_on_write(&mm->mem, &new_mm->mem, 0, MEM_PAGES);
    write_wrunlock(&mm->mem.lock);
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

static addr_t do_mmap(addr_t addr, dword_t len, dword_t prot, dword_t flags, fd_t fd_no, dword_t offset) {
    int err;
    pages_t pages = PAGE_ROUND_UP(len);
    if (!pages) return _EINVAL;
    page_t page;
    if (addr != 0) {
        if (PGOFFSET(addr) != 0)
            return _EINVAL;
        page = PAGE(addr);
#ifdef GUEST_ARM64
        // Reject hints above 4GB to prevent Go's scavengeIndex metadata
        // collision (Go tries arenas at 0x4000000000 whose metadata lands
        // at 0x80000, colliding with program text). Also reject hints that
        // would overlap the stack. Hints within the low 4GB are allowed —
        // V8 Wasm guard regions legitimately need large mappings near the
        // stack region (e.g. 0xee400000 + 256MB).
        if (page >= 0x100000 || page + pages > STACK_TOP_PAGE) {
            if (flags & MMAP_FIXED)
                return _ENOMEM;
            addr = 0;
            page = 0;
        }
#endif
        if (addr != 0 && !(flags & MMAP_FIXED) && !pt_is_hole(current->mem, page, pages))
            addr = 0;
    }
    if (addr == 0) {
        page = pt_find_hole(current->mem, pages);
        if (page == BAD_PAGE)
            return _ENOMEM;
    }

    if (flags & MMAP_SHARED)
        prot |= P_SHARED;

    if (flags & MMAP_ANONYMOUS) {
        // PROT_NONE mappings (guard regions) don't consume real memory,
        // so don't count them against the anonymous page limit.
        bool is_prot_none = !(prot & P_READ) && !(prot & P_WRITE) && !(prot & P_EXEC);
#if ANON_MMAP_LIMIT_PAGES > 0
        if (!is_prot_none && atomic_load(&anon_page_count) + (long)pages > ANON_MMAP_LIMIT_PAGES)
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
        struct fd *fd = f_get(fd_no);
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

static addr_t mmap_common(addr_t addr, dword_t len, dword_t prot, dword_t flags, fd_t fd_no, dword_t offset) {
    STRACE("mmap(0x%x, 0x%x, 0x%x, 0x%x, %d, %d)", addr, len, prot, flags, fd_no, offset);
    if (len == 0)
        return _EINVAL;
    if (prot & ~P_RWX)
        return _EINVAL;
    if ((flags & MMAP_PRIVATE) && (flags & MMAP_SHARED))
        return _EINVAL;

    write_wrlock(&current->mem->lock);
    addr_t res = do_mmap(addr, len, prot, flags, fd_no, offset);
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
    if (len > 0x40000000)
        len = 0x40000000;
    if (prot & ~P_RWX)
        return _EINVAL;
    if ((flags & MMAP_PRIVATE) && (flags & MMAP_SHARED))
        return _EINVAL;

    write_wrlock(&current->mem->lock);
    // Note: offset is already in bytes for ARM64 mmap, so pass directly
    addr_t res = do_mmap(addr, len, prot, flags, fd_no, (dword_t)offset);
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

int_t sys_munmap(addr_t addr, uint_t len) {
    STRACE("munmap(0x%x, 0x%x)", addr, len);
    pages_t pages = PAGE_ROUND_UP(len);
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

    struct pt_entry *entry = mem_pt(current->mem, PAGE(addr));
    if (entry == NULL)
        return _EFAULT;
    dword_t pt_flags = entry->flags;
    for (page_t page = PAGE(addr); page < PAGE(addr) + old_pages; page++) {
        entry = mem_pt(current->mem, page);
        if (entry == NULL && entry->flags != pt_flags)
            return _EFAULT;
    }
    if (!(pt_flags & P_ANONYMOUS)) {
        FIXME("mremap grow on file mappings");
        return _EFAULT;
    }
    page_t extra_start = PAGE(addr) + old_pages;
    pages_t extra_pages = new_pages - old_pages;
    if (!pt_is_hole(current->mem, extra_start, extra_pages))
        return _ENOMEM;
    int err = pt_map_nothing(current->mem, extra_start, extra_pages, pt_flags);
    if (err < 0)
        return err;
    return addr;
}

int_t sys_mprotect(addr_t addr, uint_t len, int_t prot) {
    STRACE("mprotect(0x%x, 0x%x, 0x%x)", addr, len, prot);
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
    // MADV_DONTNEED (4): discard pages, replace with zero-fill on next access
    // MADV_FREE (8): lazy free, pages may be reclaimed
    // Programs expect zeroed pages after MADV_DONTNEED. Without this, stale
    // data persists and V8's Zone allocator sees corrupt pointers from
    // previous allocations.
    if (advice == 4 /* MADV_DONTNEED */ || advice == 8 /* MADV_FREE */) {
        // On Linux, MADV_DONTNEED discards pages and lazily demand-zeros them.
        // We implement this by zeroing the pages via mem_ptr (handles CoW etc).
        // Without zeroing, jemalloc reuses pages with stale function pointers,
        // causing crashes when arena metadata structures contain old code addresses.
        addr_t end = addr + len;
        for (addr_t p = addr; p < end; p += PAGE_SIZE) {
            read_wrlock(&current->mem->lock);
            void *ptr = mem_ptr(current->mem, p, MEM_WRITE);
            read_wrunlock(&current->mem->lock);
            if (ptr != NULL)
                memset(ptr, 0, PAGE_SIZE);
        }
    }
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
        if (atomic_load(&anon_page_count) + (long)size > ANON_MMAP_LIMIT_PAGES)
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
