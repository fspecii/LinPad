#!/bin/sh
# Wine pack removal: only what devtools/install-wine.sh installed.
#   wine-uninstall.sh          Wine entirely (ARM64 Wine, and x86 support if present)
#   wine-uninstall.sh --x86    only Box64 and the x86_64 Wine; ARM64 Wine stays
# Windows prefixes (~/.wine, ~/.wine-x64) are the user's files and stay. The shared glibc
# libraries go only when VS Code does not use them either (glibc-island.sh).
set -eu
here=$(cd "$(dirname "$0")" && pwd)

remove_x86() {
    rm -rf /opt/wine-x64 /opt/wine-x64.new /usr/x86_64-linux-gnu
    rm -f /usr/local/bin/box64 /usr/local/bin/wine-x64 /etc/box64.box64rc
}

remove_x86
if [ "${1:-}" != --x86 ]; then
    rm -rf /usr/lib/wine /usr/share/wine /usr/lib/aarch64-linux-gnu/wine /var/cache/wine-install
    rm -f /usr/lib/aarch64-linux-gnu/.wine-glibc-packages /usr/local/bin/wine \
        /usr/share/applications/wine-notepad.desktop /usr/share/applications/wine-winecfg.desktop \
        /usr/share/applications/wine-winemine.desktop /usr/share/applications/wine-explorer.desktop \
        /tmp/.wine-display-*
fi
sh "$here/glibc-island.sh" prune
