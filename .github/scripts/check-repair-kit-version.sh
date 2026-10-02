#!/bin/sh
# Fails if a commit range changes files that go into the repair kit
# (release/build-repair-kit.sh) without bumping release/guest/repair-kit-version:
# existing installs only pick up a kit whose version is newer than theirs.
#   .github/scripts/check-repair-kit-version.sh <base>..<head>
set -eu
range=${1:?usage: check-repair-kit-version.sh <base>..<head>}
cd "$(git rev-parse --show-toplevel)"
VERSION_FILE=release/guest/repair-kit-version

changed=$(git diff --name-only "$range" -- \
    release/guest themes/guest themes/omarchy/guest \
    wl-bridge/firefox-prefs.js wl-bridge/guest/os-release.sh \
    wl-bridge/guest/foot wl-bridge/guest/fastfetch \
    | grep -vx "$VERSION_FILE" || true)
[ -n "$changed" ] || { echo "repair kit: unchanged"; exit 0; }

if git diff --quiet "$range" -- "$VERSION_FILE"; then
    echo "These repair-kit files changed in $range but $VERSION_FILE was not bumped:"
    echo "$changed" | sed 's/^/  /'
    echo "Bump it (yyyymmddNN) so existing installs get the change."
    exit 1
fi
base=${range%%..*} head=${range##*..}
old=$(git show "$base:$VERSION_FILE" 2>/dev/null | tr -d '[:space:]' || true)
new=$(git show "${head:-HEAD}:$VERSION_FILE" | tr -d '[:space:]')
case $new in *[!0-9]*|'') echo "$VERSION_FILE is not a number: $new"; exit 1 ;; esac
if [ "$new" -le "${old:-0}" ]; then
    echo "$VERSION_FILE went from $old to $new; it must increase."
    exit 1
fi
echo "repair kit: $(echo "$changed" | wc -l | tr -d ' ') files changed, version $old -> $new"
