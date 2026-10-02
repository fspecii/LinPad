#!/bin/bash
# Builds the host side of the GPU stack from pinned sources into
#   gpu/prefix-macos   (CLI emulator)
#   gpu/prefix-ios     (iOS device app)
#   gpu/prefix-iossim  (iOS simulator app)
# Each prefix gets a static libvirglrenderer.a (venus, render server as a thread,
# with gpu/patches/virglrenderer-ish.patch applied), MoltenVK's static libMoltenVK.a
# and pkg-config files for both.
#
# Needs: git, meson, ninja, pkg-config, Xcode, python3 with mako
#        (pip3 install --user mako). Downloads ~180 MB once (MoltenVK release).
# Usage: gpu/build-third-party.sh [macos] [ios] [iossim]   (default: all three)
set -euo pipefail

GPU=$(cd "$(dirname "$0")" && pwd)
VIRGL_URL=https://gitlab.freedesktop.org/virgl/virglrenderer.git
VIRGL_PIN=aafa9bd234a43c31004ec768ce000b21cf7b99ca
MVK_VERSION=1.4.2
MVK_URL=https://github.com/KhronosGroup/MoltenVK/releases/download/v$MVK_VERSION/MoltenVK-all.tar
MVK_SHA256=562a15a29bc358446a56a4091c5f7e08f604184187c1d34f712148b61ef17276

TARGETS=("$@")
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(macos ios iossim)

python3 -c 'import mako' 2>/dev/null || { echo "python3 module mako missing: pip3 install --user mako"; exit 1; }

# --- MoltenVK (prebuilt release, verified) ---
MVK_DIR=$GPU/third_party/MoltenVK-$MVK_VERSION
if [ ! -d "$MVK_DIR/MoltenVK/static/MoltenVK.xcframework" ]; then
    mkdir -p "$GPU/downloads"
    TAR=$GPU/downloads/MoltenVK-all-$MVK_VERSION.tar
    [ -f "$TAR" ] || curl -fL -o "$TAR" "$MVK_URL"
    echo "$MVK_SHA256  $TAR" | shasum -a 256 -c -
    rm -rf "$MVK_DIR" && mkdir -p "$MVK_DIR"
    tar -xf "$TAR" -C "$MVK_DIR" --strip-components 1 MoltenVK/MoltenVK MoltenVK/LICENSE
fi

# --- virglrenderer source at the pin, patched ---
SRC=$GPU/third_party/virglrenderer
if [ ! -d "$SRC/.git" ]; then
    git clone -q "$VIRGL_URL" "$SRC"
fi
git -C "$SRC" fetch -q origin 2>/dev/null || true
git -C "$SRC" checkout -q -f "$VIRGL_PIN"
git -C "$SRC" checkout -q -- .
git -C "$SRC" apply "$GPU/patches/virglrenderer-ish.patch"

VIRGL_OPTS=(-Dvenus=true -Dvrend=false -Drender-server-mode=thread -Drender-server-worker=thread
            -Ddefault_library=static -Dunstable-apis=true -Dvulkan-dload=false --buildtype=release)

build_target() {
    local t=$1 slice sdk triple frameworks
    case $t in
        macos)  slice=macos-arm64_x86_64; sdk=macosx; triple=arm64-apple-macos13.0
                frameworks="-framework Metal -framework IOSurface -framework QuartzCore -framework CoreGraphics -framework Foundation -framework AppKit -framework IOKit" ;;
        ios)    slice=ios-arm64; sdk=iphoneos; triple=arm64-apple-ios17.0
                frameworks="-framework Metal -framework IOSurface -framework QuartzCore -framework CoreGraphics -framework Foundation -framework UIKit" ;;
        iossim) slice=ios-arm64_x86_64-simulator; sdk=iphonesimulator; triple=arm64-apple-ios17.0-simulator
                frameworks="-framework Metal -framework IOSurface -framework QuartzCore -framework CoreGraphics -framework Foundation -framework UIKit" ;;
        *) echo "unknown target $t"; exit 1 ;;
    esac
    local P=$GPU/prefix-$t SYSROOT
    SYSROOT=$(xcrun --sdk $sdk --show-sdk-path)
    rm -rf "$P" && mkdir -p "$P/lib/pkgconfig" "$P/include"
    cp -R "$MVK_DIR/MoltenVK/include/." "$P/include/"
    cp "$MVK_DIR/MoltenVK/static/MoltenVK.xcframework/$slice/libMoltenVK.a" "$P/lib/"
    cat > "$P/lib/pkgconfig/vulkan.pc" <<EOF
prefix=$P
Name: vulkan
Description: MoltenVK $MVK_VERSION (static) as the Vulkan implementation
Version: 1.4.335
Libs: -L\${prefix}/lib -lMoltenVK -lc++ $frameworks
Cflags: -I\${prefix}/include
EOF
    mkdir -p "$GPU/cross"
    local cross=$GPU/cross/$t.txt
    cat > "$cross" <<EOF
[binaries]
c = ['xcrun', '--sdk', '$sdk', 'clang']
objc = ['xcrun', '--sdk', '$sdk', 'clang']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-target', '$triple', '-isysroot', '$SYSROOT']
objc_args = ['-target', '$triple', '-isysroot', '$SYSROOT']
c_link_args = ['-target', '$triple', '-isysroot', '$SYSROOT']
objc_link_args = ['-target', '$triple', '-isysroot', '$SYSROOT']

[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$P/lib/pkgconfig'

[host_machine]
system = 'darwin'
$( [ $t = macos ] || echo "subsystem = 'ios'" )
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
    local B=$GPU/build/virgl-$t
    rm -rf "$B"
    meson setup "$B" "$SRC" --cross-file "$cross" --prefix="$P" "${VIRGL_OPTS[@]}" >/dev/null
    ninja -C "$B" install >/dev/null
    echo "built $P ($(du -sh "$P/lib" | cut -f1))"
}

for t in "${TARGETS[@]}"; do
    build_target "$t"
done
