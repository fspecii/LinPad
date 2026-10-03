#!/bin/sh
# Document Scanner pack, after `apk add tesseract-ocr ffmpeg imagemagick ...`: the
# linpad-scan script and its launcher entry, which are LinPad's own, not an apk package.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
install -D -m 755 "$here/linpad-scan" /usr/local/bin/linpad-scan
install -D -m 644 "$here/linpad-scan.desktop" /usr/share/applications/linpad-scan.desktop
mkdir -p /root/Documents/Scans
