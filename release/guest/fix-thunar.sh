#!/bin/sh
# Thunar ships /usr/bin/thunar plus a /usr/bin/Thunar -> thunar symlink. On a
# case-insensitive disk (the Mac building the rootfs, the iOS simulator) both names are one
# backing file in the fakefs, and whichever apk writes last wins: the binary ends up
# overwritten by the link text, or the "thunar" entry disappears. Drop the alias and put
# the real binary back from the package. Harmless on case-sensitive disks.
set -eu
[ -e /usr/bin/Thunar ] || [ -L /usr/bin/Thunar ] && rm -f /usr/bin/Thunar
if ! head -c 4 /usr/bin/thunar 2>/dev/null | grep -q ELF; then
    echo "fix-thunar: restoring /usr/bin/thunar from the package"
    tmp=$(mktemp -d)
    apk update -q && (cd "$tmp" && apk fetch -q thunar && tar -xzf thunar-*.apk usr/bin/thunar)
    install -m 755 "$tmp/usr/bin/thunar" /usr/bin/thunar
    rm -rf "$tmp"
fi
head -c 4 /usr/bin/thunar | grep -q ELF
