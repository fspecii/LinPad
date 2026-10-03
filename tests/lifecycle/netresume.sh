#!/bin/bash
# Network across a suspension on the Mac CLI emulator: a guest client keeps a TCP
# connection to a server on this Mac; the emulator is stopped (SIGSTOP) for STOP seconds,
# the server drops its connections meanwhile, and the emulator is resumed.
#   tests/lifecycle/netresume.sh ISH FAKEFS [STOP_SECONDS]
# The guest runs /root/lc/netresume (tests/lifecycle/netresume.c, compiled in the guest).
set -u
ISH=${1:?usage: netresume.sh ISH FAKEFS [STOP]}
FS=${2:?}
STOP=${3:-30}
PORT=$((20000 + RANDOM % 10000))
SERVER=$(mktemp)
cat > "$SERVER" <<'PY'
import socket, sys, threading, time
port, generation = int(sys.argv[1]), sys.argv[2]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(8)
conns = []
def serve():
    while True:
        c, _ = s.accept(); conns.append(c); c.sendall(f"hello from server {generation}\n".encode())
threading.Thread(target=serve, daemon=True).start()
time.sleep(10_000)
PY
python3 "$SERVER" "$PORT" 1 & SPID=$!
sleep 1
OUT=$(mktemp)
"$ISH" -f "$FS" /root/lc/netresume "$PORT" $((STOP + 25)) > "$OUT" 2>&1 &
PID=$!
sleep 8
kill -STOP "$PID"
kill "$SPID"; wait "$SPID" 2>/dev/null
python3 "$SERVER" "$PORT" 2 & SPID=$!
sleep "$STOP"
kill -CONT "$PID"
wait "$PID"
kill "$SPID" 2>/dev/null
cat "$OUT"
rm -f "$OUT" "$SERVER"
