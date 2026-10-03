#!/bin/sh
# Builds the Store fixups' libraries. Run inside an aarch64 Alpine guest with build-base
# (the same way wl-bridge's preloads are built); the result is checked in next to this
# script so the repair kit can install it without a compiler on the iPad.
set -eu
cd "$(dirname "$0")"
${CC:-cc} -O2 -Wall -Wextra -fPIC -shared -o libish-sysvipc.so sysvipc-shim.c
strip libish-sysvipc.so
