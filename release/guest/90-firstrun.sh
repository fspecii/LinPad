# Sourced by ishwl-session (/etc/ishwl/session.d): once the compositor is up, installs the
# optional packs chosen in onboarding in a visible terminal window. Onboarding usually
# finishes after the session has started, so this waits for /etc/ish/firstrun.json
# (up to 30 minutes). One watcher per boot; a session restart does not start a second one.
if command -v ish-firstrun >/dev/null 2>&1 && mkdir /tmp/.ish-firstrun.lock 2>/dev/null; then
    (
        i=0
        while [ $i -lt 360 ]; do
            if [ -S "$XDG_RUNTIME_DIR/wayland-0" ] &&
                { [ -r /etc/ish/firstrun.json ] || [ -s /etc/ish/reinstall-packages ]; }; then
                if [ -n "$(ish-firstrun --pending)" ]; then
                    WAYLAND_DISPLAY=wayland-0 ish-terminal --title "Setting up Linux for iPad" \
                        sh -c 'ish-firstrun; echo; echo "Press Enter to close."; read -r _'
                fi
                break
            fi
            sleep 5
            i=$((i + 1))
        done
    ) >/dev/null 2>&1 </dev/null &
fi
