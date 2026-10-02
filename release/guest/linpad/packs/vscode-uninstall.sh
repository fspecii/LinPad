#!/bin/sh
# VS Code pack removal: what devtools/install-vscode.sh put in place (the app, its glibc
# libraries and loader, the `code` command and launcher entry). User settings and
# extensions in /root/.config/Code and /root/.vscode stay.
rm -rf /opt/vscode /opt/vscode.new /opt/vscode.old /usr/lib/aarch64-linux-gnu /var/cache/vscode-install
rm -f /lib/ld-linux-aarch64.so.1 /usr/local/bin/code /usr/share/applications/code.desktop /usr/share/pixmaps/vscode.png
install -m 644 /usr/local/share/linpad/ish-install-vscode.desktop /usr/share/applications/ish-install-vscode.desktop
