#!/bin/sh
# Installs Wine into the Alpine guest. Runs inside the guest, as root:
#   sh install-wine.sh               # Wine 10 for ARM64 Windows programs (Debian trixie)
#   BOX64=1 sh install-wine.sh       # also Box64 + Wine 10 x86_64 (WoW64) for x86 programs
#
# Wine is glibc software and Alpine is musl. Like install-vscode.sh, the glibc libraries
# come from Debian (debfetch.mjs, same directory) and live only in the multiarch
# directory /usr/lib/aarch64-linux-gnu plus the loader /lib/ld-linux-aarch64.so.1.
#
# Debian's arm64 Wine runs ARM64 Windows programs (aarch64 PE) as native code: Wine's own
# programs (notepad, winecfg, winemine, regedit, cmd, explorer) and the ARM64 builds that
# open-source projects publish (Notepad++, 7-Zip, PuTTY). x86 programs need BOX64=1:
# Box64 (Debian) runs an x86_64 Wine, whose WoW64 build also covers 32-bit programs
# without 32-bit Linux libraries.
#
# Windows programs show up through Xwayland (ishwl-x11) inside one Wine virtual desktop
# with a taskbar ("shell"), so every Windows window lives in a single LinPad window.
set -eu
unset LD_PRELOAD LD_LIBRARY_PATH
HERE=$(cd "$(dirname "$0")" && pwd)
DEBIAN_SUITE=${DEBIAN_SUITE:-trixie}
MULTIARCH=/usr/lib/aarch64-linux-gnu
CACHE=${CACHE:-/var/cache/wine-install}
BOX64=${BOX64:-0}
WINE_X64_URL=${WINE_X64_URL:-https://github.com/Kron4ek/Wine-Builds/releases/download/10.0/wine-10.0-amd64-wow64.tar.xz}
WINE_X64_PREFIX=/opt/wine-x64

# What Wine's Unix side links or dlopens for a desktop session. Left out on purpose
# (and passed to --skip): multimedia (ffmpeg, GStreamer), scanners/cameras, smart
# cards, ISDN, OpenCL, USB, PulseAudio. They only matter for programs that need them
# and add ~300 MB of libraries.
DEBS="wine wine64 libwine fonts-wine libxcomposite1 libxcursor1 libxfixes3 libxi6
libxinerama1 libxrandr2 libxrender1 libxxf86vm1 libgnutls30t64"
SKIP="libavcodec61,libavformat61,libavutil59,libgstreamer1.0-0,libgstreamer-plugins-base1.0-0,\
libgphoto2-6t64,libgphoto2-port12t64,libpcap0.8t64,libpcsclite1,libcapi20-3t64,\
ocl-icd-libopencl1,libusb-1.0-0,libpulse0"
[ "$BOX64" = 1 ] && DEBS="$DEBS box64 libgcc-s1-amd64-cross libstdc++6-amd64-cross"

log() { printf '%s\n' "install-wine: $*"; }

command -v node >/dev/null || apk add -q nodejs
command -v xzcat >/dev/null || apk add -q xz
command -v curl >/dev/null || apk add -q curl
mkdir -p "$CACHE"

log "resolving Wine and its glibc library closure (Debian $DEBIAN_SUITE)"
stage="$CACHE/stage"
rm -rf "$stage"
# shellcheck disable=SC2086
node "$HERE/debfetch.mjs" --suite "$DEBIAN_SUITE" --cache "$CACHE/debs" --dest "$stage" --skip "$SKIP" $DEBS
mkdir -p "$MULTIARCH"
cp -a "$stage/usr/lib/aarch64-linux-gnu/." "$MULTIARCH/"
[ -d "$stage/lib/aarch64-linux-gnu" ] && cp -a "$stage/lib/aarch64-linux-gnu/." "$MULTIARCH/"
ln -sf "$MULTIARCH/ld-linux-aarch64.so.1" /lib/ld-linux-aarch64.so.1
# Wine itself keeps Debian's layout: it finds its DLLs and data relative to ntdll.so.
mkdir -p /usr/lib/wine /usr/share/wine
cp -a "$stage/usr/lib/wine/." /usr/lib/wine/
cp -a "$stage/usr/share/wine/." /usr/share/wine/
cp "$stage/.packages" "$MULTIARCH/.wine-glibc-packages"
if [ "$BOX64" = 1 ]; then
    install -m 755 "$stage/usr/bin/box64" /usr/local/bin/box64
    mkdir -p /usr/x86_64-linux-gnu
    cp -a "$stage/usr/x86_64-linux-gnu/." /usr/x86_64-linux-gnu/
    [ -e "$stage/etc/box64.box64rc" ] && install -m 644 "$stage/etc/box64.box64rc" /etc/box64.box64rc
fi
rm -rf "$stage"

if [ "$BOX64" = 1 ]; then
    log "installing x86_64 Wine (WoW64) into $WINE_X64_PREFIX"
    tarball="$CACHE/wine-x64.tar.xz"
    [ -s "$tarball" ] || curl -fL --retry 3 -o "$tarball" "$WINE_X64_URL"
    rm -rf "$WINE_X64_PREFIX.new"
    mkdir -p "$WINE_X64_PREFIX.new"
    tar -xJf "$tarball" -C "$WINE_X64_PREFIX.new" --strip-components=1
    # Static import libraries and headers are for building Windows programs.
    find "$WINE_X64_PREFIX.new" -name '*.a' -delete
    rm -rf "$WINE_X64_PREFIX.new/include" "$WINE_X64_PREFIX.new/share/man"
    rm -rf "$WINE_X64_PREFIX"
    mv "$WINE_X64_PREFIX.new" "$WINE_X64_PREFIX"
    rm -f "$tarball"
fi

log "checking that Wine's libraries resolve to glibc"
for f in /usr/lib/wine/wine64 "$MULTIARCH/wine/aarch64-unix/ntdll.so"; do
    missing=$(/lib/ld-linux-aarch64.so.1 --list "$f" | awk '/not found/ || ($3 ~ /^\/(usr\/)?lib\/[^a]/) { print }')
    if [ -n "$missing" ]; then
        printf '%s\n' "$missing" >&2
        log "unresolved or musl libraries for $f; Wine would not start" >&2
        exit 1
    fi
done

install -d /usr/local/bin /usr/share/applications
# The launcher: no musl preloads (the desktop session's LD_PRELOAD would break the glibc
# loader), one prefix per user, the "shell" virtual desktop, and its own Xwayland when
# started from the desktop. `wine-x64` is the same for x86 programs through Box64.
cat > /usr/local/bin/wine <<'EOF'
#!/bin/sh
# wine PROGRAM [ARGS]: runs a Windows program. ARM64 builds run natively; x86 builds
# need wine-x64 (Box64).
unset LD_PRELOAD
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine}" WINEDEBUG="${WINEDEBUG:--all}"
loader=${WINE_LOADER:-/usr/lib/wine/wine64}
server=${WINE_SERVER:-/usr/lib/wine/wineserver}
run() { if [ -n "${WINE_BOX64:-}" ]; then box64 "$@"; else "$@"; fi; }
# In the desktop (WAYLAND_DISPLAY set, no X server yet), one rootful Xwayland holds the
# whole Wine desktop. Later programs join it through the running wineserver, so only
# the first one starts Xwayland.
if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ] && command -v ishwl-x11 >/dev/null; then
    display=$(cat "/tmp/.wine-display-$(id -u)" 2>/dev/null || true)
    if [ -n "$display" ] && [ -S "/tmp/.X11-unix/X${display#:}" ]; then
        export DISPLAY="$display"
    else
        exec env ISHWL_APP=wine ishwl-x11 -g 1024x700 sh -c \
            'echo "$DISPLAY" > /tmp/.wine-display-$(id -u); exec "$0" "$@"' "$0" "$@"
    fi
fi
if [ ! -e "$WINEPREFIX/system.reg" ]; then
    WINEDLLOVERRIDES="mscoree,mshtml=" run "$loader" wineboot -i >/dev/null 2>&1
    run "$loader" reg add 'HKCU\Software\Wine\Explorer' /v Desktop /d shell /f >/dev/null 2>&1
    run "$loader" reg add 'HKCU\Software\Wine\Explorer\Desktops' /v shell /d 1024x700 /f >/dev/null 2>&1
    run "$server" -w
fi
run "$loader" "$@"
EOF
chmod 755 /usr/local/bin/wine
if [ "$BOX64" = 1 ]; then
    cat > /usr/local/bin/wine-x64 <<EOF
#!/bin/sh
# wine-x64 PROGRAM [ARGS]: x86_64 and 32-bit x86 Windows programs, through Box64.
export WINE_BOX64=1 WINE_LOADER=$WINE_X64_PREFIX/bin/wine WINE_SERVER=$WINE_X64_PREFIX/bin/wineserver
# Its own prefix always: an ARM64 prefix holds ARM64 DLLs that x86_64 Wine cannot load.
export WINEPREFIX="\${WINEPREFIX_X64:-\$HOME/.wine-x64}" BOX64_NOBANNER=1
exec /usr/local/bin/wine "\$@"
EOF
    chmod 755 /usr/local/bin/wine-x64
fi

desktop_entry() { # file name exec icon comment
    cat > "/usr/share/applications/$1.desktop" <<EOF
[Desktop Entry]
Name=$2
Comment=$5
Exec=$3
Icon=$4
Type=Application
Categories=Wine;
EOF
}
desktop_entry wine-notepad "Notepad (Windows)" "wine notepad" accessories-text-editor "Wine's Notepad"
desktop_entry wine-winecfg "Wine Configuration" "wine winecfg" preferences-system "Configure Wine"
desktop_entry wine-winemine "Minesweeper (Windows)" "wine winemine" applications-games "Wine's Minesweeper"
desktop_entry wine-explorer "Windows Desktop" "wine explorer" user-desktop "Wine desktop with Start menu"
command -v ish-apply-style >/dev/null && ish-apply-style --current >/dev/null 2>&1 || true

log "installed $(/usr/lib/wine/wine64 --version) ($(du -smc /usr/lib/wine "$MULTIARCH/wine" /usr/share/wine | tail -n1 | cut -f1) MB of Wine)"
[ "$BOX64" = 1 ] && log "and $(box64 --version 2>/dev/null | head -n1), $(BOX64_NOBANNER=1 box64 $WINE_X64_PREFIX/bin/wine --version 2>/dev/null) via wine-x64"
true
