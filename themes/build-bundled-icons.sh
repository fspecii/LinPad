#!/bin/bash
# Renders the default icon pack (Papirus, GPL-3.0) that ships inside DesktopKit, so the
# desktop shows real pack icons before Linux has booted, on a guest without an icon cache
# and in the UX harness:
#   themes/build-bundled-icons.sh [ROOTFS]   (default release/out/ish-linux-rootfs-arm64.tar.gz)
# Output: desktop/DesktopKit/Sources/DesktopKit/Resources/Icons/ laid out like a guest icon
# cache (themes/CONTRACT.md): index.json plus <name>.png / <name>@2x.png for every name in
# NATIVE_ICONS and EXACT_ICONS of themes/guest/ish-apply-style. It runs that same script
# in an Alpine aarch64 container (docker or podman) on the rootfs's /usr/share/icons.
# Run it whenever those lists change; DesktopKit's tests fail when a name is missing.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ROOTFS=${1:-$ROOT/release/out/ish-linux-rootfs-arm64.tar.gz}
OUT=$ROOT/desktop/DesktopKit/Sources/DesktopKit/Resources/Icons
ENGINE=$(command -v docker || command -v podman) || { echo "needs docker or podman" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bundled-icons.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root" "$WORK/apps" "$WORK/ish/themes/styles"
# A few entries of a tarball made from fakefs are symlinks tar cannot create; they are
# not icons the shell asks for.
tar -xzf "$ROOTFS" -C "$WORK/root" ./usr/share/icons 2>/dev/null || true
cp "$ROOT"/themes/guest/styles/*.conf "$WORK/ish/themes/styles/"

"$ENGINE" run --rm --platform linux/arm64 \
    -v "$WORK/root/usr/share/icons:/usr/share/icons:ro" -v "$WORK/apps:/usr/share/applications:ro" \
    -v "$WORK/ish:/usr/share/ish" -v "$ROOT/themes/guest/ish-apply-style:/usr/local/bin/ish-apply-style:ro" \
    -e ISH_ICON_JOBS=4 alpine:3.21 \
    sh -c 'apk add -q --no-cache rsvg-convert gdk-pixbuf >/dev/null && mkdir -p /etc/xdg &&
           ish-apply-style --icons Papirus >&2'

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$WORK"/ish/icon-cache/ish/*.png "$OUT/"
# Only what the shell reads, without timestamps, so an unchanged pack gives the same files.
python3 - "$WORK/ish/icon-cache/ish/index.json" "$OUT/index.json" <<'EOF'
import json, sys
src = json.load(open(sys.argv[1]))
icons = {name: {k: v for k, v in entry.items() if k != "source"} | {"source": entry["source"].split("/usr/share/icons/")[-1]}
         for name, entry in src["icons"].items()}
json.dump({"version": 1, "iconTheme": src["iconTheme"], "icons": icons, "missing": sorted(src["missing"])},
          open(sys.argv[2], "w"), indent=1, sort_keys=True)
EOF
cat > "$OUT/LICENSE" <<'EOF'
Default icon pack bundled with LinPad's desktop (pre-rendered PNGs).

Papirus icon theme, https://github.com/PapirusDevelopmentTeam/papirus-icon-theme
(Alpine 3.21 papirus-icon-theme 20231201-r0). Licence: GPL-3.0.
Copyright Papirus Development Team.

A few names Papirus takes from its parent theme come from Breeze icons,
https://invent.kde.org/frameworks/breeze-icons (Alpine 3.21 breeze-icons).
Licence: LGPL-3.0-or-later. Copyright KDE Visual Design Group.

The theme a file was rendered from is the "source" of its entry in index.json.
The full licence texts: https://www.gnu.org/licenses/gpl-3.0.txt and
https://www.gnu.org/licenses/lgpl-3.0.txt. Source: the upstream repositories above.
Regenerate with themes/build-bundled-icons.sh.
EOF
echo "bundled icons: $(ls "$OUT"/*.png | wc -l | tr -d ' ') files, $(du -sh "$OUT" | cut -f1) in $OUT"
