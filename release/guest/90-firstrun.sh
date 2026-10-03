# shellcheck shell=sh
# Sourced by ishwl-session (/etc/ishwl/session.d). After "Update Linux system" the packages
# the user had added are listed in /etc/ish/reinstall-packages; once the compositor is up,
# reinstall them in a visible terminal window. Optional apps chosen in onboarding are
# installed by the desktop itself (Settings › Apps shows the progress), not here.
# One watcher per boot; a session restart does not start a second one.
if command -v linpad-apps >/dev/null 2>&1 && [ -s /etc/ish/reinstall-packages ] &&
        mkdir /tmp/.ish-firstrun.lock 2>/dev/null; then
    (
        i=0
        while [ $i -lt 120 ]; do
            if [ -S "$XDG_RUNTIME_DIR/wayland-0" ]; then
                WAYLAND_DISPLAY=wayland-0 ish-terminal --title "LinPad: finishing the update" \
                    sh -c 'linpad-apps install reinstall; echo; echo "Press Enter to close."; read -r _'
                break
            fi
            sleep 5
            i=$((i + 1))
        done
    ) >/dev/null 2>&1 </dev/null &
fi
