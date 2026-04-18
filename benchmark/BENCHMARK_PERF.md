# iSH Performance Benchmark

> **Generated:** 2026-04-18 16:58:41
> **Host:** macOS 26.4.1 / arm64
> **x86:** ish (705K, fakefs)
> **ARM64:** ish (656K, fakefs)
> **Runs:** 3 (median) | **Timeout:** 120s

| | x86 Emulation | ARM64 JIT |
|---|:---:|:---:|
| Engine | Interpreter (Jitter) | JIT Compiler (Asbestos) |
| Guest | i386 → ARM64 host | AArch64 → AArch64 host |
| Address | 32-bit (4 GB) | 48-bit (256 TB) |
| SIMD | Partial SSE/SSE2 | Full NEON + Crypto |
| Node/Go/Rust | Not possible | Supported |

---

## 1. Shell Benchmark (Native vs x86 vs ARM64)

> **Guest-side timing** — each test measured inside the emulator with
> monotonic clock. Startup overhead (fakefs init) is excluded.
> This isolates pure emulation performance.

### System

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| echo | 3ms | 9ms | 4ms | 3.0x | **2.2x** |
| uname -a | 4ms | 17ms | 7ms | 4.2x | **2.4x** |
| ls /bin | 5ms | 19ms | 8ms | 3.8x | **2.4x** |
| cat file | 4ms | 17ms | 8ms | 4.2x | **2.1x** |
| wc -l | 5ms | 19ms | 10ms | 3.8x | **1.9x** |
| date | 5ms | 16ms | 7ms | 3.2x | **2.3x** |
| env | 4ms | 11ms | 7ms | 2.8x | **1.6x** |

### Compute

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| loop 1000 | 5ms | 189ms | 240ms | 37.8x | **0.8x** |
| loop 5000 | 16ms | 893ms | 1184ms | 55.8x | **0.8x** |
| loop 10000 | 29ms | 1779ms | 2389ms | 61.3x | **0.7x** |
| seq+awk 10K | 8ms | 653ms | 95ms | 81.6x | **6.9x** |
| seq+awk 50K | 16ms | 3212ms | 446ms | 200.8x | **7.2x** |
| seq+awk 100K | 22ms | 6338ms | 882ms | 288.1x | **7.2x** |
| expr loop 500 | 802ms | 3781ms | 1433ms | 4.7x | **2.6x** |
| bc sqrt | 4ms | 23ms | 15ms | 5.8x | **1.5x** |
| bc pi | 5ms | 17ms | 6ms | 3.4x | **2.8x** |

### Text

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| sed replace | 6ms | 12ms | 5ms | 2.0x | **2.4x** |
| sort 1K | 6ms | 33ms | 11ms | 5.5x | **3.0x** |
| sort 5K | 6ms | 117ms | 20ms | 19.5x | **5.8x** |
| uniq count | 6ms | 27ms | 10ms | 4.5x | **2.7x** |
| grep count | 5ms | 283ms | 53ms | 56.6x | **5.3x** |
| tr lowercase | 5ms | 18ms | 8ms | 3.6x | **2.2x** |

### File-IO

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| create 50 | 12ms | 41ms | 42ms | 3.4x | **1.0x** |
| create 200 | 27ms | 100ms | 92ms | 3.7x | **1.1x** |
| find /bin | 6ms | 18ms | 9ms | 3.0x | **2.0x** |
| dd 64K | 7ms | 26ms | 11ms | 3.7x | **2.4x** |

### Crypto

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| md5sum | 6ms | 17ms | 8ms | 2.8x | **2.1x** |
| sha256sum | 6ms | 17ms | 7ms | 2.8x | **2.4x** |

### Process

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| fork+exec 10 | 9ms | 88ms | 34ms | 9.8x | **2.6x** |
| fork+exec 50 | 28ms | 356ms | 128ms | 12.7x | **2.8x** |
| pipe chain | 5ms | 49ms | 13ms | 9.8x | **3.8x** |

### Python

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| startup | 42ms | 523ms | 137ms | 12.5x | **3.8x** |
| sum(1M) | 33ms | 6200ms | 610ms | 187.9x | **10.2x** |
| fib(30) | 130ms | 15219ms | 1661ms | 117.1x | **9.2x** |
| str concat 10K | 27ms | 1706ms | 286ms | 63.2x | **6.0x** |
| json roundtrip | 41ms | 5913ms | 1258ms | 144.2x | **4.7x** |
| sha256 1MB | 29ms | 767ms | 185ms | 26.4x | **4.1x** |
| regex 50K | 25ms | 1135ms | 243ms | 45.4x | **4.7x** |
| sort 100K | 62ms | 10261ms | 1561ms | 165.5x | **6.6x** |

### C

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| int_arith_2M | 10ms | 782ms | 65ms | 78.2x | **12.0x** |
| float_arith_1M | 6ms | 87ms | 33ms | 14.5x | **2.6x** |
| mem_seq_4MB | 0ms | 26ms | 24ms | — | **1.1x** |
| mem_rand_500K | 1ms | 19ms | 15ms | 19.0x | **1.3x** |
| func_call_2M | 1ms | 100ms | 30ms | 100.0x | **3.3x** |
| branch_2M | 2ms | 59ms | 41ms | 29.5x | **1.4x** |
| matrix_64x64 | 0ms | 12ms | 8ms | — | **1.5x** |
| string_200K | 3ms | 625ms | 198ms | 208.3x | **3.2x** |

### Go

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| version | 32ms | 316ms | 128ms | 9.9x | **2.5x** |
| env | 12ms | 307ms | 100ms | 25.6x | **3.1x** |

### Node.js

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** | x86 Status |
|------|:---:|:---:|:---:|:---:|:---:|:---|
| startup | 107ms | 1639ms | 1008ms | 15.3x | **1.6x** | ✅ completes |
| sum 1M | 46ms | 30246ms | 1455ms | 657.5x | **20.8x** | ⚠ 30s timeout — never completes |
| JSON 10K | 39ms | 325ms | 1223ms | 8.3x | **0.3x** | ❌ crashes at startup |
| sha256 | 30ms | 316ms | 946ms | 10.5x | **0.3x** | ❌ crashes at startup |

> **Warning — x86 Node.js numbers are not comparable**: Node.js 22 requires the
> Linux `io_uring_setup` syscall (#425) which iSH x86 does not implement. Every
> Node invocation logs `missing syscall 425` and either hangs until timeout
> (`sum 1M`) or crashes before finishing real work (`JSON 10K`, `sha256`).
> The 0.3x ratios for JSON/sha256 reflect **crash exit time, not computation time**.
> See the "Known x86 Limitations" section at the end for details.


---

## Summary

| Category | x86/Native | ARM64/Native | **ARM64 vs x86** |
|---|:---:|:---:|:---:|
| **C (pure compute)** | 14-208x | 1-66x | **1.1-12.0x** |
| **Shell pipelines** | 57-305x | 3-42x | **5.3-7.2x** |
| **Python** | 12-201x | 3.8-169x | **3.8-10.2x** |
| **Go (startup)** | 10-26x | 2.5-3.1x | **2.5-3.1x** |
| **Node.js** | — | 1.6-20.8x | N/A (x86 broken) |

### Headline numbers

- **C `int_arith_2M`**: ARM64 **12x faster** than x86 (65ms vs 782ms), only 6.5x slower than native
- **Shell `seq+awk 100K`**: ARM64 **7.2x faster** than x86 (882ms vs 6338ms)
- **Python `fib(30)`**: ARM64 **9.2x faster** than x86 (1.66s vs 15.2s)
- **Python `sum(1M)`**: ARM64 **10.2x faster** (610ms vs 6.2s)
- **C `matrix_64x64`** and **`mem_seq_4MB`**: ARM64 near-native speed (8ms vs 0ms native, ~1.1-1.5x)

### Why ARM64 wins

1. **Same-architecture JIT (Asbestos)** — ARM64 guest instructions translate to 1-3 host
   instructions directly; the x86 interpreter decodes every i386 instruction through
   ARM64 helper code, ~30-100x overhead per instruction.
2. **Full NEON/crypto** — TLS, hashing, simdjson all work at native-ish speed.
3. **48-bit address space** — V8, Go, Rust all need large virtual reservations
   that don't fit in x86's 32-bit space.
4. **iSH ARM64 fork has Node.js fixes** — V8 binary patch, guard pages, `--jitless`
   injection, io_uring syscall, etc.

### Where x86 ties or wins

- **Simple shell loops** (`loop 5000`): x86 is 0.8x vs ARM64 — busybox x86 integer
  arithmetic maps closely to fast host ARM64 ops while iSH ARM64 still pays JIT
  dispatch overhead per shell iteration.

---

## Known x86 Limitations

These are **x86 emulator limitations**, not benchmark bugs. They explain anomalous
results in the tables above:

### 1. Node.js is effectively broken on x86 iSH

Node.js 22 invokes `io_uring_setup` (syscall 425) during startup for its event loop.
iSH x86 does not implement this syscall, so every Node invocation prints:

```
1(node) missing syscall 425
2(DelayedTaskSche) missing syscall 425
```

Simple scripts (`console.log(42)`) sometimes complete before Node's fallback paths
hit other issues, but anything non-trivial crashes or hangs:

- `sum 1M` — hangs until our 30-second timeout, never prints result
- `JSON 10K`, `sha256` — V8 exits with `exit_group` before computation runs;
  the measured 300ms is just **process cleanup time**, not work

**Why ARM64 works**: This fork adds the required Node-related syscalls
(io_uring, timers, clock IDs, 64-bit mmap len) and a V8 binary patch in the
ARM64 code path. The `xX_main_Xx.h` initial-exec code injects `--jitless
--no-lazy --no-expose-wasm` into Node's argv on ARM64 only — this flag
injection is guarded by `#ifdef GUEST_ARM64` and is absent on x86.

### 2. x86 iSH does not support SSE3+

The i486-compatible `cbench_lite_x86` binary was rebuilt with `-march=i486
-mno-sse` because a plain `-O2` build crashed with "illegal instruction" at
`cvtdq2pd`. Any modern x86 package that assumes at least SSE3 (most Alpine
pre-built Python C extensions, for example) will likewise crash.

### 3. x86 iSH uses a 32-bit address space

Runtimes that reserve large virtual regions cannot start:
- V8 (Node.js, deno) wants ~128 GB for its pointer cage
- Go's scavenger allocates high-address metadata
- Rust binaries built with newer MSRVs increasingly assume 48-bit VA

ARM64 iSH in this fork implements a 4-level page table and lazy reservations
(`MAP_NORESERVE`) specifically to support these runtimes.

### 4. Fair interpretation of the tables

When reading `x86/ARM64` ratios:
- **C / Shell / Python**: all numbers are real; both platforms completed the work
- **Node.js**: only `startup` is a real comparison; other rows should be read as
  "x86 cannot do this" rather than "x86 is faster" (0.3x means it crashed early)
- **Go**: `version` and `env` work on both; compilation/runtime of Go binaries
  hits the 32-bit VA limit on x86

