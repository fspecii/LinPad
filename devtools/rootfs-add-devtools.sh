#!/bin/bash
# Adds the developer tools to an iSH-ARM64 rootfs tarball: VS Code (Microsoft's official
# linux-arm64 desktop build, running as a Wayland window under ishwl) with its glibc
# library set, the `code` command, the launcher entry, and a demo Vite + React + TS
# project in /root/projects/demo.
#   devtools/rootfs-add-devtools.sh [input.tar.gz] [output.tar.gz]
# Defaults: rootfs-gui-arm64.tar.gz -> rootfs-devtools-arm64.tar.gz (repo root). The input
# is never modified, so it composes with gpu/rootfs-add-gpu.sh and
# themes/rootfs-add-themes.sh in any order (run this one last if a later step re-generates
# icon caches, or run `ish-apply-style --current` in the guest).
# Env: VSCODE=0 stages only the installer (/usr/local/share/devtools); the device then
#      fetches VS Code on first use with `sh /usr/local/share/devtools/install-vscode.sh`.
#      DEMO=0 skips the demo project. ISH=path to the ish CLI.
# The output contains Microsoft's VS Code binary when VSCODE=1 (the default): it is for
# local testing only and must not be published. Needs network.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
IN=$(cd "$(dirname "${1:-$ROOT/rootfs-gui-arm64.tar.gz}")" && pwd)/$(basename "${1:-rootfs-gui-arm64.tar.gz}")
OUT=$(cd "$(dirname "${2:-$ROOT/rootfs-devtools-arm64.tar.gz}")" && pwd)/$(basename "${2:-rootfs-devtools-arm64.tar.gz}")
ISH=${ISH:-$ROOT/build-arm64-release/ish}
FAKEFSIFY=${FAKEFSIFY:-$(dirname "$ISH")/tools/fakefsify}
[ "$IN" != "$OUT" ] || { echo "output must differ from input" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rootfs-devtools.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
echo "unpacking $IN"
"$FAKEFSIFY" "$IN" "$WORK/fs"

echo "staging the installer"
COPYFILE_DISABLE=1 tar --no-xattrs -C "$HERE" -cf - \
        install-vscode.sh install-wine.sh debfetch.mjs vscode-launch vscode-forward.mjs vscode-settings.json |
    "$ISH" -f "$WORK/fs" /bin/sh -c '
        set -e
        mkdir -p /usr/local/share/devtools
        tar -xo -f - -C /usr/local/share/devtools
        chmod 755 /usr/local/share/devtools/install-vscode.sh /usr/local/share/devtools/install-wine.sh \
            /usr/local/share/devtools/vscode-launch'

if [ "${VSCODE:-1}" = 1 ]; then
    "$ISH" -f "$WORK/fs" /bin/sh -c 'sh /usr/local/share/devtools/install-vscode.sh' </dev/null
fi

if [ "${DEMO:-1}" = 1 ]; then
    "$ISH" -f "$WORK/fs" /bin/sh -lc '
        set -e
        export HOME=/root
        mkdir -p /root/projects && cd /root/projects
        [ -d demo ] || npm create -y vite@latest demo -- --template react-ts --no-interactive >/dev/null
        cd demo && npm install --no-audit --no-fund >/dev/null
        if [ ! -d .git ]; then
            git init -q && git add -A
            git -c user.name=demo -c user.email=demo@localhost commit -qm "Vite + React + TypeScript starter"
        fi
        # A local identity, so committing from VS Code works before the user sets theirs.
        git config user.name >/dev/null || git config user.name "Demo"
        git config user.email >/dev/null || git config user.email "demo@localhost"
        echo "demo project: $(du -sh /root/projects/demo | cut -f1)"' </dev/null
fi

echo "archiving inside the guest"
"$ISH" -f "$WORK/fs" /bin/sh -c '
    rm -rf /tmp/* /var/cache/apk/* /var/cache/vscode-install /root/.cache /root/.npm/_cacache 2>/dev/null
    cd / && tar -czf /rootfs-export.tar.gz --exclude=./rootfs-export.tar.gz \
        --exclude="./proc/*" --exclude="./sys/*" --exclude="./dev/*" --exclude="./tmp/*" .
' </dev/null
mv "$WORK/fs/data/rootfs-export.tar.gz" "$OUT"
ls -la "$OUT"
