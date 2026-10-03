#!/bin/sh
# Removes what install.sh added (with the VLC pack).
rm -f /usr/share/linpad/radio/linpad-radio.xspf /usr/share/applications/linpad-radio.desktop
rmdir /usr/share/linpad/radio 2>/dev/null
[ "$(readlink /root/Music/Radio.xspf 2>/dev/null)" = /usr/share/linpad/radio/linpad-radio.xspf ] &&
    rm -f /root/Music/Radio.xspf
true
