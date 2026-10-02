#!/bin/bash
# Composes the iSH Linux Desktop rootfs that ships inside the app (root.tar.gz), from a
# clean Alpine minirootfs, by chaining every component's script:
#   1. base     Alpine 3.21 + the Linux GUI session (ishwl, built from wl-bridge/ in the
#               guest), Firefox ESR, Thunar, Mousepad, foot, fastfetch, Node, npm, git,
#               Claude Code. Same package set as the bridge agent's rootfs-gui-lean.
#   2. gpu      gpu/rootfs-add-gpu.sh (Mesa Venus/zink from edge, vulkan-tools)
#   3. themes   themes/rootfs-add-themes.sh (5 styles, icon caches, ishaudio, VLC)
#   4. devtools devtools/rootfs-add-devtools.sh, VSCODE=0 (installer only) by default
#   5. final    release/guest/finalize.sh (branding, version, first-run hooks, VS Code
#               installer entry, case-collision cleanup, icon caches, sanity check)
#
#   release/build-rootfs.sh                 -> release/out/ish-linux-rootfs-arm64.tar.gz
#   VSCODE=1 release/build-rootfs.sh        -> ipad-jit/release-work/ish-linux-rootfs-vscode-arm64.tar.gz
#
# The VSCODE=1 variant contains Microsoft's VS Code binary: local testing only, never
# publish it (it is written outside the repo for that reason).
# Env:
#   BASE=tarball      skip stage 1 and start from this GUI rootfs instead
#   RESUME=1          keep stage outputs from an earlier run (same WORK dir)
#   WORK=dir          stage outputs and temp files (default ipad-jit/release-work/stages)
#   ROOTFS_VERSION=N  version stamp (default UTC yyyymmddHHMM); the app offers an update
#                     when the bundled number is larger than the installed one
#   ISH=path          ish CLI (default: a private copy of build-arm64-release/ish, so a
#                     concurrent rebuild of that directory cannot change it mid-run)
#   DEMO=0            no demo project in /root/projects
# Needs network (Alpine CDN, npm, GitHub and the Ubuntu/Debian archives for the themes).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCRATCH=/Volumes/ExternalHD/Dev/ipad-jit/release-work
WORK=${WORK:-$SCRATCH/stages}
VSCODE=${VSCODE:-0}
DEMO=${DEMO:-1}
ROOTFS_VERSION=${ROOTFS_VERSION:-$(date -u +%Y%m%d%H%M)}
if [ "$VSCODE" = 1 ]; then
    OUT=${OUT:-$SCRATCH/ish-linux-rootfs-vscode-arm64.tar.gz}
else
    OUT=${OUT:-$HERE/out/ish-linux-rootfs-arm64.tar.gz}
fi
MINIROOTFS=${MINIROOTFS:-$ROOT/alpine-minirootfs-3.21.0-aarch64.tar.gz}

mkdir -p "$WORK" "$(dirname "$OUT")" "$SCRATCH/bin"
if [ -z "${ISH:-}" ]; then
    # A private copy: other work rebuilds build-arm64-release while this runs for an hour.
    cp "$ROOT/build-arm64-release/ish" "$SCRATCH/bin/ish"
    cp "$ROOT/build-arm64-release/tools/fakefsify" "$SCRATCH/bin/fakefsify"
    ln -sf fakefsify "$SCRATCH/bin/unfakefsify"
    ISH=$SCRATCH/bin/ish
fi
FAKEFSIFY=${FAKEFSIFY:-$(dirname "$ISH")/fakefsify}
[ -x "$FAKEFSIFY" ] || FAKEFSIFY=$(dirname "$ISH")/tools/fakefsify
export ISH FAKEFSIFY
export TMPDIR=$WORK/tmp
mkdir -p "$TMPDIR"
LOG=$WORK/build.log
SIZES=$(dirname "$OUT")/SIZES-$(basename "$OUT" .tar.gz).txt
: > "$SIZES"

say() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }
size_of() { ls -l "$1" | awk '{ printf "%.0f MB", $5 / 1048576 }'; }
record() { echo "$1: $(size_of "$2") ($(basename "$2"))" | tee -a "$SIZES"; }
stage_done() { [ "${RESUME:-}" = 1 ] && [ -s "$1" ]; }

guest_tar_export() {
    # Archive inside the guest, so ownership and modes are the guest's view.
    local fs=$1 out=$2
    "$ISH" -f "$fs" /bin/sh -c '
        rm -rf /tmp/* /var/cache/apk/* /root/.cache 2>/dev/null
        cd / && tar -czf /rootfs-export.tar.gz --exclude=./rootfs-export.tar.gz \
            --exclude="./proc/*" --exclude="./sys/*" --exclude="./dev/*" --exclude="./tmp/*" .
    ' </dev/null
    mv "$fs/data/rootfs-export.tar.gz" "$out"
}

T0=$(date +%s)
say "rootfs $ROOTFS_VERSION, VSCODE=$VSCODE, ish $ISH, work $WORK"

# 1. GUI base -----------------------------------------------------------------------
S1=$WORK/01-base.tar.gz
if [ -n "${BASE:-}" ]; then
    S1=$(cd "$(dirname "$BASE")" && pwd)/$(basename "$BASE")
    say "1/5 base: using $S1"
elif stage_done "$S1"; then
    say "1/5 base: kept $S1"
else
    say "1/5 base: Alpine minirootfs + GUI session (about 15-30 min)"
    FS=$WORK/fs-base
    rm -rf "$FS"
    "$FAKEFSIFY" "$MINIROOTFS" "$FS"
    "$ISH" -f "$FS" /bin/sh -s >>"$LOG" 2>&1 <<'EOF'
set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root
[ -s /etc/resolv.conf ] || echo "nameserver 1.1.1.1" > /etc/resolv.conf
cat > /etc/apk/repositories <<REPOS
https://dl-cdn.alpinelinux.org/alpine/v3.21/main
https://dl-cdn.alpinelinux.org/alpine/v3.21/community
REPOS
apk update -q
apk add -q adwaita-icon-theme bash curl dbus fastfetch firefox-esr font-dejavu \
    font-jetbrains-mono font-noto font-noto-cjk font-noto-emoji foot git gtk+3.0-demo libxkbcommon mousepad nodejs npm \
    thunar wayland-libs-server xkeyboard-config zlib
npm install -g --no-audit --no-fund @anthropic-ai/claude-code >/dev/null
apk add -q --virtual .ishwl-build build-base wayland-dev wayland-protocols pkgconf zlib-dev \
    libxkbcommon-dev libx11-dev
EOF
    say "1/5 base: building ishwl in the guest"
    "$ISH" -f "$FS" /bin/sh -c 'cat > /tmp/fix-thunar.sh' < "$HERE/guest/fix-thunar.sh"
    COPYFILE_DISABLE=1 tar --no-xattrs -C "$ROOT/wl-bridge" \
        --exclude=build --exclude=gen --exclude='*.o' --exclude='*.so' --exclude=ishwl \
        --exclude=ishwl-x11-wm -cf - . |
        "$ISH" -f "$FS" /bin/sh -c '
            set -e
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root
            rm -rf /tmp/wl-bridge && mkdir -p /tmp/wl-bridge && tar -xo -f - -C /tmp/wl-bridge
            cd /tmp/wl-bridge && make CC=tools/ccwrap >/dev/null && make install >/dev/null
            sh /tmp/fix-thunar.sh
            sh guest/os-release.sh /etc/os-release
            apk del -q .ishwl-build
            rm -rf /tmp/wl-bridge
            ishwl --help >/dev/null 2>&1 || command -v ishwl' >>"$LOG" 2>&1
    guest_tar_export "$FS" "$S1"
    rm -rf "$FS"
fi
record "1 base" "$S1"

# 2. GPU ----------------------------------------------------------------------------
S2=$WORK/02-gpu.tar.gz
if stage_done "$S2"; then say "2/5 gpu: kept"; else
    say "2/5 gpu"
    "$ROOT/gpu/rootfs-add-gpu.sh" "$S1" "$S2" >>"$LOG" 2>&1
fi
record "2 +gpu" "$S2"

# 3. Themes, audio, VLC -------------------------------------------------------------
S3=$WORK/03-themes.tar.gz
if stage_done "$S3"; then say "3/5 themes: kept"; else
    say "3/5 themes (about 20-40 min)"
    "$ROOT/themes/rootfs-add-themes.sh" "$S2" "$S3" >>"$LOG" 2>&1
fi
record "3 +themes" "$S3"

# 4. Developer tools ----------------------------------------------------------------
S4=$WORK/04-devtools-vscode$VSCODE.tar.gz
if stage_done "$S4"; then say "4/5 devtools: kept"; else
    say "4/5 devtools (VSCODE=$VSCODE)"
    VSCODE=$VSCODE DEMO=$DEMO "$ROOT/devtools/rootfs-add-devtools.sh" "$S3" "$S4" >>"$LOG" 2>&1
fi
record "4 +devtools" "$S4"

# 5. Finalize -----------------------------------------------------------------------
say "5/5 finalize"
FS=$WORK/fs-final
rm -rf "$FS"
"$FAKEFSIFY" "$S4" "$FS"
COPYFILE_DISABLE=1 tar --no-xattrs -cf - -C "$HERE/guest" . -C "$ROOT/wl-bridge/guest" os-release.sh |
    "$ISH" -f "$FS" /bin/sh -c '
        set -e
        rm -rf /tmp/ish-release && mkdir -p /tmp/ish-release && tar -xo -f - -C /tmp/ish-release'
"$ISH" -f "$FS" /bin/sh -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root
    sh /tmp/ish-release/finalize.sh '$ROOTFS_VERSION'" </dev/null 2>&1 | tee -a "$LOG"
guest_tar_export "$FS" "$OUT.tmp"
"$ISH" -f "$FS" /bin/sh -c 'du -sk / 2>/dev/null | cut -f1; find / -xdev 2>/dev/null | wc -l' </dev/null > "$WORK/final-stats.txt" || true
rm -rf "$FS"
mv "$OUT.tmp" "$OUT"
printf '%s\n' "$ROOTFS_VERSION" > "${OUT%.tar.gz}.version"
record "5 final" "$OUT"

# Case collisions in the shipped archive itself (names that differ only in case).
collisions=$(tar -tzf "$OUT" | sed 's|/$||' | awk '{ k = tolower($0); if (k in s) print s[k] " <> " $0; else s[k] = $0 }')
{
    echo "uncompressed: $(sed -n 1p "$WORK/final-stats.txt") KB, entries: $(sed -n 2p "$WORK/final-stats.txt")"
    echo "case collisions in archive: $(printf '%s' "$collisions" | grep -c . || true)"
    [ -z "$collisions" ] || printf '%s\n' "$collisions"
    echo "version: $ROOTFS_VERSION"
    echo "built in $(( ($(date +%s) - T0) / 60 )) min"
} | tee -a "$SIZES"
say "done: $OUT ($(size_of "$OUT")); sizes in $SIZES"
