#!/bin/sh
# Guest syscall regressions: each tests/syscalls/*.c is built with gcc inside the guest and
# run there. A test passes if it exits 0 and prints no FAIL line; it must also finish
# within TEST_TIMEOUT seconds (a hang is a failure).
#   ISH=build/ish FAKEFS=/path/to/fakefs tests/syscalls/smoke.sh [name-prefix]
# FAKEFS is an Alpine aarch64 fakefs with gcc and musl-dev installed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ISH=${ISH:?set ISH to the ish binary}
FAKEFS=${FAKEFS:?set FAKEFS to the guest fakefs directory}
TEST_TIMEOUT=${TEST_TIMEOUT:-60}
TIMEOUT=$(command -v timeout || command -v gtimeout || true)
# Every test runs under the timeout: without coreutils, perl's alarm (macOS has perl) kills it.
bounded() {
    if [ -n "$TIMEOUT" ]; then
        "$TIMEOUT" "$TEST_TIMEOUT" "$@"
    else
        perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$TEST_TIMEOUT" "$@"
    fi
}
CFLAGS="-O1 -pthread"
failed=0
for src in "$HERE"/${1:-}*.c; do
    name=$(basename "$src" .c)
    out=$(bounded "$ISH" -f "$FAKEFS" /bin/sh -c \
        "mkdir -p /root/sys && cd /root/sys && cat > $name.c && gcc $CFLAGS -o $name $name.c && ./$name" \
        < "$src" 2>&1)
    status=$?
    if [ $status -eq 0 ] && ! printf '%s\n' "$out" | grep -q '^FAIL'; then
        echo "ok   $name"
    else
        echo "FAIL $name (exit $status)"
        printf '%s\n' "$out" | tail -n 15 | sed 's/^/     /'
        failed=1
    fi
done
[ $failed = 0 ] && echo "syscall regressions: all passed"
exit $failed
