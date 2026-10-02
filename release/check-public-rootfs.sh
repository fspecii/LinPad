#!/bin/bash
# Fails if a rootfs tarball contains something LinPad may not redistribute:
#   - Microsoft's VS Code binary (VSCODE=1 builds; the public image ships only its installer)
#   - Anthropic's Claude Code (@anthropic-ai/claude-code is proprietary; the public image
#     offers it as the "Claude Code" catalog item, installed from npm on the iPad)
#   - openKylin / Kylin logos (trademarks; the UKUI theme itself is GPL and stays)
#   release/check-public-rootfs.sh ROOTFS.tar.gz
set -euo pipefail
ROOTFS=${1:?usage: check-public-rootfs.sh ROOTFS.tar.gz}
[ -f "$ROOTFS" ] || { echo "no such file: $ROOTFS" >&2; exit 1; }

found=$(tar -tzf "$ROOTFS" | grep -E \
    -e '^\./opt/vscode/' \
    -e '^\./usr/local/lib/node_modules/@anthropic-ai/claude-code' \
    -e '^\./usr/local/bin/claude$' \
    -e '/distributor-logo-kylin[^/]*$' \
    -e '/kylin-startmenu[^/]*$' \
    -e '/openkylin[^/]*\.(png|svg)$' || true)
if [ -n "$found" ]; then
    echo "check-public-rootfs: $ROOTFS contains components that must not be published:" >&2
    printf '%s\n' "$found" | sed 's|/[^/]*$||' | sort | uniq -c | sort -rn | head -20 >&2
    exit 1
fi
echo "check-public-rootfs: ok ($(basename "$ROOTFS"))"
