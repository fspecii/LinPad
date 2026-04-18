# iSH ARM64 — Linux on iOS via Native JIT

**Fork of [ish-app/ish](https://github.com/ish-app/ish)** — a userspace Linux emulator for iOS.

This fork adds a **native ARM64 JIT engine** (codename *Asbestos*) that emulates AArch64 Linux
on Apple Silicon, alongside the original x86 interpreter (*Jitter*). The result is a dramatically
faster and more compatible Linux environment capable of running **Python, Node.js, Go, Rust, and
native CLI tools** directly on iPhone and iPad.

---

## Why ARM64?

The original iSH translates **x86 (i386) instructions** on an ARM64 host — every guest instruction
must be cross-architecture decoded and emulated. This works well for simple tools but creates
fundamental limits:

| Limitation | x86 (original) | ARM64 (this fork) |
|---|---|---|
| Architecture translation | i386 → ARM64 (cross) | AArch64 → AArch64 (same) |
| Address space | 32-bit (4 GB) | 48-bit (256 TB) |
| SIMD | Partial SSE/SSE2 | Full NEON + Crypto |
| Node.js / V8 | Not possible (needs >4 GB VA) | Fully supported |
| Go / Rust | Not possible (large VA requirements) | Fully supported |
| Compute overhead | 15-100x native | 3-30x native |

## Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│  iOS App (iSH ARM64)                                     │
│  ┌────────────────────────────────────────────────────┐  │
│  │  Asbestos JIT Engine                               │  │
│  │  ┌──────────┐  ┌───────────��  ┌────────────────┐  │  │
│  │  │ Decoder  │→ │ Code Gen  │→ │ Fiber Blocks   │  │  │
│  │  │ (gen.c)  ���  │ (gadgets) │  │ (block cache)  │  │  │
│  │  └─���────────┘  └───────────┘  └────────────────┘  │  │
│  │       ↕              ↕               ↕             │  │
│  │  ┌──────────────────────────────────────────────┐  │  │
│  │  ���  48-bit Virtual Memory (4-level page table)  │  │  │
│  │  │  TLB (8192 entries) + CoW + Lazy Reservations│  │  │
│  │  └──────────────��───────────────────────────���───┘  │  │
│  └────────────────────────────────────────────────────┘  │
│  ┌─────────────────┐  ┌───────────────────────────────┐  │
│  │  Linux Kernel    │  │  Agent Integration            │  │
│  │  (syscalls,      │  │  - ISHShellExecutor           │  │
│  │   signals,       │  ��  - DebugServer (JSON-RPC)     ���  │
│  │   futex, epoll)  │  │  - Native Offload             │  │
│  └─────────────────┘  │  - Bind Mounts                 │  │
│  ┌──────���──────────┐  └───────────────────────────────┘  │
│  │  Filesystem      │                                    │
│  │  fakefs + realfs │                                    │
│  │  + bind mounts   │                                    │
│  └─────��───────────┘                                     │
└───────────────���──────────────────────────────────────────┘
```

---

## Key Changes from Upstream

### 1. Asbestos JIT Engine

The core of the ARM64 port. Compiles guest ARM64 instructions into host ARM64 code at runtime.

**Key files:**
- `asbestos/asbestos.c` — JIT cache, block management, RCU-like jetsam cleanup
- `asbestos/guest-arm64/gen.c` — Instruction decoder and gadget generator (~200+ opcodes)
- `asbestos/guest-arm64/gadgets-aarch64/` — Assembly gadgets:
  - `entry.S` — fiber_enter/exit, crash recovery trampoline
  - `memory.S` — Load/store with inline TLB lookup (~12 instructions fast path)
  - `control.S` — Branches, conditionals, fused compare-and-branch
  - `math.S` — Arithmetic, shifts, bit manipulation, NEON/SIMD
  - `crypto.S` — AES, SHA, CRC32 instructions

**Design highlights:**
- **Block chaining**: Sequential basic blocks link directly, skipping dispatch overhead
- **Persistent TLB**: 8192-entry TLB survives across syscalls (not flushed on every entry)
- **Crash recovery**: SIGSEGV in JIT code redirects to trampoline for CoW resolution
- **Full NEON**: All 128-bit SIMD operations including crypto extensions

### 2. 48-bit Virtual Address Space

4-level page table (L0→L1→L2→L3, 9 bits each = 36-bit page number + 12-bit offset = 48 bits).

- Supports V8's 128GB+ pointer cage (via `MAP_NORESERVE` lazy reservations)
- Go's large virtual address requirements for heap/stack
- Guard pages at 0x0-0x100000 for V8 compressed pointer safety
- Layout kept compact (stack at `0xffffe000`, mmap at `0xefffd`) for TLB efficiency

**Key files:** `kernel/memory.h`, `kernel/memory.c`, `emu/tlb.h`

### 3. Node.js / V8 Support

Running Node.js on a userspace emulator required solving multiple V8-specific problems:

- **128GB MAP_NORESERVE**: Lazy address reservations that don't consume physical memory
- **Guard pages at 0x0-0x100000**: V8 compressed pointers dereference small integers —
  mapping the low 1MB as readable zeros prevents SIGSEGV
- **V8 binary patch**: 9-instruction code cave patch for `InterpreterEntryTrampoline`
  derived constructor bug (zero emulator overhead)
- **`--jitless --no-lazy`**: V8 flags to avoid Wasm compilation and lazy parsing issues
- **Exit cleanup**: Safety valves for stuck V8 threads during process exit

**Result**: `npm install`, `npm exec`, `npx`, and `create-next-app` all work.

### 4. Agent Integration

Mechanisms designed for AI agent orchestration on iOS:

#### ISHShellExecutor (`app/ISHShellExecutor.h`)

Objective-C API for programmatic shell execution with streaming output:

```objc
[ISHShellExecutor executeCommand:@"pip install requests"
                    lineCallback:^(NSString *line, BOOL isStdErr) {
                        NSLog(@"%@", line);
                    }
                      completion:^(ISHShellExecutionResult *result) {
                          NSLog(@"Exit code: %d", result.exitCode);
                      }];
```

#### DebugServer (`app/DebugServer.c`)

JSON-RPC over HTTP server for guest introspection:

```bash
# List files
curl localhost:1234 -d '{"jsonrpc":"2.0","id":1,"method":"fs.readdir","params":{"path":"/usr/bin"}}'

# Execute command
curl localhost:1234 -d '{"jsonrpc":"2.0","id":1,"method":"guest.exec","params":{"command":"python3 --version"}}'

# Inspect processes
curl localhost:1234 -d '{"jsonrpc":"2.0","id":1,"method":"task.list"}'
```

#### Native Offload (`kernel/native_offload.c`)

Bypass emulation entirely for registered binaries. Guest `execve()` is intercepted and
routed to a native handler or host binary:

```c
// Register handler (call once at startup)
native_offload_add_handler("ffmpeg", ffmpeg_main);

// Now guest `ffmpeg -i input.mp4 output.mp3` runs natively
// Arguments auto-translated from guest paths to host paths
```

Supports both in-process handlers (iOS + macOS) and `posix_spawn` delegation (macOS CLI).

#### Bind Mounts (`fs/fake.c`)

Mount host directories into the guest filesystem:

```c
// Read-only bind mount of host directory
fakefs_bind_mount("/host/path/to/data", "/mnt/data", /*read_only=*/true);
```

Enables AI agents to share files between the host app and the Linux guest without copying.

### 5. Rootfs Management

- **Alpine 3.21 aarch64** with full apk package manager
- **RootfsPatch.bundle**: Versioned overlay system for incremental rootfs updates
- **Polyfills**: WebAssembly polyfill for undici/llhttp, fetch polyfill for HTTP downloads
- **OPENSSL_armcap=0** and **GODEBUG/GOMAXPROCS** injection in `sys_execve`

---

## Build Configuration

| Target | Scheme | xcconfig | Guest Arch | Bundle ID Suffix |
|--------|--------|----------|------------|------------------|
| x86 (original) | iSH | `App.xcconfig` | i386 | — |
| ARM64 | iSH-ARM64 | `AppARM64.xcconfig` | aarch64 | `.arm64` |
| ARM64 + FFmpeg | iSH-ARM64-ffmpeg | `AppARM64-ffmpeg.xcconfig` | aarch64 | `.arm64` |

The ARM64 target links meson-built libraries (`libish.a`, `libish_emu.a`, `libfakefs.a`) directly
from `build-arm64-release/`, bypassing Xcode's auto-discovery of x86 library targets.

```bash
# Build ARM64 CLI (macOS, for testing)
meson setup build-arm64-release -Dguest_arch=arm64 --buildtype=release
ninja -C build-arm64-release

# Run
./build-arm64-release/ish -f ./alpine-arm64-fakefs /bin/sh
```

---

## Performance

### ARM64 vs x86 vs Native

Tested on macOS 26.4.1 / Apple Silicon using `/usr/bin/time -l` for precise measurement.
**Instructions retired** is the fairest metric (eliminates filesystem mode differences):

| Test | Native | x86 | | ARM64 | | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|:---:|
| | | time | insns | time | insns | **insns ratio** |
| echo hello | 0.00s | 0.00s | 61M | 0.28s | 5.3B | — (startup) |
| loop 5000 | 0.01s | 0.95s | 12.5B | 0.57s | 7.1B | **1.7x** |
| seq+awk 10K | 0.00s | 0.66s | 11.4B | 0.52s | 6.8B | **1.7x** |
| seq+awk 50K | 0.01s | 3.30s | 57.0B | 0.74s | 12.4B | **4.6x** |
| fork+exec 50 | 0.02s | 0.09s | 1.7B | 0.46s | 7.4B | 0.2x |

**Key findings**:
- **Compute-heavy**: ARM64 JIT executes **4.6x fewer instructions** than x86 for `seq+awk 50K`,
  and is **4.5x faster** in wall clock time. The gap widens with workload size.
- **Startup**: ARM64's 5.3B instruction baseline is fakefs (SQLite) initialization. On iOS
  this cost is paid once at app launch, not per-command. x86 uses realfs (zero startup).
- **Instruction efficiency**: x86 emulates `echo` in 61M host instructions; ARM64 needs
  5.3B — but 99% of that is one-time fakefs init, not the echo itself.

### Language Runtime Performance (ARM64 vs Docker Native)

Measured with `bench/cross_lang_bench.sh` against Docker Alpine aarch64 (bare metal):

| Language | Typical Overhead | Startup | Best Case |
|----------|:---:|:---:|:---:|
| C/C++ tools | 5-15x | 0.3s | 8.5x (perl) |
| Go binaries | 8-15x | 0.4s | — |
| Python | 30-120x | 0.5s | 33.6x (print) |
| Node.js | 25-80x | 0.4s | 47.4x (npm list) |
| Rust (uv) | 5-12x | 0.3s | — |

> **Why interpreters are slower**: Python/Node create "double virtualization" — bytecode
> dispatch through the interpreter, then JIT translation of the interpreter itself. Each
> Python bytecode operation costs ~100+ memory accesses (vs ~10 natively).

### Compatibility (68 tests, CLI mode)

| Test Suite | x86 (Jitter) + minirootfs | ARM64 (Asbestos) + full rootfs |
|---|:---:|:---:|
| Core utilities (24 tests) | 46% | **100%** |
| File operations (13 tests) | 62% | **100%** |
| Text processing (13 tests) | 15% | **100%** |
| /proc & /dev (9 tests) | 67% | **100%** |
| **Overall (68 tests)** | **44%** | **100%** |

> x86 failures are largely due to the minimal busybox rootfs (no `/dev` nodes, no `apk`).
> With the iOS app's full rootfs, x86 passes most of these. ARM64's fakefs provides
> virtual devices and a complete Alpine package ecosystem out of the box.

**Extended compatibility (ARM64 only)**:
- Node.js ecosystem: **93%** pass (201/214 tests)
- Software packages: **82-85%** pass (249 tests)

> Full benchmark reports: [Performance](benchmark/BENCHMARK_PERF.md) | [Compatibility](benchmark/BENCHMARK_COMPAT.md)

---

## Supported Software

### Fully Working

| Category | Examples |
|----------|---------|
| **Package managers** | apk, pip, npm, npx, uv |
| **Languages** | Python 3, Node.js 22, Go, Perl, Ruby, Lua |
| **Dev tools** | git, curl, wget, ssh, vim, nano |
| **Build tools** | gcc, g++, cmake, make, meson |
| **Data tools** | sqlite3, jq, yt-dlp, ffmpeg (via native offload) |
| **Network** | curl, wget, dig, netstat, ss |
| **Node frameworks** | Express, Koa, Fastify, Axios, Socket.io |
| **npm ecosystem** | lodash, moment, dayjs, uuid, chalk, commander, glob, semver |

### Not Supported

- **GUI applications** (no X11/Wayland)
- **Docker / containers** (no kernel namespace support)
- **Kernel modules** (userspace emulator)
- **Hardware access** (no /dev/gpu, no USB passthrough)

---

## Commit History

86 commits on `feature-arm64`, 101 files changed, +23,198 / -7,620 lines.

Major milestones:
1. **JIT foundation**: fiber_enter/exit, basic block compilation, TLB
2. **Instruction coverage**: 200+ ARM64 opcodes including full NEON/Crypto
3. **48-bit address space**: 4-level page table, lazy reservations
4. **Node.js support**: V8 guard pages, MAP_NORESERVE, binary patch, exit cleanup
5. **Go support**: Signal frame alignment, sigreturn fixes, NZCV preservation
6. **Rust/uv support**: FUTEX_WAIT_BITSET, PMULL, BFM, demand-mapped reads
7. **Agent integration**: ISHShellExecutor, DebugServer, Native Offload, Bind Mounts
8. **Stability**: 50+ bug fixes for concurrency, memory leaks, use-after-free, deadlocks

---

## Project Structure

```
iSH/
├── asbestos/                    # ARM64 JIT engine
│   ├── asbestos.c/h             # Block cache, RCU cleanup
│   └── guest-arm64/
│       ├── gen.c                # Instruction decoder → gadgets
│       ├── crypto_helpers.c     # AES/SHA/CRC32 helpers
│       └── gadgets-aarch64/     # Assembly gadgets
│           ├── entry.S          # JIT entry/exit, crash handler
│           ├── memory.S         # Load/store, TLB inline lookup
│           ├── control.S        # Branches, conditionals
│           ├── math.S           # ALU, shifts, NEON/SIMD
│           ├── crypto.S         # AES, SHA, PMULL, CRC32
│           ├── bits.S           # Bitfield operations
│           └── gadgets.h        # Register map, TLB macros
├── emu/
│   ├── tlb.c/h                  # TLB miss handling, cross-page
│   └── arch/arm64/
│       ├── cpu.h                # CPU state (regs, NEON, flags)
│       └── decode.h             # Instruction field extraction
├── kernel/
│   ├── arch/arm64/calls.c       # ARM64 syscall table
│   ├── memory.c/h               # Page table, CoW, fault handling
│   ├── mmap.c                   # mmap, lazy reservations
│   ├── native_offload.c/h       # Binary offload system
│   ├── signal.c/h               # Signal delivery/frame
│   ├── futex.c                  # Futex with pipe wakeup
│   ├── exec.c                   # ELF loader, V8 guard pages
│   └── exit.c                   # Thread cleanup, safety valves
├── fs/
│   ├── fake.c/h                 # fakefs + bind mount support
│   ├── real.c                   # Host filesystem access
│   ├── sock.c/h                 # Socket emulation
│   └── poll.c                   # epoll/poll/select
├── app/
│   ├── AppARM64.xcconfig        # ARM64 build config
│   ├── GuestARM64.xcconfig      # Guest arch definition
│   ├── ISHShellExecutor.h/m     # Shell execution API
│   ��── DebugServer.c/h          # JSON-RPC debug server
│   └── RootfsPatch.bundle/      # Versioned rootfs overlay
└── bench/
    ├── bench_triarch.sh          # Native vs x86 vs ARM64 benchmark
    ├── cross_lang_bench.sh       # ARM64 vs Docker (40 tests)
    ├── BENCHMARK_PERF.md         # Performance report
    └── BENCHMARK_COMPAT.md       # Compatibility report
```

---

## License

Same as upstream iSH. See [LICENSE](LICENSE).
