#!/bin/sh
# LinPad Store fixup for apps that need System V IPC (iSH has none), e.g. Audacity's
# single-instance check. Installs libish-sysvipc.so (sysvipc-shim.c) and a wrapper in
# /usr/local/bin that preloads it, so the app's .desktop Exec finds the wrapper first.
#   sysvipc.sh install PROGRAM...   |   sysvipc.sh remove PROGRAM...
set -eu
here=$(cd "$(dirname "$0")" && pwd)
lib=/usr/local/lib/libish-sysvipc.so
action=$1
shift
case $action in
install)
    install -D -m 755 "$here/libish-sysvipc.so" "$lib"
    for program in "$@"; do
        real=/usr/bin/$program
        [ -x "$real" ] || { echo "sysvipc fixup: $real not found" >&2; exit 1; }
        cat > "/usr/local/bin/$program" <<WRAPPER
#!/bin/sh
# LinPad Store fixup (sysvipc.sh): $program needs System V IPC, which iSH lacks.
export LD_PRELOAD="$lib\${LD_PRELOAD:+ \$LD_PRELOAD}"
exec $real "\$@"
WRAPPER
        chmod 755 "/usr/local/bin/$program"
    done
    ;;
remove)
    for program in "$@"; do
        grep -q 'sysvipc.sh' "/usr/local/bin/$program" 2>/dev/null && rm -f "/usr/local/bin/$program"
    done
    ;;
*)
    echo "usage: sysvipc.sh install|remove PROGRAM..." >&2
    exit 2
    ;;
esac
