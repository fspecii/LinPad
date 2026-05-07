# iSH Performance Benchmark

> **Generated:** 2026-05-07 11:37:25
> **Host:** macOS 26.4.1 / arm64
> **x86:** ish (705K, fakefs)
> **ARM64:** ish (706K, fakefs)
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
| echo | 3ms | 12ms | 5ms | 4.0x | **2.4x** |
| uname -a | 5ms | 18ms | 7ms | 3.6x | **2.6x** |
| ls /bin | 7ms | 20ms | 11ms | 2.9x | **1.8x** |
| cat file | 5ms | 17ms | 9ms | 3.4x | **1.9x** |
| wc -l | 4ms | 20ms | 8ms | 5.0x | **2.5x** |
| date | 4ms | 17ms | 7ms | 4.2x | **2.4x** |
| env | 7ms | 11ms | 5ms | 1.6x | **2.2x** |

### Compute

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| loop 1000 | 6ms | 186ms | 244ms | 31.0x | **0.8x** |
| loop 5000 | 16ms | 898ms | 1222ms | 56.1x | **0.7x** |
| loop 10000 | 29ms | 1793ms | 2435ms | 61.8x | **0.7x** |
| seq+awk 10K | 8ms | 653ms | 91ms | 81.6x | **7.2x** |
| seq+awk 50K | 14ms | 3219ms | 417ms | 229.9x | **7.7x** |
| seq+awk 100K | 21ms | 6437ms | 816ms | 306.5x | **7.9x** |
| expr loop 500 | 925ms | 4015ms | 1615ms | 4.3x | **2.5x** |
| bc sqrt | 6ms | 24ms | 15ms | 4.0x | **1.6x** |
| bc pi | 6ms | 18ms | 7ms | 3.0x | **2.6x** |

### Text

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| sed replace | 5ms | 13ms | 6ms | 2.6x | **2.2x** |
| sort 1K | 7ms | 35ms | 12ms | 5.0x | **2.9x** |
| sort 5K | 7ms | 119ms | 21ms | 17.0x | **5.7x** |
| uniq count | 6ms | 28ms | 11ms | 4.7x | **2.5x** |
| grep count | 6ms | 290ms | 50ms | 48.3x | **5.8x** |
| tr lowercase | 5ms | 19ms | 8ms | 3.8x | **2.4x** |

### File-IO

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| create 50 | 17ms | 43ms | 50ms | 2.5x | **0.9x** |
| create 200 | 29ms | 107ms | 113ms | 3.7x | **0.9x** |
| find /bin | 8ms | 19ms | 11ms | 2.4x | **1.7x** |
| dd 64K | 7ms | 26ms | 12ms | 3.7x | **2.2x** |

### Crypto

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| md5sum | 7ms | 17ms | 8ms | 2.4x | **2.1x** |
| sha256sum | 6ms | 17ms | 9ms | 2.8x | **1.9x** |

### Process

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| fork+exec 10 | 11ms | 89ms | 42ms | 8.1x | **2.1x** |
| fork+exec 50 | 30ms | 376ms | 148ms | 12.5x | **2.5x** |
| pipe chain | 6ms | 50ms | 15ms | 8.3x | **3.3x** |

### Python

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| startup | 45ms | 563ms | 164ms | 12.5x | **3.4x** |
| sum(1M) | 33ms | 6272ms | 588ms | 190.1x | **10.7x** |
| fib(30) | 131ms | 15500ms | 1676ms | 118.3x | **9.2x** |
| str concat 10K | 29ms | 1765ms | 279ms | 60.9x | **6.3x** |
| json roundtrip | 44ms | 6040ms | 1265ms | 137.3x | **4.8x** |
| sha256 1MB | 41ms | 791ms | 185ms | 19.3x | **4.3x** |
| regex 50K | 28ms | 1168ms | 249ms | 41.7x | **4.7x** |
| sort 100K | 64ms | 10373ms | 1508ms | 162.1x | **6.9x** |

### C

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| int_arith_2M | 10ms | 804ms | 61ms | 80.4x | **13.2x** |
| float_arith_1M | 6ms | 87ms | 33ms | 14.5x | **2.6x** |
| mem_seq_4MB | 0ms | 26ms | 22ms | — | **1.2x** |
| mem_rand_500K | 1ms | 21ms | 13ms | 21.0x | **1.6x** |
| func_call_2M | 1ms | 99ms | 29ms | 99.0x | **3.4x** |
| branch_2M | 2ms | 59ms | 39ms | 29.5x | **1.5x** |
| matrix_64x64 | 0ms | 12ms | 9ms | — | **1.3x** |
| string_200K | 2ms | 638ms | 218ms | 319.0x | **2.9x** |

### Go

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| version | 37ms | 313ms | 118ms | 8.5x | **2.7x** |
| env | 13ms | 299ms | 84ms | 23.0x | **3.6x** |

### Node.js

| Test | Native | x86 | ARM64 | x86/Native | **x86/ARM64** |
|------|:---:|:---:|:---:|:---:|:---:|
| startup | 92ms | 1752ms | 419ms | 19.0x | **4.2x** |
| sum 1M | 45ms | FAIL | 1031ms | — | **—** |
| JSON 10K | 41ms | 329ms | 789ms | 8.0x | **0.4x** |
| sha256 | 30ms | 320ms | 649ms | 10.7x | **0.5x** |

