// Trace JIT for V8 jitless codespace.
//
// Shape A (per-block): on dispatch into the node binary range
// (0xed1dd000-0xeff08000 in current node 22.15.1 build), attempt to
// translate the guest block at `ip` into native ARM64. On success, cache
// the translation by guest PC and call it directly on subsequent
// dispatches instead of compiling/running the gadget threaded code.
//
// First milestone (this commit): translate blocks consisting of zero or
// more `movz wN, #imm16` instructions terminating in `ret x30`. Anything
// else returns NULL — caller falls back to gadget JIT.
//
// Gated by ISH_TRACEJIT=1. Default off.

#ifndef TRACEJIT_TRACEJIT_H
#define TRACEJIT_TRACEJIT_H

#include <stdbool.h>
#include <stdint.h>

struct fiber_frame;

// Returns 1 if trace-JIT is enabled (env). Cached after first call.
int tracejit_enabled(void);

// Returns true if `pc` falls inside a known V8/node-binary codespace
// range that's a candidate for translation.
bool tracejit_pc_in_codespace(uint64_t pc);

// Enter a chained translation run. Looks up cpu->pc in the dispatch
// table; if a translation exists, branches into it. Returns the
// interrupt number from the chain (INT_NONE on graceful exit, or any
// other value if the chain decided to bail to dispatch loop).
//
// Returns -1 (INT_NONE) immediately if no translation is available for
// frame->cpu.pc, signaling the caller to fall through to the gadget
// path.
int tracejit_enter(struct fiber_frame *frame);

// Try to translate the block starting at guest PC `ip`. On success,
// returns a callable `int (*)(struct fiber_frame *)` pointer; the caller
// invokes it and the function returns an interrupt number (INT_NONE on
// normal completion). On failure (unsupported pattern, alloc failure,
// etc.), returns NULL.
//
// Translations are cached by guest PC. Repeated calls with the same `ip`
// return the cached pointer.
typedef int (*tracejit_block_fn)(struct fiber_frame *frame);
tracejit_block_fn tracejit_translate(uint64_t ip);

// Stats dump (called from atexit / halt_system).
void tracejit_dump_stats(void);

// Bump the invocation counter (called once per successful tjfn() call).
void tracejit_count_invocation(void);

#endif
