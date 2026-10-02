#!/bin/bash

# Try to figure out the user's PATH to pick up their installed utilities.
export PATH="$PATH:$(sudo -u "$USER" -i printenv PATH)"

mkdir -p "$MESON_BUILD_DIR"
cd "$MESON_BUILD_DIR"

config=$(meson introspect --buildoptions)
if [[ $? -ne 0 ]]; then
    export CC_FOR_BUILD="env -u SDKROOT -u IPHONEOS_DEPLOYMENT_TARGET xcrun clang"
    export CC="$CC_FOR_BUILD" # compatibility with meson < 0.54.0
    crossfile=cross.txt
    for arch in $ARCHS; do
        arch_args="'-arch', '$arch', $arch_args"
    done
    arch_args="${arch_args%%, }"
    meson_arch=${ARCHS%% *}
    case "$meson_arch" in
        arm64) meson_arch=aarch64 ;;
    esac
    cat | tee $crossfile <<-EOF
    [binaries]
    c = 'clang'
    ar = 'ar'
    pkg-config = 'pkg-config'

    [host_machine]
    system = 'darwin'
    cpu_family = '$meson_arch'
    cpu = '$meson_arch'
    endian = 'little'

    [built-in options]
    c_args = [$arch_args]
    
    [properties]
    needs_exe_wrapper = true
EOF
    guest_arch_opt=""
    if [[ -n "$GUEST_ARCH" ]]; then
        guest_arch_opt="-Dguest_arch=$GUEST_ARCH"
    fi
    (set -x; meson $SRCROOT --cross-file $crossfile $guest_arch_opt) || exit $?
    config=$(meson introspect --buildoptions)
fi

# GPU (gpu/DESIGN.md): ISH_VIRTGPU and ISH_VIRTGPU_PREFIX come from app/VirtGPU.xcconfig.
virtgpu=${ISH_VIRTGPU:-disabled}
pkg_config_path=
if [[ $virtgpu == enabled ]]; then
    pkg_config_path=$ISH_VIRTGPU_PREFIX/lib/pkgconfig
    if [[ ! -f $pkg_config_path/virglrenderer.pc ]]; then
        echo "error: $pkg_config_path/virglrenderer.pc missing; run gpu/build-third-party.sh (or set ISH_VIRTGPU=disabled)"
        exit 1
    fi
    # meson dirs created before the GPU work have no host pkg-config
    if [[ -f cross.txt ]] && ! grep -q pkg-config cross.txt; then
        awk '{ print } /^ *ar = .ar.$/ { match($0, /^ */); printf "%spkg-config = '\''pkg-config'\''\n", substr($0, 1, RLENGTH) }' cross.txt > cross.txt.new && mv cross.txt.new cross.txt
    fi
fi

buildtype=debug
b_ndebug=false
if [[ $CONFIGURATION == Release ]]; then
    buildtype=debugoptimized
fi
b_sanitize=none
if [[ -n "$ENABLE_ADDRESS_SANITIZER" ]]; then
    b_sanitize=address
fi
log=$ISH_LOG
log_handler=$ISH_LOGGER
kernel=ish
if [[ -n "$ISH_KERNEL" ]]; then
    kernel=$ISH_KERNEL
fi
kconfig=""
guest_arch=${GUEST_ARCH:-x86}
# Native JIT (jit/DESIGN.md): ISH_JIT_BUILD=enabled on the xcodebuild command line.
jit=${ISH_JIT_BUILD:-disabled}
for var in buildtype log b_ndebug b_sanitize log_handler kernel kconfig guest_arch virtgpu pkg_config_path jit; do
    old_value=$(python3 -c "import sys, json; v = next(x['value'] for x in json.load(sys.stdin) if x['name'] == '$var'); print(str(v).lower() if isinstance(v, bool) else ','.join(v) if isinstance(v, list) else v)" <<< $config)
    new_value=${!var}
    if [[ $old_value != $new_value ]]; then
        set -x; meson configure "-D$var=$new_value"
    fi
done
