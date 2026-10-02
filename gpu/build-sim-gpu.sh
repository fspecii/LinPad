#!/bin/bash
# Build iSH-ARM64 for the simulator into build-sim-gpu (GPU is on by default through
# app/VirtGPU.xcconfig; run gpu/build-third-party.sh once first). Then gpu/simrun-gpu.sh.
set -euo pipefail
ROOT=/Volumes/ExternalHD/Dev/ish-arm64
cd "$ROOT"
export PATH=/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/llvm/bin:$PATH
xcodebuild -project iSH.xcodeproj -target iSH-ARM64 -configuration Release \
    -sdk iphonesimulator ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SYMROOT="$ROOT/build-sim-gpu" \
    IPHONEOS_DEPLOYMENT_TARGET=17.0 CODE_SIGNING_ALLOWED=NO build > /tmp/ish-gpu-sim-build.log 2>&1 ||
    { grep -E "error:" /tmp/ish-gpu-sim-build.log | sort -u | head -20; exit 1; }
echo "built: build-sim-gpu/Release-iphonesimulator/iSH ARM64.app"
