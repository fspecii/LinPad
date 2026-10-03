#!/bin/sh
# Persistent terminals pack: ish-terminal runs a plain terminal window inside tmux
# (linpad-tmux-attach). The user's own ~/.tmux.conf, if any, is left alone.
set -eu
mkdir -p /etc/ish
touch /etc/ish/terminal-tmux
if [ ! -e /root/.tmux.conf ]; then
    cat > /root/.tmux.conf <<'CONF'
# LinPad: mouse scrolling and selection, true colour in foot, long history.
set -g mouse on
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",foot:Tc"
set -g history-limit 20000
CONF
fi
