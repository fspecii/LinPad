# asbestos (ARM64 guest) performance notes

How guest code runs, where the time went, and what was changed (2026-10-02).
Benchmarks: `tests/perf/bench.py` (CPU time of the `ish` process tree, median of
5 interleaved runs, A/B against a saved baseline binary). Results are in
`/Volumes/ExternalHD/Dev/ipad-jit/decoder-fixes.md`, section "Perf".

## Execution model (unchanged)

Guest blocks are translated into threaded code: an array of gadget addresses
and parameters. Each gadget ends with `ldr x8, [_pc], #8; br x8`. Blocks end at
branches. Direct branches are *chained*: the main loop patches the branch slot
with the target block's code pointer, so later executions jump block to block
without leaving `fiber_enter`. `cpu_step_to_interrupt` (asbestos.c) is the
dispatch loop for everything that isn't chained. It looks up or translates the
block for `cpu->pc`, patches chains, enters the fiber, and handles interrupts.

## What profiling showed

`sample` on the CLI (`sample <ish pid> 10`):

* **sqlite**: only 28% of samples were guest code. The rest was
  `memmove(cpu_state)` and `handle_interrupt`/`receive_signals` mutexes, because
  the thread returned `INT_TIMER` on **every block transition**. That was
  201 million interrupts for one benchmark, against 2 actual `cpu_poke` calls.
* **tsc / firefox**: 78% guest code, 8% dispatch loop (hash-chain walks on
  block-cache misses), 4% lock waits on `asbestos->lock` (translation ran while
  holding it), and 3% translation.
* **gzip**: 25% of guest time in conditional-branch gadgets and the chaining
  tail (`inline_chain`).

## Changes

1. **Sticky poke (the big one).** `cpu_step_to_interrupt` copies the task's
   `cpu_state` into the fiber frame on entry and back on exit. The copy-back also
   wrote the frame's snapshot of `_poked`. So a poke the loop had already consumed
   was re-armed, and every later block transition exited with `INT_TIMER` and
   went through `handle_interrupt`. Any process that had ever been poked was
   affected: a shell after its first child (SIGCHLD), node after any signal, any
   process with a signal handler. Fix: `cpu_writeback()` copies everything up to
   `_poked` (the last field). This also stops it overwriting a poke that arrives
   while the thread runs. Also, `cpu->poked_ptr` now always points at the task's own flag.
   `task_create_` copies the parent task wholesale, so a child's pointer started out
   aimed at the parent.
2. **Indirect branches stay in the fiber.** BR, BLR and RET-cache misses used to
   always return to the dispatch loop. `indirect_chain` (control.S) looks the
   target up in the thread's `tlb->block_cache` (filled by the dispatch loop). It is
   valid only while `tlb->block_cache_gen == asbestos->invalidate_gen` and the page
   tables are unchanged, and the same poke/timer checks as `inline_chain` apply.
   On a hit it jumps straight to the block.
3. **Periodic exits release `mem->lock`.** Guest code runs with `mem->lock` held
   for reading (task.c). Fully chained code never left `cpu_run_to_interrupt`, so
   `mmap`/`munmap` in another thread waited. JSC fib went from 0.3 s to 3.7 s
   with change 2 alone. Now every `TIMER_PERIOD_MASK + 1` (8192) chained
   transitions, and every 8192 dispatch-loop iterations, the thread returns
   `INT_TIMER`. The chained countdown lives in host x29, which no gadget uses and
   C callees preserve, instead of a load/add/store of `cpu->cycle` per transition.
4. **Block hash.** `addr % size` with a power-of-two size used 1/4 of the buckets
   (code is 4-byte aligned). It is now a multiplicative hash, and the table grows at
   load factor 1.
5. **Translate outside `asbestos->lock`.** The loop looks up under the lock, drops
   it, translates, then re-locks. If another thread inserted the block first, the
   new one is discarded. If an invalidation happened meanwhile (generation
   changed), the block is translated again under the lock.
6. **CMP/SUBS Wn, Wm + B.cond fusion** (32-bit; 64-bit already existed): one
   gadget instead of two.
7. Generations are unique across all asbestos instances (round-3 crash fix; it
   also means stale caches are never reused across exec).

All changes keep guest semantics: the fuzzers, conformance tests, and stress and
regression runs pass, see decoder-fixes.md.

## Round 2 (2026-10-02)

8. **Chaining above 4 GB (the big one for JIT code).** When the dispatch loop
   patched a branch slot, it compared `(*slot & 0xffffffff) == block->addr`.
   Slots hold a fake_ip (bit 63 + 48-bit guest address), so branches to code
   above 4 GB were **never chained**. That covers V8's and JSC's JIT code heaps
   (for example 0x2fffcd43000) and libpas. Every branch in JIT-compiled JS went
   through the dispatch loop. The check is now `bit 63 set && low 48 bits ==
   addr`, which also no longer matches an already-patched host pointer.
   node_loop got about 3.5x faster and Firefox about 1.5x.
9. **Page-precise invalidation.** The 1024-bucket `page % N` index is replaced by
   an exact per-page table (`struct page_table` in asbestos.c, open addressing,
   lock-free reads for the fast path, retired arrays kept until asbestos_free).
   Writes to a data page no longer throw away code from unrelated pages.
   Large-range invalidations (munmap of V8's multi-GB reservations) walk the
   table once. Why node "depended on" over-invalidation: it was not correctness.
   With per-page filtering inside shared buckets, a munmap of N pages cost
   N x (bucket length) under the lock, and bucket-wide dropping had kept the
   buckets empty. A stale-code checker that hashed each block's guest bytes at
   every dispatch found no stale blocks in either variant.
10. **Post-indexed parameter loads.** In 489 gadgets, `ldr xN, [_pc]; add _pc, _pc, #8`
    became `ldr xN, [_pc], #8` (small gain).
11. **Histogram-driven fusions.** `ISH_PAIR_PROFILE=<file>` in a
    `-DISH_GADGET_PROFILE` build samples adjacent gadget pairs over a whole run.
    Over the bench suite the distribution is flat: the top pair is 1.5% of
    dispatches, and the top 50 sum to about 25%. Fused so far:
    * MOVZ/MOVN plus following MOVKs to the same register become one
      `set_reg_imm` with the constant folded at translation time;
    * two consecutive MOV Xd, Xm become `mov_reg_pair`.

    Coverage: `tests/arm64-insn/seq.c`.

### Register caching / multi-exit superblocks: not done, and why

After change 8, profiles of tsc, vite and node are 85-90% guest gadget
execution, spread thinly. Each gadget pays one indirect branch plus loads and
stores of guest registers in `cpu_state`. Register caching would remove some of
those memory operations, but it has costs:

* About 20 host registers would have to be reserved across all of the roughly
  400 gadgets. Today x19-x26 are used as scratch throughout math.S/memory.S, so
  every gadget would need auditing and rewriting.
* Every gadget that touches a guest register needs a variant per cached register,
  or gen.c must spill and reload around uncached gadgets. Both are large and
  risky against the bit-exact requirement.

Multi-exit superblocks (continuing translation after a conditional branch so
the not-taken path costs nothing) need more than 2 patchable exit slots per
block. That means changing `struct fiber_block`, the chaining code and every
conditional-branch gadget family. The measured upside is small: the bcond
not-taken tail is about 2-3% of samples.

Both remain the next steps for compute-bound code in the gadget engine. The
native JIT in jit/ is the real answer for compute.

## Tried and reverted

* **Per-page filtering in `asbestos_invalidate_range`** (round 1; superseded by change 9). `page_hash` has 1024
  buckets, and invalidating a page drops every block in its bucket, including
  blocks of unrelated pages. That is the "code-cache invalidation on every
  kernel→guest write" the syscall agent saw. Filtering by page made node startup
  4x *slower* and once made `claude --help` fail. So something depends on the
  over-invalidation, and the cause is not understood yet; V8 here uses a single RWX
  region, not a dual mapping. Left as is. Investigate before retrying, ideally
  with alias-aware (backing-page) invalidation in kernel/memory.c.
* **A 16K-entry second-level block cache in `fiber_frame`.** No measurable gain;
  its 128 KB memset on every invalidation hurt Firefox.

## Not done (candidates, rough order of value)

* Cross-process translation cache for shared-library code, keyed by file
  identity + offset and validated by page contents or mtime. fork/exec-heavy
  workloads retranslate libc, libnode and libxul in every process. Translation is
  about 3% of tsc and more of short-lived processes.
* Fusing more common pairs at translation time: ADRP+ADD, ADRP+LDR (64-bit
  exists), LDR+ADD, MOVZ+MOVK sequences into one constant, register-offset
  8/16-bit loads (`calc_addr_reg` + `load16_reg` is two gadgets today).
* `cpu_state` copy on every dispatch-loop entry and exit (about 1.2 KB of
  memmove). Cheap now that interrupts are rare again.
* The guest-code floor is about 20-30 host instructions per guest instruction:
  register file in memory, inline TLB lookup per access, one indirect branch per
  gadget. Going past about 1.3x on pure compute (gzip, sha256, the node loop)
  needs register caching across gadgets or superblocks with fewer dispatches,
  which is a bigger redesign.
