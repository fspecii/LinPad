#!/bin/sh
# Guest-side benchmark — runs INSIDE iSH, measures with /proc/uptime
# Outputs: "category|name|milliseconds" per line
# No eval, no bash-isms — pure POSIX sh

# Millisecond timer: prefer date +%s%N (nanosecond), fall back to /proc/uptime (centisecond)
if date +%s%N >/tmp/_null 2>&1 && [ "$(date +%N)" != "%N" ] && [ "$(date +%N)" != "N" ]; then
    _ms() { echo $(( $(date +%s%N) / 1000000 )); }
else
    _ms() { awk '{printf "%.0f", $1 * 1000}' /proc/uptime; }
fi

_t0=0
_start() { _t0=$(_ms); }
_end()   { local t1; t1=$(_ms); echo "$1|$2|$(( t1 - _t0 ))"; }

# ── System ──────────────────────────────────────────────────
_start; echo Hello World >/tmp/_null 2>&1;                    _end System "echo"
_start; uname -a >/tmp/_null 2>&1;                            _end System "uname -a"
_start; ls /bin >/tmp/_null 2>&1;                             _end System "ls /bin"
_start; cat /etc/os-release >/tmp/_null 2>&1;                 _end System "cat file"
_start; ls /bin | wc -l >/tmp/_null 2>&1;                     _end System "wc -l"
_start; date >/tmp/_null 2>&1;                                _end System "date"
_start; env >/tmp/_null 2>&1;                                 _end System "env"

# ── Compute ─────────────────────────────────────────────────
_start; i=0; while [ $i -lt 1000 ]; do i=$((i+1)); done;    _end Compute "loop 1000"
_start; i=0; while [ $i -lt 5000 ]; do i=$((i+1)); done;    _end Compute "loop 5000"
_start; i=0; while [ $i -lt 10000 ]; do i=$((i+1)); done;   _end Compute "loop 10000"
_start; seq 1 10000 | awk '{s+=$1} END{print s}' >/tmp/_null 2>&1;  _end Compute "seq+awk 10K"
_start; seq 1 50000 | awk '{s+=$1} END{print s}' >/tmp/_null 2>&1;  _end Compute "seq+awk 50K"
_start; seq 1 100000 | awk '{s+=$1} END{print s}' >/tmp/_null 2>&1; _end Compute "seq+awk 100K"
_start; i=0; while [ $i -lt 500 ]; do i=$(expr $i + 1); done;     _end Compute "expr loop 500"
_start; echo 'scale=100; sqrt(2)' | bc -l >/tmp/_null 2>&1;  _end Compute "bc sqrt"
_start; echo 'scale=50; 4*a(1)' | bc -l >/tmp/_null 2>&1;    _end Compute "bc pi"

# ── Text ────────────────────────────────────────────────────
_start; echo hello | sed 's/hello/world/g' >/tmp/_null 2>&1;  _end Text "sed replace"
_start; seq 1 1000 | sort -nr | tail -1 >/tmp/_null 2>&1;    _end Text "sort 1K"
_start; seq 1 5000 | sort -nr | tail -1 >/tmp/_null 2>&1;    _end Text "sort 5K"
_start; seq 1 500 | sort | uniq -c | wc -l >/tmp/_null 2>&1; _end Text "uniq count"
_start; seq 1 10000 | grep -c 5 >/tmp/_null 2>&1;            _end Text "grep count"
_start; seq 1 1000 | tr '0-9' 'a-j' | wc -l >/tmp/_null 2>&1; _end Text "tr lowercase"

# ── File I/O ────────────────────────────────────────────────
_start; for i in $(seq 1 50); do echo x > /tmp/_b$i; done; rm -f /tmp/_b*;  _end File-IO "create 50"
_start; for i in $(seq 1 200); do echo x > /tmp/_b$i; done; rm -f /tmp/_b*; _end File-IO "create 200"
_start; find /bin -type f 2>/tmp/_null | wc -l >/tmp/_null;    _end File-IO "find /bin"
_start; dd if=/dev/zero of=/tmp/_dd bs=1024 count=64 2>/tmp/_null; rm -f /tmp/_dd; _end File-IO "dd 64K"

# ── Crypto ──────────────────────────────────────────────────
_start; echo test | md5sum >/tmp/_null 2>&1;                  _end Crypto "md5sum"
_start; echo test | sha256sum >/tmp/_null 2>&1;               _end Crypto "sha256sum"

# ── Process ─────────────────────────────────────────────────
_start; for i in $(seq 1 10); do /bin/true; done;            _end Process "fork+exec 10"
_start; for i in $(seq 1 50); do /bin/true; done;            _end Process "fork+exec 50"
_start; seq 1 1000 | grep 5 | sort -n | wc -l >/tmp/_null 2>&1; _end Process "pipe chain"

# ── Python (if available) ──────────────────────────────────
if command -v python3 >/tmp/_null 2>&1; then
    _start; python3 -c 'pass';                               _end Python "startup"
    _start; python3 -c 'print(sum(range(1000000)))' >/tmp/_null; _end Python "sum(1M)"
    _start
    python3 -c '
def f(n):
 if n<2: return n
 return f(n-1)+f(n-2)
print(f(30))' >/tmp/_null
    _end Python "fib(30)"

    _start
    python3 -c '
s=""
for i in range(10000): s+=str(i)
print(len(s))' >/tmp/_null
    _end Python "str concat 10K"

    _start
    python3 -c '
import json
d=[{"id":i,"v":i*3.14} for i in range(5000)]
for _ in range(5): d=json.loads(json.dumps(d))
print(len(d))' >/tmp/_null
    _end Python "json roundtrip"

    _start; python3 -c 'import hashlib; print(hashlib.sha256(b"x"*1000000).hexdigest()[:8])' >/tmp/_null; _end Python "sha256 1MB"

    _start
    python3 -c '
import re
t="abc123def456"*5000
print(len(re.findall(r"\d+",t)))' >/tmp/_null
    _end Python "regex 50K"

    _start
    python3 -c '
import random; random.seed(42)
a=[random.randint(0,999999) for _ in range(100000)]
a.sort()
print(a[0])' >/tmp/_null
    _end Python "sort 100K"
fi

# ── Node.js (if available) ─────────────────────────────────
if command -v node >/tmp/_null 2>&1; then
    _start; node -e 'process.exit(0)';                       _end Node.js "startup"
    _start; node -e 'let s=0;for(let i=0;i<1e6;i++)s+=i;console.log(s)' >/tmp/_null; _end Node.js "sum 1M"
    _start
    node -e '
const d=Array.from({length:10000},(_,i)=>({id:i,v:i*3.14}));
for(let r=0;r<5;r++)JSON.parse(JSON.stringify(d));
console.log(d.length)' >/tmp/_null
    _end Node.js "JSON 10K"
    _start; node -e 'console.log(require("crypto").createHash("sha256").update("x".repeat(1000000)).digest("hex").slice(0,8))' >/tmp/_null; _end Node.js "sha256"
fi

# ── C benchmark (prefer pre-compiled binary, fallback to gcc) ──
# Prebuilt binaries pushed to /tmp/cbench_prebuilt by the host runner.
# On native macOS, the script directory is probed for cbench_lite_macos.
_cbench=""
_script_dir=$(dirname "$0" 2>/dev/null)
if [ -x /tmp/cbench_prebuilt ]; then
    _cbench=/tmp/cbench_prebuilt
elif [ -x "$_script_dir/cbench_lite_macos" ]; then
    _cbench="$_script_dir/cbench_lite_macos"
elif command -v gcc >/tmp/_null 2>&1 && [ -f /tmp/cbench_lite.c ]; then
    _start; gcc -O2 -o /tmp/cbench_compiled /tmp/cbench_lite.c -lm 2>/tmp/_null; _end C "gcc compile"
    [ -x /tmp/cbench_compiled ] && _cbench=/tmp/cbench_compiled
fi
if [ -n "$_cbench" ]; then
    $_cbench 2>/tmp/_null | while IFS= read -r line; do
        name=$(echo "$line" | awk '{print $1}')
        ms=$(echo "$line" | awk '{print $2}')
        [ -n "$name" ] && [ -n "$ms" ] && echo "C|$name|$ms"
    done
fi

# ── Go (if available) ──────────────────────────────────────
if command -v go >/tmp/_null 2>&1; then
    _start; go version >/tmp/_null 2>&1;                      _end Go "version"
    _start; go env GOROOT >/tmp/_null 2>&1;                   _end Go "env"
fi
