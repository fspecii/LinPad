#include "emu/cpu.h"
#include "emu/tlb.h"
#include "kernel/task.h"
#include "kernel/memory.h"
#include "kernel/fs.h"
#include "util/sync.h"

#if defined(GUEST_ARM64) && defined(WATCH_ADDR)
static int watch_load_hits = 0;
static int watch_store_hits = 0;
static int watch_dumped_maps = 0;
static void watch_log_mapping(const char *label, addr_t addr) {
    if (!current || !current->mem)
        return;
    read_wrlock(&current->mem->lock);
    struct pt_entry *pt = mem_pt(current->mem, PAGE(addr));
    if (pt == NULL || pt->data == NULL) {
        read_wrunlock(&current->mem->lock);
        fprintf(stderr, "[WATCH] %s addr=0x%llx unmapped\n",
                label, (unsigned long long)addr);
        return;
    }
    char path[MAX_PATH] = "";
    if (pt->data->name != NULL) {
        strncpy(path, pt->data->name, sizeof(path) - 1);
    } else if (pt->data->fd != NULL) {
        generic_getpath(pt->data->fd, path);
    }
    size_t file_off = pt->offset + (addr & (PAGE_SIZE - 1));
    unsigned flags = pt->flags;
    read_wrunlock(&current->mem->lock);
    fprintf(stderr, "[WATCH] %s addr=0x%llx file_off=0x%zx flags=%c%c%c %s\n",
            label, (unsigned long long)addr, file_off,
            (flags & P_READ) ? 'r' : '-',
            (flags & P_WRITE) ? 'w' : '-',
            (flags & P_EXEC) ? 'x' : '-',
            path);
}
#endif
void tlb_refresh(struct tlb *tlb, struct mmu *mmu) {
    if (tlb->mmu == mmu && tlb->mem_changes == mmu->changes)
        return;
    tlb->mmu = mmu;
    tlb->dirty_page = TLB_PAGE_EMPTY;
    tlb->mem_changes = mmu->changes;
    tlb_flush(tlb);
}

void tlb_flush(struct tlb *tlb) {
    tlb->mem_changes = tlb->mmu->changes;
    for (unsigned i = 0; i < TLB_SIZE; i++)
        tlb->entries[i] = (struct tlb_entry) {.page = 1, .page_if_writable = 1};
}

void tlb_free(struct tlb *tlb) {
    free(tlb);
}

bool __tlb_read_cross_page(struct tlb *tlb, addr_t addr, char *value, unsigned size) {
    char *ptr1 = __tlb_read_ptr(tlb, addr);
    if (ptr1 == NULL)
        return false;
    char *ptr2 = __tlb_read_ptr(tlb, (PAGE(addr) + 1) << PAGE_BITS);
    if (ptr2 == NULL)
        return false;
    size_t part1 = PAGE_SIZE - PGOFFSET(addr);
    assert(part1 < size);
    memcpy(value, ptr1, part1);
    memcpy(value + part1, ptr2, size - part1);
    return true;
}

bool __tlb_write_cross_page(struct tlb *tlb, addr_t addr, const char *value, unsigned size) {
    char *ptr1 = __tlb_write_ptr(tlb, addr);
    if (ptr1 == NULL)
        return false;
    char *ptr2 = __tlb_write_ptr(tlb, (PAGE(addr) + 1) << PAGE_BITS);
    if (ptr2 == NULL)
        return false;
    size_t part1 = PAGE_SIZE - PGOFFSET(addr);
    assert(part1 < size);
    memcpy(ptr1, value, part1);
    memcpy(ptr2, value + part1, size - part1);
    return true;
}


__no_instrument void *tlb_handle_miss(struct tlb *tlb, addr_t addr, int type) {
    char *ptr = mmu_translate(tlb->mmu, TLB_PAGE(addr), type);
    if (tlb->mmu->changes != tlb->mem_changes)
        tlb_flush(tlb);
    if (ptr == NULL) {
        tlb->segfault_addr = addr;
        return NULL;
    }
    tlb->dirty_page = TLB_PAGE(addr);

    struct tlb_entry *tlb_ent = &tlb->entries[TLB_INDEX(addr)];
    tlb_ent->page = TLB_PAGE(addr);
    if (type == MEM_WRITE)
        tlb_ent->page_if_writable = tlb_ent->page;
    else
        tlb_ent->page_if_writable = TLB_PAGE_EMPTY;
    tlb_ent->data_minus_addr = (uintptr_t) ptr - TLB_PAGE(addr);

    void *result = (void *) (tlb_ent->data_minus_addr + addr);
    return result;
}

#if defined(GUEST_ARM64)
/*
 * C-based memory access functions for ARM64 guest gadgets.
 * These provide reliable memory access by using the proven C-based TLB code.
 *
 * Return value convention for loads:
 * - Returns the loaded value through the 'out' pointer
 * - Returns 0 on success, -1 on segfault (tlb->segfault_addr is set)
 *
 * Return value convention for stores:
 * - Returns 0 on success, -1 on segfault (tlb->segfault_addr is set)
 */

// Debug function for tracing TST/ANDS execution
static int tst_trace_count = 0;
__no_instrument void debug_tst(uint64_t val, uint64_t imm, uint32_t flags) {
    uint64_t result = val & imm;
    tst_trace_count++;
    if (tst_trace_count < 200 || (imm == 0x8080808080808080ULL && result != 0)) {
        fprintf(stderr, "[TST #%d] val=0x%llx imm=0x%llx result=0x%llx flags=0x%x (Z=%d)\n",
                tst_trace_count, (unsigned long long)val, (unsigned long long)imm,
                (unsigned long long)result, flags, (flags >> 30) & 1);
    }
}

// Debug defines (unused, kept for reference)
#if 0
// ld-musl rodata range (base 0xf7f3b000 + rodata offset 0x6d790 to 0xa11dc)
#define RODATA_START 0xf7fa8790ULL  // 0xf7f3b000 + 0x6d790
#define RODATA_END   0xf7fdc1dcULL  // 0xf7f3b000 + 0xa11dc
// Error string address
#define ERROR_STRING_ADDR 0xf7fda610ULL
#endif


// Load functions - return 0 on success, -1 on segfault
__no_instrument int c_load64(struct tlb *tlb, addr_t addr, uint64_t *out) {
    // Debug: trace specific address (disabled)
#if 0
    if (addr == 0xf7ff8028) {
        uint64_t pc = current ? current->cpu.pc : 0;
        fprintf(stderr, "[C_LOAD64 0xf7ff8028] addr=0x%llx pc=0x%llx\n",
                (unsigned long long)addr, (unsigned long long)pc);
    }
#endif
    // Debug: log all loads from the qsort array area
#if 0  // Disabled for now
    if (addr >= 0xf7ff3200 && addr < 0xf7ff3300 && (addr & 7) != 0) {
        fprintf(stderr, "[C_LOAD64 UNALIGNED] addr=0x%llx (misaligned by %d)\n",
                (unsigned long long)addr, (int)(addr & 7));
        // Print where the call came from - use __builtin_return_address
        void *caller = __builtin_return_address(0);
        fprintf(stderr, "[C_LOAD64 UNALIGNED] caller=%p\n", caller);
    }
#endif
    // Handle unaligned access by reading byte-by-byte
    if ((addr & 7) != 0) {
        // Unaligned - read each byte separately (little-endian)
        uint64_t result = 0;
        for (int i = 0; i < 8; i++) {
            void *ptr = __tlb_read_ptr(tlb, addr + i);
            if (ptr == NULL) {
                return -1;
            }
            result |= ((uint64_t)*(uint8_t *)ptr) << (i * 8);
        }
        *out = result;
#if defined(GUEST_ARM64)
        if (*out == 0xffffffff00000000ULL) {
            uint64_t pc = current ? current->cpu.pc : 0;
            fprintf(stderr, "[WATCH] load64 pc=0x%llx addr=0x%llx value=0x%llx (unaligned)\n",
                    (unsigned long long)pc, (unsigned long long)addr, (unsigned long long)*out);
        }
#endif
        return 0;
    }

    void *ptr = __tlb_read_ptr(tlb, addr);
    if (ptr == NULL) {
        return -1;  // segfault_addr already set by tlb_handle_miss
    }
    *out = *(uint64_t *)ptr;
    // Debug: trace specific address result
    if (addr == 0xf7ff8028) {
        fprintf(stderr, "[C_LOAD64 0xf7ff8028] result=0x%llx ptr=%p\n",
                (unsigned long long)*out, ptr);
    }
// Debug: trace loads that return values in the rodata range (might be source of bad pointers)
#if defined(GUEST_ARM64) && 0  // Disabled to reduce noise
    if (*out >= RODATA_START && *out < RODATA_END) {
        uint64_t pc = current ? current->cpu.pc : 0;
        fprintf(stderr, "[LOAD RODATA PTR] pc=0x%llx addr=0x%llx value=0x%llx\n",
                (unsigned long long)pc, (unsigned long long)addr, (unsigned long long)*out);
    }
#endif
#if defined(GUEST_ARM64) && defined(WATCH_ADDR)
    if (*out == 0xffffffff00000000ULL || WATCH_MATCH_ANY(addr)) {
        uint64_t pc = current ? current->cpu.pc : 0;
        uint32_t insn = 0;
        if (pc != 0) {
            void *iptr = __tlb_read_ptr(tlb, (addr_t)pc);
            if (iptr != NULL)
                insn = *(uint32_t *)iptr;
        }
        uint64_t x19 = current ? current->cpu.x19 : 0;
        uint64_t x20 = current ? current->cpu.x20 : 0;
        fprintf(stderr, "[WATCH] load64 pc=0x%llx insn=0x%08x addr=0x%llx value=0x%llx (hit=%d) x19=0x%llx x20=0x%llx\n",
                (unsigned long long)pc, insn, (unsigned long long)addr,
                (unsigned long long)*out, ++watch_load_hits,
                (unsigned long long)x19, (unsigned long long)x20);
        // Dump 16 bytes around the watch address
        unsigned char bytes1[16] = {0};
        unsigned char bytes2[16] = {0};
        for (int i = 0; i < 16; i++) {
            void *bptr1 = __tlb_read_ptr(tlb, (addr_t)(WATCH_ADDR + i));
            if (bptr1 != NULL)
                bytes1[i] = *(unsigned char *)bptr1;
            void *bptr2 = __tlb_read_ptr(tlb, (addr_t)(WATCH_ADDR + i));
            if (bptr2 != NULL)
                bytes2[i] = *(unsigned char *)bptr2;
        }
        fprintf(stderr, "[WATCH] mem1[%llx..%llx]=%02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x\n",
                (unsigned long long)WATCH_ADDR,
                (unsigned long long)(WATCH_ADDR + 15),
                bytes1[0], bytes1[1], bytes1[2], bytes1[3], bytes1[4], bytes1[5], bytes1[6], bytes1[7],
                bytes1[8], bytes1[9], bytes1[10], bytes1[11], bytes1[12], bytes1[13], bytes1[14], bytes1[15]);
        fprintf(stderr, "[WATCH] mem2[%llx..%llx]=%02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x\n",
                (unsigned long long)WATCH_ADDR,
                (unsigned long long)(WATCH_ADDR + 15),
                bytes2[0], bytes2[1], bytes2[2], bytes2[3], bytes2[4], bytes2[5], bytes2[6], bytes2[7],
                bytes2[8], bytes2[9], bytes2[10], bytes2[11], bytes2[12], bytes2[13], bytes2[14], bytes2[15]);
        watch_log_mapping("pc", (addr_t)pc);
        watch_log_mapping("watch1", (addr_t)WATCH_ADDR);
        watch_log_mapping("watch2", (addr_t)WATCH_ADDR);
        if (!watch_dumped_maps && current && current->mem) {
            watch_dumped_maps = 1;
            fprintf(stderr, "[WATCH] dumping maps on first hit\n");
            void dump_maps(void);
            dump_maps();
        }
    }
#endif
    return 0;
}

__no_instrument int c_load32(struct tlb *tlb, addr_t addr, uint32_t *out) {
    void *ptr = __tlb_read_ptr(tlb, addr);
    if (ptr == NULL) {
        return -1;
    }
    *out = *(uint32_t *)ptr;
#if defined(GUEST_ARM64) && defined(WATCH_ADDR)
    if (*out == 0xfffffff1U) {
        uint64_t pc = current ? current->cpu.pc : 0;
        uint32_t insn = 0;
        if (pc != 0) {
            void *iptr = __tlb_read_ptr(tlb, (addr_t)pc);
            if (iptr != NULL)
                insn = *(uint32_t *)iptr;
        }
        fprintf(stderr, "[WATCH] load32 value=0xfffffff1 pc=0x%llx insn=0x%08x addr=0x%llx\n",
                (unsigned long long)pc, insn, (unsigned long long)addr);
        watch_log_mapping("pc", (addr_t)pc);
        watch_log_mapping("idx", addr);
    }
#endif
    return 0;
}

__no_instrument int c_load16(struct tlb *tlb, addr_t addr, uint16_t *out) {
    void *ptr = __tlb_read_ptr(tlb, addr);
    if (ptr == NULL) {
        return -1;
    }
    *out = *(uint16_t *)ptr;
    return 0;
}

__no_instrument int c_load8(struct tlb *tlb, addr_t addr, uint8_t *out) {
    void *ptr = __tlb_read_ptr(tlb, addr);
    if (ptr == NULL) {
        return -1;
    }
    *out = *(uint8_t *)ptr;
    return 0;
}

// Sign-extending load functions
__no_instrument int c_load32_sx(struct tlb *tlb, addr_t addr, int64_t *out) {
    void *ptr = __tlb_read_ptr(tlb, addr);
    if (ptr == NULL) {
        return -1;
    }
    *out = (int64_t)(int32_t)*(uint32_t *)ptr;
    return 0;
}

__no_instrument int c_load16_sx64(struct tlb *tlb, addr_t addr, int64_t *out) {
    void *ptr = __tlb_read_ptr(tlb, addr);
    if (ptr == NULL) {
        return -1;
    }
    *out = (int64_t)(int16_t)*(uint16_t *)ptr;
    return 0;
}

__no_instrument int c_load16_sx32(struct tlb *tlb, addr_t addr, int32_t *out) {
    void *ptr = __tlb_read_ptr(tlb, addr);
    if (ptr == NULL) {
        return -1;
    }
    *out = (int32_t)(int16_t)*(uint16_t *)ptr;
    return 0;
}

__no_instrument int c_load8_sx64(struct tlb *tlb, addr_t addr, int64_t *out) {
    void *ptr = __tlb_read_ptr(tlb, addr);
    if (ptr == NULL) {
        return -1;
    }
    *out = (int64_t)(int8_t)*(uint8_t *)ptr;
    return 0;
}

__no_instrument int c_load8_sx32(struct tlb *tlb, addr_t addr, int32_t *out) {
    void *ptr = __tlb_read_ptr(tlb, addr);
    if (ptr == NULL) {
        return -1;
    }
    *out = (int32_t)(int8_t)*(uint8_t *)ptr;
    return 0;
}

// Store functions - return 0 on success, -1 on segfault
__no_instrument int c_store64(struct tlb *tlb, addr_t addr, uint64_t value) {
#if 0  // Debug: track stores to help debug SIMD STP
#define DEBUG_STORE_ADDR 0x7fffd8c0ULL  // buf_size address (FILE+0x60 where FILE is at 0x7fffd860)
    // Debug: specifically trace stores to buf_size (FILE+0x60 = 0x7fffd8e8)
    static int store_to_file_count = 0;
    // Track stores to buf_size location specifically
    if (addr == 0x7fffd8e8ULL) {  // buf_size address
        uint64_t pc = current ? current->cpu.pc : 0;
        fprintf(stderr, "[STORE BUF_SIZE] pc=0x%llx value=0x%llx\n",
                (unsigned long long)pc, (unsigned long long)value);
    }
    // Also track all FILE struct stores
    if (addr >= 0x7fffd880ULL && addr < 0x7fffd960ULL) {
        uint64_t pc = current ? current->cpu.pc : 0;
        int64_t file_offset = (int64_t)(addr - 0x7fffd888ULL);
        fprintf(stderr, "[STORE FILE #%d] pc=0x%llx (ldmusl=0x%llx) FILE+0x%llx addr=0x%llx value=0x%llx\n",
                ++store_to_file_count,
                (unsigned long long)pc,
                (unsigned long long)(pc > 0xf7f3b000ULL ? pc - 0xf7f3b000ULL : pc),
                (long long)file_offset,
                (unsigned long long)addr, (unsigned long long)value);
        if (store_to_file_count > 200) store_to_file_count = 0;
    }

    // Debug: trace stores of the specific error string pointer
    if (value == ERROR_STRING_ADDR || (value >= ERROR_STRING_ADDR && value < ERROR_STRING_ADDR + 0x100)) {
        uint64_t pc = current ? current->cpu.pc : 0;
        // Read the instruction at PC to help identify what's happening
        uint32_t insn = 0;
        void *iptr = __tlb_read_ptr(tlb, (addr_t)pc);
        if (iptr != NULL)
            insn = *(uint32_t *)iptr;
        fprintf(stderr, "[STORE ERROR_STR] pc=0x%llx (offset=0x%llx) insn=0x%08x addr=0x%llx value=0x%llx\n",
                (unsigned long long)pc,
                (unsigned long long)(pc - 0xf7f3b000ULL),
                insn,
                (unsigned long long)addr, (unsigned long long)value);
        // Print FILE struct offset (addr - FILE base on stack)
        // The FILE struct is allocated on stack at sp+0x38 in vdprintf
        // Let's show more context
        if (current) {
            // Try to determine FILE base - it's at different stack offsets in different functions
            // In __stdio_write, x24 is the FILE pointer
            uint64_t file_base = current->cpu.x24;  // Usually FILE* is in x24 or similar
            fprintf(stderr, "  FILE* estimate x24=0x%llx, addr-x24=0x%llx\n",
                    (unsigned long long)file_base,
                    (unsigned long long)(addr - file_base));
            fprintf(stderr, "  x0-x3: 0x%llx 0x%llx 0x%llx 0x%llx\n",
                    (unsigned long long)current->cpu.x0, (unsigned long long)current->cpu.x1,
                    (unsigned long long)current->cpu.x2, (unsigned long long)current->cpu.x3);
        }
    }
#endif
#if defined(GUEST_ARM64) && defined(WATCH_ADDR)
    if (WATCH_MATCH_ANY(addr)) {
        uint64_t pc = current ? current->cpu.pc : 0;
        uint32_t insn = 0;
        if (pc != 0) {
            void *iptr = __tlb_read_ptr(tlb, (addr_t)pc);
            if (iptr != NULL)
                insn = *(uint32_t *)iptr;
        }
        fprintf(stderr, "[WATCH] store64 pc=0x%llx insn=0x%08x addr=0x%llx value=0x%llx (hit=%d)\n",
                (unsigned long long)pc, insn, (unsigned long long)addr,
                (unsigned long long)value, ++watch_store_hits);
    }
#endif
    // Debug: disable store logging for now
#if 0
    // Looking for stores around the failing qsort comparison area
    if (addr >= 0xf7ff3200 && addr < 0xf7ff3300) {
        fprintf(stderr, "[QSORT_AREA STORE] addr=0x%llx value=0x%llx\n",
                (unsigned long long)addr, (unsigned long long)value);
    }
#endif
    // Handle unaligned access by writing byte-by-byte
    if ((addr & 7) != 0) {
        // Unaligned - write each byte separately (little-endian)
        for (int i = 0; i < 8; i++) {
            void *ptr = __tlb_write_ptr(tlb, addr + i);
            if (ptr == NULL) {
                return -1;
            }
            *(uint8_t *)ptr = (value >> (i * 8)) & 0xFF;
        }
        return 0;
    }

    void *ptr = __tlb_write_ptr(tlb, addr);
    if (ptr == NULL) {
        return -1;  // segfault_addr already set
    }
    *(uint64_t *)ptr = value;
    return 0;
}

__no_instrument int c_store32(struct tlb *tlb, addr_t addr, uint32_t value) {
#if defined(GUEST_ARM64) && defined(WATCH_ADDR)
    if (WATCH_MATCH_ANY(addr)) {
        uint64_t pc = current ? current->cpu.pc : 0;
        uint32_t insn = 0;
        if (pc != 0) {
            void *iptr = __tlb_read_ptr(tlb, (addr_t)pc);
            if (iptr != NULL)
                insn = *(uint32_t *)iptr;
        }
        uint64_t x0 = current ? current->cpu.x0 : 0;
        uint64_t x2 = current ? current->cpu.regs[2] : 0;
        uint64_t x6 = current ? current->cpu.regs[6] : 0;
        uint64_t x30 = current ? current->cpu.regs[30] : 0;
        uint64_t sp = current ? current->cpu.sp : 0;
        fprintf(stderr, "[WATCH] store32 pc=0x%llx insn=0x%08x addr=0x%llx value=0x%x (hit=%d) x0=0x%llx x2=0x%llx x6=0x%llx x30=0x%llx sp=0x%llx\n",
                (unsigned long long)pc, insn, (unsigned long long)addr,
                value, ++watch_store_hits,
                (unsigned long long)x0, (unsigned long long)x2,
                (unsigned long long)x6, (unsigned long long)x30, (unsigned long long)sp);
    }
    if (value == 0xfffffff1U) {
        uint64_t pc = current ? current->cpu.pc : 0;
        uint32_t insn = 0;
        if (pc != 0) {
            void *iptr = __tlb_read_ptr(tlb, (addr_t)pc);
            if (iptr != NULL)
                insn = *(uint32_t *)iptr;
        }
        fprintf(stderr, "[WATCH] store32 value=0xfffffff1 pc=0x%llx insn=0x%08x addr=0x%llx\n",
                (unsigned long long)pc, insn, (unsigned long long)addr);
        watch_log_mapping("pc", (addr_t)pc);
        watch_log_mapping("idx", addr);
    }
#endif
    void *ptr = __tlb_write_ptr(tlb, addr);
    if (ptr == NULL) {
        return -1;
    }
    *(uint32_t *)ptr = value;
    return 0;
}

__no_instrument int c_store16(struct tlb *tlb, addr_t addr, uint16_t value) {
#if defined(GUEST_ARM64) && defined(WATCH_ADDR)
    if (WATCH_MATCH_ANY(addr)) {
        uint64_t pc = current ? current->cpu.pc : 0;
        fprintf(stderr, "[WATCH] store16 pc=0x%llx addr=0x%llx value=0x%x (hit=%d)\n",
                (unsigned long long)pc, (unsigned long long)addr,
                value, ++watch_store_hits);
    }
#endif
    void *ptr = __tlb_write_ptr(tlb, addr);
    if (ptr == NULL) {
        return -1;
    }
    *(uint16_t *)ptr = value;
    return 0;
}

__no_instrument int c_store8(struct tlb *tlb, addr_t addr, uint8_t value) {
#if defined(GUEST_ARM64) && defined(WATCH_ADDR)
    if (WATCH_MATCH_ANY(addr)) {
        uint64_t pc = current ? current->cpu.pc : 0;
        fprintf(stderr, "[WATCH] store8 pc=0x%llx addr=0x%llx value=0x%x (hit=%d)\n",
                (unsigned long long)pc, (unsigned long long)addr,
                value, ++watch_store_hits);
    }
#endif
    void *ptr = __tlb_write_ptr(tlb, addr);
    if (ptr == NULL) {
        return -1;
    }
    *(uint8_t *)ptr = value;
    return 0;
}

// Atomic memory operations (LSE): LDADD/LDCLR/LDEOR/LDSET/LDSMAX/LDSMIN/LDUMAX/LDUMIN/SWP
// Return: 0 on success, -1 on segfault or unsupported op
__no_instrument int c_atomic_rmw(struct tlb *tlb, addr_t addr, uint64_t value,
                                 uint32_t size, uint32_t op, uint64_t *old_out) {
    if (old_out == NULL)
        return -1;

    switch (size) {
        case 0: { // 8-bit
            uint8_t old;
            if (c_load8(tlb, addr, &old) < 0)
                return -1;
            uint8_t val = (uint8_t)value;
            uint8_t newv;
            switch (op) {
                case 0: newv = (uint8_t)(old + val); break;                    // LDADD
                case 1: newv = (uint8_t)(old & (uint8_t)~val); break;           // LDCLR
                case 2: newv = (uint8_t)(old ^ val); break;                     // LDEOR
                case 3: newv = (uint8_t)(old | val); break;                     // LDSET
                case 4: newv = ((int8_t)old > (int8_t)val) ? old : val; break;   // LDSMAX
                case 5: newv = ((int8_t)old < (int8_t)val) ? old : val; break;   // LDSMIN
                case 6: newv = (old > val) ? old : val; break;                  // LDUMAX
                case 7: newv = (old < val) ? old : val; break;                  // LDUMIN
                case 8: newv = val; break;                                      // SWP
                default: return -1;
            }
            if (c_store8(tlb, addr, newv) < 0)
                return -1;
            *old_out = old;
            return 0;
        }
        case 1: { // 16-bit
            uint16_t old;
            if (c_load16(tlb, addr, &old) < 0)
                return -1;
            uint16_t val = (uint16_t)value;
            uint16_t newv;
            switch (op) {
                case 0: newv = (uint16_t)(old + val); break;
                case 1: newv = (uint16_t)(old & (uint16_t)~val); break;
                case 2: newv = (uint16_t)(old ^ val); break;
                case 3: newv = (uint16_t)(old | val); break;
                case 4: newv = ((int16_t)old > (int16_t)val) ? old : val; break;
                case 5: newv = ((int16_t)old < (int16_t)val) ? old : val; break;
                case 6: newv = (old > val) ? old : val; break;
                case 7: newv = (old < val) ? old : val; break;
                case 8: newv = val; break;
                default: return -1;
            }
            if (c_store16(tlb, addr, newv) < 0)
                return -1;
            *old_out = old;
            return 0;
        }
        case 2: { // 32-bit
            uint32_t old;
            if (c_load32(tlb, addr, &old) < 0)
                return -1;
            uint32_t val = (uint32_t)value;
            uint32_t newv;
            switch (op) {
                case 0: newv = old + val; break;
                case 1: newv = old & ~val; break;
                case 2: newv = old ^ val; break;
                case 3: newv = old | val; break;
                case 4: newv = ((int32_t)old > (int32_t)val) ? old : val; break;
                case 5: newv = ((int32_t)old < (int32_t)val) ? old : val; break;
                case 6: newv = (old > val) ? old : val; break;
                case 7: newv = (old < val) ? old : val; break;
                case 8: newv = val; break;
                default: return -1;
            }
            if (c_store32(tlb, addr, newv) < 0)
                return -1;
            *old_out = old;
            return 0;
        }
        case 3: { // 64-bit
            uint64_t old;
            if (c_load64(tlb, addr, &old) < 0)
                return -1;
            uint64_t val = value;
            uint64_t newv;
            switch (op) {
                case 0: newv = old + val; break;
                case 1: newv = old & ~val; break;
                case 2: newv = old ^ val; break;
                case 3: newv = old | val; break;
                case 4: newv = ((int64_t)old > (int64_t)val) ? old : val; break;
                case 5: newv = ((int64_t)old < (int64_t)val) ? old : val; break;
                case 6: newv = (old > val) ? old : val; break;
                case 7: newv = (old < val) ? old : val; break;
                case 8: newv = val; break;
                default: return -1;
            }
            if (c_store64(tlb, addr, newv) < 0)
                return -1;
            *old_out = old;
            return 0;
        }
        default:
            return -1;
    }
}

// Atomic compare-and-swap (CAS/CASA/CASL/CASAL)
// Return: 0 on success, -1 on segfault or unsupported size
__no_instrument int c_atomic_cas(struct tlb *tlb, addr_t addr, uint64_t expected,
                                 uint64_t desired, uint32_t size, uint64_t *old_out) {
    if (old_out == NULL)
        return -1;

    switch (size) {
        case 0: { // 8-bit
            uint8_t old;
            if (c_load8(tlb, addr, &old) < 0)
                return -1;
            *old_out = old;
            if (old == (uint8_t)expected) {
                if (c_store8(tlb, addr, (uint8_t)desired) < 0)
                    return -1;
            }
            return 0;
        }
        case 1: { // 16-bit
            uint16_t old;
            if (c_load16(tlb, addr, &old) < 0)
                return -1;
            *old_out = old;
            if (old == (uint16_t)expected) {
                if (c_store16(tlb, addr, (uint16_t)desired) < 0)
                    return -1;
            }
            return 0;
        }
        case 2: { // 32-bit
            uint32_t old;
            if (c_load32(tlb, addr, &old) < 0)
                return -1;
            *old_out = old;
            if (old == (uint32_t)expected) {
                if (c_store32(tlb, addr, (uint32_t)desired) < 0)
                    return -1;
            }
            return 0;
        }
        case 3: { // 64-bit
            uint64_t old;
            if (c_load64(tlb, addr, &old) < 0)
                return -1;
            *old_out = old;
            if (old == expected) {
                if (c_store64(tlb, addr, desired) < 0)
                    return -1;
            }
            return 0;
        }
        default:
            return -1;
    }
}

// LDP/STP helper functions for pair loads/stores
// Return: 0 on success, -1 on segfault
__no_instrument int c_ldp64(struct tlb *tlb, addr_t addr, uint64_t *val1, uint64_t *val2) {
    void *ptr1 = __tlb_read_ptr(tlb, addr);
    if (ptr1 == NULL) {
        return -1;
    }
    void *ptr2 = __tlb_read_ptr(tlb, addr + 8);
    if (ptr2 == NULL) {
        return -1;
    }
    *val1 = *(uint64_t *)ptr1;
    *val2 = *(uint64_t *)ptr2;
    return 0;
}

__no_instrument int c_ldp32(struct tlb *tlb, addr_t addr, uint32_t *val1, uint32_t *val2) {
    void *ptr1 = __tlb_read_ptr(tlb, addr);
    if (ptr1 == NULL) {
        return -1;
    }
    void *ptr2 = __tlb_read_ptr(tlb, addr + 4);
    if (ptr2 == NULL) {
        return -1;
    }
    *val1 = *(uint32_t *)ptr1;
    *val2 = *(uint32_t *)ptr2;
    return 0;
}

__no_instrument int c_stp64(struct tlb *tlb, addr_t addr, uint64_t val1, uint64_t val2) {
#if defined(GUEST_ARM64) && defined(WATCH_ADDR)
    if (WATCH_MATCH_ANY(addr) || WATCH_MATCH_ANY(addr + 8)) {
        uint64_t pc = current ? current->cpu.pc : 0;
        uint32_t insn = 0;
        if (pc != 0) {
            void *iptr = __tlb_read_ptr(tlb, (addr_t)pc);
            if (iptr != NULL)
                insn = *(uint32_t *)iptr;
        }
        fprintf(stderr, "[WATCH] stp64 pc=0x%llx insn=0x%08x addr=0x%llx val1=0x%llx val2=0x%llx (hit=%d)\n",
                (unsigned long long)pc, insn, (unsigned long long)addr,
                (unsigned long long)val1, (unsigned long long)val2, ++watch_store_hits);
    }
#endif
    // DEBUG: Check if storing the suspicious value 0xfffffffffffffff8
#if 0  // Disabled - too noisy
    if (val1 == 0xfffffffffffffff8ULL || val2 == 0xfffffffffffffff8ULL) {
        fprintf(stderr, "[STP64 SUSPICIOUS] addr=0x%x val1=0x%llx val2=0x%llx\n",
                addr, (unsigned long long)val1, (unsigned long long)val2);
    }
#endif
    void *ptr1 = __tlb_write_ptr(tlb, addr);
    if (ptr1 == NULL) {
        return -1;
    }
    void *ptr2 = __tlb_write_ptr(tlb, addr + 8);
    if (ptr2 == NULL) {
        return -1;
    }
    *(uint64_t *)ptr1 = val1;
    *(uint64_t *)ptr2 = val2;
    return 0;
}

__no_instrument int c_stp32(struct tlb *tlb, addr_t addr, uint32_t val1, uint32_t val2) {
#if defined(GUEST_ARM64) && defined(WATCH_ADDR)
    if (WATCH_MATCH_ANY(addr) || WATCH_MATCH_ANY(addr + 4)) {
        uint64_t pc = current ? current->cpu.pc : 0;
        uint32_t insn = 0;
        if (pc != 0) {
            void *iptr = __tlb_read_ptr(tlb, (addr_t)pc);
            if (iptr != NULL)
                insn = *(uint32_t *)iptr;
        }
        fprintf(stderr, "[WATCH] stp32 pc=0x%llx insn=0x%08x addr=0x%llx val1=0x%x val2=0x%x (hit=%d)\n",
                (unsigned long long)pc, insn, (unsigned long long)addr,
                val1, val2, ++watch_store_hits);
    }
#endif
    void *ptr1 = __tlb_write_ptr(tlb, addr);
    if (ptr1 == NULL) {
        return -1;
    }
    void *ptr2 = __tlb_write_ptr(tlb, addr + 4);
    if (ptr2 == NULL) {
        return -1;
    }
    *(uint32_t *)ptr1 = val1;
    *(uint32_t *)ptr2 = val2;
    return 0;
}
#endif
