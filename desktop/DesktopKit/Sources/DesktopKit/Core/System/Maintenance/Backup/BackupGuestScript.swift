import Foundation

/// The guest side of Settings › Maintenance › Back Up and Restore. Running tar inside Linux
/// keeps what the fakefs stores outside the files themselves (owners, modes, symlinks,
/// device nodes); the host only moves the finished archive.
///
/// `invocation(_:)` prepends the arguments; every command prints "@@" lines the service
/// reads. The script is also run on a cloned fakefs with the Mac CLI emulator
/// (desktop/DesktopKit/Tests/backup-roundtrip.sh extracts it from this file), so keep it
/// between the two marker lines with no Swift interpolation.
enum BackupGuestScript {
    /// Where backups and restores stage their files in the guest (on the fakefs, not a
    /// tmpfs, so a large archive does not need RAM).
    static let workRoot = "/var/tmp/linpad-backup"

    static func invocation(_ arguments: [String]) -> String {
        "set -- " + arguments.map(\.shellQuoted).joined(separator: " ") + "\n" + source
    }

    // BEGIN GUEST SCRIPT
    static let source = #"""
# Commands (positional parameters):
#   scan PRIMARY...   @@total KB for /root and /home, then "@@candidate KB<TAB>PATH" for every
#                     directory matching "name:GLOB" or "path:GLOB" (pruned, so never nested)
#   facts             versions, the apk world and linpad-apps state, for the manifest
#   list WORK         WORK/list: what /root and /home hold minus the find -path patterns in
#                     WORK/excludes (one per line); prints @@files COUNT
#   archive WORK COMP tars WORK/list and appends the compressed stream (COMP: zstd or gzip)
#                     to WORK/backup.tar; the names tar has read go to WORK/names (progress)
#   cancel WORK       stops a running archive or restore
#   restore ARCHIVE OFFSET SIZE COMP MODE WORK
#                     unpacks SIZE bytes at OFFSET of ARCHIVE (COMP: zstd or gzip) over / (MODE
#                     merge) or, for MODE replace, into WORK/stage first and then swaps it in for
#                     /root and /home, moving the old ones aside
set -u
command=$1
shift
cd / || exit 1

roots() {
    for top in root home; do
        if [ -d "/$top" ]; then printf '%s\n' "$top"; fi
    done
}

scan() {
    tops=$(roots)
    if [ -z "$tops" ]; then
        echo "@@total 0"
        return 0
    fi
    echo "@@total $(du -skx $tops 2>/dev/null | awk '{ sum += $1 } END { print sum + 0 }')"
    count=$#
    index=0
    for primary in "$@"; do
        if [ "$index" -gt 0 ]; then set -- "$@" -o; fi
        case $primary in
            name:*) set -- "$@" -name "${primary#name:}" ;;
            path:*) set -- "$@" -path "${primary#path:}" ;;
            *) set -- "$@" -name "$primary" ;;
        esac
        index=$((index + 1))
    done
    shift "$count"
    if [ $# -eq 0 ]; then return 0; fi
    find $tops -xdev \( "$@" \) -prune -print0 2>/dev/null | xargs -0 -r du -sk 2>/dev/null | sed 's/^/@@candidate /'
    return 0
}

facts() {
    echo "@@rootfs $(cat /usr/share/ish/rootfs-version 2>/dev/null)"
    echo "@@kit $(cat /usr/share/ish/repair-kit-version 2>/dev/null)"
    if command -v zstd >/dev/null 2>&1; then echo "@@zstd yes"; else echo "@@zstd no"; fi
    if [ -f /etc/apk/world ]; then sed 's/^/@@world /' /etc/apk/world; fi
    if command -v linpad-apps >/dev/null 2>&1; then
        linpad-apps state 2>/dev/null | sed -n '1s/^/@@state /p'
    fi
    return 0
}

list() {
    work=$1
    tops=$(roots)
    set --
    if [ -f "$work/excludes" ]; then
        while IFS= read -r excluded; do
            if [ -n "$excluded" ]; then set -- "$@" -o -path "$excluded"; fi
        done < "$work/excludes"
    fi
    if [ $# -gt 0 ]; then
        shift
        find $tops -xdev \( "$@" \) -prune -o -print > "$work/list"
    else
        find $tops -xdev -print > "$work/list"
    fi
    echo "@@files $(wc -l < "$work/list" | tr -d ' ')"
    return 0
}

archive() {
    work=$1
    compressor=$2
    rm -f "$work/cancel" "$work/names" "$work/pid" "$work/tar.status" "$work/compressor.status"
    case $compressor in
        zstd) set -- nice -n 10 zstd -q -3 -T0 ;;
        gzip) set -- nice -n 10 gzip -1 ;;
        *) echo "@@fail Unknown compression: $compressor"; return 1 ;;
    esac
    {
        tar -c -v -f - --no-recursion -T "$work/list" 2>"$work/names" &
        echo $! > "$work/pid"
        wait $!
        echo $? > "$work/tar.status"
    } | {
        "$@" >> "$work/backup.tar"
        echo $? > "$work/compressor.status"
    }
    tar_status=$(cat "$work/tar.status" 2>/dev/null || echo 1)
    compressor_status=$(cat "$work/compressor.status" 2>/dev/null || echo 1)
    if [ -e "$work/cancel" ]; then
        echo "@@cancelled"
        return 130
    fi
    grep '^tar: ' "$work/names" | head -n 20 | sed 's/^/@@warn /'
    if [ "$compressor_status" != 0 ]; then
        echo "@@fail Compressing the backup stopped (status $compressor_status). The iPad may be out of space."
        return 1
    fi
    if [ "$tar_status" != 0 ] && ! grep -q '^tar: ' "$work/names"; then
        echo "@@fail tar stopped (status $tar_status)."
        return 1
    fi
    echo "@@done"
    return 0
}

cancel() {
    work=$1
    : > "$work/cancel"
    if [ -f "$work/pid" ]; then kill "$(cat "$work/pid")" 2>/dev/null; fi
    if [ -f "$work/parent" ]; then pkill -P "$(cat "$work/parent")" 2>/dev/null; fi
    return 0
}

restore() {
    archive=$1
    offset=$2
    size=$3
    compressor=$4
    mode=$5
    work=$6
    rm -f "$work/cancel" "$work/names" "$work/pid" "$work/parent"
    case $compressor in
        zstd) set -- zstd -dc ;;
        gzip) set -- gzip -dc ;;
        *) echo "@@fail Unknown compression: $compressor"; return 1 ;;
    esac
    case $mode in
        merge) destination=/ ;;
        replace)
            destination="$work/stage"
            rm -rf "$destination"
            mkdir -p "$destination" || return 1
            ;;
        *) echo "@@fail Unknown restore mode: $mode"; return 1 ;;
    esac
    (
        set -o pipefail
        tail -c +$((offset + 1)) "$archive" | head -c "$size" | "$@" | tar -x -v -f - -C "$destination" > "$work/names" 2>"$work/errors"
    ) &
    echo $! > "$work/parent"
    wait $!
    status=$?
    if [ -e "$work/cancel" ]; then
        echo "@@cancelled"
        return 130
    fi
    head -n 20 "$work/errors" | sed 's/^/@@warn /'
    if [ "$status" != 0 ]; then
        echo "@@fail Unpacking the backup failed (status $status). Nothing was removed."
        return 1
    fi
    if [ "$mode" = replace ]; then
        aside="/var/lib/linpad/before-restore-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$aside" || return 1
        for top in root home; do
            if [ ! -d "$destination/$top" ]; then continue; fi
            if [ -e "/$top" ] && ! mv "/$top" "$aside/$top"; then
                echo "@@fail Could not move /$top aside."
                return 1
            fi
            if ! mv "$destination/$top" "/$top"; then
                mv "$aside/$top" "/$top"
                echo "@@fail Could not put the restored /$top in place; the old one is back."
                return 1
            fi
        done
        echo "@@aside $aside"
    fi
    echo "@@done"
    return 0
}

case $command in
    scan) scan "$@" ;;
    facts) facts ;;
    list) list "$@" ;;
    archive) archive "$@" ;;
    cancel) cancel "$@" ;;
    restore) restore "$@" ;;
    *) echo "@@fail Unknown command: $command"; exit 2 ;;
esac
"""#
    // END GUEST SCRIPT
}
