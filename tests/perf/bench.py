#!/usr/bin/env python3
"""CLI benchmark suite for iSH-ARM64.

Each run is a fresh `ish` process. Records wall time and CPU time (user+sys of
the ish process tree, from getrusage); CPU time is the primary metric because
it is far less sensitive to other load on the machine. With several binaries,
runs are interleaved (A B A B ...) so drift in machine load hits all equally.

  FAKEFS=/path/fakefs python3 tests/perf/bench.py [-n 5] [-o out.json] \
      --ish name=path [--ish name2=path2] [benchmark names...]

Guest setup (once): apk add python3 sqlite; /root/vt/app = `npm create vite`
vanilla template (npm i done); /root/bts/app = react-ts template (npm i done);
/root/b100 = 100 MB from /dev/urandom; /tmp/test.html = the CSS+JS test page.
"""
import json, os, resource, statistics, subprocess, sys, time

BENCH = [
    ("node_start", "node -e 0"),
    ("node_loop", "node -e 'let s=0;for(let i=0;i<5e7;i++)s+=i%7;'"),
    ("vite_build", "cd /root/vt/app && npx vite build > /dev/null"),
    ("tsc", "cd /root/bts/app && npx tsc --noEmit -p tsconfig.app.json"),
    ("jsc_fib", "Malloc=1 /usr/libexec/webkit2gtk-4.1/jsc -e 'function f(n){return n<2?n:f(n-1)+f(n-2)} f(27)'"),
    ("py_fib", "python3 -c 'f=lambda n: n if n<2 else f(n-1)+f(n-2); f(25)'"),
    ("gzip100", "gzip -1 -c /root/b100 > /dev/null"),
    ("sha256_100", "sha256sum /root/b100 > /dev/null"),
    ("sqlite", "rm -f /tmp/b.db; sqlite3 /tmp/b.db 'create table t(a,b); begin; with recursive c(x) as (select 1 union all select x+1 from c where x<200000) insert into t select x, hex(randomblob(16)) from c; commit; create index i on t(b); select count(*) from t;' > /dev/null"),
    ("firefox_headless", "mkdir -p /dev/shm; rm -rf /tmp/ffb; mkdir /tmp/ffb; MOZ_CRASHREPORTER_DISABLE=1 MOZ_HEADLESS=1 /usr/lib/firefox-esr/firefox-esr --headless --no-remote --profile /tmp/ffb --screenshot /tmp/ffb.png file:///tmp/test.html > /dev/null 2>&1; test -s /tmp/ffb.png"),
    ("claude_help", "HOME=/root claude --help > /dev/null"),
    # Long-lived processes that have received a signal (SIGCHLD from a child, a
    # handled SIGUSR2): shells, dev servers, editors.
    ("sh_loop", "/bin/true; i=0; while [ $i -lt 300000 ]; do i=$((i+1)); done"),
    ("node_sig_loop", "node -e 'process.on(\"SIGUSR2\",()=>{}); process.kill(process.pid,\"SIGUSR2\"); setTimeout(()=>{let s=0;for(let i=0;i<5e7;i++)s+=i%7;},10)'"),
]

def run(ish, fakefs, cmd):
    r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    t = time.perf_counter()
    r = subprocess.run(["timeout", "900", ish, "-f", fakefs, "/bin/sh", "-c", cmd],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wall = time.perf_counter() - t
    r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (r1.ru_utime - r0.ru_utime) + (r1.ru_stime - r0.ru_stime)
    return wall, cpu, r.returncode == 0

def main():
    args = sys.argv[1:]
    n, out, ishes = 5, None, []
    while args and args[0].startswith("-"):
        a = args.pop(0)
        if a == "-n": n = int(args.pop(0))
        elif a == "-o": out = args.pop(0)
        elif a == "--ish": k, v = args.pop(0).split("=", 1); ishes.append((k, v))
    fakefs = os.environ["FAKEFS"]
    names = args or [b[0] for b in BENCH]
    res = {"load_before": os.getloadavg(), "ish": dict(ishes)}
    for name, cmd in BENCH:
        if name not in names: continue
        data = {k: {"wall": [], "cpu": [], "ok": True} for k, _ in ishes}
        for _ in range(n):
            for k, path in ishes:
                w, c, ok = run(path, fakefs, cmd)
                data[k]["wall"].append(w); data[k]["cpu"].append(c); data[k]["ok"] &= ok
        line = f"{name:17s}"
        for k, _ in ishes:
            d = data[k]
            d["wall_med"], d["cpu_med"] = statistics.median(d["wall"]), statistics.median(d["cpu"])
            line += f"  {k}: cpu {d['cpu_med']:7.2f}s wall {d['wall_med']:7.2f}s{'' if d['ok'] else ' FAIL'}"
        print(line + f"  load={os.getloadavg()[0]:.0f}", flush=True)
        res[name] = data
    res["load_after"] = os.getloadavg()
    if out: json.dump(res, open(out, "w"), indent=1)

main()
