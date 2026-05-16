# iSH Performance Benchmark

> **Generated:** 2026-05-16 11:15:55
> **Host:** macOS 26.4.1 / arm64
> **x86:** ish (759K, fakefs)
> **ARM64:** ish (688K, fakefs)
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
| echo | 3ms | 6ms | 5ms | 2.0x | **1.2x** |
| uname -a | 6ms | 10ms | 7ms | 1.7x | **1.4x** |
| ls /bin | 6ms | 11ms | 7ms | 1.8x | **1.6x** |
| cat file | 4ms | 10ms | 7ms | 2.5x | **1.4x** |
| wc -l | 4ms | 11ms | 8ms | 2.8x | **1.4x** |
| date | 4ms | 9ms | 7ms | 2.2x | **1.3x** |
| env | 6ms | 7ms | 5ms | 1.2x | **1.4x** |

### Compute

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| loop 1000 | 6ms | 310ms | 239ms | 51.7x | **1.3x** |
| loop 5000 | 16ms | 1537ms | 1206ms | 96.1x | **1.3x** |
| loop 10000 | 29ms | 3078ms | 2416ms | 106.1x | **1.3x** |
| seq+awk 10K | 6ms | 351ms | 87ms | 58.5x | **4.0x** |
| seq+awk 50K | 14ms | 1782ms | 419ms | 127.3x | **4.3x** |
| seq+awk 100K | 21ms | 3447ms | 828ms | 164.1x | **4.2x** |
| expr loop 500 | 942ms | 2272ms | 1524ms | 2.4x | **1.5x** |
| bc sqrt | 5ms | 15ms | 15ms | 3.0x | **1.0x** |
| bc pi | 5ms | 10ms | 7ms | 2.0x | **1.4x** |

### Text

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| sed replace | 5ms | 9ms | 6ms | 1.8x | **1.5x** |
| sort 1K | 9ms | 15ms | 10ms | 1.7x | **1.5x** |
| sort 5K | 6ms | 35ms | 20ms | 5.8x | **1.8x** |
| uniq count | 6ms | 15ms | 9ms | 2.5x | **1.7x** |
| grep count | 6ms | 174ms | 49ms | 29.0x | **3.6x** |
| tr lowercase | 6ms | 11ms | 8ms | 1.8x | **1.4x** |

### File-IO

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| create 50 | 14ms | 39ms | 45ms | 2.8x | **0.9x** |
| create 200 | 32ms | 81ms | 95ms | 2.5x | **0.9x** |
| find /bin | 7ms | 14ms | 11ms | 2.0x | **1.3x** |
| dd 64K | 7ms | 20ms | 11ms | 2.9x | **1.8x** |

### Crypto

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| md5sum | 7ms | 13ms | 6ms | 1.9x | **2.2x** |
| sha256sum | 7ms | 10ms | 7ms | 1.4x | **1.4x** |

### Process

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| fork+exec 10 | 9ms | 50ms | 31ms | 5.6x | **1.6x** |
| fork+exec 50 | 30ms | 205ms | 130ms | 6.8x | **1.6x** |
| pipe chain | 5ms | 29ms | 13ms | 5.8x | **2.2x** |

### Python

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| startup | 46ms | 250ms | 145ms | 5.4x | **1.7x** |
| sum(1M) | 34ms | 1339ms | 569ms | 39.4x | **2.4x** |
| fib(30) | 132ms | 3711ms | 1651ms | 28.1x | **2.2x** |
| str concat 10K | 31ms | 549ms | 284ms | 17.7x | **1.9x** |
| json roundtrip | 45ms | 3149ms | 1270ms | 70.0x | **2.5x** |
| sha256 1MB | 32ms | 356ms | 182ms | 11.1x | **2.0x** |
| regex 50K | 28ms | 490ms | 248ms | 17.5x | **2.0x** |
| sort 100K | 66ms | 5053ms | 1570ms | 76.6x | **3.2x** |

### C

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| int_arith_2M | 9ms | 233ms | 62ms | 25.9x | **3.8x** |
| float_arith_1M | 6ms | 82ms | 33ms | 13.7x | **2.5x** |
| mem_seq_4MB | 0ms | 11ms | 23ms | — | **0.5x** |
| mem_rand_500K | 1ms | 16ms | 13ms | 16.0x | **1.2x** |
| func_call_2M | 1ms | 18ms | 28ms | 18.0x | **0.6x** |
| branch_2M | 2ms | 60ms | 37ms | 30.0x | **1.6x** |
| matrix_64x64 | 0ms | 10ms | 8ms | — | **1.2x** |
| string_200K | 2ms | 425ms | 214ms | 212.5x | **2.0x** |

### Go

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| version | 48ms | 123ms | 115ms | 2.6x | **1.1x** |
| env | 16ms | 99ms | 88ms | 6.2x | **1.1x** |

### Node.js

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| startup | 91ms | 653ms | 485ms | 7.2x | **1.3x** |
| sum 1M | 45ms | 550ms | 1015ms | 12.2x | **0.5x** |
| JSON 10K | 43ms | 500ms | 775ms | 11.6x | **0.6x** |
| sha256 | 31ms | 787ms | 630ms | 25.4x | **1.2x** |

