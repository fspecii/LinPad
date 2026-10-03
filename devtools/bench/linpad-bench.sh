#!/bin/sh
# LinPad guest-side benchmarks on the Mac CLI emulator (release ish + release rootfs).
#
#   devtools/bench/linpad-bench.sh setup FAKEFS [ROOTFS.tar.gz]
#       Make FAKEFS from the rootfs (default: release/out/ish-linux-rootfs-arm64.tar.gz),
#       add python3 + ffmpeg (network), copy the guest scripts, make test clips, apply
#       release/guest/gecko-tune.sh (TUNE=0: don't), and build ishwl from wl-bridge/ when
#       the installed one has no ISHWL_FRAMELOG.
#   devtools/bench/linpad-bench.sh run FAKEFS OUTDIR [cli|firefox|video|youtube|all]
#       Runs each suite REPS times per engine and writes OUTDIR/<suite>-jit<J>-<n>.json
#       plus OUTDIR/summary.txt (medians).
#   devtools/bench/linpad-bench.sh sample FAKEFS OUT.sample [ffbench args...]
#       Runs ffbench.py and takes a 12 s host `sample` of ish once the phase log has a
#       line matching $SAMPLE_AT (default "begin": the first page load or playback
#       window; e.g. SAMPLE_AT="begin scroll"). Then: devtools/bench/sampan.py OUT.sample
#
# Environment: ISH (emulator binary, default build-speed/ish, then build-arm64-release/ish),
# JITS ("0 1"), REPS (3), FIRST (number of the first run, 1; for interleaving A/B
# configurations one run at a time), FFBENCH_ARGS (extra ffbench.py arguments), SCALE (2),
# SUMMARY (0 skips the summary).
# The Mac is shared: guest CPU seconds (from /proc/PID/stat) are the robust numbers;
# frame rates and wall times move with the host load, which is logged with every run.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
ISH=${ISH:-}
if [ -z "$ISH" ]; then
    for c in "$REPO/build-speed/ish" "$REPO/build-arm64-release/ish"; do
        [ -x "$c" ] && { ISH=$c; break; }
    done
fi
JITS=${JITS:-"0 1"}
REPS=${REPS:-3}
SCALE=${SCALE:-2}

guest() {  # guest FAKEFS JIT CMD...  (stdin is passed through)
    f=$1 j=$2; shift 2
    ISH_JIT=$j "$ISH" -f "$f" /bin/sh -c "$*"
}

copy_scripts() {
    tar cf - -C "$HERE/guest" --exclude=__pycache__ . | guest "$1" 1 'mkdir -p /root/bench && cd /root/bench && tar xf -'
}

make_media() {
    f=$1
    tmp=$(mktemp -d)
    if command -v ffmpeg >/dev/null; then
        for r in 480 720; do
            w=$((r * 16 / 9 / 2 * 2))
            ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=${w}x${r}:rate=30" \
                -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 30 -c:v libx264 -profile:v high \
                -pix_fmt yuv420p -b:v $((r * 4))k -c:a aac -b:a 128k -movflags +faststart "$tmp/h264-${r}p.mp4"
            ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=${w}x${r}:rate=30" \
                -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 30 -c:v libvpx-vp9 -deadline realtime \
                -cpu-used 8 -b:v $((r * 4))k -c:a libopus "$tmp/vp9-${r}p.webm"
        done
        tar cf - -C "$tmp" . | guest "$f" 1 'mkdir -p /root/bench/media && cd /root/bench/media && tar xf -'
    else
        guest "$f" 1 'mkdir -p /root/bench/media && cd /root/bench/media && for r in 480 720; do w=$((r*16/9/2*2));
            ffmpeg -nostdin -loglevel error -y -f lavfi -i testsrc2=size=${w}x${r}:rate=30 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 30 -c:v libx264 -pix_fmt yuv420p -b:v $((r*4))k -c:a aac h264-${r}p.mp4;
            ffmpeg -nostdin -loglevel error -y -f lavfi -i testsrc2=size=${w}x${r}:rate=30 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 30 -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v $((r*4))k -c:a libopus vp9-${r}p.webm; done' </dev/null
    fi
    rm -rf "$tmp"
}

cmd_setup() {
    f=$1 tgz=${2:-$REPO/release/out/ish-linux-rootfs-arm64.tar.gz}
    [ -e "$f" ] && { echo "linpad-bench: $f exists" >&2; exit 1; }
    "$(dirname "$ISH")/tools/fakefsify" "$tgz" "$f"
    guest "$f" 1 'apk add --no-progress python3 ffmpeg >/tmp/apk.log 2>&1 || { tail /tmp/apk.log; exit 1; }' </dev/null
    copy_scripts "$f"
    make_media "$f"
    # The tree's Firefox prefs and /etc/ishwl/app-scale (the 1.4.0 rootfs predates them
    # and has no working video); TUNE=0 keeps the rootfs as shipped.
    [ "${TUNE:-1}" = 0 ] || guest "$f" 1 'cat > /tmp/gecko-tune.sh && sh /tmp/gecko-tune.sh' < "$REPO/release/guest/gecko-tune.sh"
    if ! grep -q ISHWL_FRAMELOG "$f/data/usr/local/bin/ishwl" 2>/dev/null; then
        tar cf - -C "$REPO" --exclude=build --exclude=gen wl-bridge | guest "$f" 1 \
            'rm -rf /root/wlsrc && mkdir -p /root/wlsrc && cd /root/wlsrc && tar xf - --strip-components=1 &&
             apk add --no-progress build-base wayland-dev wayland-protocols zlib-dev libxkbcommon-dev >/tmp/apk.log 2>&1 &&
             make CC=tools/ccwrap ishwl >/tmp/ishwl-build.log 2>&1 && echo "ishwl with frame log: /root/wlsrc/ishwl"'
    fi
    echo "linpad-bench: $f ready"
}

ishwl_path() {
    [ -f "$1/data/root/wlsrc/ishwl" ] && echo /root/wlsrc/ishwl || echo /usr/local/bin/ishwl
}

cmd_run() {
    f=$1 out=$2 suites=${3:-all}
    mkdir -p "$out"
    copy_scripts "$f"
    [ "$suites" = all ] && suites="cli firefox video youtube"
    wl=$(ishwl_path "$f")
    for s in $suites; do
        for j in $JITS; do
            n=${FIRST:-1}
            while [ $n -lt $((${FIRST:-1} + REPS)) ]; do
                load=$(sysctl -n vm.loadavg | awk '{print $2}')
                name="$s-jit$j-$n"
                case $s in
                    cli) g="python3 clibench.py /root/bench/out.json --reps 1" ;;
                    firefox) g="ISHWL=$wl python3 ffbench.py /root/bench/out.json --scale $SCALE --suites launch,scroll,type,pages,tabs ${FFBENCH_ARGS:-}" ;;
                    video) g="ISHWL=$wl python3 ffbench.py /root/bench/out.json --scale $SCALE --suites launch,video ${FFBENCH_ARGS:-}" ;;
                    youtube) g="ISHWL=$wl python3 ffbench.py /root/bench/out.json --scale $SCALE --suites launch,youtube ${FFBENCH_ARGS:-}" ;;
                esac
                rm -f "$f/data/root/bench/out.json"
                timeout 1800 sh -c "ISH_JIT=$j \"$ISH\" -f \"$f\" /bin/sh -c 'cd /root/bench && $g'" \
                    </dev/null >"$out/$name.log" 2>&1 || echo "linpad-bench: $name exited $?" >&2
                if [ -f "$f/data/root/bench/out.json" ]; then
                    python3 - "$f/data/root/bench/out.json" "$out/$name.json" "$load" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1])); r["host_load_1m_before"] = float(sys.argv[3])
json.dump(r, open(sys.argv[2], "w"), indent=1)
EOF
                fi
                echo "linpad-bench: $name done (host load $load)"
                n=$((n + 1))
            done
        done
    done
    [ "${SUMMARY:-1}" = 0 ] || python3 "$HERE/summarize.py" "$out" | tee "$out/summary.txt"
}

cmd_sample() {
    f=$1 dst=$2; shift 2
    copy_scripts "$f"
    phase="$f/data/root/bench/phase.log"
    rm -f "$phase"
    wl=$(ishwl_path "$f")
    ISH_JIT=1 "$ISH" -f "$f" /bin/sh -c "cd /root/bench && FFBENCH_PHASE=/root/bench/phase.log ISHWL=$wl python3 ffbench.py /root/bench/out.json $*" \
        </dev/null >"$dst.log" 2>&1 &
    pid=$!
    i=0
    while [ $i -lt 900 ] && ! grep -q "${SAMPLE_AT:-begin}" "$phase" 2>/dev/null; do sleep 1; i=$((i + 1)); done
    sleep 2
    sample "$pid" 12 -mayDie -file "$dst" >/dev/null 2>&1 || true
    wait "$pid" || true
    grep -v pollnval "$dst.log" | tail -3
}

case ${1:-} in
    setup) shift; cmd_setup "$@" ;;
    run) shift; cmd_run "$@" ;;
    sample) shift; cmd_sample "$@" ;;
    *) sed -n '2,20p' "$0"; exit 2 ;;
esac
