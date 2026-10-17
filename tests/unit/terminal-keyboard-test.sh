#!/bin/sh
# Exercise the production CoreGraphics helper without UIKit or a simulator.
# Additional arguments are passed to the compiler (for example -fsanitize=undefined).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/linpad-keyboard-test.XXXXXX")
trap 'rm -rf "$build"' EXIT HUP INT TERM
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -I"$root" "$@" \
    "$root/tests/unit/terminal-keyboard-test.c" -framework CoreGraphics \
    -o "$build/terminal-keyboard-test"
"$build/terminal-keyboard-test"
