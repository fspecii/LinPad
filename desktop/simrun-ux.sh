#!/bin/bash
# simrun.sh with its own simulator (iPad Air 13") and build directory (build-sim-ux), so it
# can run beside simrun.sh. Builds iSH-ARM64 (with the DesktopKit desktop) for the simulator, embeds the dev rootfs,
# ad-hoc signs, installs, launches, and saves a screenshot.
#   desktop/simrun-ux.sh [screenshot.png] [-- app launch arguments...]
# Env: WAIT=seconds before the screenshot (default 25), SIM=simulator udid,
#      NOBUILD=1 to reinstall the last build, CLASSIC=1 to launch the classic terminal UI,
#      ROOTFS=path to the rootfs tarball to embed (default rootfs-dev-arm64.tar.gz; the
#      GUI one is rootfs-gui-arm64.tar.gz), FRESH=1 to uninstall first so the rootfs is
#      imported again (it is only imported on the app's first launch).
# Example: ROOTFS=rootfs-gui-arm64.tar.gz FRESH=1 desktop/simrun-ux.sh /tmp/x.png -- -desktop.autostart linux:thunar
set -euo pipefail
ROOT=/Volumes/ExternalHD/Dev/ish-arm64
cd "$ROOT"
export PATH=/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/llvm/bin:$PATH
SIM=${SIM:-518E05EE-26E1-4302-B4D9-90537588D271}
BUNDLE_ID=com.valentinneagu.ish.arm64
APP="build-sim-ux/Release-iphonesimulator/iSH ARM64.app"
LOG_DIR=${TMPDIR:-/tmp}
BUILD_LOG="$LOG_DIR/ish-desktop-sim-ux-build.log"
SHOT=$LOG_DIR/ish-desktop-sim-ux.png
if [ $# -gt 0 ] && [ "$1" != "--" ]; then SHOT=$1; shift; fi
[ "${1:-}" = "--" ] && shift
ROOTFS=${ROOTFS:-rootfs-dev-arm64.tar.gz}

if [ -z "${NOBUILD:-}" ]; then
    if ! xcodebuild -project iSH.xcodeproj -target iSH-ARM64 -configuration Release \
            -sdk iphonesimulator ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SYMROOT="$PWD/build-sim-ux" \
            IPHONEOS_DEPLOYMENT_TARGET=17.0 CODE_SIGNING_ALLOWED=NO build > "$BUILD_LOG" 2>&1; then
        grep -E "^[^ ].*error:" "$BUILD_LOG" | sort -u | head -30
        echo "build failed, full log: $BUILD_LOG"
        exit 1
    fi
fi

cp "$ROOTFS" "$APP/root.tar.gz"
codesign -f -s - "$APP" >/dev/null 2>&1

xcrun simctl boot "$SIM" >/dev/null 2>&1 || true
xcrun simctl terminate "$SIM" "$BUNDLE_ID" >/dev/null 2>&1 || true
[ -n "${FRESH:-}" ] && xcrun simctl uninstall "$SIM" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIM" "$APP"
xcrun simctl spawn "$SIM" defaults write "$BUNDLE_ID" desktop.enabled -bool "$([ -n "${CLASSIC:-}" ] && echo NO || echo YES)"
xcrun simctl launch "$SIM" "$BUNDLE_ID" ${@+"$@"}
sleep "${WAIT:-25}"
xcrun simctl io "$SIM" screenshot "$SHOT" >/dev/null 2>&1
echo "screenshot: $SHOT"
