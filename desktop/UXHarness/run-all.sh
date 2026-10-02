#!/bin/bash
# Runs the DesktopKit unit tests and every UI test shard (one per desktop style) on one
# simulator, then prints a summary. Exit status is non-zero if anything failed.
#   desktop/UXHarness/run-all.sh [shard ...]     shards: unit ish windows macos ubuntu kylin
# Env: SIM=simulator udid (default: the UX agent's iPad Air 13"), LOGS=directory for logs.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SIM=${SIM:-518E05EE-26E1-4302-B4D9-90537588D271}
LOGS=${LOGS:-${TMPDIR:-/tmp}/desktop-ux-tests}
DERIVED=${DERIVED:-${TMPDIR:-/tmp}/desktop-ux-derived}
DESTINATION="platform=iOS Simulator,id=$SIM"
SHARDS=("$@")
[ ${#SHARDS[@]} -eq 0 ] && SHARDS=(unit ish windows macos ubuntu kylin)
mkdir -p "$LOGS"

command -v xcodegen >/dev/null && (cd "$HERE" && xcodegen generate --quiet)
xcrun simctl boot "$SIM" >/dev/null 2>&1 || true

# xcodebuild sometimes lingers for minutes after the last test; stop it once the
# result line is in the log.
run() {
    local log=$1; shift
    "$@" >"$log" 2>&1 &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if grep -qE '^\*\* TEST (SUCCEEDED|FAILED) \*\*|^\*\* BUILD FAILED \*\*' "$log"; then
            sleep 2; kill "$pid" 2>/dev/null; break
        fi
        sleep 3
    done
    wait "$pid" 2>/dev/null
}

class_for() {
    case $1 in
        ish) echo DesktopUITests ;;
        windows) echo WindowsStyleUITests ;;
        macos) echo MacStyleUITests ;;
        ubuntu) echo UbuntuStyleUITests ;;
        kylin) echo KylinStyleUITests ;;
    esac
}

status=0
summary=()
for shard in "${SHARDS[@]}"; do
    log="$LOGS/$shard.log"
    if [ "$shard" = unit ]; then
        (cd "$HERE/../DesktopKit" && run "$log" xcodebuild test -scheme DesktopKit -destination "$DESTINATION" \
            -derivedDataPath "$DERIVED-unit")
    else
        cls=$(class_for "$shard")
        [ -z "$cls" ] && { echo "unknown shard: $shard"; exit 2; }
        (cd "$HERE" && run "$log" xcodebuild test -project DesktopUX.xcodeproj -scheme DesktopHarness \
            -destination "$DESTINATION" -derivedDataPath "$DERIVED" -only-testing:"DesktopUITests/$cls")
    fi
    # xcodebuild prints each result twice (runner and summary); count each test once.
    passed=$(grep -E "^Test Case .* passed" "$log" | sed 's/ (.*//' | sort -u | wc -l | tr -d ' ')
    failed=$(grep -E "^Test Case .* failed" "$log" | sed 's/ (.*//' | sort -u | wc -l | tr -d ' ')
    if grep -q "BUILD FAILED" "$log" || [ "$failed" -gt 0 ] || [ "$passed" -eq 0 ]; then status=1; fi
    summary+=("$(printf '%-8s %3d passed %3d failed   %s' "$shard" "$passed" "$failed" "$log")")
    grep -E "^.*\.swift:[0-9]+: error" "$log" | sed 's/^.*\/\([A-Za-z]*\.swift\)/  \1/' | head -10
done

echo
echo "Desktop UX tests"
printf '%s\n' "${summary[@]}"
[ $status -eq 0 ] && echo "ALL GREEN" || echo "FAILURES"
exit $status
