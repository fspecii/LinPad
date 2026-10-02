# Native AArch64 JIT for iSH-ARM64

Status: prototype, behind `-Djit=enabled` (default disabled) and `ISH_JIT=1` at
runtime. Files: `jit/jit.h` (interface), `jit/jit_internal.h` (structures,
register map), `jit/translate.c` (translator), `jit/jit.c` (runtime),
`jit/codemem.c` (executable memory), `jit/emit.h` (encoders). Hooks: a few
`#ifdef ISH_JIT` lines in `asbestos/asbestos.{c,h}`, `meson.build`,
`meson_options.txt`. Nothing in `kernel/` changed.

Guest and host are both AArch64, so a guest basic block is translated by
copying most instructions with their register fields renamed, and rewriting
only what touches guest memory, guest control flow, or system state. The
gadget engine ("asbestos") stays the fallback: it runs when the JIT is off,
when no executable memory can be obtained, and for single instructions the
translator doesn't handle.

## 1. Guest memory: software TLB, inline or via shared stubs (decided)

Two forms. By default every block inlines the lookup below. The compact
form (`ISH_JIT_COMPACT=1`, section 12) calls a shared per-chunk stub for
accesses of 1/2/4/8/16/32 bytes instead:
`[mov x12, Xbase] ; str x30, [ctx, x30 slot] ; bl stub[size][write][atomic][x12|x15] ; ldr x30, [ctx, x30 slot] ; ldr Xt, [x13, x12]`.
The stub does the lookup and `ret`s with the addend in x13; a miss calls the
helper, which finds the faulting guest instruction through the saved return
address. The inline lookup:

```
  add   x12, <base>, #off           ; guest address (skipped when off == 0)
  eor   x13, A, A, lsr #13          ; TLB index = ((A>>12) ^ (A>>25)) & 8191
  ubfx  x13, x13, #12, #13
  add   x13, x11, x13, lsl #5       ; &ctx->tlbe[index]
  ldr   x14, [x13, #0x800 (+8 for writes)]   ; tag = guest page if readable/writable
  sub   x14, A, x14                 ; offset into the page, huge if other page
  add   x14, x14, #size-1           ; page-crossing check
  lsr   x14, x14, #12
  cbnz  x14, slow                   ; miss / crossing / no permission
  ldr   x13, [x13, #0x810]          ; addend = host - guest
  ldr   Xt, [x13, A]                ; the original access, renamed
```

A page-crossing store goes into a bounce buffer. The inline slow path writes
it back right after the store (`JH_COMMIT`). A stub can't, so for a store
from a stub the helper empties the thread's TLB: the next access of any kind
misses and commits first, and the dispatcher also commits on every exit.
(An earlier round-2 build emptied the TLB for inline stores too: 4x the TLB
misses and 12% slower on tsc.) Inline loads take a compact slow path that
returns the addend and re-runs the access.

The TLB is private to the JIT (in the per-thread context, 8192 entries x 32
bytes), filled by `jtlb_fill` through `mmu->ops->translate` with exactly the
gadget TLB's rules (speculative write permission on read miss, flush on
`mmu->changes`). The slow path calls a C helper that fills the entry and
returns the host pointer; page-crossing accesses go through a 128-byte bounce
buffer (loads are copied in; stores are written out after the instruction by a
second helper). Faults return `INT_GPF` with the exact faulting PC and
untouched register state.

**Why not a fixed-offset window** (guest + base = host, page protections
mirroring the guest, SIGSEGV for misses), which would make accesses 1:1:

* Host pages are 16 KB on every Apple CPU, guest pages are 4 KB. The guest
  needs 4 KB `mprotect`, 4 KB `MAP_FIXED` file mappings and 4 KB CoW. The host
  cannot express any of that, and the iSH page table maps each guest page to an
  arbitrary host allocation (`struct data` + offset), not to one contiguous
  region.
* The guest address space is 48 bits and iSH puts V8/JSC cages above 4 GB.
  Largest `PROT_NONE` reservation measured on this Mac: 2^46 bytes (64 TB), so a
  full 48-bit window doesn't fit even on macOS. On iOS without
  `com.apple.developer.kernel.extended-virtual-addressing` the limit is far
  lower (a few to tens of GB, depending on device RAM; not measurable in the
  simulator), so a window could cover only the low 4 GB.
* It would be a rewrite of `kernel/memory.c`, which other agents are editing.

A window becomes possible later if the guest kernel reports 16 KB pages
(`AT_PAGESZ` = 16384; aarch64 Linux userland supports it, Asahi runs that way)
and `kernel/memory.c` maps guest pages as host mappings. Expected gain over the
soft TLB: about 1.3-1.5x on memory-heavy code. Not needed for the 3x goal.

## 2. Register allocation (decided)

| guest | host | notes |
|---|---|---|
| x0-x10, x16, x17, x19-x30 | same number | identity: those fields are copied unchanged |
| SP | x15 | guest SP is a normal host register, the host SP stays the C stack (signal frames, helper calls) |
| x11-x15, x18 | `ctx->cpu.regs[]` | "spilled": moved through scratch registers around each use |
| - | x11 | `struct jit_ctx *` (cpu state, TLB, exit flag, indirect table) |
| - | x12, x13, x14 | scratch (T0-T2: address, TLB entry/host pointer, compare) |
| - | x18 | never touched (Darwin platform register) |

The compact form's `bl` to a TLB stub needs host x30, so it parks guest x30
in its `ctx` slot around the call (the helper then knows x30 is in `ctx`).
A round-2 experiment moved guest x30 into host x17 and spilled guest x17
instead. That cost about 9% on V8 code, which uses x16/x17 as scratch in
nearly every macro instruction, so it was reverted.

The spilled set was chosen from static register counts over node (GCC),
ld-musl/busybox and libxul (clang): x11-x15 and x18 are the least used across
both compilers (x18: 0.02-0.14 % of instructions, x13-x15: 0.1-0.6 %), while
x16/x17 stay in registers because V8/SpiderMonkey/JSC generated code uses them
as scratch in nearly every macro instruction. The map is one table
(`jit_g2h`), so it can be retuned from dynamic profiles.

Field renaming is table-driven per instruction class (`struct opnd`: field
position, read/write, whether 31 means SP or ZR). When a memory instruction
needs more scratch registers than are free (e.g. `stxp w12, x13, x14`), it
borrows home registers the instruction doesn't use, parks their guest values in
`ctx`, and records a borrow mask in the block's fault map so the fault handler
reads those values from `ctx`, not from the registers.

**Flags**: guest NZCV is host NZCV. All inserted code is flag-free (`cbnz`,
`eor`, `sub` without S), so `cmp; <load>; b.cond` works unchanged.

**SIMD/FP**: guest V0-V31 are host V0-V31 for the whole time the JIT runs
(saved/restored only at dispatcher entry/exit and around C helper calls).
FPCR: the guest's AHP/DN/FZ/RMode/FZ16 bits are loaded on entry and the host's
restored on exit (the same mask as the gadget engine). FPSR is native too.
Almost the whole AdvSIMD/FP space is copied verbatim; only FMOV/SCVTF/FCVT*
general-register forms and DUP/INS/SMOV/UMOV (general) get GPR renaming.

## 3. Instruction handling

* **Copied (renamed)**: all integer data processing (immediate and register,
  incl. CCMP/CSEL/MADD/UMULH/CRC32), all AdvSIMD/FP data processing, barriers
  (DMB/DSB/ISB/SB/CLREX), MRS/MSR NZCV, MRS/MSR FPSR, MRS FPCR,
  MRS CNTVCT/CNTFRQ.
* **Rewritten**: every load/store (single, pair, literal, register offset,
  pre/post index, exclusives, LDAR/STLR/LDAPR, LSE atomics and SWP, CAS,
  AdvSIMD LD1-4/ST1-4 multiple/single/replicate); ADR/ADRP become constants;
  MRS/MSR TPIDR_EL0 become ctx loads/stores; MRS CTR_EL0/DCZID_EL0 become the
  gadget engine's constants (DC ZVA stays prohibited); PRFM, DC CVAU/CVAC/CIVAC/CVAP and
  all HINT-space instructions (NOP, YIELD, BTI, PAC hints) become nothing.
* **Branches**: B/BL/B.cond/CBZ/TBZ end the block with chainable exits;
  BR/BLR/RET use an inline lookup in a per-mm indirect-branch table; SVC exits
  with `INT_SYSCALL` and PC = next; IC IVAU exits and invalidates that page.
* **Fallback**: anything else (MSR FPCR/DAIF, other MRS, BRK, UDF, CASP with
  non-identity register pairs, SVE, DC ZVA, PAC loads/branches, MTE, RCPC2,
  unallocated encodings in the integer/system space) ends the block; the
  dispatcher runs exactly one instruction through the gadget engine (a cached
  one-instruction fiber block) and continues in the JIT. Unallocated
  AdvSIMD/FP encodings are copied; if the host raises SIGILL, the fault
  handler converts it to the guest's `INT_UNDEFINED` at the exact PC.

Exclusives must never be split between the engines (the gadget engine
emulates the monitor with `excl_addr`/CAS, the JIT uses the host monitor), so
every LDXR/STXR/LDXP/STXP form is native. CASP is a plain CAS in the gadget
engine and has no monitor state, so it is safe to fall back.

## 4. Atomics and exclusive monitors

LDXR/STXR/LDAXR/STLXR/LDXP/STXP and the LSE ops execute natively on the host
address. The TLB lookup between them only loads, so the host monitor stays
armed; a TLB miss or a dispatcher round trip clears it, the STXR fails and the
guest's retry loop runs again with the TLB warm and the block chained. Before
each exclusive/atomic/acquire-release access the JIT compares
`ctx->mem_changes` with `mmu->changes` (5 instructions) and flushes the TLB if
another thread changed the page tables (CoW after fork, munmap), so a lock
acquired after a CoW never reads through a stale entry. Validated with
`tests/arm64-insn/mem.c` (CAS/CASP/LDXP/STXP, 4-thread 128-bit contention).

## 5. Self-modifying code and guest JITs

The JIT follows the gadget engine's rules, which are the architectural ones:

* `IC IVAU` exits to the dispatcher and invalidates every block on that page
  (V8, JSC, SpiderMonkey and sljit all issue it after writing code).
* Write misses (`mem_ptr(MEM_WRITE)`), munmap/mmap and exec go through
  `asbestos_invalidate_*`, which also calls `jit_invalidate_range`.
* An invalidated block's first instruction is patched to a "redispatch" stub,
  every chained branch into it is reset to the dispatcher (incoming slots are
  tracked per block), and it leaves the lookup structures. Memory is not freed
  until the whole cache of that mm is retired (section 8).

Blocks never span a guest page, so per-page invalidation is exact.
`tests/arm64-insn/smc.c` and `pcre_jit_reuse.c` (sljit reusing RWX memory),
the difffuzz harness (which JITs 900k instructions through RWX memory + IC
IVAU) and node/V8 all pass.

## 6. Signals and precise state

* Synchronous guest faults come from the slow-path helper, before the
  instruction has any side effect: exact PC, exact registers.
* Host SIGSEGV/SIGBUS/SIGILL inside translated code (stale TLB entry after
  another thread's munmap, unaligned exclusive, unallocated SIMD encoding): the
  JIT's handler finds the block (per-chunk sorted block list), maps the host PC
  to the guest instruction (per-block map, also carries the borrow mask),
  copies all registers, V registers, NZCV and FPSR from the ucontext into the
  guest state, and redirects the thread to the exit trampoline. SEGV/BUS are
  retried with a flushed TLB (3 times, then `INT_GPF`); ILL becomes
  `INT_UNDEFINED`. Faults outside JIT code go to the previously installed
  handler (main.c's crash handler).
* Asynchronous delivery: while the JIT runs, `cpu->poked_ptr` points at
  `ctx->exitflag`, so `cpu_poke()` sets it directly. Backward direct branches
  and all indirect branches test it (`ldrb; cbnz`, 2 instructions). A ticker
  thread sets it every 500 us for all threads inside the JIT, which replaces
  the gadget engine's 8K-transition countdown (threads must periodically drop
  `mem->lock` so `mmap` in another thread can take it for writing). Every exit
  returns to `handle_interrupt` with a consistent `cpu_state`, so signal frames
  are built exactly as before.

## 7. Block chaining and indirect branches

Direct exits end in a patch slot (`nop`, then materialize the target PC and
branch to the exit trampoline). When the dispatcher sees the target block, it
patches the slot to `b target` (a single aligned 32-bit store, which the
architecture allows to be concurrently modified and executed). Backward exits
check the exit flag before the slot. Indirect branches look up a 64K-entry
per-mm table (`{guest pc, host code}` written with one 16-byte `stp`, read
with `ldp`); misses go to the dispatcher, which fills it. The dispatcher has a
per-thread 4K-entry lookup cache in front of the per-mm hash.

## 8. Code cache

One arena per process (`codemem.c`; 512 MB of address space on macOS, 128 MB
on iOS, `ISH_JIT_CACHE_MB`), split into 2 MB chunks owned by address spaces.
Each chunk starts with its own copy of the trampolines (enter, exit, helper
call), so every exit branch is in range.

**Chains must never exit.** An LDXR/STXR loop that spans blocks livelocks if
a block transition goes through the dispatcher (the exit clears the monitor).
So:
* An mm takes its chunks within +-30 chunks (+-60 MB) of its first one (the
  anchor), where a plain `b` reaches everything.
* When other address spaces have filled that window, it takes any free
  chunk, and chains to far chunks go through a veneer
  (`ldr x13, #8; br x13; .quad target`) from the last 64 KB of the slot's
  chunk.
* When a chunk's veneers run out, the exit's final `b exit_chain` is patched to
  the chunk's `far_chain` trampoline. That trampoline looks the target up in the
  indirect table inside JIT code, and exits only on a miss.
  (`ISH_JIT_FORCE_VENEER=2` forces this path for testing.)

The window used to be strict: a full window made the mm retire its own
chunks over and over. Firefox, whose processes share the arena, took 70 s
instead of 6 s.

An mm may own three quarters of the arena. Past that, it retires its own
oldest chunk. When the arena is full, the oldest chunk of the address space
that ran least recently (`mm->last_active`) is retired instead, so idle
processes give up their code first. With per-mm FIFO, Firefox in a 128 MB
cache retranslated about 1.5 GB per session; it scrolled at 1 fps and typing
took 1-3 s. With this policy it scrolls at 50 fps and typing takes 40 ms.
A retired chunk:
* its blocks are invalidated like modified code;
* chain slots inside it are dropped from the incoming lists of the blocks
  that stay;
* it is freed once every thread of that mm has passed through the dispatcher
  since. That is an epoch check against the per-thread `ctx->epoch`, and the
  ticker guarantees it within about 0.5 ms.

Chunks of an exited or exec'd mm are freed at once.

Code size is about 10 host words per guest instruction (6 in the hot path):
each memory access has an 11-instruction inline lookup and an out-of-line
slow path (4 words for loads since round 2, 6-10 for stores). The compact
form (section 12) is about 5. Helper calls are `adr x14, lit; b helper; .word lit`
(one literal word: helper kind, access size/flags, guest instruction index),
so they don't touch x30 and need no per-site PC constant.

Invalidation is cheap when nothing is translated on the page: a per-bucket
page tag makes the lock-free check exact, single-step blocks have their own
64-bit page filter, and page writes during `mem_destroy` (refcount 0) are
ignored. Patched words are cache-maintained in batches (one `dsb` per batch).

## 9. Thread safety

Per-mm mutex for the hash, page index, chaining and patching. Translation
reads guest code without the lock (it can fault into `mem_ptr`, which takes
`mem->lock` for writing), then inserts under the lock and retries if the mm's
invalidation generation moved meanwhile. Code writes use the RW view
(dual-mapping) or `pthread_jit_write_protect_np` (MAP_JIT, per thread), plus
`sys_icache_invalidate`.

## 10. Executable memory on iOS (TXM) and macOS

* **macOS CLI**: by default the iOS scheme, an RX view plus an RW alias made
  with `vm_remap` (works for unhardened binaries, needs no W^X toggling and
  was measured ~10% faster on node startup). `ISH_JIT_MAPJIT=1` uses one
  `MAP_JIT` mapping and `pthread_jit_write_protect_np` instead; that is also
  the fallback if the alias can't be made.
* **iOS 26+/27 with TXM** (iPad Air M3 on 27.2): the process can't make pages
  executable itself; only pages the debugger has written become executable.
  We use StikDebug's `universal.js` protocol (StikDebug 3.1.13; source
  `StikDebug/Scripts/universal.js`):
  1. StikDebug attaches with `universal.js` (assign it to the app's bundle ID
     once in StikDebug, or open
     `stikdebug://enable-jit?bundle-id=<id>&script-name=universal.js`).
  2. The app checks `P_TRACED` (sysctl `KERN_PROC_PID`); never issue the
     `brk` untraced (it would be a fatal SIGTRAP).
  3. `jit26_prepare_region(NULL, size)`: `mov x16, #1; brk #0xf00d`, x1 = size.
     The script sends `_M<size>,rx` (debugserver allocates RX memory in our
     process), writes one byte per 16 KB page (`M<addr>,1:69`), and returns
     the address in x0.
  4. Validate: non-null, 16 KB aligned, not `0xE0000069` (error), below
     64 GB (StikDebug encodes 9 hex digits).
  5. `vm_remap` an RW alias of it (`mach_vm.h` is unavailable in the iOS
     SDK), `mprotect(PROT_READ|PROT_WRITE)`.
  6. `jit26_detach()` (`x16 = 0`), so later signals don't round-trip through
     the debugger.
  UTM's own path (`brk #0x69` with x0/x1 = region, in `qemu/tcg/region.c`) is
  only served by StikDebug's `legacy.js`, which StikDebug auto-assigns by app
  name ("UTM"); `universal.js` answers it with an error. So we use the
  universal protocol, which needs no name matching and allows later requests.
  One region is requested up front (default 128 MB, `ISH_JIT_CACHE_MB`);
  each request costs one debugger stop plus one packet per 16 KB page.
* **Pre-TXM devices with `CS_DEBUGGED`**: mmap RW, remap, mprotect RX.
* **Simulator**: dual mapping (the simulator is a macOS process). Tested in a
  private simulator with the CLI built for `arm64-apple-ios-simulator` and run
  with `simctl spawn`.
* If none of this works, `jit_enabled()` returns false and the gadget engine
  runs unchanged.
* Selection: `ISH_JIT=1` forces the JIT, `ISH_JIT=0` disables it. Unset, it is
  off everywhere except on an iOS device with a debugger attached (`P_TRACED`).

The app side (Xcode target) still needs: build with `-DISH_JIT=1` + the three
`jit/*.c` files, set `ISH_JIT=1` (or flip the default) when the debugger is
attached, and a UI hint telling the user to enable JIT in StikDebug. See
`/Volumes/ExternalHD/Dev/ipad-jit/jit-report.md` for the device test plan.

## 12. Compact code and tiering (round 2, off by default)

With `ISH_JIT_COMPACT=1`, blocks from read-only file mappings start compact
(tier 1: stub calls, section 1) with a 32-bit execution countdown
(`mm->counters`, address in a block literal):
`ldr x12, =cnt; ldr w13, [x12]; sub w13, w13, #1; str w13, [x12]; cbz w13, promote`.
After 128 entries (`ISH_JIT_PROMOTE`) the block exits with `JR_PROMOTE`; the
dispatcher retranslates it with inline lookups and no counter (tier 2), and
the new block replaces the old one (invalidated, chains redone). Code from
anonymous or writable memory (V8/SpiderMonkey output, CoW'd code) always
starts at tier 2.

Compact code is 4.9 host words per guest instruction against about 7 inline.
It is off by default because it costs speed and saves little memory in
practice:
* **tsc, interleaved A/B (CPU):** 6.23 s compact vs 5.89 s inline, and 6.53 s
  if nothing is promoted. That is about 20M tier-1 block runs (128 each for
  ~160K blocks) paying the counter and the stub branches, plus 64K
  promotions.
* **Code size:** tsc's main process ends at 61 MB of code either way, because
  the hot code is promoted anyway.

What stays from this work by default: the compact load slow path (inline
loads re-run after the helper returns the addend), out-of-line exits, and the
position-independent block layout that the persistent cache needs.

## 13. Persistent translation cache (round 2, `jit/pcache.c`)

Translations are position independent: guest PCs come from a per-block
literal, and trampoline/stub branches are relocation records. So images of
code from read-only file mappings (inline lookups by default, compact with
`ISH_JIT_COMPACT=1`) are written to
`$HOME/Library/Caches/ish-jit/` (`ISH_JIT_PCACHE_DIR`):
* `tcache.dat`: append-only records;
* `tcache.idx`: a 1M-slot index, `mmap`ed shared.

A record is keyed by the page offset and the first 16 guest words. It is used
only after an exact comparison of all the guest bytes it was translated
from, plus header/relocation bounds and a checksum, so a stale, foreign or
corrupt record is a miss, never wrong code.
* **Version:** the key salt includes the translator build stamp, the context
  layout and the compact setting. It is also stored in `tcache.salt`, and a
  salt change resets the files at startup (records of another salt can never
  hit).
* **Size:** capped at 128 MB (48 MB on iOS). Reset at startup when within
  4 MB of the cap, since appends stop there.
* **Writes:** buffered, flushed at 1 MB, about every second by the ticker,
  and when a process exits.

Hits skip decoding but still pay for installation (copy, relocation, icache
maintenance, block registration). Measured on `claude --help`: 0.69 → 0.49 s
CPU. On node startup it saves about 15% of translation time, which is
within noise of total node start (most of node start is executing V8's own
startup).

## 14. Memory pressure (round 2)

The code arena is reserved up front, but chunks are handed out against a
budget:
* **iOS:** starts at 32 MB and grows in 16 MB steps while
  `os_proc_available_memory()` > 768 MB. The TXM region request itself is
  128 MB, or 64 MB when less than 3 GB is available.
* **`ish_jit_trim()`:** exported in `jit.h`, and also called by a
  `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` source. It drops the budget to the
  minimum, retires every address space's chunks except the newest, frees them
  once no thread is inside, and flushes the persistent cache.
* **Freed chunks:** `madvise(MADV_FREE_REUSABLE)`, except on TXM, where a
  discarded page would come back non-executable.
* **Testing on the Mac:** `ISH_JIT_BUDGET_MB` and `ISH_JIT_TRIM_EVERY_MS`.
  Firefox and tsc pass with a 32 MB budget and a trim every 200 ms.

## 11. Limits and next steps

* Exclusive sequences that contain an instruction the JIT hands to the gadget
  engine (e.g. an MRS between LDXR and STXR) would livelock; none were seen.
* FPSR cumulative flags are native while in the JIT, not modelled by the
  gadget engine.
* Next optimizations, by expected value: keep the TLB addend for runs of
  same-base accesses (stack frames) to skip repeated lookups; superblocks
  across forward conditional branches; a return-address stack for RET;
  translation-cache sharing for shared libraries across fork/exec; a direct
  16 KB-page memory window (section 1).
