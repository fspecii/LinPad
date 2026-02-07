#!/bin/bash
# Check if the provided compiler can target aarch64

CLANG="$1"

if [ -z "$CLANG" ]; then
    echo "Usage: $0 <clang-path>"
    exit 1
fi

# Try to compile a simple aarch64 program
TMPFILE=$(mktemp /tmp/check-cc-arm64.XXXXXX.c)
TMPOUT=$(mktemp /tmp/check-cc-arm64.XXXXXX.o)

cat > "$TMPFILE" << 'EOF'
void _start(void) {
    __asm__ volatile("svc #0");
}
EOF

"$CLANG" -target aarch64-linux-gnu -c "$TMPFILE" -o "$TMPOUT" 2>/dev/null
RESULT=$?

rm -f "$TMPFILE" "$TMPOUT"

if [ $RESULT -ne 0 ]; then
    echo "Error: $CLANG cannot compile for aarch64 target"
    exit 1
fi

echo "ARM64 cross-compiler check passed"
exit 0
