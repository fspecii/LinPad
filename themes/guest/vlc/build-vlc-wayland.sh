#!/bin/sh
# Runs INSIDE the guest. Builds the two VLC 3.0 plugins Alpine leaves out (its VLC is
# built without Wayland) so VLC's video gets its own native window through ishwl:
#   libwl_shm_plugin.so    VLC 3.0.21's modules/video_output/wayland/shm.c, unchanged
#   libishxdg_plugin.so    xdg-wm-base.c, VLC's xdg-shell window provider ported from
#                          unstable v5 to xdg_wm_base (the only shell ishwl offers)
# Idempotent: skipped when both plugins exist and are newer than the sources.
set -eu
SRC=$(cd "$(dirname "$0")" && pwd)
. "$SRC/../versions.sh"
PLUGINS=/usr/lib/vlc/plugins/video_output
OUT_SHM=$PLUGINS/libwl_shm_plugin.so
OUT_XDG=$PLUGINS/libishxdg_plugin.so
if [ -f "$OUT_SHM" ] && [ -f "$OUT_XDG" ] && [ "$OUT_XDG" -nt "$SRC/xdg-wm-base.c" ] && [ -f /usr/local/lib/libish-vlc-compat.so ]; then
    exit 0
fi

apk add -q --virtual .ish-vlc-build build-base pkgconf vlc-dev wayland-dev wayland-protocols curl
W=/tmp/vlc-wayland-build
rm -rf "$W"; mkdir -p "$W"
cd "$W"
VLC_RAW=https://raw.githubusercontent.com/videolan/vlc/$VLC_REF/modules/video_output/wayland
curl -fsSL -o shm.c "$VLC_RAW/shm.c"
curl -fsSL -o server-decoration.xml "$VLC_RAW/server-decoration.xml"
cp "$SRC/xdg-wm-base.c" .

PROTO=$(pkg-config --variable=pkgdatadir wayland-protocols)
gen() { wayland-scanner client-header "$1" "$2-client-protocol.h"; wayland-scanner private-code "$1" "$2-protocol.c"; }
gen "$PROTO/stable/xdg-shell/xdg-shell.xml" xdg-shell
gen "$PROTO/stable/viewporter/viewporter.xml" viewporter
gen server-decoration.xml server-decoration

CFLAGS="-O2 -fPIC -shared -std=gnu11 -D_GNU_SOURCE -D__PLUGIN__ -DN_(s)=s -I. $(pkg-config --cflags vlc-plugin wayland-client)"
LIBS="$(pkg-config --libs vlc-plugin wayland-client)"
# shellcheck disable=SC2086
gcc $CFLAGS -DMODULE_STRING='"wl_shm"' -DMODULE_NAME=wl_shm \
    shm.c viewporter-protocol.c -o "$OUT_SHM" $LIBS
# shellcheck disable=SC2086
gcc $CFLAGS -DMODULE_STRING='"ishxdg"' -DMODULE_NAME=ishxdg \
    xdg-wm-base.c xdg-shell-protocol.c server-decoration-protocol.c -o "$OUT_XDG" $LIBS

gcc -O2 -fPIC -shared "$SRC/vlc-compat.c" -o /usr/local/lib/libish-vlc-compat.so -ldl

# Alpine's Qt interface (X11-only build) starts Qt with "-platform xcb" (ThreadXCB in
# modules/gui/qt/qt.cpp passes a stack string "xcb"). Two instructions there are
# rewritten so it passes the plugin's own "wayland" string (.rodata) instead:
#   +0x6ff38  mov x1, sp        -> adrp x1, 0x1e2000
#   +0x6ff44  mov x4, #0        -> add  x1, x1, #0x128   (x4 is dead: canary scratch)
# Only the exact vlc-qt 3.0.21-r3 aarch64 build is patched; the original is kept as
# libqt_plugin.so.orig.
QT=/usr/lib/vlc/plugins/gui/libqt_plugin.so
word_at() { od -An -tx4 -j $(($2)) -N 4 "$1" | tr -d ' '; }
if [ "$(word_at "$QT" 0x6ff38)" != f0000b81 ]; then
    if [ "$(sha256sum "$QT" | cut -d' ' -f1)" = "$VLC_QT_SHA256" ]; then
        cp "$QT" "$QT.orig"
        printf '\201\013\000\360' | dd of="$QT" bs=1 seek=$((0x6ff38)) conv=notrunc 2>/dev/null
        printf '\041\240\004\221' | dd of="$QT" bs=1 seek=$((0x6ff44)) conv=notrunc 2>/dev/null
    else
        echo "build-vlc-wayland: unknown libqt_plugin.so, not patched; VLC's Qt interface needs X11" >&2
    fi
fi

/usr/lib/vlc/vlc-cache-gen "$(dirname "$PLUGINS")"
apk del -q .ish-vlc-build
cd /
rm -rf "$W"
echo "built $OUT_SHM $OUT_XDG"
