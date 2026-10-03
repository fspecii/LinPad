#!/bin/sh
# Internet radio for VLC, installed by the VLC pack (vlc/postinstall.sh): the curated
# playlist (release/build-radio-playlist.py, stations from the Radio Browser directory),
# a "Radio (VLC)" launcher that also opens VLC's Icecast directory, and ~/Music/Radio.xspf
# pointing at the playlist so VLC's file dialog and the media library find it.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
install -D -m 644 "$here/linpad-radio.xspf" /usr/share/linpad/radio/linpad-radio.xspf
install -D -m 644 "$here/linpad-radio.desktop" /usr/share/applications/linpad-radio.desktop
mkdir -p /root/Music
[ -e /root/Music/Radio.xspf ] || [ -L /root/Music/Radio.xspf ] ||
    ln -s /usr/share/linpad/radio/linpad-radio.xspf /root/Music/Radio.xspf
