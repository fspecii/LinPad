# Sourced by ishwl-session. Commands the desktop runs (playerctl for Now Playing) start
# outside the session, so they read the session bus address from here.
if [ -n "$DBUS_SESSION_BUS_ADDRESS" ]; then
    printf '%s\n' "$DBUS_SESSION_BUS_ADDRESS" > /tmp/ishwl-dbus-address
fi
