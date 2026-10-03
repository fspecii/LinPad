#!/bin/sh
# Sound Recorder pack: GNOME Sound Recorder keeps its recordings in
# ~/.local/share/org.gnome.SoundRecorder; ~/Music/Recordings shows them in Files and to
# other apps. An existing ~/Music/Recordings is left alone.
set -eu
home=/root
store=$home/.local/share/org.gnome.SoundRecorder
mkdir -p "$store" "$home/Music"
[ -e "$home/Music/Recordings" ] || [ -L "$home/Music/Recordings" ] || ln -s "$store" "$home/Music/Recordings"
