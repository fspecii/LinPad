#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <stdatomic.h>

#define DEFAULT_CHANNEL memory
#include "debug.h"
#include "kernel/errno.h"
#include "kernel/signal.h"
#include "kernel/memory.h"
#include "asbestos/asbestos.h"
#include "kernel/vdso.h"
#include "kernel/task.h"
#include "kernel/resource.h"
#include "fs/fd.h"

// increment the change count
static void mem_changed(struct mem *mem);
static struct mmu_ops mem_mmu_ops;

#include "kernel/mm.h"


#ifdef GUEST_ARM64
// ============================================================
// ARM64: 4-level page table for 48-bit address space
// ============================================================

void mem_init(struct mem *mem) {
    mem->pgdir = calloc(1, sizeof(struct pt_node));
    mem->pgdir_used = 0;
    mem->mmu.ops = &mem_mmu_ops;
    mem->mmu.asbestos = asbestos_new(&mem->mmu);
    mem->mmu.changes = 0;
    wrlock_init(&mem->lock);
    lock_init(&mem->cow_lock);
}

// Recursively free page table nodes at given level
static void pt_node_free(void *node, int level) {
    if (node == NULL)
        return;
    if (level == 3) {
        // L3: array of pt_entry — just free the array
        free(node);
        return;
    }
    struct pt_node *n = node;
    for (int i = 0; i < PT_ENTRIES; i++) {
        pt_node_free(n->children[i], level + 1);
    }
    free(n);
}

void mem_destroy(struct mem *mem) {
    write_wrlock(&mem->lock);
    pt_unmap_always(mem, 0, MEM_PAGES);
    asbestos_free(mem->mmu.asbestos);
    pt_node_free(mem->pgdir, 0);
    mem->pgdir = NULL;
    write_wrunlock(&mem->lock);
    wrlock_destroy(&mem->lock);
}

// Navigate 4-level page table to find L3 entry, creating intermediate nodes as needed
static struct pt_entry *mem_pt_new(struct mem *mem, page_t page) {
    struct pt_node *l0 = mem->pgdir;
    int i0 = PT_INDEX(page, 0);
    struct pt_node *l1 = l0->children[i0];
    if (l1 == NULL) {
        l1 = l0->children[i0] = calloc(1, sizeof(struct pt_node));
        mem->pgdir_used++;
    }

    int i1 = PT_INDEX(page, 1);
    struct pt_node *l2 = l1->children[i1];
    if (l2 == NULL)
        l2 = l1->children[i1] = calloc(1, sizeof(struct pt_node));

    int i2 = PT_INDEX(page, 2);
    struct pt_entry *l3 = l2->children[i2];
    if (l3 == NULL)
        l3 = l2->children[i2] = calloc(PT_ENTRIES, sizeof(struct pt_entry));

    int i3 = PT_INDEX(page, 3);
    return &l3[i3];
}

struct pt_entry *mem_pt(struct mem *mem, page_t page) {
    struct pt_node *l0 = mem->pgdir;
    if (l0 == NULL) return NULL;

    struct pt_node *l1 = l0->children[PT_INDEX(page, 0)];
    if (l1 == NULL) return NULL;

    struct pt_node *l2 = l1->children[PT_INDEX(page, 1)];
    if (l2 == NULL) return NULL;

    struct pt_entry *l3 = l2->children[PT_INDEX(page, 2)];
    if (l3 == NULL) return NULL;

    struct pt_entry *entry = &l3[PT_INDEX(page, 3)];
    if (entry->data == NULL) return NULL;
    return entry;
}

static void mem_pt_del(struct mem *mem, page_t page) {
    struct pt_entry *entry = mem_pt(mem, page);
    if (entry != NULL)
        entry->data = NULL;
}

// Skip over large unallocated regions efficiently by checking intermediate levels
void mem_next_page(struct mem *mem, page_t *page) {
    (*page)++;
    if (*page >= MEM_PAGES)
        return;

    struct pt_node *l0 = mem->pgdir;
    if (l0 == NULL) { *page = MEM_PAGES; return; }

    while (*page < MEM_PAGES) {
        int i0 = PT_INDEX(*page, 0);
        struct pt_node *l1 = l0->children[i0];
        if (l1 == NULL) {
            // Skip entire L0 region (2^27 pages)
            *page = (((*page >> (PT_BITS * 3)) + 1) << (PT_BITS * 3));
            continue;
        }

        int i1 = PT_INDEX(*page, 1);
        struct pt_node *l2 = l1->children[i1];
        if (l2 == NULL) {
            // Skip entire L1 region (2^18 pages)
            *page = (((*page >> (PT_BITS * 2)) + 1) << (PT_BITS * 2));
            continue;
        }

        int i2 = PT_INDEX(*page, 2);
        struct pt_entry *l3 = l2->children[i2];
        if (l3 == NULL) {
            // Skip entire L2 region (2^9 = 512 pages)
            *page = (((*page >> PT_BITS) + 1) << PT_BITS);
            continue;
        }
        // Found a populated L3 array — page might exist here
        return;
    }
}

page_t pt_find_hole(struct mem *mem, pages_t size) {
    // Scan downward from MMAP_HOLE_START, skipping unallocated page table
    // subtrees for efficiency (each L0 entry covers 2^27 pages = 512GB,
    // L1 covers 2^18 pages = 1GB, L2 covers 2^9 pages = 2MB).
    struct pt_node *l0 = mem->pgdir;
    page_t hole_end = 0;
    bool in_hole = false;

    page_t page = MMAP_HOLE_START;
    while (page > MMAP_HOLE_END) {
        // Fast-skip unallocated L0 subtrees
        int i0 = PT_INDEX(page, 0);
        struct pt_node *l1 = l0 ? l0->children[i0] : NULL;
        if (l1 == NULL) {
            // Entire L0 subtree (2^27 pages) is unmapped
            pages_t l0_size = (pages_t)1 << (PT_BITS * 3);
            page_t l0_base = (page_t)i0 << (PT_BITS * 3);
            if (!in_hole) { in_hole = true; hole_end = page + 1; }
            // The entire range [l0_base, page] is a hole
            page_t effective_base = (l0_base > MMAP_HOLE_END) ? l0_base : MMAP_HOLE_END + 1;
            if (in_hole && hole_end - effective_base >= size)
                return hole_end - size;
            if (l0_base == 0) break;
            page = l0_base - 1;
            continue;
        }

        // Fast-skip unallocated L1 subtrees
        int i1 = PT_INDEX(page, 1);
        struct pt_node *l2 = l1->children[i1];
        if (l2 == NULL) {
            page_t l1_base = ((page_t)i0 << (PT_BITS * 3)) | ((page_t)i1 << (PT_BITS * 2));
            if (!in_hole) { in_hole = true; hole_end = page + 1; }
            page_t effective_base = (l1_base > MMAP_HOLE_END) ? l1_base : MMAP_HOLE_END + 1;
            if (in_hole && hole_end - effective_base >= size)
                return hole_end - size;
            if (l1_base == 0) break;
            page = l1_base - 1;
            continue;
        }

        // Fast-skip unallocated L2 subtrees
        int i2 = PT_INDEX(page, 2);
        struct pt_entry *l3 = l2->children[i2];
        if (l3 == NULL) {
            page_t l2_base = ((page_t)i0 << (PT_BITS * 3)) | ((page_t)i1 << (PT_BITS * 2)) | ((page_t)i2 << PT_BITS);
            if (!in_hole) { in_hole = true; hole_end = page + 1; }
            page_t effective_base = (l2_base > MMAP_HOLE_END) ? l2_base : MMAP_HOLE_END + 1;
            if (in_hole && hole_end - effective_base >= size)
                return hole_end - size;
            if (l2_base == 0) break;
            page = l2_base - 1;
            continue;
        }

        // L3 exists — check individual pages
        if (mem_pt(mem, page) != NULL) {
            in_hole = false;
        } else {
            if (!in_hole) { in_hole = true; hole_end = page + 1; }
            if (hole_end - page >= size)
                return page;
        }
        if (page == 0) break;
        page--;
    }
    return BAD_PAGE;
}

#else
// ============================================================
// x86: 2-level flat page table for 32-bit address space
// ============================================================

void mem_init(struct mem *mem) {
    mem->pgdir = calloc(MEM_PGDIR_SIZE, sizeof(struct pt_entry *));
    mem->pgdir_used = 0;
    mem->mmu.ops = &mem_mmu_ops;
    mem->mmu.asbestos = asbestos_new(&mem->mmu);
    mem->mmu.changes = 0;
    wrlock_init(&mem->lock);
    lock_init(&mem->cow_lock);
}

void mem_destroy(struct mem *mem) {
    write_wrlock(&mem->lock);
    pt_unmap_always(mem, 0, MEM_PAGES);
    asbestos_free(mem->mmu.asbestos);
    for (int i = 0; i < MEM_PGDIR_SIZE; i++) {
        if (mem->pgdir[i] != NULL)
            free(mem->pgdir[i]);
    }
    free(mem->pgdir);
    write_wrunlock(&mem->lock);
    wrlock_destroy(&mem->lock);
}

#define PGDIR_TOP(page) ((page) >> 10)
#define PGDIR_BOTTOM(page) ((page) & (MEM_PGDIR_SIZE - 1))

static struct pt_entry *mem_pt_new(struct mem *mem, page_t page) {
    struct pt_entry *pgdir = mem->pgdir[PGDIR_TOP(page)];
    if (pgdir == NULL) {
        pgdir = mem->pgdir[PGDIR_TOP(page)] = calloc(MEM_PGDIR_SIZE, sizeof(struct pt_entry));
        mem->pgdir_used++;
    }
    return &pgdir[PGDIR_BOTTOM(page)];
}

struct pt_entry *mem_pt(struct mem *mem, page_t page) {
    struct pt_entry *pgdir = mem->pgdir[PGDIR_TOP(page)];
    if (pgdir == NULL)
        return NULL;
    struct pt_entry *entry = &pgdir[PGDIR_BOTTOM(page)];
    if (entry->data == NULL)
        return NULL;
    return entry;
}

static void mem_pt_del(struct mem *mem, page_t page) {
    struct pt_entry *entry = mem_pt(mem, page);
    if (entry != NULL)
        entry->data = NULL;
}

void mem_next_page(struct mem *mem, page_t *page) {
    (*page)++;
    if (*page >= MEM_PAGES)
        return;
    while (*page < MEM_PAGES && mem->pgdir[PGDIR_TOP(*page)] == NULL)
        *page = (*page - PGDIR_BOTTOM(*page)) + MEM_PGDIR_SIZE;
}

page_t pt_find_hole(struct mem *mem, pages_t size) {
    page_t hole_end = 0;
    bool in_hole = false;
    for (page_t page = 0xefffd; page > 0x40000; page--) {
        if (!in_hole && mem_pt(mem, page) == NULL) {
            in_hole = true;
            hole_end = page + 1;
        }
        if (mem_pt(mem, page) != NULL)
            in_hole = false;
        else if (hole_end - page == size)
            return page;
    }
    return BAD_PAGE;
}

#endif // GUEST_ARM64

bool pt_is_hole(struct mem *mem, page_t start, pages_t pages) {
    for (page_t page = start; page < start + pages; page++) {
        if (mem_pt(mem, page) != NULL)
            return false;
    }
    return true;
}

int pt_map(struct mem *mem, page_t start, pages_t pages, void *memory, size_t offset, unsigned flags) {
    if (memory == MAP_FAILED)
        return errno_map();

    // If this fails, the munmap in pt_unmap would probably fail.
    assert((uintptr_t) memory % real_page_size == 0 || memory == vdso_data);

    struct data *data = malloc(sizeof(struct data));
    if (data == NULL)
        return _ENOMEM;
    *data = (struct data) {
        .data = memory,
        .size = pages * PAGE_SIZE + offset,

#if LEAK_DEBUG
        .pid = current ? current->pid : 0,
        .dest = start << PAGE_BITS,
#endif
    };

    for (page_t page = start; page < start + pages; page++) {
        if (mem_pt(mem, page) != NULL)
            pt_unmap(mem, page, 1);
        data->refcount++;
        struct pt_entry *pt = mem_pt_new(mem, page);
        pt->data = data;
        pt->offset = ((page - start) << PAGE_BITS) + offset;
        pt->flags = flags;

    }
    return 0;
}

int pt_unmap(struct mem *mem, page_t start, pages_t pages) {
    for (page_t page = start; page < start + pages; page++)
        if (mem_pt(mem, page) == NULL)
            return -1;
    return pt_unmap_always(mem, start, pages);
}

int pt_unmap_always(struct mem *mem, page_t start, pages_t pages) {
    for (page_t page = start; page < start + pages; mem_next_page(mem, &page)) {
        struct pt_entry *pt = mem_pt(mem, page);
        if (pt == NULL)
            continue;

        asbestos_invalidate_page(mem->mmu.asbestos, page);
        struct data *data = pt->data;
#if ANON_MMAP_LIMIT_PAGES > 0
        // Decrement per-page for anonymous mappings. This correctly handles
        // partial unmaps (munmap of subset of original mmap region) where the
        // data object's refcount doesn't reach 0 but the guest page is gone.
        if (pt->flags & P_ANONYMOUS)
            atomic_fetch_sub(&anon_page_count, 1);
#endif
        // NOTE: Per-page mprotect(PROT_NONE) is NOT safe on macOS ARM64.
        // macOS has 16K host pages, so mprotect on a 4K guest page would
        // affect the entire 16K host page, potentially invalidating adjacent
        // live guest pages that share the same data region.
        // Instead, we only mprotect when refcount reaches 0 (entire region freed).
        mem_pt_del(mem, page);
        if (--data->refcount == 0) {
            // vdso wasn't allocated with mmap, it's just in our data segment
            if (data->data != vdso_data) {
                // Replace with PROT_NONE pages before freeing. On macOS,
                // munmap+mmap can reuse the same host virtual address. If a
                // JIT thread has a stale TLB entry pointing to this address,
                // it would silently read/write to the new allocation's data
                // instead of getting SIGSEGV (ABA problem). By replacing with
                // PROT_NONE first, we ensure stale accesses get SIGSEGV, which
                // the JIT crash recovery handles correctly.
                //
                // We DON'T munmap — the PROT_NONE region stays mapped to block
                // host address reuse. This leaks virtual address space but
                // prevents data corruption. The leak is bounded because new
                // mmap calls use pt_find_hole which finds unused guest pages,
                // and the host regions are eventually reclaimed when the process
                // exits or when the address space is destroyed.
                mprotect(data->data, data->size, PROT_NONE);
                // Don't munmap — keep the address reserved as PROT_NONE
            }
            if (data->fd != NULL) {
                fd_close(data->fd);
            }
            free(data);
        }
    }
    mem_changed(mem);
    return 0;
}

int pt_map_nothing(struct mem *mem, page_t start, pages_t pages, unsigned flags) {
    if (pages == 0) return 0;
    void *memory = mmap(NULL, pages * PAGE_SIZE,
            PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0);
    return pt_map(mem, start, pages, memory, 0, flags | P_ANONYMOUS);
}

// Metadata flags that must be preserved across mprotect — they track
// allocation type and state, not user-visible protection bits.
#define P_META_FLAGS (P_ANONYMOUS | P_GROWSDOWN | P_COW | P_SHARED)

int pt_set_flags(struct mem *mem, page_t start, pages_t pages, int flags) {
    for (page_t page = start; page < start + pages; page++)
        if (mem_pt(mem, page) == NULL)
            return _ENOMEM;
    for (page_t page = start; page < start + pages; page++) {
        struct pt_entry *entry = mem_pt(mem, page);
        int old_flags = entry->flags;
        entry->flags = flags | (old_flags & P_META_FLAGS);

        // check if protection is increasing
        if ((flags & ~old_flags) & (P_READ|P_WRITE)) {
            void *data = (char *) entry->data->data + entry->offset;
            // force to be page aligned
            data = (void *) ((uintptr_t) data & ~(real_page_size - 1));
            int prot = PROT_READ;
            if (flags & P_WRITE) prot |= PROT_WRITE;
            if (mprotect(data, real_page_size, prot) < 0)
                return errno_map();
        }
    }
    mem_changed(mem);
    return 0;
}

int pt_copy_on_write(struct mem *src, struct mem *dst, page_t start, page_t pages) {
#if ANON_MMAP_LIMIT_PAGES > 0
    long anon_copied = 0;
#endif
    for (page_t page = start; page < start + pages; mem_next_page(src, &page)) {
        struct pt_entry *entry = mem_pt(src, page);
        if (entry == NULL)
            continue;
        if (pt_unmap_always(dst, page, 1) < 0)
            return -1;
        if (!(entry->flags & P_SHARED))
            entry->flags |= P_COW;
        entry->data->refcount++;
        struct pt_entry *dst_entry = mem_pt_new(dst, page);
        dst_entry->data = entry->data;
        dst_entry->offset = entry->offset;
        dst_entry->flags = entry->flags;
#if ANON_MMAP_LIMIT_PAGES > 0
        if (entry->flags & P_ANONYMOUS)
            anon_copied++;
#endif
    }
#if ANON_MMAP_LIMIT_PAGES > 0
    // The child process now has its own set of anonymous pages.
    // These will be decremented per-page when the child's mm is freed.
    atomic_fetch_add(&anon_page_count, anon_copied);
#endif
    mem_changed(src);
    mem_changed(dst);
    return 0;
}

static void mem_changed(struct mem *mem) {
    __atomic_add_fetch(&mem->mmu.changes, 1, __ATOMIC_RELEASE);
}

// This version will return NULL instead of making necessary pagetable changes.
// Used by the emulator to avoid deadlocks.
static void *mem_ptr_nofault(struct mem *mem, addr_t addr, int type) {
    struct pt_entry *entry = mem_pt(mem, PAGE(addr));
    if (entry == NULL)
        return NULL;
    if (type == MEM_WRITE && !P_WRITABLE(entry->flags))
        return NULL;
    return entry->data->data + entry->offset + PGOFFSET(addr);
}

void *mem_ptr(struct mem *mem, addr_t addr, int type) {
#ifndef NDEBUG
    void *old_ptr = mem_ptr_nofault(mem, addr, type); // just for an assert
#endif

    page_t page = PAGE(addr);
    struct pt_entry *entry = mem_pt(mem, page);


    if (entry == NULL) {
        // page does not exist
        // look to see if the next VM region is willing to grow down
        page_t p = page;
        mem_next_page(mem, &p);
        while (p < MEM_PAGES && mem_pt(mem, p) == NULL)
            mem_next_page(mem, &p);
        if (p >= MEM_PAGES)
            return NULL;
        if (!(mem_pt(mem, p)->flags & P_GROWSDOWN))
            return NULL;

        // Enforce RLIMIT_STACK: don't grow stack beyond the limit.
#ifdef GUEST_ARM64
        // Stack top is at STACK_TOP_PAGE (guard page), stack grows down from STACK_INIT_PAGE.
        pages_t guard_page = STACK_TOP_PAGE;
#else
        // Stack top is at page 0xffffe (guard page), stack grows down from 0xffffd.
        pages_t guard_page = 0xffffe;
#endif
        rlim_t_ stack_limit = rlimit(RLIMIT_STACK_);
        if (stack_limit != RLIM_INFINITY_) {
            pages_t stack_pages = guard_page - page;
            if ((uint64_t)stack_pages * PAGE_SIZE > stack_limit)
                return NULL;
        }

        // Changing memory maps must be done with the write lock. But this is
        // called with the read lock.
        read_wrunlock(&mem->lock);
        write_wrlock(&mem->lock);
#if ANON_MMAP_LIMIT_PAGES > 0
        atomic_fetch_add(&anon_page_count, 1);
#endif
        pt_map_nothing(mem, page, 1, P_WRITE | P_GROWSDOWN);
        write_wrunlock(&mem->lock);
        read_wrlock(&mem->lock);

        entry = mem_pt(mem, page);
    }

    if (entry != NULL && (type == MEM_WRITE || type == MEM_WRITE_PTRACE)) {
        // if page is unwritable, well tough luck
        if (type != MEM_WRITE_PTRACE && !(entry->flags & P_WRITE))
            return NULL;
        if (type == MEM_WRITE_PTRACE) {
            // TODO: Is P_WRITE really correct? The page shouldn't be writable without ptrace.
            entry->flags |= P_WRITE | P_COW;
        }
        // get rid of any compiled blocks in this page
        asbestos_invalidate_page(mem->mmu.asbestos, page);
        // if page is cow, ~~milk~~ copy it
        if (entry->flags & P_COW) {
            void *copy = mmap(NULL, PAGE_SIZE, PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS, 0, 0);

            read_wrunlock(&mem->lock);
            write_wrlock(&mem->lock);
            // Re-fetch entry after lock upgrade — another thread may have
            // already resolved this CoW while we were waiting for the lock.
            entry = mem_pt(mem, page);
            if (entry != NULL && (entry->flags & P_COW)) {
                void *data = (char *) entry->data->data + entry->offset;
                memcpy(copy, data, PAGE_SIZE);
#if ANON_MMAP_LIMIT_PAGES > 0
                // pt_map will unmap the old page (decrementing anon_page_count),
                // so pre-increment for the new CoW copy to keep balance.
                if (entry->flags & P_ANONYMOUS)
                    atomic_fetch_add(&anon_page_count, 1);
#endif
                pt_map(mem, page, 1, copy, 0, entry->flags &~ P_COW);
                mem_changed(mem);
            } else {
                munmap(copy, PAGE_SIZE);
            }
            write_wrunlock(&mem->lock);
            read_wrlock(&mem->lock);
        }
    }

    void *ptr = mem_ptr_nofault(mem, addr, type);
#ifndef NDEBUG
    assert(old_ptr == NULL || old_ptr == ptr || type == MEM_WRITE_PTRACE);
#endif
    return ptr;
}

static void *mem_mmu_translate(struct mmu *mmu, addr_t addr, int type) {
    // Use mem_ptr instead of mem_ptr_nofault to properly handle:
    // 1. Copy-on-write (COW) pages - need to copy before write
    // 2. Growing stack pages (P_GROWSDOWN)
    return mem_ptr(container_of(mmu, struct mem, mmu), addr, type);
}

static void *mem_mmu_translate_write_nofault(struct mmu *mmu, addr_t addr) {
    return mem_ptr_nofault(container_of(mmu, struct mem, mmu), addr, MEM_WRITE);
}

static struct mmu_ops mem_mmu_ops = {
    .translate = mem_mmu_translate,
    .translate_write_nofault = mem_mmu_translate_write_nofault,
};

int mem_segv_reason(struct mem *mem, addr_t addr) {
    struct pt_entry *pt = mem_pt(mem, PAGE(addr));
    if (pt == NULL)
        return SEGV_MAPERR_;
    return SEGV_ACCERR_;
}

size_t real_page_size;
__attribute__((constructor)) static void get_real_page_size() {
    real_page_size = sysconf(_SC_PAGESIZE);
}

void mem_coredump(struct mem *mem, const char *file) {
    int fd = open(file, O_CREAT | O_RDWR | O_TRUNC, 0666);
    if (fd < 0) {
        perror("open");
        return;
    }
    if (ftruncate(fd, 0xffffffff) < 0) {
        perror("ftruncate");
        return;
    }

    int pages = 0;
    for (page_t page = 0; page < MEM_PAGES; mem_next_page(mem, &page)) {
        struct pt_entry *entry = mem_pt(mem, page);
        if (entry == NULL)
            continue;
        pages++;
        if (lseek(fd, (off_t)(page << PAGE_BITS), SEEK_SET) < 0) {
            perror("lseek");
            return;
        }
        if (write(fd, entry->data->data, PAGE_SIZE) < 0) {
            perror("write");
            return;
        }
    }
    printk("dumped %d pages\n", pages);
    close(fd);
}
