#!/bin/bash
# VS Code agent copy of simrun.sh (own simulator, SYMROOT build-sim-vscode).
# Build iSH-ARM64 (with the DesktopKit desktop) for the simulator, embed the dev rootfs,
# ad-hoc sign, install, launch, and save a screenshot.
#   desktop/simrun.sh [screenshot.png] [-- app launch arguments...]
# Env: WAIT=seconds before the screenshot (default 25), SIM=simulator udid,
#      AUTOMATION=1 compiles in the test-only remote control (DragDrop/DebugAutomation.swift),
#      enabled at run time with -desktop.debugAutomation YES.
#      NOBUILD=1 to reinstall the last build, CLASSIC=1 to launch the classic terminal UI,
#      ROOTFS=path to the rootfs tarball to embed (default rootfs-gui-lean-arm64.tar.gz:
#      Firefox and the Linux GUI session; rootfs-gui-arm64.tar.gz adds Falkon, Dillo and
#      Xwayland; rootfs-dev-arm64.tar.gz has no GUI), FRESH=1 to uninstall first so the rootfs is
#      imported again (it is only imported on the app's first launch).
# Example: ROOTFS=rootfs-gui-arm64.tar.gz FRESH=1 desktop/simrun.sh /tmp/x.png -- -desktop.autostart linux:thunar
set -euo pipefail
ROOT=/Volumes/ExternalHD/Dev/ish-arm64
cd "$ROOT"
export PATH=/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/llvm/bin:$PATH
# "iPad Air 13 vscode-ui" in the default device set (so xcodebuild test can use it), with
# its data directory symlinked to /Volumes/ExternalHD/Dev/ipad-jit/sim-ui-data: the internal
# disk is too small for a VS Code rootfs.
SIM=${SIM:-33790852-6492-4B6A-8CC6-2D164B527976}
SIMSET=${SIMSET:-$HOME/Library/Developer/CoreSimulator/Devices}
BUNDLE_ID=com.valentinneagu.ish.arm64
APP="build-sim-vscode/Release-iphonesimulator/iSH ARM64.app"
LOG_DIR=${TMPDIR:-/tmp}
BUILD_LOG="$LOG_DIR/ish-desktop-sim-vscode-build.log"
SHOT=$LOG_DIR/ish-desktop-sim-vscode.png
if [ $# -gt 0 ] && [ "$1" != "--" ]; then SHOT=$1; shift; fi
[ "${1:-}" = "--" ] && shift
ROOTFS=${ROOTFS:-/Volumes/ExternalHD/Dev/ipad-jit/rootfs-devtools-arm64.tar.gz}

if [ -z "${NOBUILD:-}" ]; then
    if ! xcodebuild -project iSH.xcodeproj -target iSH-ARM64 -configuration Release \
            -sdk iphonesimulator ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SYMROOT="$PWD/build-sim-vscode" \
            IPHONEOS_DEPLOYMENT_TARGET=17.0 CODE_SIGNING_ALLOWED=NO \
            ${AUTOMATION:+SWIFT_ACTIVE_COMPILATION_CONDITIONS=DESKTOP_AUTOMATION} build > "$BUILD_LOG" 2>&1; then
        grep -E "^[^ ].*error:" "$BUILD_LOG" | sort -u | head -30
        echo "build failed, full log: $BUILD_LOG"
        exit 1
    fi
fi

cp "$ROOTFS" "$APP/root.tar.gz"
codesign -f -s - "$APP" >/dev/null 2>&1

xcrun simctl --set "$SIMSET" boot "$SIM" >/dev/null 2>&1 || true
xcrun simctl --set "$SIMSET" terminate "$SIM" "$BUNDLE_ID" >/dev/null 2>&1 || true
[ -n "${FRESH:-}" ] && xcrun simctl --set "$SIMSET" uninstall "$SIM" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl --set "$SIMSET" install "$SIM" "$APP"
xcrun simctl --set "$SIMSET" spawn "$SIM" defaults write "$BUNDLE_ID" desktop.enabled -bool "$([ -n "${CLASSIC:-}" ] && echo NO || echo YES)"
xcrun simctl --set "$SIMSET" launch "$SIM" "$BUNDLE_ID" ${@+"$@"}
sleep "${WAIT:-25}"
xcrun simctl --set "$SIMSET" io "$SIM" screenshot "$SHOT" >/dev/null 2>&1
echo "screenshot: $SHOT"
