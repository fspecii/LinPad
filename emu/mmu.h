#ifndef EMU_CPU_MEM_H
#define EMU_CPU_MEM_H

#include "misc.h"

// Page number type: bits of address above PAGE_BITS
// Both x86 and ARM64 guests use 32-bit address space (4GB), so page_t is 32-bit.
// TLB_PAGE(addr) = addr & 0xfffff000 always fits in 32 bits.
// This keeps tlb_entry at 16 bytes for efficient assembly TLB lookup.
typedef dword_t page_t;
typedef dword_t pages_t;
#define BAD_PAGE 0x100000       // Invalid page marker (beyond 20-bit page range)
#define MEM_PAGES (1 << 20)     // 4GB address space (page numbers 0 to 0xFFFFF)

#ifndef __KERNEL__
#define PAGE_BITS 12
#undef PAGE_SIZE // defined in system headers somewhere
#define PAGE_SIZE (1 << PAGE_BITS)
#define PAGE(addr) ((addr) >> PAGE_BITS)
#define PGOFFSET(addr) ((addr) & (PAGE_SIZE - 1))
// bytes MUST be unsigned if you would like this to overflow to zero
#define PAGE_ROUND_UP(bytes) (PAGE((bytes) + PAGE_SIZE - 1))
#endif

struct mmu {
    struct mmu_ops *ops;
    struct asbestos *asbestos;
    uint64_t changes;
};

#define MEM_READ 0
#define MEM_WRITE 1
#define MEM_WRITE_PTRACE 2

struct mmu_ops {
    // type is MEM_READ or MEM_WRITE
    void *(*translate)(struct mmu *mmu, addr_t addr, int type);
};

static inline void *mmu_translate(struct mmu *mmu, addr_t addr, int type) {
    return mmu->ops->translate(mmu, addr, type);
}

#endif