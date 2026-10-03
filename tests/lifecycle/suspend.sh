#!/bin/bash
# Suspension on the Mac CLI emulator, the way iPadOS suspends the app: the whole
# emulator process is stopped (SIGSTOP) for STOP seconds and resumed (SIGCONT).
#   tests/lifecycle/suspend.sh ISH FAKEFS [STOP_SECONDS]
# The guest runs /root/lc/timercatchup (tests/lifecycle/timercatchup.c, compiled in the
# guest beforehand) with a 1 ms timerfd and a 1 ms ITIMER_REAL. Reported: the guest's
# per-second lines, its bad= count, and the emulator's CPU time in the 3 s after the
# resume (catch-up work for the missed timer periods shows up there).
set -u
ISH=${1:?usage: suspend.sh ISH FAKEFS [STOP_SECONDS]}
FS=${2:?usage: suspend.sh ISH FAKEFS [STOP_SECONDS]}
STOP=${3:-60}
OUT=$(mktemp)
RUN=$((STOP + 12))
"$ISH" -f "$FS" /root/lc/timercatchup "$RUN" > "$OUT" 2>&1 &
PID=$!
sleep 6
cpu() { ps -o time= -p "$PID" | awk -F'[:.]' '{ printf "%.2f\n", $1 * 60 + $2 + ("0." $3) }'; }
kill -STOP "$PID"
echo "stopped for ${STOP}s"
sleep "$STOP"
before=$(cpu)
kill -CONT "$PID"
sleep 3
after=$(cpu)
wait "$PID"
cat "$OUT"
echo "cpu-after-resume-3s=$(echo "$after - $before" | bc)s"
rm -f "$OUT"
