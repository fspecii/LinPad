#!/bin/bash
# Parking the fakefs (what the app does just before iPadOS may suspend it), on the Mac
# CLI emulator:
#   tests/lifecycle/park.sh ISH FAKEFS
# The guest holds a flock (busybox flock) and writes a counter file every 50 ms. Then
# the emulator is parked: there must be no open meta.db connection, no host lock on any
# file of the fakefs (lsof), and the guest writer must stand still; after unparking it
# must carry on, and meta.db must pass sqlite's integrity check. Prints "bad=N".
set -u
ISH=${1:?usage: park.sh ISH FAKEFS}
FS=${2:?}
CTL=$(mktemp)
bad=0
ISH_PARK_CONTROL=$CTL "$ISH" -f "$FS" /bin/sh -c '
    mkdir -p /root/park; i=0
    flock /root/park/held -c "sleep 1000" &
    while :; do i=$((i + 1)); echo $i > /root/park/count; touch /root/park/f$((i % 50)); usleep 50000; done' \
    >/dev/null 2>&1 &
PID=$!
# The guest rewrites the file all the time; a read can catch it empty.
count() { local c; for _ in 1 2 3 4 5; do c=$(cat "$FS/data/root/park/count" 2>/dev/null); [ -n "$c" ] && break; sleep 0.05; done; echo "$c"; }
sleep 4
echo "before park: count=$(count) $(cat "$CTL.status")"
python3 "$(dirname "$0")/lockscan.py" "$PID" "$FS" | grep -E "LOCKED|locked=" | sed 's/^/  running: /'
echo park > "$CTL"
sleep 2
status=$(cat "$CTL.status")
echo "parked: $status"
[[ $status == *"open=0"* ]] || { echo "FAIL: a meta.db connection is still open"; bad=$((bad + 1)); }
scan=$(python3 "$(dirname "$0")/lockscan.py" "$PID" "$FS")
echo "$scan" | sed 's/^/  /'
[[ $scan == *"locked=0"* ]] && echo "ok: no host lock on any fakefs file" || { echo "FAIL: host locks while parked"; bad=$((bad + 1)); }
grep -q meta.db <<< "$scan" && { echo "FAIL: meta.db still open while parked"; bad=$((bad + 1)); }
c1=$(count); sleep 2; c2=$(count)
if [ "$c1" = "$c2" ]; then echo "ok: the guest writer waits while parked ($c1)"; else echo "FAIL: guest kept writing while parked ($c1 -> $c2)"; bad=$((bad + 1)); fi
echo unpark > "$CTL"
sleep 2
c3=$(count)
if [ "${c3:-0}" -gt "${c2:-0}" ]; then echo "ok: the guest carries on after unpark ($c2 -> $c3)"; else
    sample "$PID" 1 -file "${PARK_SAMPLE:-/tmp/park-stuck-sample.txt}" >/dev/null 2>&1
    sleep 5
    echo "FAIL: guest stuck after unpark ($c2 -> $c3, 5 s later $(count))"; bad=$((bad + 1)); fi
echo "after unpark: $(cat "$CTL.status")"
kill -9 "$PID"
wait "$PID" 2>/dev/null
integrity=$(sqlite3 "$FS/meta.db" 'pragma integrity_check' 2>&1)
[ "$integrity" = ok ] && echo "ok: integrity" || { echo "FAIL: integrity $integrity"; bad=$((bad + 1)); }
rm -f "$CTL" "$CTL.status"
echo "bad=$bad"
