#!/bin/sh
# Fails if tracked files (or commit messages in an optional range) carry a personal
# Apple team ID, a device UDID, or an AI co-author trailer.
#   .github/scripts/check-identifiers.sh [<base>..<head>]
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2

# Apple team IDs are 10 uppercase alphanumerics; placeholders (<your team>, "", #{...}) pass.
TEAM='DEVELOPMENT_TEAM[[:space:]]*[=:][[:space:]]*"?[A-Z0-9]{10}([^A-Za-z0-9]|$)'
# A14+ / M-series device UDIDs: 8 hex, dash, 16 hex (00008112-001A2B3C4D5E6F70).
UDID='(^|[^0-9A-Fa-f-])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}([^0-9A-Fa-f-]|$)'
# Split so this file does not match itself.
TRAILER='co-authored-by:[[:space:]]*'"claude"

status=0
report() { # title, grep output
    [ -n "$2" ] || return 0
    printf '%s\n%s\n\n' "$1" "$2"
    status=1
}

self=.github/scripts/check-identifiers.sh
report "Committed DEVELOPMENT_TEAM value (set it on the xcodebuild command line instead):" \
    "$(git grep -nIE "$TEAM" -- . ":(exclude)$self")"
report "Device UDID (keep it in an untracked file such as gpu/sim-udid.txt):" \
    "$(git grep -nIE "$UDID" -- . ":(exclude)$self")"
report "AI co-author trailer in a file:" \
    "$(git grep -nIiE "$TRAILER" -- . ":(exclude)$self")"

if [ $# -gt 0 ]; then
    report "AI co-author trailer in a commit message ($1):" \
        "$(git log --format='%h %s' -i -E --grep="$TRAILER" "$1")"
fi

[ $status = 0 ] && echo "identifier check: clean"
exit $status
