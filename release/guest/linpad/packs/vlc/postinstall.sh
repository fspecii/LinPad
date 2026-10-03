#!/bin/sh
# Multimedia pack, after `apk add vlc vlc-qt qt5-qtwayland`: puts back LinPad's VLC
# pieces, which the release build compiled once (themes/guest/vlc/build-vlc-wayland.sh)
# and stashed here, so the iPad compiles nothing: the Wayland video plugins, the
# root/Qt-on-Wayland compat library, the ish-vlc launcher and its .desktop entry. Then the
# two-instruction patch that makes the Qt interface use Wayland (only for the exact
# vlc-qt build it was made for).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
plugins=/usr/lib/vlc/plugins
install -m 755 "$here/libwl_shm_plugin.so" "$here/libishxdg_plugin.so" "$plugins/video_output/"
install -D -m 755 "$here/libish-vlc-compat.so" /usr/local/lib/libish-vlc-compat.so
install -D -m 755 "$here/ish-vlc" /usr/local/bin/ish-vlc
install -D -m 644 "$here/vlc.desktop" /usr/share/applications/vlc.desktop
qt=$plugins/gui/libqt_plugin.so
word_at() { od -An -tx4 -j $(($2)) -N 4 "$1" | tr -d ' '; }
if [ "$(word_at "$qt" 0x6ff38)" != f0000b81 ]; then
    if [ "$(sha256sum "$qt" | cut -d' ' -f1)" = 46be20c0e4f2404655ac26a8b86241367020c528226ad824c7fe5d35a3467922 ]; then
        cp "$qt" "$qt.orig"
        printf '\201\013\000\360' | dd of="$qt" bs=1 seek=$((0x6ff38)) conv=notrunc 2>/dev/null
        printf '\041\240\004\221' | dd of="$qt" bs=1 seek=$((0x6ff44)) conv=notrunc 2>/dev/null
    else
        echo "vlc pack: unknown libqt_plugin.so, not patched; VLC's interface needs X11" >&2
    fi
fi
/usr/lib/vlc/vlc-cache-gen "$plugins"
# Internet radio (../radio): the curated station playlist and the "Radio (VLC)" launcher.
if [ -f "$here/../radio/install.sh" ]; then
    sh "$here/../radio/install.sh"
fi
