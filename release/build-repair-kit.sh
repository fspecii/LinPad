#!/bin/bash
# Packs the guest repair kit that ships inside the app (Settings › Maintenance › Repair
# System, and the silent repair after an app update):
#   release/build-repair-kit.sh OUTDIR    -> OUTDIR/repair-kit.tar, OUTDIR/repair-kit.json
# The iSH-ARM64 target runs this as its "Bundle Repair Kit" build phase, with OUTDIR the
# app bundle. The app streams the tar into the guest and runs guest/linpad-repair.
#
# Layout of the tar (what linpad-repair expects):
#   guest/     release/guest       (linpad-repair, gecko-tune.sh, linpad/ catalog + packs, ...)
#   themes/    themes/guest        (ish-apply-style, styles, session hooks, audio)
#   omarchy/   themes/omarchy/guest (colour themes, ish-apply-colors)
#   wl-bridge/ firefox-prefs.js, os-release.sh, ish-terminal, foot/*.ini, fastfetch/
#
# The version is release/guest/repair-kit-version (yyyymmddNN). Bump it whenever anything
# above changes in a way existing installs should get: the app repairs silently once when
# its kit is newer than the guest's /usr/share/ish/repair-kit-version.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
OUT=${1:?usage: build-repair-kit.sh OUTDIR}
VERSION=$(tr -d '[:space:]' < "$HERE/guest/repair-kit-version")
[[ $VERSION =~ ^[0-9]+$ ]] || { echo "release/guest/repair-kit-version is not a number: $VERSION" >&2; exit 1; }

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/repair-kit.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/kit/wl-bridge"
cp -R "$HERE/guest" "$STAGE/kit/guest"
cp -R "$ROOT/themes/guest" "$STAGE/kit/themes"
cp -R "$ROOT/themes/omarchy/guest" "$STAGE/kit/omarchy"
cp "$ROOT/wl-bridge/firefox-prefs.js" "$ROOT/wl-bridge/guest/os-release.sh" "$ROOT/wl-bridge/guest/ish-terminal" "$STAGE/kit/wl-bridge/"
cp -R "$ROOT/wl-bridge/guest/foot" "$ROOT/wl-bridge/guest/fastfetch" "$STAGE/kit/wl-bridge/"
find "$STAGE/kit" \( -name .DS_Store -o -name '._*' \) -exec rm -f {} +

for f in guest/linpad-repair guest/gecko-tune.sh guest/repair-kit-version themes/ish-apply-style; do
    [ -f "$STAGE/kit/$f" ] || { echo "repair kit: $f is missing" >&2; exit 1; }
done
sh -n "$STAGE/kit/guest/linpad-repair"

# Sorted entries, root ownership, no extended attributes: the same sources give the
# same archive, so an unchanged kit does not dirty the app bundle.
mkdir -p "$OUT"
(cd "$STAGE/kit" && find . -mindepth 1 | LC_ALL=C sort) > "$STAGE/list"
touch -t 202601010000 $(cd "$STAGE/kit" && find . -mindepth 1 | sed "s|^\.|$STAGE/kit|")
COPYFILE_DISABLE=1 tar --no-xattrs --uid 0 --gid 0 --uname root --gname root -n \
    -cf "$STAGE/repair-kit.tar" -C "$STAGE/kit" -T "$STAGE/list"

python3 - "$STAGE/repair-kit.tar" "$VERSION" "$STAGE/list" "$STAGE/repair-kit.json" <<'EOF'
import hashlib, json, os, sys
archive, version, listing, out = sys.argv[1:]
files = [line.strip()[2:] for line in open(listing) if line.strip()]
root = os.path.dirname(archive) + "/kit/"
manifest = {
    "format": 1,
    "version": version,
    "entry": "guest/linpad-repair",
    "archiveSHA256": hashlib.sha256(open(archive, "rb").read()).hexdigest(),
    "archiveSize": os.path.getsize(archive),
    "files": [f for f in files if os.path.isfile(root + f)],
}
json.dump(manifest, open(out, "w"), indent=1, sort_keys=True)
EOF

for f in repair-kit.tar repair-kit.json; do
    cmp -s "$STAGE/$f" "$OUT/$f" || cp "$STAGE/$f" "$OUT/$f"
done
echo "repair kit $VERSION: $(du -k "$OUT/repair-kit.tar" | cut -f1) KB, $(wc -l < "$STAGE/list" | tr -d ' ') entries"
