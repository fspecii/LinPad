#!/bin/sh
# Multimedia pack removal: the files postinstall.sh added outside apk's packages.
rm -f /usr/local/bin/ish-vlc /usr/local/lib/libish-vlc-compat.so /usr/share/applications/vlc.desktop \
    /usr/lib/vlc/plugins/video_output/libwl_shm_plugin.so /usr/lib/vlc/plugins/video_output/libishxdg_plugin.so \
    /usr/lib/vlc/plugins/gui/libqt_plugin.so.orig
rmdir /usr/lib/vlc/plugins/video_output /usr/lib/vlc/plugins/gui /usr/lib/vlc/plugins /usr/lib/vlc 2>/dev/null
true
