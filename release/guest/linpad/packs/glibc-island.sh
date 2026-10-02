#!/bin/sh
# The glibc "island" that VS Code and Wine share: Debian's libraries in
# /usr/lib/aarch64-linux-gnu plus the loader /lib/ld-linux-aarch64.so.1 (see
# devtools/install-vscode.sh and install-wine.sh). Each pack's uninstaller removes its
# own files, then calls this, which deletes the island only when no pack still uses it.
#   glibc-island.sh prune
set -eu
[ "${1:-}" = prune ] || { echo "usage: glibc-island.sh prune" >&2; exit 2; }
users=
[ -e /opt/vscode/code ] && users="$users vscode"
[ -e /usr/lib/wine/wine64 ] && users="$users wine"
[ -e /opt/wine-x64/bin/wine ] && users="$users wine-x86"
if [ -n "$users" ]; then
    echo "glibc libraries kept: still used by$users"
    exit 0
fi
rm -rf /usr/lib/aarch64-linux-gnu
rm -f /lib/ld-linux-aarch64.so.1
echo "glibc libraries removed (no pack uses them)"
