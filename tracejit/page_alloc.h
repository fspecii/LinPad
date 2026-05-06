// Page-protect abstraction for the trace JIT.
//
// Goal: every page-allocation and W↔X toggle goes through this header so
// the macOS / iOS / Linux paths converge to a single seam. Future port to
// iOS replaces nothing in callers; only the .c implementation switches.
//
// macOS (current PoC target): MAP_JIT + pthread_jit_write_protect_np.
// iOS ship: same APIs, requires com.apple.developer.cs.allow-jit entitlement.
// Linux/Android: PROT_RWX (no W^X enforcement); toggle is a no-op.

#ifndef TRACEJIT_PAGE_ALLOC_H
#define TRACEJIT_PAGE_ALLOC_H

#include <stddef.h>
#include <stdbool.h>

// Allocate a contiguous RX-capable region of at least `size` bytes.
// Returned region is initially executable (W^X: not writable).
// Caller must use jit_page_writable_begin/end to mutate.
// Returns NULL on failure.
void *jit_page_alloc(size_t size);

// Free a region previously returned by jit_page_alloc.
void jit_page_free(void *p, size_t size);

// Begin a writable window on the calling thread. After this returns, the
// thread may freely write into any region returned by jit_page_alloc.
// Pair with jit_page_writable_end before executing emitted code.
void jit_page_writable_begin(void);

// End the writable window and re-enable execution. After this returns,
// pages are non-writable for this thread; emitted code may be called.
// Caller is responsible for icache invalidation via jit_icache_flush.
void jit_page_writable_end(void);

// Invalidate the i-cache for `size` bytes starting at `addr`. Required
// after any code emission before that code is executed.
void jit_icache_flush(void *addr, size_t size);

// Self-test: alloc a page, emit `mov w0,#imm; ret`, call it, free.
// Returns true if the toggle + execute round-trip works. Used at ish
// startup to fail fast if codesigning blocks MAP_JIT.
bool jit_page_alloc_self_test(int imm);

// Host page size. On Apple Silicon this is 16K, not 4K — affects
// translation budget calculations.
size_t jit_page_size(void);

#endif
