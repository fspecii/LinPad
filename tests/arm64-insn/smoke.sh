#!/bin/sh
# CPU smoke run for CI, a few minutes on Apple Silicon. For each engine (JIT, then the
# interpreter): the run.sh conformance tests built with gcc inside the guest and diffed
# against the host, the guest-only SMC and host-page-protection checks, and difffuzz on
# a fixed corpus from gen_fuzz_words.py.
#   ISH=build/ish FAKEFS=/path/to/fakefs tests/arm64-insn/smoke.sh
# FAKEFS is an Alpine aarch64 fakefs with gcc and musl-dev installed. The ish binary
# must be built with -Djit=enabled for the JIT pass to exercise the JIT.
# A difffuzz difference fails the run for both engines; STRICT_INTERP=0 only
# reports the interpreter's.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ISH=${ISH:?set ISH to the ish binary}
FAKEFS=${FAKEFS:?set FAKEFS to the guest fakefs directory}
OUT=${OUT:-/tmp/arm64-insn-smoke}
STRICT_INTERP=${STRICT_INTERP:-1}
export ISH FAKEFS
CFLAGS="-O1 -march=armv8.2-a+fp16+aes -pthread"
mkdir -p "$OUT"
failed=0

guest() { "$ISH" -f "$FAKEFS" /bin/sh -c "$1"; }
guest_build() { # name: copies tests/arm64-insn/<name>.c into the guest and builds it
    guest "mkdir -p /root/insn && cat > /root/insn/$1.c && cd /root/insn && gcc $CFLAGS -o $1 $1.c" \
        < "$HERE/$1.c"
}

echo "== building guest-only tests and difffuzz"
for t in smc hostprot difffuzz; do guest_build "$t"; done
cc -O1 -o "$OUT/difffuzz-native" "$HERE/difffuzz.c"
python3 "$HERE/gen_fuzz_words.py" > "$OUT/words.txt"
"$OUT/difffuzz-native" < "$OUT/words.txt" > "$OUT/fuzz-native.txt"
awk '$3 == "ILL" { print $1 }' "$OUT/fuzz-native.txt" | sort -u > "$OUT/native-ill.txt"

for engine in jit interp; do
    if [ "$engine" = jit ]; then
        ISH_JIT=1; export ISH_JIT
        tests="conv seq mem neon lane"
    else
        unset ISH_JIT
        tests="conv seq mem neon"
    fi
    echo "== $engine"
    for t in $tests; do
        OUT=$OUT/$engine sh "$HERE/run.sh" "$t" || failed=1
    done
    for t in smc hostprot; do
        result=$(guest "/root/insn/$t") || true
        if [ "$result" = "$t ok" ]; then echo "$t: ok"; else echo "$t: FAILED ($result)"; failed=1; fi
    done

    guest /root/insn/difffuzz < "$OUT/words.txt" > "$OUT/fuzz-$engine.txt"
    words=$(wc -l < "$OUT/words.txt" | tr -d ' ')
    wrong=$(diff "$OUT/fuzz-native.txt" "$OUT/fuzz-$engine.txt" | awk '/^[<>]/ { print $2 }' | sort -u | wc -l | tr -d ' ')
    # Encodings the host CPU implements but the guest gets wrong (not ILL-vs-executed).
    wrong_valid=$(diff "$OUT/fuzz-native.txt" "$OUT/fuzz-$engine.txt" | awk '/^[<>]/ { print $2 }' | sort -u \
        | comm -23 - "$OUT/native-ill.txt" | wc -l | tr -d ' ')
    echo "difffuzz ($engine): $wrong of $words encodings differ from the host ($wrong_valid of them allocated)"
    if [ "$wrong" != 0 ]; then
        diff "$OUT/fuzz-native.txt" "$OUT/fuzz-$engine.txt" | head -20 || true
        if [ "$engine" = jit ] || [ "$STRICT_INTERP" = 1 ]; then failed=1; fi
    fi
done

[ $failed = 0 ] && echo "arm64-insn smoke: all passed"
exit $failed
