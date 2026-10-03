#!/bin/sh
# Firefox stability soak on the Mac CLI emulator (guest/ffsoak.py): real sites in a loop,
# tabs, back/forward, YouTube playback, under an emulated iPad memory limit.
#
#   devtools/bench/ffsoak.sh setup FAKEFS [ROOTFS.tar.gz]
#       FAKEFS from the release rootfs (default release/out/ish-linux-rootfs-arm64.tar.gz)
#       plus python3 (the driver).
#   devtools/bench/ffsoak.sh run FAKEFS OUTDIR
#       One soak per memory limit and engine -> OUTDIR/soak-mem<MB>-jit<J>.{json,log,host.log}
#       and OUTDIR/summary.txt. Each run works on FAKEFS.run, a fresh clone. If the
#       emulator itself dies, it is counted and the soak goes on until MINUTES are over.
#
# Environment: ISH (default build-arm64-release/ish), MEMLIMITS ("2500 3000", MB, through
# ISH_MEM_LIMIT_MB; "0" for none), JITS ("1 0"), MINUTES (30), MINIDUMPS (1: crash
# reporter on, minidumps kept in OUTDIR), JIT_CACHE_MB (256, the iPad's default code
# cache; the Mac's default is 512), FFSOAK_ARGS. OUTDIR/<name>.footprint has the host
# footprint every 10 s.
# Firefox processes that die are found three ways: Firefox's own log, the kernel's crash
# log on the host's stderr (ISH_CRASHLOG=1: process, signal, pc/lr as library+offset,
# last syscalls), and relaunches of a dead parent.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
ISH=${ISH:-$REPO/build-arm64-release/ish}
MEMLIMITS=${MEMLIMITS:-"2500 3000"}
JITS=${JITS:-"1 0"}
MINUTES=${MINUTES:-30}

guest() {  # guest FAKEFS JIT CMD...
    f=$1 j=$2; shift 2
    ISH_JIT=$j "$ISH" -f "$f" /bin/sh -lc "$*"
}

cmd_setup() {
    f=$1 tgz=${2:-$REPO/release/out/ish-linux-rootfs-arm64.tar.gz}
    [ -e "$f" ] && { echo "ffsoak: $f exists" >&2; exit 1; }
    "$(dirname "$ISH")/tools/fakefsify" "$tgz" "$f"
    guest "$f" 1 'apk add --no-progress python3 >/tmp/apk.log 2>&1 || { tail /tmp/apk.log; exit 1; }' </dev/null
    echo "ffsoak: $f ready"
}

copy_scripts() {
    tar cf - -C "$HERE/guest" ffbench.py ffsoak.py pages | guest "$1" 1 'mkdir -p /root/bench && cd /root/bench && tar xf -'
}

run_one() {  # FAKEFS OUTDIR MEM JIT
    src=$1 out=$2 mem=$3 j=$4
    name=soak-mem$mem-jit$j
    f=$src.run
    rm -rf "$f"
    cp -cR "$src" "$f" 2>/dev/null || cp -R "$src" "$f"
    copy_scripts "$f"
    : >"$out/$name.log"
    : >"$out/$name.host.log"
    end=$(( $(date +%s) + MINUTES * 60 ))
    emu_deaths=0 part=0
    while [ "$(date +%s)" -lt $((end - 60)) ]; do
        part=$((part + 1))
        left=$(( (end - $(date +%s)) / 60 ))
        rm -f "$f/data/root/bench/out.json"
        rc=0
        env ISH_CRASHLOG=${ISH_CRASHLOG:-1} ISH_MEM_LIMIT_MB=$mem ISH_JIT=$j ISH_JIT_CACHE_MB=${JIT_CACHE_MB:-256} \
            ISH_JIT_PCACHE_DIR="$src.pcache" \
            "$ISH" -f "$f" /bin/sh -lc "cd /root/bench && python3 ffsoak.py /root/bench/out.json --minutes $left \
                $([ "${MINIDUMPS:-1}" = 1 ] && echo --minidumps) ${FFSOAK_ARGS:-}" \
            </dev/null >>"$out/$name.log" 2>>"$out/$name.host.log" &
        epid=$!
        # the host footprint every 10 s (what an iPad's memory limit is measured against)
        sleep 3
        ipid=$(pgrep -n -f "^$ISH -f $f" || true)
        while kill -0 $epid 2>/dev/null; do
            [ -n "$ipid" ] && footprint -p "$ipid" 2>/dev/null | sed -n "s/.*Footprint: \([0-9.]*\) \([KMG]B\).*/$(date +%s) \1 \2/p" \
                >>"$out/$name.footprint" || true
            sleep 10
        done
        wait $epid || rc=$?
        cp "$f/data/root/bench/out.json" "$out/$name-part$part.json" 2>/dev/null || true
        if [ -d "$f/data/root/bench/minidumps" ]; then
            mkdir -p "$out/$name-minidumps" && cp "$f"/data/root/bench/minidumps/* "$out/$name-minidumps/" 2>/dev/null || true
        fi
        if grep -q "HOST CRASH" "$out/$name.host.log" 2>/dev/null &&
                [ "$(grep -c 'HOST CRASH' "$out/$name.host.log")" -gt "$emu_deaths" ]; then
            emu_deaths=$(grep -c 'HOST CRASH' "$out/$name.host.log")
            echo "ffsoak: emulator died (rc=$rc), restarting" >>"$out/$name.host.log"
        elif [ -f "$out/$name-part$part.json" ]; then
            break
        else
            echo "ffsoak: ish exited rc=$rc without a result, restarting" >>"$out/$name.host.log"
        fi
    done
    python3 - "$out" "$name" "$emu_deaths" <<'EOF' | tee -a "$out/summary.txt"
import collections, glob, json, re, sys
out, name, emu = sys.argv[1], sys.argv[2], int(sys.argv[3])
tot = collections.Counter()
yt = []
for p in sorted(glob.glob(f"{out}/{name}-part*.json")):
    r = json.load(open(p))
    for k in ("iterations", "loads", "load_errors", "relaunches", "tab_crashes", "child_deaths"):
        tot[k] += r.get(k, 0)
    yt += r.get("youtube_played_s", [])
    if r.get("fatal"):
        tot["driver_fatal"] += 1
host = open(f"{out}/{name}.host.log", errors="replace").read()
peak = 0
try:
    for l in open(f"{out}/{name}.footprint"):
        t, v, u = l.split()
        mb = float(v) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[u]
        peak = max(peak, mb)
except OSError:
    pass
crashes = [l for l in host.splitlines() if l.startswith("ish crash: pid")]
by = collections.Counter()
for l in crashes:
    m = re.match(r"ish crash: pid \d+ tgid \d+ \((.*?)\) signal (\d+)", l)
    if m:
        by[f"{m.group(1)}/sig{m.group(2)}"] += 1
print(f"{name}: iterations={tot['iterations']} loads={tot['loads']} load_errors={tot['load_errors']}"
      f" | parent_deaths={tot['relaunches']} child_deaths={tot['child_deaths']} tab_crashes={tot['tab_crashes']}"
      f" kernel_crash_log={len(crashes)} {dict(by)} emulator_aborts={emu}"
      f" driver_fatal={tot['driver_fatal']} peak_footprint={peak:.0f}MB youtube_played={yt}")
EOF
}

cmd_run() {
    f=$1 out=$2
    mkdir -p "$out"
    for mem in $MEMLIMITS; do
        for j in $JITS; do
            echo "== $(date '+%H:%M') mem=$mem jit=$j load $(sysctl -n vm.loadavg)" >>"$out/summary.txt"
            run_one "$f" "$out" "$mem" "$j"
        done
    done
}

case ${1:-} in
    setup) shift; cmd_setup "$@" ;;
    run) shift; cmd_run "$@" ;;
    *) sed -n '2,20p' "$0" >&2; exit 2 ;;
esac
