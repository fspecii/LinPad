#!/bin/sh
# Camera pack (Cheese): Cheese saves into the XDG Pictures and Videos folders
# (~/Pictures/Webcam, ~/Videos/Webcam), but without ~/.config/user-dirs.dirs GLib knows
# no such folders and Cheese falls back to the hidden ~/.gnome2/cheese/media. Name them,
# unless the user already has a user-dirs file.
set -eu
home=/root
dirs=$home/.config/user-dirs.dirs
mkdir -p "$home/Pictures/Webcam" "$home/Videos/Webcam"
if [ ! -e "$dirs" ]; then
    mkdir -p "${dirs%/*}"
    cat > "$dirs" <<'DIRS'
XDG_DESKTOP_DIR="$HOME/Desktop"
XDG_DOCUMENTS_DIR="$HOME/Documents"
XDG_DOWNLOAD_DIR="$HOME/Downloads"
XDG_MUSIC_DIR="$HOME/Music"
XDG_PICTURES_DIR="$HOME/Pictures"
XDG_VIDEOS_DIR="$HOME/Videos"
DIRS
fi
