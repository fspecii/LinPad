// Translation dispatch table.
//
// Flat array indexed by (guest_pc - V8_BASE) / 4. One entry per guest
// instruction in the V8 codespace; entries are pointers to translated
// native code (or NULL when no translation exists yet).
//
// Allocated lazily on first access. Sparse: virtual reservation is ~96 MiB,
// real residency is paged in on touch (only ~30 MiB for the hot footprint).
//
// Reads (from chained translated code via `ldr x17, [x28, idx, lsl #3]`)
// use relaxed loads — a transient NULL between translation completion and
// memory ordering on the writer side just causes a fallback to dispatch
// loop, which is safe and self-healing on the next pass.

#ifndef TRACEJIT_DISPATCH_H
#define TRACEJIT_DISPATCH_H

#include <stdbool.h>
#include <stdint.h>

// V8 codespace bounds. Default values; runtime env override (ISH_TRACEJIT_RANGE)
// can adjust at process start before any table access.
#define TRACEJIT_V8_BASE_DEFAULT   0xed1dd000ULL
#define TRACEJIT_V8_LIMIT_DEFAULT  0xeff08000ULL

// Configure (or reconfigure) the codespace range. Must be called before
// the first dispatch-table allocation. Idempotent if same args.
void tracejit_set_range(uint64_t base, uint64_t limit);

// Reads the current effective range. Both must be called at runtime;
// these are not compile-time constants because env override may change
// them at process start.
uint64_t tracejit_range_base(void);
uint64_t tracejit_range_limit(void);

// Returns the dispatch table base. Allocates on first call.
void **tracejit_dispatch_table(void);

static inline bool tracejit_pc_in_table(uint64_t pc) {
    return pc >= tracejit_range_base() && pc < tracejit_range_limit();
}

static inline uint64_t tracejit_pc_to_idx(uint64_t pc) {
    return (pc - tracejit_range_base()) >> 2;
}

// Publish a translation: store fn at table[idx_for(pc)] with release semantics.
// Idempotent — duplicate writes of equivalent code are harmless.
void tracejit_table_publish(uint64_t pc, void *fn);

// Read for diagnostics; not on the hot path (chained code reads inline via x28).
void *tracejit_table_lookup(uint64_t pc);

#endif
