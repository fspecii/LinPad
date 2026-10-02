#!/bin/bash
# Installs the desktop styles, icon cache, ishaudio and VLC into a guest fakefs.
#   themes/build-themes.sh <fakefs-dir> [default-style]
# The fakefs is modified in place (use a copy). Needs network inside the guest (Alpine
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

echo "installing (this takes several minutes under emulation)"
"$ISH" -f "$FS" /bin/sh -c "sh /tmp/ish-themes-src/install.sh '$STYLE' && rm -rf /tmp/ish-themes-src" </dev/null
