#!/usr/bin/env python3
"""lsof-style lock scan: which files under ROOT does process PID have open, and does it
hold a lock on any of them (the files iPadOS would kill a suspended LinPad for).

    tests/lifecycle/lockscan.py PID ROOT

macOS lsof does not show lock state, so each open regular file is probed from this
process: a non-blocking flock(LOCK_EX) and a whole-file fcntl write lock (lockf). Either
failing means PID holds a lock there. Prints the open files, the locked ones, and
"locked=N".
"""
import fcntl
import os
import subprocess
import sys

pid, root = sys.argv[1], os.path.realpath(sys.argv[2])
out = subprocess.run(["lsof", "-p", pid, "-Fn"], capture_output=True, text=True).stdout
paths = sorted({line[1:] for line in out.splitlines()
                if line.startswith("n/") and os.path.realpath(line[1:]).startswith(root + "/")})
locked = []
for path in paths:
    if not os.path.isfile(path):
        continue
    try:
        fd = os.open(path, os.O_RDWR)
    except OSError:
        continue
    held = []
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
    except OSError:
        held.append("flock")
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.lockf(fd, fcntl.LOCK_UN)
    except OSError:
        held.append("fcntl")
    os.close(fd)
    if held:
        locked.append(f"{path} ({', '.join(held)})")
print(f"open files under the root: {len(paths)}")
for path in paths:
    print("  " + os.path.relpath(path, root))
for entry in locked:
    print("LOCKED " + entry)
print(f"locked={len(locked)}")
