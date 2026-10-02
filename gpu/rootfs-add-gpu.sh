#!/bin/bash
# Adds the guest GPU userspace to an iSH-ARM64 rootfs tarball:
#   Mesa (Alpine edge) Venus Vulkan driver, zink/EGL/GLES/GBM, vulkan-loader and
#   vulkan-tools, plus /etc/profile.d/gpu.sh with the environment defaults.
#   gpu/rootfs-add-gpu.sh rootfs-gui-lean-arm64.tar.gz rootfs-gui-lean-gpu-arm64.tar.gz
# The input is not modified. Needs network (Alpine CDN) and a built ish CLI
# (ISH=..., default build-gpu-off/ish; any build works, the device is not used).
# See gpu/DESIGN.md, "Guest userspace".
set -euo pipefail
ROOT=/Volumes/ExternalHD/Dev/ish-arm64
IN=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
OUT=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
ISH=${ISH:-$ROOT/build-gpu-off/ish}
FAKEFSIFY=${FAKEFSIFY:-$(dirname "$ISH")/tools/fakefsify}
EDGE=https://dl-cdn.alpinelinux.org/alpine/edge/main
# Venus first shipped for aarch64 in edge; 3.21's Mesa 24.2 has neither the ICD nor a
# zink that accepts a renderer without dma-buf. Pinned so every rootfs gets the same stack.
MESA=26.2.3-r1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rootfs-gpu.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
echo "unpacking $IN"
"$FAKEFSIFY" "$IN" "$WORK/fs"

"$ISH" -f "$WORK/fs" /bin/sh -s <<EOF
set -e
apk update -q
# Mesa 26 needs symbols that 3.21's libxcb (dri3 1.4) and libwayland-client (1.24)
# lack; musl has no symbol versions, so apk cannot see that and they are upgraded
# explicitly. Both are backward compatible.
apk add -q --upgrade --repository $EDGE libxcb wayland-libs-client libdrm
apk add -q --repository $EDGE \
    mesa-vulkan-virtio=$MESA mesa-dri-gallium=$MESA mesa-egl=$MESA mesa-gles=$MESA \
    mesa-gbm=$MESA mesa-gl=$MESA vulkan-loader vulkan-tools
mkdir -p /etc/profile.d
cat > /etc/profile.d/gpu.sh <<'PROFILE'
# GPU acceleration through the emulated virtio-gpu node (gpu/DESIGN.md in iSH-ARM64).
# Only set when the emulator provides the device, so CPU-only builds are unaffected.
if [ -c /dev/dri/renderD128 ]; then
    # Vulkan: the Venus driver only (lavapipe stays installed but is not enumerated).
    export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/virtio_icd.aarch64.json
    # The node is virtio_gpu, whose own DRI driver (virgl) needs a capset this device
    # does not offer; GL/GLES/GBM on it must go through zink.
    export MESA_LOADER_DRIVER_OVERRIDE=zink
    # Vulkan WSI on Wayland: render on the GPU, present as wl_shm (ishwl imports no dma-bufs).
    export MESA_VK_WSI_DEBUG=sw
fi
PROFILE
chmod 644 /etc/profile.d/gpu.sh
rm -rf /var/cache/apk/*
echo "installed: \$(apk info -v 2>/dev/null | grep -E '^(mesa-vulkan-virtio|mesa-dri-gallium|vulkan-loader)-' | tr '\n' ' ')"
EOF

echo "packing $OUT"
"$(dirname "$FAKEFSIFY")/unfakefsify" "$WORK/fs" "$OUT"
ls -la "$OUT"
