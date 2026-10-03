#!/bin/bash
# Lifecycle test in the simulator: open apps, leave the screen, let "iPadOS" end LinPad
# while it is in the background, launch it again, and check what came back.
#   desktop/simrun-lifecycle.sh OUTDIR
# Steps (screenshots OUTDIR/lc-*.png, automation log OUTDIR/automation.log):
#   1. fresh install (rootfs-gui-lean), launch with the test-only remote control
#   2. open the Text Editor (untitled) and type into it, open foot (a Linux window)
#   3. background: Settings comes to the front; LinPad's flush runs (lc-2-background)
#   4. foreground again: windows redraw, typing still reaches the editor (lc-3-resumed)
#   5. background again, then `simctl terminate` while suspended (iPadOS ending it)
#   6. launch again: the windows come back, the editor shows its unsaved text, the
#      "Restored your session" toast is up (lc-4-restored)
# Env: SIM (default: the lifecycle agent's iPad Air 11-inch (M3)), NOBUILD=1, BUILD=dir.
# The location permission is never requested: -lifecycle.mockLocationAccess denied.
set -euo pipefail
ROOT=/Volumes/ExternalHD/Dev/ish-arm64
cd "$ROOT"
export PATH=/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/llvm/bin:$PATH
OUT=${1:?usage: simrun-lifecycle.sh OUTDIR}
mkdir -p "$OUT"
SIM=${SIM:-311290AE-04BA-4B74-B6A6-80FAE34BD089}
BUNDLE_ID=com.valentinneagu.ish.arm64
BUILD=${BUILD:-/Volumes/ExternalHD/Dev/ipad-jit/lifecycle-work/build-sim}
APP="$BUILD/Release-iphonesimulator/iSH ARM64.app"
ROOTFS=${ROOTFS:-rootfs-gui-lean-arm64.tar.gz}
AUTO=/tmp/ish-automation/$SIM
ARGS=(-desktop.debugAutomation YES -lifecycle.mockLocationAccess denied)

if [ -z "${NOBUILD:-}" ]; then
    if ! xcodebuild -project iSH.xcodeproj -target iSH-ARM64 -configuration Release \
            -sdk iphonesimulator ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SYMROOT="$BUILD" \
            IPHONEOS_DEPLOYMENT_TARGET=17.0 CODE_SIGNING_ALLOWED=NO \
            SWIFT_ACTIVE_COMPILATION_CONDITIONS=DESKTOP_AUTOMATION build > "$OUT/build.log" 2>&1; then
        grep -E "^[^ ].*error:" "$OUT/build.log" | sort -u | head -30
        echo "build failed, full log: $OUT/build.log"
        exit 1
    fi
fi
cp "$ROOTFS" "$APP/root.tar.gz"
codesign -f -s - "$APP" >/dev/null 2>&1

booted=$(xcrun simctl list devices booted | grep -c Booted || true)
if ! xcrun simctl list devices booted | grep -q "$SIM"; then
    [ "$booted" -lt 3 ] || { echo "3 simulators are booted already; try later"; exit 2; }
    xcrun simctl boot "$SIM"
fi
xcrun simctl terminate "$SIM" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$SIM" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIM" "$APP"
rm -rf ~/Library/Developer/CoreSimulator/Devices/"$SIM"/data/Library/Caches/com.apple.containermanagerd/Dead/* 2>/dev/null || true
xcrun simctl spawn "$SIM" defaults write "$BUNDLE_ID" desktop.enabled -bool YES
xcrun simctl spawn "$SIM" defaults write "$BUNDLE_ID" desktop.onboarded -bool YES
rm -rf "$AUTO" && mkdir -p "$AUTO/in"

n=0
cmd() { n=$((n + 1)); printf '%s' "$1" > "$AUTO/in/$(printf '%04d' $n).cmd"; }
wait_log() { # PATTERN SECONDS
    local i=0
    until grep -q "$1" "$AUTO/log" 2>/dev/null; do
        sleep 1; i=$((i + 1))
        [ $i -lt "$2" ] || { echo "timeout waiting for '$1'"; return 1; }
    done
}
shot() { xcrun simctl io "$SIM" screenshot "$OUT/$1.png" >/dev/null 2>&1; echo "screenshot $OUT/$1.png"; }
foreground_other() { xcrun simctl launch "$SIM" com.apple.Preferences >/dev/null; }

xcrun simctl launch "$SIM" "$BUNDLE_ID" "${ARGS[@]}" >/dev/null
wait_log "automation ready" 180
# The Linux session (ishwl) is up once the guest answers and foot can map.
sleep 20
cmd "open|editor"
cmd "lifecycle|editor-text|Draft typed before the lock\\nsecond line"
cmd "open|linux:foot"
sleep 25
cmd "state"
cmd "lifecycle|editors"
sleep 3
shot lc-1-apps

foreground_other
sleep 12
shot lc-2-background
xcrun simctl launch "$SIM" "$BUNDLE_ID" "${ARGS[@]}" >/dev/null
sleep 6
cmd "lifecycle|report"
cmd "lifecycle|editor-text|Draft typed before the lock\\nsecond line\\nthird line after resume"
cmd "state"
sleep 4
shot lc-3-resumed

foreground_other
sleep 12
cmd_after_kill=$(cat "$AUTO/log" | wc -l)
xcrun simctl terminate "$SIM" "$BUNDLE_ID"
sleep 3
cp "$AUTO/log" "$OUT/automation-before-kill.log"
rm -f "$AUTO/log"
xcrun simctl launch "$SIM" "$BUNDLE_ID" "${ARGS[@]}" >/dev/null
wait_log "automation ready" 120
sleep 30
cmd "lifecycle|report"
cmd "lifecycle|editors"
cmd "state"
sleep 4
shot lc-4-restored
cp "$AUTO/log" "$OUT/automation.log"
echo "log lines before the kill: $cmd_after_kill"
grep -E "previous-exit|last-flush|restored|editor |window " "$OUT/automation.log"
