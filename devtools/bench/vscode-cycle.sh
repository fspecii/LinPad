#!/bin/sh
# VS Code cycle on the Mac CLI emulator: start, open a folder, TypeScript ready, typing,
# integrated terminal, an Open VSX extension, the git panel, quit (guest/vscodebench.py).
#
#   devtools/bench/vscode-cycle.sh setup FAKEFS [ROOTFS.tar.gz]
#       Make FAKEFS from the release rootfs (default release/out/ish-linux-rootfs-arm64.tar.gz),
#       install VS Code from the catalog pack as the desktop does (`linpad-apps install
#       vscode`), add python3 (the driver), and create /root/projects/vscb (a small TypeScript project in git; the
#       rootfs's own /root/projects/demo is left as shipped).
#       Test settings: no workspace trust prompt, solid cursor (no blink frames), tsserver log.
#   devtools/bench/vscode-cycle.sh run FAKEFS OUTDIR
#       REPS runs per engine (JITS) -> OUTDIR/vscode-jit<J>-<n>.json, .log, the step
#       screenshots, and the host footprint (peak, and when each step ended).
#   devtools/bench/vscode-cycle.sh sample FAKEFS OUT.sample STEP [SECS]
#       One run (JIT on) with a host `sample` of ish for SECS (12) from the start of STEP
#       (launch, open, type, ...). Then: devtools/bench/sampan.py OUT.sample
#
# Environment: ISH (default build-speed/ish, then build-arm64-release/ish), JITS ("1 0"),
# REPS (1), EXTENSION (Open VSX id, usernamehw.errorlens), SHOTS (1: a screenshot per step,
# which costs frame time; off for timings). Each run works on FAKEFS.run, a
# fresh clone of FAKEFS. The JIT's persistent translation cache is FAKEFS.pcache (PCACHE),
# not the user's ~/Library/Caches/ish-jit: the first run after setup starts it cold, later
# runs warm, as the iPad does after the first start.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
ISH=${ISH:-}
if [ -z "$ISH" ]; then
    for c in "$REPO/build-speed/ish" "$REPO/build-arm64-release/ish"; do
        [ -x "$c" ] && { ISH=$c; break; }
    done
fi
JITS=${JITS:-"1 0"}
REPS=${REPS:-1}
EXTENSION=${EXTENSION:-usernamehw.errorlens}

guest() {  # guest FAKEFS JIT CMD...  (stdin is passed through)
    f=$1 j=$2; shift 2
    ISH_JIT=$j ISH_JIT_PCACHE_DIR=${PCACHE:-${f%.run}.pcache} "$ISH" -f "$f" /bin/sh -lc "$*"
}

copy_scripts() {
    tar cf - -C "$HERE/guest" --exclude=__pycache__ ffbench.py vscodebench.py |
        guest "$1" 1 'mkdir -p /root/bench && cd /root/bench && tar xf -'
}

cmd_setup() {
    f=$1 tgz=${2:-$REPO/release/out/ish-linux-rootfs-arm64.tar.gz}
    [ -e "$f" ] && { echo "vscode-cycle: $f exists" >&2; exit 1; }
    "$(dirname "$ISH")/tools/fakefsify" "$tgz" "$f"
    guest "$f" 1 'apk add --no-progress python3 >/tmp/apk.log 2>&1 || { tail /tmp/apk.log; exit 1; }
        linpad-apps install vscode 2>&1 | grep -v "^==> @progress" | tail -3
        [ -x /opt/vscode/code ] || { echo "vscode-cycle: VS Code did not install" >&2; exit 1; }' </dev/null
    guest "$f" 1 'set -e; mkdir -p /root/projects/vscb/src && cd /root/projects/vscb
        cat > package.json <<EOF
{ "name": "demo", "version": "1.0.0", "private": true, "type": "module" }
EOF
        cat > tsconfig.json <<EOF
{ "compilerOptions": { "target": "ES2022", "module": "ES2022", "strict": true }, "include": ["src"] }
EOF
        cat > src/index.ts <<EOF
export class Counter {
    private value = 0;
    increment(by = 1): number {
        this.value += by;
        return this.value;
    }
    get count(): number {
        return this.value;
    }
}

export function sum(...xs: number[]): number {
    return xs.reduce((a, b) => a + b, 0);
}

const counter = new Counter();
counter.increment(sum(1, 2, 3));
EOF
        git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init
        s=/root/.config/Code/User/settings.json
        [ -f $s.orig ] || cp $s $s.orig
        # appended keys before the final brace (the file is JSON with comments)
        sed -i "\$ d" $s
        cat >> $s <<EOF
    ,"security.workspace.trust.enabled": false,
    "editor.cursorBlinking": "solid",
    "typescript.tsserver.log": "normal",
    "git.openRepositoryInParentFolders": "never"
}
EOF
        echo "project and settings ready"' </dev/null
    copy_scripts "$f"
    echo "vscode-cycle: $f ready"
}

footprint_mb() {
    footprint -p "$1" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]*\) \([KMG]B\).*/\1 \2/p' |
        awk '{m=$1; if($2=="KB")m/=1024; if($2=="GB")m*=1024; printf "%d", m}'
}

run_one() {  # FAKEFS OUTDIR JIT NAME [SAMPLE_STEP SECS]
    out=$2 j=$3 name=$4 sstep=${5:-} ssecs=${6:-12}
    # every run starts from the set-up state (a run installs an extension, writes logs and
    # caches): a copy-on-write clone where the file system can make one
    f=$1.run
    rm -rf "$f"
    cp -cR "$1" "$f" 2>/dev/null || cp -R "$1" "$f"
    rm -f "$f/data/tmp/vscb-phase"
    (guest "$f" "$j" "cd /root/bench && FFBENCH_PHASE=/tmp/vscb-phase python3 vscodebench.py /root/bench/out.json \
        --extension $EXTENSION $([ "${SHOTS:-0}" = 1 ] && echo --png)" </dev/null >"$out/$name.log" 2>&1; echo "rc=$?" >>"$out/$name.log") &
    peak=0 sampled=0 steps=
    sleep 3
    pid=$(pgrep -n -f "^$ISH -f $f" || true)
    while ! grep -q '^rc=' "$out/$name.log" 2>/dev/null; do
        if [ -n "$pid" ]; then
            m=$(footprint_mb "$pid")
            [ -n "$m" ] && [ "$m" -gt "$peak" ] && peak=$m
            last=$(tail -1 "$f/data/tmp/vscb-phase" 2>/dev/null || true)
            case "$last" in *" end "*) s=${last##* end }; case " $steps " in *" $s="*) ;; *) steps="$steps $s=${m}MB";; esac;; esac
            if [ -n "$sstep" ] && [ $sampled = 0 ] && grep -q "begin $sstep\$" "$f/data/tmp/vscb-phase" 2>/dev/null; then
                sample "$pid" "$ssecs" -file "$out/$name.sample" >/dev/null 2>&1 &
                sampled=1
            fi
        fi
        sleep 2
    done
    wait
    cp "$f/data/root/bench/out.json" "$out/$name.json" 2>/dev/null || true
    mkdir -p "$out/$name-png" && cp "$f"/data/tmp/vscb-png/[a-z]*.png "$out/$name-png/" 2>/dev/null || true
    echo "$name host_footprint_peak=${peak}MB at_step_end:$steps"
    python3 - "$out/$name.json" <<'EOF' || true
import json, sys
r = json.load(open(sys.argv[1]))
s = r.get("steps", {})
print("  " + " ".join(f"{k}={v['wall_s']}s{'' if v['ok'] else '(FAIL)'}" for k, v in s.items()),
      f"| first_frame={r.get('launch_first_frame_s')} workbench={r.get('launch_workbench_s')} exthost={r.get('launch_exthost_s')}"
      f" type_median={r.get('type_latency_ms_median')}ms p90={r.get('type_latency_ms_p90')}ms"
      f" completion={r.get('completion_s')}s (server {r.get('completion_server_ms')}ms)"
      f" git_after_save={r.get('git_status_after_save_s')}s total={r.get('total_s')}s",
      r.get("fatal", ""), r.get("timeouts", ""))
EOF
}

cmd_run() {
    f=$1 out=$2
    mkdir -p "$out"
    copy_scripts "$f"
    for j in $JITS; do
        n=1
        while [ $n -le "$REPS" ]; do
            echo "host load: $(sysctl -n vm.loadavg)"
            run_one "$f" "$out" "$j" "vscode-jit$j-$n" | tee -a "$out/summary.txt"
            n=$((n + 1))
        done
    done
}

cmd_sample() {
    f=$1 out=$2 step=$3 secs=${4:-12}
    d=$(dirname "$out")
    copy_scripts "$f"
    run_one "$f" "$d" 1 "$(basename "$out" .sample)" "$step" "$secs"
}

case ${1:-} in
    setup) shift; cmd_setup "$@" ;;
    run) shift; cmd_run "$@" ;;
    sample) shift; cmd_sample "$@" ;;
    *) sed -n '2,20p' "$0" >&2; exit 2 ;;
esac
