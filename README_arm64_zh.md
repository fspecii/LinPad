# iSH ARM64 — 通过原生 threaded-code 解释器在 iOS 上运行 Linux

**Fork 自 [ish-app/ish](https://github.com/ish-app/ish)** — iOS 上的用户态 Linux 模拟器。

本 fork 新增了**原生 ARM64 threaded-code 解释器**（代号 *Asbestos*），可在 Apple Silicon 上模拟
AArch64 Linux，与原始 x86 解释器（*Jitter*）并存。结果是一个性能和兼容性大幅提升的 Linux 环境,
能在 iPhone / iPad 上直接运行 **Python、Node.js、Go、Rust 和原生 CLI 工具**。

> **命名说明**：Asbestos 和上游 Jitter 都是 **threaded-code 解释器**，不是真正的 JIT ——
> 两者都不在运行时生成机器码，而是把 guest 指令解码成"指向预编译原生 gadget 函数的指针数组"，
> 各 gadget 通过尾调用衔接（与 Forth 解释器采用相同技术）。Asbestos 的 gadget 处理 ARM64 guest
> 运行在 ARM64 host（同架构、接近直接翻译），Jitter 的 gadget 处理 x86 guest（总是跨架构）。
> 下文部分地方仍用 "JIT" 作为简写，请理解为"同架构 gadget 分派"而非运行时代码生成。
>
> 英文版: [README_arm64.md](README_arm64.md)

---

## 为什么要做 ARM64 版本？

原始 iSH 在 ARM64 主机上翻译 **x86 (i386) 指令** — 每条 guest 指令都要跨架构解码和模拟。
这对简单工具还行，但有根本限制：

| 限制 | x86（原版） | ARM64（本 fork） |
|---|---|---|
| 架构翻译 | i386 → ARM64（跨架构） | AArch64 → AArch64（同架构） |
| 地址空间 | 32-bit (4 GB) | 48-bit (256 TB) |
| SIMD | 部分 SSE/SSE2 | 完整 NEON + Crypto |
| Node.js / V8 | 无法运行（需要 >4 GB 虚拟地址） | 完整支持 |
| Go / Rust | 无法运行（需要大虚拟地址） | 完整支持 |
| 计算开销 | 相对原生 15-100x | 相对原生 3-30x |

## 架构总览

```
+--------------------------------------------------------------+
|  iOS App (iSH ARM64)                                         |
|                                                              |
|  +--------------------------------------------------------+  |
|  |  Asbestos (threaded-code 解释器)                       |  |
|  |                                                        |  |
|  |   Decoder  -->  Gadget program  -->  Fiber Blocks      |  |
|  |   (gen.c)       builder              (block cache)     |  |
|  |                                                        |  |
|  |   --- 48-bit 虚拟内存 (4 级页表) ---                    |  |
|  |       TLB (8192 项) + CoW + 惰性预留                   |  |
|  +--------------------------------------------------------+  |
|                                                              |
|  +-------------------+    +-------------------------------+  |
|  |  Linux 内核       |    |  Agent 集成                   |  |
|  |  (syscalls,       |    |  - ISHShellExecutor           |  |
|  |   signals,        |    |  - DebugServer (JSON-RPC)     |  |
|  |   futex, epoll)   |    |  - Native Offload             |  |
|  +-------------------+    |  - Bind Mounts                |  |
|                           +-------------------------------+  |
|  +-------------------+                                       |
|  |  文件系统         |                                       |
|  |  fakefs + realfs  |                                       |
|  |  + bind mounts    |                                       |
|  +-------------------+                                       |
+--------------------------------------------------------------+
```

---

## 相对上游的主要增强

### 1. Asbestos — threaded-code 解释器

ARM64 移植的核心。每个 guest 基本块会被编译成一个 **gadget 程序**：一个 `unsigned long`
数组，交替存放预编译 ARM64 gadget 函数指针和内联操作数。执行流程是一串尾调用 —— 每个 gadget
从程序流读取下一条指针并 `br` 跳过去。**不分配可执行内存，不在运行时生成任何机器码**。每条
guest 指令的 host 指令开销就是对应 gadget 中的几条 ARM64 指令。

**关键文件:**
- `asbestos/asbestos.c` — 块缓存、块管理、RCU 风格的 jetsam 清理
- `asbestos/guest-arm64/gen.c` — 指令解码器 + gadget 程序构建（200+ 指令）
- `asbestos/guest-arm64/gadgets-aarch64/` — 手写 ARM64 汇编 gadget:
  - `entry.S` — fiber_enter/exit、崩溃恢复 trampoline
  - `memory.S` — 内联 TLB 查找的 load/store（快路径约 12 条指令）
  - `control.S` — 分支、条件、融合 compare-and-branch
  - `math.S` — 算术、移位、位操作、NEON/SIMD
  - `crypto.S` — AES、SHA、CRC32 指令

**设计亮点:**
- **块链接**: 顺序基本块直接链接，跳过 dispatch 开销
- **持久 TLB**: 8192 项 TLB 跨 syscall 保留（不会每次进出 gadget 分派都刷）
- **崩溃恢复**: gadget 中 SIGSEGV 重定向到 trampoline 进行 CoW 处理
- **完整 NEON**: 所有 128-bit SIMD 操作，含加密扩展

### 2. 48-bit 虚拟地址空间

4 级页表（L0→L1→L2→L3，每级 9 bit = 36-bit 页号 + 12-bit 偏移 = 48-bit）。

- 支持 V8 的 128GB+ 指针笼（通过 `MAP_NORESERVE` 惰性预留）
- Go 对堆栈的大虚拟地址需求
- `0x0-0x100000` 的守护页防止 V8 compressed pointer 崩溃
- 布局保持紧凑（stack `0xffffe000`，mmap `0xefffd`）以提高 TLB 效率

**关键文件:** `kernel/memory.h`、`kernel/memory.c`、`emu/tlb.h`

### 3. Node.js / V8 支持

在用户态模拟器上跑 Node.js 需要解决多个 V8 特有问题：

- **128GB MAP_NORESERVE**: 不占物理内存的惰性地址预留
- **0x0-0x100000 守护页**: V8 compressed pointer 会解引用小整数 —
  把低 1MB 映射成可读的零页能避免 SIGSEGV
- **V8 二进制补丁**: 在代码 cave 中植入 9 条指令修复 `InterpreterEntryTrampoline`
  派生构造函数 bug（零模拟器开销）
- **`--jitless --no-lazy`**: V8 启动 flag，避开 Wasm 编译和懒解析问题
- **退出清理**: V8 线程卡死时的 safety valve

**效果**: `npm install`、`npm exec`、`npx`、`create-next-app` 全部可用。

### 4. Agent 集成

为 iOS 上的 AI agent 编排设计的机制:

#### ISHShellExecutor（`app/ISHShellExecutor.h`）

支持流式输出的 Objective-C shell 执行 API:

```objc
[ISHShellExecutor executeCommand:@"pip install requests"
                    lineCallback:^(NSString *line, BOOL isStdErr) {
                        NSLog(@"%@", line);
                    }
                      completion:^(ISHShellExecutionResult *result) {
                          NSLog(@"Exit code: %d", result.exitCode);
                      }];
```

#### DebugServer（`app/DebugServer.c`）

HTTP 上的 JSON-RPC 服务器，用于 guest 内省:

```bash
# 列出文件
curl localhost:1234 -d '{"jsonrpc":"2.0","id":1,"method":"fs.readdir","params":{"path":"/usr/bin"}}'

# 执行命令
curl localhost:1234 -d '{"jsonrpc":"2.0","id":1,"method":"guest.exec","params":{"command":"python3 --version"}}'

# 查看进程
curl localhost:1234 -d '{"jsonrpc":"2.0","id":1,"method":"task.list"}'
```

#### Native Offload（`kernel/native_offload.c`）

完全绕过模拟，对注册的二进制直接由原生处理。guest 的 `execve()` 被拦截并路由到
原生 handler 或 host 二进制：

```c
// 注册 handler（启动时调用一次）
native_offload_add_handler("ffmpeg", ffmpeg_main);

// 现在 guest 的 `ffmpeg -i input.mp4 output.mp3` 会原生执行
// 参数中的 guest 路径自动转换为 host 路径
```

同时支持进程内 handler（iOS + macOS）和通过 `posix_spawn` 的委托（macOS CLI）。

#### Bind Mounts（`fs/fake.c`）

把 host 目录挂载到 guest 文件系统：

```c
// 只读 bind mount host 目录
fakefs_bind_mount("/host/path/to/data", "/mnt/data", /*read_only=*/true);
```

让 AI agent 能在 host app 与 Linux guest 之间共享文件而无需复制。

### 5. Rootfs 管理

- **Alpine 3.21 aarch64**，自带完整 apk 包管理器
- **RootfsPatch.bundle**: 增量 rootfs 更新的版本化 overlay 系统
- **Polyfills**: undici/llhttp 的 WebAssembly polyfill、HTTP 下载的 fetch polyfill
- **OPENSSL_armcap=0** 和 **GODEBUG/GOMAXPROCS** 在 `sys_execve` 中注入

---

## 构建配置

| Target | Scheme | xcconfig | Guest Arch | Bundle ID 后缀 |
|--------|--------|----------|------------|------------------|
| x86（原版） | iSH | `App.xcconfig` | i386 | — |
| ARM64 | iSH-ARM64 | `AppARM64.xcconfig` | aarch64 | `.arm64` |
| ARM64 + FFmpeg | iSH-ARM64-ffmpeg | `AppARM64-ffmpeg.xcconfig` | aarch64 | `.arm64` |

ARM64 target 直接链接 `build-arm64-release/` 中 meson 构建的库
（`libish.a`、`libish_emu.a`、`libfakefs.a`），避免 Xcode 自动发现 x86 的 library target。

```bash
# 构建 ARM64 CLI（macOS，测试用）
meson setup build-arm64-release -Dguest_arch=arm64 --buildtype=release
ninja -C build-arm64-release

# 运行
./build-arm64-release/ish -f ./alpine-arm64-fakefs /bin/sh
```

---

## 性能

使用 `benchmark/run.sh` 在 macOS 26.4.1 / Apple Silicon 上测试，采用 guest 内置计时
（排除启动开销）。完整数据见
**[benchmark/BENCHMARK_PERF.md](benchmark/BENCHMARK_PERF.md)**。

### 相对原生的开销（按负载类型）

| 类别 | x86/Native | ARM64/Native | **ARM64 vs x86** |
|---|:---:|:---:|:---:|
| C 纯计算 | 14-208x | 1-66x | **1.1-12.0x** |
| Shell 管道 | 57-305x | 3-42x | **5.3-7.2x** |
| Python | 12-201x | 3.8-169x | **3.8-10.2x** |
| Go 启动 | 10-26x | 2.5-3.1x | **2.5-3.1x** |
| Node.js | — | 1.6-20.8x | N/A（x86 不可用） |

### 亮点数据（计算密集型）

- **C `int_arith_2M`**: ARM64 比 x86 **快 12.0x**（65ms vs 782ms）
- **Python `sum(1M)`**: ARM64 **快 10.2x**（610ms vs 6200ms）
- **Python `fib(30)`**: ARM64 **快 9.2x**（1661ms vs 15219ms）
- **Shell `seq+awk 100K`**: ARM64 **快 7.2x**（882ms vs 6338ms）
- **C `matrix_64x64`** / **`mem_seq_4MB`**: ARM64 接近原生速度（仅 ~1.1-1.5x）

> **ARM64 为什么快**: 同架构 gadget 分派（每条 guest 指令只需对应 gadget 中的几条 host 指令）、完整 NEON + 加密扩展、
> 48-bit 地址空间支持 V8/Go/Rust，以及 Node.js 专项修复（V8 二进制补丁、守护页、`--jitless`
> 注入、io_uring syscall）—— 这些上游 x86 分支都没有。Node.js 22 在 x86 iSH 上无法运行
> （缺少 syscall 425 即 `io_uring_setup`）。

## 兼容性

205 项测试覆盖 18 个分类（基础 OS、文件操作、文本处理、构建、Python、Node.js、
Go/Rust/Perl/…、网络、VCS、编辑器、Shell、数据库、多媒体、加密、系统监控、调试、
包管理、信号）。两个架构在相同 fakefs 环境下安装相同软件包后测试。完整报告见
**[benchmark/BENCHMARK_COMPAT.md](benchmark/BENCHMARK_COMPAT.md)**。

| 架构 | 通过 | 失败 | 通过率 |
|---|:---:|:---:|:---:|
| **x86** (Jitter, threaded-code) | 201 | 4 | **98%** |
| **ARM64** (Asbestos, threaded-code) | 205 | 0 | **100%** |

**x86 的 4 项失败**均为模拟器真实限制（而非 benchmark bug）：
`automake`、`perl`（/dev/null 写入 quirk）、`go env`、`go compile`（32-bit 虚拟地址空间限制）。

---

## 支持的软件

### 完全可用

| 类别 | 示例 |
|------|------|
| **包管理器** | apk、pip、npm、npx、uv |
| **语言** | Python 3、Node.js 22、Go、Perl、Ruby、Lua |
| **开发工具** | git、curl、wget、ssh、vim、nano |
| **构建工具** | gcc、g++、cmake、make、meson |
| **数据工具** | sqlite3、jq、yt-dlp、ffmpeg（通过 native offload） |
| **网络** | curl、wget、dig、netstat、ss |
| **Node 框架** | Express、Koa、Fastify、Axios、Socket.io |
| **npm 生态** | lodash、moment、dayjs、uuid、chalk、commander、glob、semver |

### 不支持

- **GUI 应用**（无 X11/Wayland）
- **Docker / 容器**（无内核命名空间支持）
- **内核模块**（用户态模拟器）
- **硬件访问**（无 /dev/gpu、无 USB 透传）

---

## 提交历史

`feature-arm64` 分支上 86+ 提交，101+ 个文件变更，+23,000+ / -7,600+ 行。

主要里程碑:
1. **解释器基础**: fiber_enter/exit、基本块编译（到 gadget 程序）、TLB
2. **指令覆盖**: 200+ ARM64 指令含完整 NEON/Crypto
3. **48-bit 地址空间**: 4 级页表、惰性预留
4. **Node.js 支持**: V8 守护页、MAP_NORESERVE、二进制补丁、退出清理
5. **Go 支持**: 信号帧对齐、sigreturn 修复、NZCV 保留
6. **Rust/uv 支持**: FUTEX_WAIT_BITSET、PMULL、BFM、按需映射读取
7. **Agent 集成**: ISHShellExecutor、DebugServer、Native Offload、Bind Mounts
8. **稳定性**: 50+ 个 bug 修复（并发、内存泄漏、use-after-free、死锁）

---

## 工程结构

```
iSH/
├── asbestos/                    # ARM64 threaded-code 解释器
│   ├── asbestos.c/h             # 块缓存、RCU 清理
│   └── guest-arm64/
│       ├── gen.c                # 指令解码器 → gadgets
│       ├── crypto_helpers.c     # AES/SHA/CRC32 helpers
│       └── gadgets-aarch64/     # 汇编 gadgets
│           ├── entry.S          # Fiber 入口/退出、崩溃 handler
│           ├── memory.S         # Load/store、TLB 内联查找
│           ├── control.S        # 分支、条件
│           ├── math.S           # ALU、移位、NEON/SIMD
│           ├── crypto.S         # AES、SHA、PMULL、CRC32
│           ├── bits.S           # 位域操作
│           └── gadgets.h        # 寄存器映射、TLB 宏
├── emu/
│   ├── tlb.c/h                  # TLB miss 处理、跨页
│   └── arch/arm64/
│       ├── cpu.h                # CPU 状态（寄存器、NEON、flags）
│       └── decode.h             # 指令字段提取
├── kernel/
│   ├── arch/arm64/calls.c       # ARM64 syscall 表
│   ├── memory.c/h               # 页表、CoW、缺页
│   ├── mmap.c                   # mmap、惰性预留
│   ├── native_offload.c/h       # 二进制 offload 系统
│   ├── signal.c/h               # 信号投递/帧
│   ├── futex.c                  # 基于 pipe 唤醒的 futex
│   ├── exec.c                   # ELF 加载器、V8 守护页
│   └── exit.c                   # 线程清理、safety valve
├── fs/
│   ├── fake.c/h                 # fakefs + bind mount
│   ├── real.c                   # Host 文件系统访问
│   ├── sock.c/h                 # Socket 模拟
│   └── poll.c                   # epoll/poll/select
├── app/
│   ├── AppARM64.xcconfig        # ARM64 构建配置
│   ├── GuestARM64.xcconfig      # Guest 架构定义
│   ├── ISHShellExecutor.h/m     # Shell 执行 API
│   ├── DebugServer.c/h          # JSON-RPC 调试服务
│   └── RootfsPatch.bundle/      # 版本化 rootfs overlay
└── benchmark/
    ├── run.sh                   # 统一入口
    ├── assets/                  # 测试脚本和预编译二进制
    ├── BENCHMARK_PERF.md        # 性能报告
    └── BENCHMARK_COMPAT.md      # 兼容性报告
```

---

## 许可

与上游 iSH 相同。见 [LICENSE](LICENSE)。
