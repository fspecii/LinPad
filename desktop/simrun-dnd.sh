#!/bin/bash
# Build iSH-ARM64 (with the DesktopKit desktop) for the simulator, embed the dev rootfs,
# ad-hoc sign, install, launch, and save a screenshot.
#   desktop/simrun.sh [screenshot.png] [-- app launch arguments...]
# Env: WAIT=seconds before the screenshot (default 25), SIM=simulator udid,
#      NOBUILD=1 to reinstall the last build, CLASSIC=1 to launch the classic terminal UI,
#      ROOTFS=path to the rootfs tarball to embed (default rootfs-gui-lean-arm64.tar.gz:
#      Firefox and the Linux GUI session; rootfs-gui-arm64.tar.gz adds Falkon, Dillo and
#      Xwayland; rootfs-dev-arm64.tar.gz has no GUI), FRESH=1 to uninstall first so the rootfs is
#      imported again (it is only imported on the app's first launch).
#      AUTOMATION=1 compiles in the test-only remote control (DragDrop/DebugAutomation.swift),
#      enabled at run time with -desktop.debugAutomation YES.
# Example: ROOTFS=rootfs-gui-arm64.tar.gz FRESH=1 desktop/simrun.sh /tmp/x.png -- -desktop.autostart linux:thunar
set -euo pipefail
ROOT=/Volumes/ExternalHD/Dev/ish-arm64
cd "$ROOT"
export PATH=/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/llvm/bin:$PATH
SIM=${SIM:-F3A6AD48-7A55-400C-A189-52349AF6A317}
BUNDLE_ID=com.valentinneagu.ish.arm64
APP="build-sim-dnd/Release-iphonesimulator/iSH ARM64.app"
LOG_DIR=${TMPDIR:-/tmp}
BUILD_LOG="$LOG_DIR/ish-desktop-sim-dnd-build.log"
SHOT=$LOG_DIR/ish-desktop-sim-dnd.png
if [ $# -gt 0 ] && [ "$1" != "--" ]; then SHOT=$1; shift; fi
[ "${1:-}" = "--" ] && shift
ROOTFS=${ROOTFS:-rootfs-gui-arm64.tar.gz}

if [ -z "${NOBUILD:-}" ]; then
    if ! xcodebuild -project iSH.xcodeproj -target iSH-ARM64 -configuration Release \
            -sdk iphonesimulator ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SYMROOT="$PWD/build-sim-dnd" \
            IPHONEOS_DEPLOYMENT_TARGET=17.0 CODE_SIGNING_ALLOWED=NO \
            ${AUTOMATION:+SWIFT_ACTIVE_COMPILATION_CONDITIONS=DESKTOP_AUTOMATION} build > "$BUILD_LOG" 2>&1; then
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
# Each reinstall leaves the previous bundle (with its rootfs copy) behind; keep the Mac's disk lean.
rm -rf ~/Library/Developer/CoreSimulator/Devices/"$SIM"/data/Library/Caches/com.apple.containermanagerd/Dead/* 2>/dev/null || true
xcrun simctl spawn "$SIM" defaults write "$BUNDLE_ID" desktop.enabled -bool "$([ -n "${CLASSIC:-}" ] && echo NO || echo YES)"
xcrun simctl launch "$SIM" "$BUNDLE_ID" ${@+"$@"}
sleep "${WAIT:-25}"
xcrun simctl io "$SIM" screenshot "$SHOT" >/dev/null 2>&1
echo "screenshot: $SHOT"
