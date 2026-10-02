#!/bin/sh
# Cross-compile a C file for the aarch64 musl guest using the guest's own sysroot.
S=${SYSROOT:-/Volumes/ExternalHD/Dev/ipad-jit/fakefs-gpu/data}
exec /opt/homebrew/opt/llvm/bin/clang --target=aarch64-linux-musl --sysroot=$S -fuse-ld=lld \
  -nostdlib -Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1 -Wl,--allow-shlib-undefined \
  $S/usr/lib/crt1.o $S/usr/lib/crti.o "$@" -L$S/usr/lib -L$S/lib $S/lib/ld-musl-aarch64.so.1 $S/usr/lib/crtn.o
