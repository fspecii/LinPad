#!/bin/bash
# Installs the desktop styles, icon cache, ishaudio and VLC into a guest fakefs.
#   themes/build-themes.sh <fakefs-dir> [default-style]
# The fakefs is modified in place (use a copy). Env ISH_STYLE_PACKS: see below. Needs network inside the guest (Alpine
# CDN, GitHub, Ubuntu archive). ISH=path/to/ish overrides the emulator binary.
# Re-running is safe: packages and downloads already present are skipped.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FS=${1:?usage: build-themes.sh <fakefs-dir> [default-style]}
STYLE=${2:-ish}
ISH=${ISH:-$HERE/../build-arm64-release/ish}
[ -f "$FS/meta.db" ] || { echo "not a fakefs: $FS" >&2; exit 1; }

echo "copying themes/guest into the guest"
tar -C "$HERE/guest" -cf - . | "$ISH" -f "$FS" /bin/sh -c \
    'rm -rf /tmp/ish-themes-src && mkdir -p /tmp/ish-themes-src && tar -C /tmp/ish-themes-src -xf -'
# Colour themes (Omarchy port) go to /tmp/ish-themes-src/omarchy; install.sh installs them.
tar -C "$HERE/omarchy/guest" -cf - . | "$ISH" -f "$FS" /bin/sh -c \
    'mkdir -p /tmp/ish-themes-src/omarchy && tar -C /tmp/ish-themes-src/omarchy -xf -'

echo "installing (this takes several minutes under emulation)"
# ISH_STYLE_PACKS="luna aero …" pre-installs desktop-theme GTK packs (default: on first use).
PACKS=$(printf '%s' "${ISH_STYLE_PACKS:-}" | tr -cd 'a-z ')
"$ISH" -f "$FS" /bin/sh -c "ISH_STYLE_PACKS='$PACKS' sh /tmp/ish-themes-src/install.sh '$STYLE' && rm -rf /tmp/ish-themes-src" </dev/null
