#!/bin/sh
# VS Code pack removal: what devtools/install-vscode.sh put in place (the app, the `code`
# command and launcher entry). User settings and extensions in /root/.config/Code and
# /root/.vscode stay. The glibc libraries are shared with Wine and go only when no pack
# uses them any more (glibc-island.sh).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
rm -rf /opt/vscode /opt/vscode.new /opt/vscode.old /var/cache/vscode-install
rm -f /usr/lib/aarch64-linux-gnu/.vscode-glibc-packages /usr/local/bin/code \
    /usr/share/applications/code.desktop /usr/share/pixmaps/vscode.png
install -m 644 /usr/local/share/linpad/ish-install-vscode.desktop /usr/share/applications/ish-install-vscode.desktop
sh "$here/glibc-island.sh" prune
