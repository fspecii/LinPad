#!/bin/sh
# LinPad Store fixup: a wrapper in /usr/local/bin for an app that needs help on iSH. The
# app's .desktop Exec finds the wrapper first on PATH; the package's own files stay as
# they are, so updates keep working.
#   wrap.sh install PROGRAM [--sysvipc] [--wayland] [--preload-svg] [--sdl-wayland]  |  wrap.sh remove PROGRAM
#   --sysvipc  preload libish-sysvipc.so (sysvipc-shim.c): iSH has no System V IPC, which
#              e.g. Audacity's single-instance check needs
#   --wayland  drop GDK_BACKEND=x11 that the .desktop file sets, so the GTK app opens on
#              LinPad's Wayland bridge instead of needing Xwayland
#   --preload-svg  preload gdk-pixbuf's SVG loader before the app starts threads: iSH has no
#              membarrier(), so musl's dlopen of a library with TLS falls back to signalling
#              every thread, which deadlocks while another thread waits on a futex (Audacity
#              hung on its splash screen loading the first SVG icon)
#   --sdl-wayland  SDL_VIDEODRIVER=wayland: SDL 2 tries only X11 when it is not told, and
#              LinPad has no X server outside an app's own Xwayland
set -eu
here=$(cd "$(dirname "$0")" && pwd)
lib=/usr/local/lib/libish-sysvipc.so
action=${1:-}
program=${2:-}
[ -n "$program" ] || { echo "usage: wrap.sh install|remove PROGRAM [--sysvipc] [--wayland] [--preload-svg] [--sdl-wayland]" >&2; exit 2; }
shift 2
wrapper=/usr/local/bin/$program
case $action in
install)
    real=/usr/bin/$program
    [ -x "$real" ] || { echo "wrap fixup: $real not found" >&2; exit 1; }
    lines=
    for option in "$@"; do
        case $option in
        --sysvipc)
            install -D -m 755 "$here/libish-sysvipc.so" "$lib"
            lines="${lines}export LD_PRELOAD=\"$lib\${LD_PRELOAD:+ \$LD_PRELOAD}\"
" ;;
        --wayland)
            lines="${lines}[ \"\${GDK_BACKEND:-}\" = x11 ] && unset GDK_BACKEND
" ;;
        --preload-svg)
            svg=$(ls /usr/lib/gdk-pixbuf-2.0/*/loaders/libpixbufloader*svg.so 2>/dev/null | head -1)
            [ -n "$svg" ] && lines="${lines}export LD_PRELOAD=\"$svg\${LD_PRELOAD:+ \$LD_PRELOAD}\"
" ;;
        --sdl-wayland)
            lines="${lines}export SDL_VIDEODRIVER=\${SDL_VIDEODRIVER:-wayland}
" ;;
        *) echo "wrap fixup: unknown option $option" >&2; exit 2 ;;
        esac
    done
    printf '#!/bin/sh\n# LinPad Store fixup (wrap.sh) for %s.\n%sexec %s "$@"\n' "$program" "$lines" "$real" > "$wrapper"
    chmod 755 "$wrapper"
    ;;
remove)
    grep -q 'LinPad Store fixup (wrap.sh)' "$wrapper" 2>/dev/null && rm -f "$wrapper"
    exit 0
    ;;
*)
    echo "usage: wrap.sh install|remove PROGRAM [--sysvipc] [--wayland] [--preload-svg] [--sdl-wayland]" >&2
    exit 2
    ;;
esac
