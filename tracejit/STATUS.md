# tracejit — shipped status

State at e51c8b04 (code) + 70a51420 (design log). Closed out as PoC ship,
not a multi-week ABI rollout. See DESIGN_LOG for the step-3 postponement
record and the chaining-ABI reasoning.

## Scope shipped

ISA pattern recognized:
- `movz wRd, #imm16, lsl #0`  (32-bit, low-16 only)
- `add xRd, xRn, #imm12`       (sf=1, sh=0)
- terminator: `ret x30`        (only x30, not arbitrary xN)
- terminator: `b <imm26>`      (unconditional direct, with native chain
                                when target is also translated)

Anything else falls through to ish gadget threaded code transparently.

## Measured speedup

Hardware: MacBook M-series, macOS host, alpine-arm64-fakefs guest.
n=5 interleaved BASE/TJIT, ISH_TRACEJIT off vs on.

| workload                              | BASE user | TJIT user | ratio |
|---------------------------------------|----------:|----------:|------:|
| node -e 'console.log(2+2)'            | 0.69-0.72s | 0.41-0.42s | **1.66×** |
| node + 4 require (path/url/events/stream) | 0.69-0.71s | 0.42-0.43s | **1.66×** |

Translation stats (single representative TJIT run):
- ~900 unique blocks translated, ~267k native invocations
- 0 alloc failures, 0 regressions

## How to enable

Set `ISH_TRACEJIT=1` in environment. Default off; ish behavior is
byte-identical to pre-tracejit when off. No config file, no rebuild.

Optional: `ISH_TRACEJIT_RANGE=lo-hi` (hex) overrides the codespace
window for micro-benchmarks running outside `/usr/bin/node`.
`ISH_TRACEJIT_SELFTEST=1` runs an in-process MAP_JIT round-trip at
startup to fail fast on codesigning issues.

## Known boundaries

- Guest arch: ARM64 only. x86 guest is gadget-only (no tracejit code path).
- Host: macOS only. iOS port is one-function swap in `tracejit/page_alloc.c`
  (the MAP_JIT + `pthread_jit_write_protect_np` path) but blocked on
  Apple's distribution policy for JIT entitlements outside EU; not a v1
  concern for a Mac-side PoC.
- Codespace: V8 jitless interpreter range (`/usr/bin/node` mapping,
  approx 0xed1dd000-0xeff08000). Other guest code is never translated.
- 1.66× applies to require/startup-bound workloads. Workloads dominated
  by I/O or guest-side computation outside V8 codespace see no benefit.

## Known unfinished — explicit non-goals at ship

- ldr/str (imm or reg) body coverage — no translated block reads or
  writes guest memory; any guest insn touching memory aborts translation.
- ALU reg-form (sub/and/orr/eor/shifts) — only add-imm is translated.
- Indirect chain (br xN / blr xN / ret xN with native dispatch table) —
  attempted as step 3, regressed to 0.94× under minimal coverage, deferred.
  See DESIGN_LOG.
- Conditional chain (b.cond / cbz / cbnz / tbz / tbnz) — never started.
- Inline cache for megamorphic dispatch — would only matter if step 3 ran.
- Transitive eager translation — when block A is translated, we don't
  also translate A's branch targets unless they happen to be hit by
  later dispatches. Identified during step-3 postmortem as the actual
  missing ingredient for a useful indirect chain; not addressed here.
- Back-patching of already-emitted chain sites — only forward-direction
  chain works (translate B first, then A's chain to B).

## Re-engagement path

If a future session wants to extend, the order from the postmortem is:

1. Add transitive eager translation (translate b/ret targets at
   translate-time, depth-bounded).
2. Reapply step-3 stash on top: `git stash apply stash@{0}` —
   "step3-attempt-regressed". Contains br/blr/ret xN decoders +
   `emit_indirect_terminator` + movz/movk x sf=1 extension.
3. Re-measure end-to-end node hello + require, n=5 interleaved.
   Threshold: **≥2×** to continue. <2× triggers IC design or stop.

Stash `stash@{0}` must be preserved until step-3 retry completes.

## Reproduce 1.66× (one-liner)

```sh
ISH=/Users/ethan/Downloads/ish-opt/build/ish; FS=/Users/ethan/Downloads/ish/alpine-arm64-fakefs; for i in 1 2 3 4 5; do b=$(/usr/bin/time -p "$ISH" -f "$FS" /usr/bin/node -e 'console.log(2+2)' 2>&1 | awk '/^user/{print $2}'); t=$(ISH_TRACEJIT=1 /usr/bin/time -p "$ISH" -f "$FS" /usr/bin/node -e 'console.log(2+2)' 2>&1 | awk '/^user/{print $2}'); printf "BASE=%s  TJIT=%s\n" "$b" "$t"; done
```

Expected output: 5 lines, BASE ~0.69-0.72s, TJIT ~0.41-0.42s.
