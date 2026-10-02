#!/bin/sh
# Installs Microsoft's official VS Code desktop build (linux-arm64, Electron) into the
# Alpine guest, as a native Wayland window under ishwl. Runs inside the guest, as root:
#   sh install-vscode.sh            # downloads the latest stable build
#   VSCODE_TARBALL=- sh install-vscode.sh < code-stable-arm64.tar.gz
#
# VS Code is glibc software and Alpine is musl. Its glibc library closure comes from
# Debian (debfetch.mjs, same directory) and lives only in the multiarch directory
# /usr/lib/aarch64-linux-gnu plus the loader /lib/ld-linux-aarch64.so.1. Debian's loader
# searches the multiarch directory first by default, so no LD_LIBRARY_PATH is needed and
# musl programs started from VS Code's terminal are unaffected.
#
# Licensing: the VS Code binary is Microsoft's (proprietary license, marketplace terms).
# It is fetched from code.visualstudio.com on the user's device; never redistribute a
# rootfs that contains it.
set -eu
# The desktop session preloads musl helpers into every program (ishwl-session:
# libishwl-scm.so). Inherited here, the glibc loader would load them into the library
# check below and into VS Code's CLI, and the check would fail on libc.musl. Nothing
# this script runs needs them.
unset LD_PRELOAD LD_LIBRARY_PATH
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-/opt/vscode}
DEBIAN_SUITE=${DEBIAN_SUITE:-trixie}
URL=${VSCODE_URL:-https://update.code.visualstudio.com/latest/linux-arm64/stable}
MULTIARCH=/usr/lib/aarch64-linux-gnu
CACHE=${CACHE:-/var/cache/vscode-install}

# Everything VS Code's ELF files list as NEEDED (code, *.node, chrome_crashpad_handler),
# plus what Electron dlopens on Wayland (wayland-*, xshmfence) and libsecret for keyring
# fallback. GTK pulls in the rest (pango, cairo, gdk-pixbuf, ...).
DEBS="libc6 libgcc-s1 libstdc++6 libx11-6 libxcb1 libxext6 libxkbfile1 libxkbcommon0
libudev1 libnss3 libnspr4 libpango-1.0-0 libgtk-3-0t64 libglib2.0-0t64 libgbm1 libexpat1
libdbus-1-3 libcups2t64 libcairo2 libatspi2.0-0t64 libatk-bridge2.0-0t64 libatk1.0-0t64
libasound2t64 libxrandr2 libxfixes3 libxdamage1 libxcomposite1 libsecret-1-0
libxshmfence1 libwayland-client0 libwayland-cursor0 libwayland-egl1"

log() { printf '%s\n' "install-vscode: $*"; }

command -v node >/dev/null || apk add -q nodejs
command -v xzcat >/dev/null || apk add -q xz
command -v curl >/dev/null || apk add -q curl
mkdir -p "$CACHE"

log "resolving the glibc library closure (Debian $DEBIAN_SUITE)"
stage="$CACHE/stage"
rm -rf "$stage"
# shellcheck disable=SC2086
node "$HERE/debfetch.mjs" --suite "$DEBIAN_SUITE" --cache "$CACHE/debs" --dest "$stage" $DEBS
# Only the libraries are taken: Alpine already provides the data (fonts, icons, XKB,
# GSettings schemas) and the configuration, and Debian's must not shadow them.
mkdir -p "$MULTIARCH"
cp -a "$stage/usr/lib/aarch64-linux-gnu/." "$MULTIARCH/"
[ -d "$stage/lib/aarch64-linux-gnu" ] && cp -a "$stage/lib/aarch64-linux-gnu/." "$MULTIARCH/"
cp "$stage/.packages" "$MULTIARCH/.vscode-glibc-packages"
ln -sf "$MULTIARCH/ld-linux-aarch64.so.1" /lib/ld-linux-aarch64.so.1
rm -rf "$stage"

log "installing VS Code into $PREFIX"
tarball=${VSCODE_TARBALL:-}
if [ -z "$tarball" ]; then
    tarball="$CACHE/vscode-linux-arm64.tar.gz"
    curl -fL --retry 3 -o "$tarball" "$URL"
fi
new="$PREFIX.new"
rm -rf "$new"
mkdir -p "$new"
if [ "$tarball" = - ]; then tar -xzf - -C "$new" --strip-components=1
else tar -xzf "$tarball" -C "$new" --strip-components=1; fi
# Copilot is a 160 MB built-in that users who want it reinstall from the marketplace;
# the other files are for platforms this device is not.
rm -rf "$new/resources/app/extensions/copilot" \
    "$new"/resources/app/node_modules.asar.unpacked/@github/copilot-sdk-linux-x64 \
    "$new/resources/app/node_modules.asar.unpacked/windows-foreground-love" \
    "$new/resources/app/node_modules.asar.unpacked/@vscode/deviceid"
find "$new" -path '*linux-x64*' -prune -exec rm -rf {} + 2>/dev/null || true
find "$new" -name '*.win32-*' -exec rm -f {} + 2>/dev/null || true
rm -rf "$PREFIX.old"
[ -d "$PREFIX" ] && mv "$PREFIX" "$PREFIX.old"
mv "$new" "$PREFIX"
rm -rf "$PREFIX.old"
[ -z "${VSCODE_TARBALL:-}" ] && rm -f "$tarball"

log "checking that every library resolves to glibc"
missing=$(/lib/ld-linux-aarch64.so.1 --list "$PREFIX/code" | awk '/not found/ || ($3 ~ /^\/(usr\/)?lib\/[^a]/) { print }')
if [ -n "$missing" ]; then
    printf '%s\n' "$missing" >&2
    log "unresolved or musl libraries above; VS Code would not start" >&2
    exit 1
fi

install -d /usr/local/bin /usr/share/applications /usr/share/pixmaps
install -m 755 "$HERE/vscode-launch" /usr/local/bin/code
install -m 644 "$HERE/vscode-forward.mjs" /usr/local/lib/vscode-forward.mjs
install -m 644 "$PREFIX/resources/app/resources/linux/code.png" /usr/share/pixmaps/vscode.png
cat > /usr/share/applications/code.desktop <<'EOF'
[Desktop Entry]
Name=Visual Studio Code
Comment=Code Editing. Redefined.
GenericName=Text Editor
Exec=/usr/local/bin/code %F
Icon=vscode
Type=Application
StartupNotify=false
StartupWMClass=Code
Categories=TextEditor;Development;IDE;
MimeType=text/plain;inode/directory;
Keywords=vscode;code;editor;ide;
EOF

# First-run defaults for root: only written when the user has no settings yet.
# argv.json is VS Code's own place for Chromium flags it applies on every start.
mkdir -p /root/.vscode /root/.config/Code/User
[ -e /root/.vscode/argv.json ] || cat > /root/.vscode/argv.json <<'EOF'
{
    "disable-hardware-acceleration": true,
    "password-store": "basic",
    "enable-crash-reporter": false
}
EOF
[ -e /root/.config/Code/User/settings.json ] || install -m 644 "$HERE/vscode-settings.json" /root/.config/Code/User/settings.json

# Extensions every install gets. TypeScript 7 (the native "tsgo" language server, a Go
# binary) instead of the JavaScript tsserver: under emulation tsserver needs about 25 s
# to check the demo project where tsgo needs 1 s, so IntelliSense is usable at all.
# Best effort: without network the built-in TypeScript support is used. After the
# settings above, which turn off signature checks (vsce-sign hangs under the emulator).
HOME=/root timeout 600 "$PREFIX/bin/code" --no-sandbox --user-data-dir /root/.config/Code \
    --install-extension typescriptteam.native-preview >/dev/null 2>&1 ||
    log "warning: could not install TypeScript 7 (offline?); using the built-in TypeScript support"

# The desktop's icon cache is per style; rebuild it so the launcher shows the VS Code icon.
command -v ish-apply-style >/dev/null && ish-apply-style --current >/dev/null 2>&1 || true

log "installed $(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$PREFIX/resources/app/package.json" | head -n1) ($(du -sh "$PREFIX" | cut -f1) app, $(du -sh "$MULTIARCH" | cut -f1) glibc libraries)"
