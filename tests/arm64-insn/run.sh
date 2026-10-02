#!/bin/sh
# Build tests/arm64-insn/<name>.c natively (Apple Silicon) and inside the guest,
# run both and diff the output. Results must be identical.
#   ISH=build-cpu/ish FAKEFS=/path/to/fakefs OUT=/tmp/insn tests/arm64-insn/run.sh neon|conv|mem
set -e
N=$1
HERE=$(cd "$(dirname "$0")" && pwd)
ISH=${ISH:-$HERE/../../build-cpu/ish}
FAKEFS=${FAKEFS:?set FAKEFS to the guest fakefs directory}
OUT=${OUT:-/tmp/arm64-insn}
CFLAGS="-O1 -march=armv8.2-a+fp16+aes -pthread"
mkdir -p "$OUT"
cc $CFLAGS -o "$OUT/$N-native" "$HERE/$N.c"
"$OUT/$N-native" > "$OUT/$N-native.txt"
timeout 900 "$ISH" -f "$FAKEFS" /bin/sh -c \
    "mkdir -p /root/insn && cat > /root/insn/$N.c && cd /root/insn && gcc $CFLAGS -o $N $N.c && ./$N > $N-guest.txt" \
    < "$HERE/$N.c"
if diff "$OUT/$N-native.txt" "$FAKEFS/data/root/insn/$N-guest.txt" > "$OUT/$N.diff"; then
    echo "$N: match ($(wc -l < "$OUT/$N-native.txt") lines)"
else
    echo "$N: MISMATCH, see $OUT/$N.diff"
    exit 1
fi
