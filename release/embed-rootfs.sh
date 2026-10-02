#!/bin/bash
# Puts a release rootfs into a built iSH ARM64 app and signs the app again.
#   release/embed-rootfs.sh APP ROOTFS.tar.gz            simulator build: ad-hoc signature
#   release/embed-rootfs.sh --device APP ROOTFS.tar.gz   device build: signs with the
#       identity, entitlements and embedded.mobileprovision Xcode used for APP
# The version stamp (ROOTFS.version, written by build-rootfs.sh) goes next to it as
# root.version: the app compares it with the installed root's to offer "Update Linux
# system". Checks the signature with `codesign -v --strict` afterwards.
set -euo pipefail
DEVICE=
[ "${1:-}" = --device ] && { DEVICE=1; shift; }
APP=${1:?usage: embed-rootfs.sh [--device] APP ROOTFS.tar.gz}
ROOTFS=${2:?usage: embed-rootfs.sh [--device] APP ROOTFS.tar.gz}
VERSION_FILE=${ROOTFS%.tar.gz}.version
[ -d "$APP" ] && [ -f "$ROOTFS" ] || { echo "missing $APP or $ROOTFS" >&2; exit 1; }

if [ -n "$DEVICE" ]; then
    # Read the signing setup before the bundle changes.
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/embed.XXXXXX")
    trap 'rm -rf "$WORK"' EXIT
    codesign -d --entitlements :"$WORK/entitlements.plist" "$APP" 2>/dev/null
    IDENTITY=${IDENTITY:-$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Apple Development: .*\)$/\1/p' | head -n1)}
    [ -n "$IDENTITY" ] || { echo "no Apple Development signature on $APP" >&2; exit 1; }
    [ -f "$APP/embedded.mobileprovision" ] || { echo "no embedded.mobileprovision in $APP" >&2; exit 1; }
fi

cp "$ROOTFS" "$APP/root.tar.gz"
if [ -f "$VERSION_FILE" ]; then
    cp "$VERSION_FILE" "$APP/root.version"
else
    rm -f "$APP/root.version"
    echo "warning: no $VERSION_FILE; the app will not offer system updates" >&2
fi

if [ -n "$DEVICE" ]; then
    codesign --force --sign "$IDENTITY" --entitlements "$WORK/entitlements.plist" \
        --generate-entitlement-der "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign -v --strict "$APP"
echo "embedded $(basename "$ROOTFS") ($(du -h "$APP/root.tar.gz" | cut -f1), version $(cat "$APP/root.version" 2>/dev/null || echo none)); signature ok"
