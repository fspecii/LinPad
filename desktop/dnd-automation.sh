#!/bin/sh
# Sends one command to the app's test-only automation hook (DragDrop/DebugAutomation.swift)
# and prints the log lines it produced. Usage: desktop/dnd-automation.sh 'COMMAND' [WAIT]
D=/tmp/ish-automation/${SIM:-F3A6AD48-7A55-400C-A189-52349AF6A317}
mkdir -p $D/in
before=$(wc -l < $D/log 2>/dev/null || echo 0)
f=$D/in/$(date +%s%N 2>/dev/null || date +%s)-$$.cmd
printf '%s' "$1" > $f.tmp && mv $f.tmp $f
sleep ${2:-2}
tail -n +$((before + 1)) $D/log
