#!/bin/sh
# Compile the production poll and real-fd readiness paths without a guest image.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/linpad-poll-test.XXXXXX")
trap 'rm -rf "$build"' EXIT HUP INT TERM
case $(uname -s) in
    Darwin) dead_strip=-Wl,-dead_strip ;;
    Linux) dead_strip=-Wl,--gc-sections ;;
    *) echo 'poll-test requires Darwin kqueue or Linux epoll' >&2; exit 1 ;;
esac
"${CC:-cc}" -std=gnu11 -O2 -DGUEST_ARM64=1 -I"$root" \
    -ffunction-sections -fdata-sections -pthread "$dead_strip" \
    "$root/tests/unit/poll-test.c" "${POLL_TEST_SOURCE:-$root/fs/poll.c}" \
    "$root/fs/real.c" -o "$build/poll-test"
"$build/poll-test" "$@"
