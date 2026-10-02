#!/bin/sh
# Adds (or with --remove, drops) an "NAME x11" launch rule in /etc/ishwl/apps, so ishwl
# starts that X11-only program inside its own Xwayland (wl-bridge/ishwl-launch).
rules=/etc/ishwl/apps
if [ "$1" = --remove ]; then
    [ -f "$rules" ] && sed -i "/^$2 x11\$/d" "$rules"
    exit 0
fi
grep -q "^$1 " "$rules" 2>/dev/null || echo "$1 x11" >> "$rules"
