#!/bin/bash
# Install the -Dvirtgpu build (build-sim-gpu) into a dedicated simulator, launch it, and
# save a screenshot. Mirrors desktop/simrun.sh but never touches build-sim or the shared
# simulator. Build first with gpu/build-sim-gpu.sh.
#   gpu/simrun-gpu.sh [screenshot.png] [-- app launch arguments...]
# Env: WAIT (default 25), FRESH=1 (reinstall, re-import rootfs), CLASSIC=1 (terminal UI),
#      ROOTFS (default rootfs-gui-arm64.tar.gz)
set -euo pipefail
ROOT=/Volumes/ExternalHD/Dev/ish-arm64
cd "$ROOT"
SIM=${SIM:-$(cat gpu/sim-udid.txt)}
BUNDLE_ID=com.valentinneagu.ish.arm64
APP="build-sim-gpu/Release-iphonesimulator/iSH ARM64.app"
SHOT=${TMPDIR:-/tmp}/ish-gpu-sim.png
if [ $# -gt 0 ] && [ "$1" != "--" ]; then SHOT=$1; shift; fi
[ "${1:-}" = "--" ] && shift
ROOTFS=${ROOTFS:-rootfs-gui-arm64.tar.gz}
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
