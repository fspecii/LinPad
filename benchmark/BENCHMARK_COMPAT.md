# iSH Compatibility: x86 vs ARM64

> **Generated:** 2026-04-18 15:20:20 | **Tests:** 205 | **Host:** macOS 26.4.1
>
> Both architectures use **fakefs** mode with virtual device nodes.
> x86 rootfs = Alpine x86 minirootfs (busybox only)
> ARM64 rootfs = Alpine aarch64 full rootfs (apk, python3, node, gcc, go, etc.)
>
> All tests attempt to run on both architectures. x86 failures in the
> software/language categories reflect genuine 32-bit architecture limitations
> (no python3/node/gcc packages available for i386, or runtime VA requirements).

| Architecture | Pass | Fail | Rate |
|:---:|:---:|:---:|:---:|
| **x86** (Jitter) | 201 | 4 | **98%** |
| **ARM64** (Asbestos JIT) | 205 | 0 | **100%** |

---

### Core (28 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| ls | PASS | PASS |
| cat | PASS | PASS |
| echo | PASS | PASS |
| grep | PASS | PASS |
| sed | PASS | PASS |
| awk | PASS | PASS |
| wc | PASS | PASS |
| sort | PASS | PASS |
| uniq | PASS | PASS |
| head | PASS | PASS |
| tail | PASS | PASS |
| cut | PASS | PASS |
| tr | PASS | PASS |
| tee | PASS | PASS |
| xargs | PASS | PASS |
| find | PASS | PASS |
| which | PASS | PASS |
| whoami | PASS | PASS |
| pwd | PASS | PASS |
| basename | PASS | PASS |
| dirname | PASS | PASS |
| date | PASS | PASS |
| sleep | PASS | PASS |
| yes | PASS | PASS |
| seq | PASS | PASS |
| expr | PASS | PASS |
| env | PASS | PASS |
| printenv | PASS | PASS |

> x86: 28/28 — ARM64: 28/28

### FileOps (22 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| cp | PASS | PASS |
| mv | PASS | PASS |
| rm | PASS | PASS |
| mkdir | PASS | PASS |
| touch | PASS | PASS |
| chmod | PASS | PASS |
| ln -s | PASS | PASS |
| readlink | PASS | PASS |
| stat | PASS | PASS |
| file | PASS | PASS |
| du | PASS | PASS |
| df | PASS | PASS |
| dd | PASS | PASS |
| truncate | PASS | PASS |
| split | PASS | PASS |
| tar | PASS | PASS |
| gzip | PASS | PASS |
| bzip2 | PASS | PASS |
| xz | PASS | PASS |
| zstd | PASS | PASS |
| sync | PASS | PASS |
| rsync | PASS | PASS |

> x86: 22/22 — ARM64: 22/22

### TextProc (16 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| diff | PASS | PASS |
| fold | PASS | PASS |
| nl | PASS | PASS |
| rev | PASS | PASS |
| strings | PASS | PASS |
| hexdump | PASS | PASS |
| od | PASS | PASS |
| base64 | PASS | PASS |
| iconv | PASS | PASS |
| fmt | PASS | PASS |
| column | PASS | PASS |
| numfmt | PASS | PASS |
| comm | PASS | PASS |
| shuf | PASS | PASS |
| jq | PASS | PASS |
| bc | PASS | PASS |

> x86: 16/16 — ARM64: 16/16

### Build (18 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| gcc | PASS | PASS |
| g++ | PASS | PASS |
| cc | PASS | PASS |
| make | PASS | PASS |
| cmake | PASS | PASS |
| ld | PASS | PASS |
| as | PASS | PASS |
| ar | PASS | PASS |
| nm | PASS | PASS |
| objdump | PASS | PASS |
| strip | PASS | PASS |
| readelf | PASS | PASS |
| pkg-config | PASS | PASS |
| autoconf | PASS | PASS |
| automake | FAIL | PASS |
| bison | PASS | PASS |
| flex | PASS | PASS |
| m4 | PASS | PASS |

> x86: 17/18 — ARM64: 18/18

### Python (20 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| python3 | PASS | PASS |
| pip3 | PASS | PASS |
| pip list | PASS | PASS |
| import os | PASS | PASS |
| import json | PASS | PASS |
| import re | PASS | PASS |
| import math | PASS | PASS |
| import sqlite3 | PASS | PASS |
| import hashlib | PASS | PASS |
| import socket | PASS | PASS |
| import datetime | PASS | PASS |
| import venv | PASS | PASS |
| import csv | PASS | PASS |
| import subprocess | PASS | PASS |
| import pathlib | PASS | PASS |
| import tempfile | PASS | PASS |
| import argparse | PASS | PASS |
| async/await | PASS | PASS |
| dataclass | PASS | PASS |
| http.server | PASS | PASS |

> x86: 20/20 — ARM64: 20/20

### Node.js (18 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| node | PASS | PASS |
| npm | PASS | PASS |
| console.log | PASS | PASS |
| require fs | PASS | PASS |
| require path | PASS | PASS |
| require os | PASS | PASS |
| require crypto | PASS | PASS |
| require http | PASS | PASS |
| require url | PASS | PASS |
| require zlib | PASS | PASS |
| require stream | PASS | PASS |
| require events | PASS | PASS |
| Promise | PASS | PASS |
| async/await | PASS | PASS |
| Buffer | PASS | PASS |
| JSON parse | PASS | PASS |
| Map/Set | PASS | PASS |
| RegExp | PASS | PASS |

> x86: 18/18 — ARM64: 18/18

### Lang (10 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| perl | FAIL | PASS |
| ruby | PASS | PASS |
| php | PASS | PASS |
| lua | PASS | PASS |
| bash | PASS | PASS |
| ash | PASS | PASS |
| go version | PASS | PASS |
| go env | FAIL | PASS |
| go compile | FAIL | PASS |
| clang | PASS | PASS |

> x86: 7/10 — ARM64: 10/10

### Network (14 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| curl | PASS | PASS |
| wget | PASS | PASS |
| ssh | PASS | PASS |
| scp | PASS | PASS |
| ping | PASS | PASS |
| netstat | PASS | PASS |
| ss | PASS | PASS |
| nslookup | PASS | PASS |
| dig | PASS | PASS |
| nc | PASS | PASS |
| socat | PASS | PASS |
| ip | PASS | PASS |
| ifconfig | PASS | PASS |
| openssl | PASS | PASS |

> x86: 14/14 — ARM64: 14/14

### VCS (5 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| git | PASS | PASS |
| git init | PASS | PASS |
| hg | PASS | PASS |
| svn | PASS | PASS |
| git config | PASS | PASS |

> x86: 5/5 — ARM64: 5/5

### Editor (6 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| vi | PASS | PASS |
| vim | PASS | PASS |
| nano | PASS | PASS |
| ed | PASS | PASS |
| sed -i | PASS | PASS |
| awk script | PASS | PASS |

> x86: 6/6 — ARM64: 6/6

### Shell (6 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| bash | PASS | PASS |
| ash | PASS | PASS |
| screen | PASS | PASS |
| tmux | PASS | PASS |
| timeout | PASS | PASS |
| time | PASS | PASS |

> x86: 6/6 — ARM64: 6/6

### DB (5 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| sqlite3 | PASS | PASS |
| sqlite3 query | PASS | PASS |
| redis-cli | PASS | PASS |
| psql | PASS | PASS |
| mariadb | PASS | PASS |

> x86: 5/5 — ARM64: 5/5

### Media (6 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| ffmpeg | PASS | PASS |
| ffprobe | PASS | PASS |
| convert | PASS | PASS |
| identify | PASS | PASS |
| sox | PASS | PASS |
| gm | PASS | PASS |

> x86: 6/6 — ARM64: 6/6

### Crypto (8 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| openssl enc | PASS | PASS |
| sha256sum | PASS | PASS |
| sha512sum | PASS | PASS |
| md5sum | PASS | PASS |
| gpg | PASS | PASS |
| ssh-keygen | PASS | PASS |
| base64 enc | PASS | PASS |
| /dev/urandom | PASS | PASS |

> x86: 8/8 — ARM64: 8/8

### SysMon (8 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| ps | PASS | PASS |
| free | PASS | PASS |
| uptime | PASS | PASS |
| /proc/meminfo | PASS | PASS |
| /proc/cpuinfo | PASS | PASS |
| /proc/version | PASS | PASS |
| /dev/null | PASS | PASS |
| /dev/zero | PASS | PASS |

> x86: 8/8 — ARM64: 8/8

### Debug (8 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| strace | PASS | PASS |
| ldd | PASS | PASS |
| gdb | PASS | PASS |
| lsof | PASS | PASS |
| objdump | PASS | PASS |
| valgrind | PASS | PASS |
| ltrace | PASS | PASS |
| perf | PASS | PASS |

> x86: 8/8 — ARM64: 8/8

### PkgMgr (3 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| apk | PASS | PASS |
| pip3 | PASS | PASS |
| npm | PASS | PASS |

> x86: 3/3 — ARM64: 3/3

### Signal (4 tests)

| Test | x86 | ARM64 |
|------|:---:|:---:|
| trap | PASS | PASS |
| kill | PASS | PASS |
| wait | PASS | PASS |
| bg job | PASS | PASS |

> x86: 4/4 — ARM64: 4/4

---

## Failures

### x86 only

- `automake` (Build)
- `perl` (Lang)
- `go env` (Lang)
- `go compile` (Lang)

### ARM64 only

_None_
