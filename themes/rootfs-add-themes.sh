#!/bin/bash
# Builds rootfs-full-arm64.tar.gz: the bridge agent's GUI rootfs plus the desktop styles,
# icon caches for all four styles, ishaudio and VLC.
#   themes/rootfs-add-themes.sh [input.tar.gz] [output.tar.gz]
# Defaults: rootfs-gui-arm64.tar.gz -> rootfs-full-arm64.tar.gz (repo root). The input
# is never modified. The output is archived by tar *inside the guest*, so ownership and
# modes come from the guest's view of the filesystem. Needs network (see build-themes.sh).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
IN=$(cd "$(dirname "${1:-$ROOT/rootfs-gui-arm64.tar.gz}")" && pwd)/$(basename "${1:-rootfs-gui-arm64.tar.gz}")
OUT=$(cd "$(dirname "${2:-$ROOT/rootfs-full-arm64.tar.gz}")" && pwd)/$(basename "${2:-rootfs-full-arm64.tar.gz}")
ISH=${ISH:-$ROOT/build-arm64-release/ish}
FAKEFSIFY=${FAKEFSIFY:-$(dirname "$ISH")/tools/fakefsify}
[ "$IN" != "$OUT" ] || { echo "output must differ from input" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rootfs-themes.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
echo "unpacking $IN"
"$FAKEFSIFY" "$IN" "$WORK/fs"

"$HERE/build-themes.sh" "$WORK/fs" ish

# The default style stays "ish"; caches for the other three are pre-built so the first
# switch on the device is instant. The last call re-selects ish.
# A short H.264/AAC clip (720p, 10 s) so VLC has something to play out of the box.
"$ISH" -f "$WORK/fs" /bin/sh -c '
    mkdir -p /root/Videos
    [ -s /root/Videos/ish-test-720p.mp4 ] || ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=10" \
        -f lavfi -i "sine=frequency=440:duration=10:sample_rate=48000" \
        -c:v libx264 -preset veryfast -crf 30 -pix_fmt yuv420p -c:a aac -b:a 128k -ac 2 \
        -shortest -movflags +faststart /root/Videos/ish-test-720p.mp4
    for s in windows macos ubuntu kylin ish; do ish-apply-style "$s" >/dev/null || exit 1; done
    ish-apply-style --current' </dev/null

echo "archiving inside the guest"
"$ISH" -f "$WORK/fs" /bin/sh -c '
    rm -rf /tmp/* /var/cache/apk/* /root/.cache 2>/dev/null
    cd / && tar -czf /rootfs-export.tar.gz --exclude=./rootfs-export.tar.gz \
        --exclude="./proc/*" --exclude="./sys/*" --exclude="./dev/*" --exclude="./tmp/*" .
' </dev/null
cp "$WORK/fs/data/rootfs-export.tar.gz" "$OUT"
ls -la "$OUT"
