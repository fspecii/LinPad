#!/bin/sh
# Low-memory scenarios on the Mac CLI emulator under an emulated iPad memory limit.
#
#   devtools/bench/lowmem.sh run FAKEFS OUTDIR [SCENARIO...]
#       SCENARIO: idle ff5 ffcode yt720 ffcodeyt (default: the first four). Each runs on a fresh clone
#       of FAKEFS (FAKEFS.run) with guest/lowmem.py, while memsample records the host
#       footprint every 250 ms. Writes OUTDIR/<TAG>-<scenario>-mem<MB>.{json,tsv,log}
#       and appends a line to OUTDIR/summary.txt: peak footprint, how many times the
#       footprint reached the limit (each one a jetsam kill on the iPad), guest kills by
#       the OOM monitor, guest processes that died, MB written to disk.
#
# FAKEFS needs python3 (ffbench.py's Marionette client) and, for ffcode, VS Code
# (`linpad-apps install vscode`). Environment: ISH (emulator), TAG (label, default the
# binary's name), MEMLIMIT (2500, MB, as ISH_MEM_LIMIT_MB), JIT (1), and anything else
# the emulator reads (ISH_OOM, ISH_SWAPFILE, ...) is passed through.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
ISH=${ISH:-$REPO/build-lowmem/ish}
TAG=${TAG:-$(basename "$ISH")}
MEMLIMIT=${MEMLIMIT:-2500}
JIT=${JIT:-1}
SAMPLER=${SAMPLER:-${TMPDIR:-/tmp}/ish-memsample}
# The JIT code cache the iPad picks for this allowance (jit/codemem.c: 128 MB when
# less than 3 GB is available at start); the Mac default is 512 MB.
export ISH_JIT_CACHE_MB=${ISH_JIT_CACHE_MB:-128}

[ -x "$SAMPLER" ] || clang -O2 -o "$SAMPLER" "$HERE/memsample.c"

run_one() {  # FAKEFS OUTDIR SCENARIO
    src=$1 out=$2 sc=$3
    name=$TAG-$sc-mem$MEMLIMIT
    f=$src.run
    rm -rf "$f"
    cp -cR "$src" "$f" 2>/dev/null || cp -R "$src" "$f"
    tar cf - -C "$HERE/guest" lowmem.py ffbench.py pages |
        ISH_JIT=1 "$ISH" -f "$f" /bin/sh -c 'mkdir -p /root/bench && cd /root/bench && tar xf -'
    start=$(date +%s)
    ISH_MEM_LIMIT_MB=$MEMLIMIT ISH_JIT=$JIT "$ISH" -f "$f" /bin/sh -lc \
        "timeout 900 python3 /root/bench/lowmem.py $sc /root/bench/out.json" >"$out/$name.log" 2>&1 &
    pid=$!
    "$SAMPLER" "$pid" 250 "$MEMLIMIT" >"$out/$name.tsv" 2>"$out/$name.sample"
    rc=0
    wait "$pid" || rc=$?
    cp "$f/data/root/bench/out.json" "$out/$name.json" 2>/dev/null || echo '{}' >"$out/$name.json"
    python3 - "$out/$name.json" "$out/$name.sample" "$out/$name.log" "$rc" "$(($(date +%s) - start))" \
        "$name" "$(uptime | sed 's/.*averages*: //')" >>"$out/summary.txt" <<'EOF'
import json, re, sys
res = json.load(open(sys.argv[1]))
sample = open(sys.argv[2]).read()
log = open(sys.argv[3], errors="replace").read()
peak = re.search(r"peak (\d+) MB", sample)
kills = re.search(r"would-be kills (\d+)", sample)
disk = re.search(r"disk written (\d+) MB", sample)
oom = len(res.get("dmesg_oom", [])) or log.count("Out of memory: Killed")
crashes = len(re.findall(r"exited on signal|mozalloc_abort|out of memory|Segmentation fault", log, re.I))
print(f"{sys.argv[6]}: rc={sys.argv[4]} secs={sys.argv[5]} peak={peak and peak[1]}MB "
      f"jetsam_kills={kills and kills[1]} oom_kills={oom} errors={res.get('errors')} "
      f"firefox_alive={res.get('firefox_alive')} crash_lines={crashes} disk_written={disk and disk[1]}MB "
      f"died={len(res.get('died', []))} load={sys.argv[7]}")
EOF
    tail -1 "$out/summary.txt"
    rm -rf "$f"
}

cmd_run() {
    src=$1 out=$2
    shift 2
    mkdir -p "$out"
    [ $# -gt 0 ] || set -- idle ff5 ffcode yt720
    for sc in "$@"; do
        run_one "$src" "$out" "$sc"
    done
}

case "${1:-}" in
    run) shift; cmd_run "$@" ;;
    *) sed -n '2,18p' "$0" >&2; exit 2 ;;
esac
