#!/usr/bin/env python3
"""Fault injection: kill -9 the emulator while the guest writes files, then check the fakefs.

    tests/lifecycle/killloop.py --ish build/ish --fakefs PRISTINE --work DIR [--kills 200]

iPadOS ends a suspended or memory-hungry app with SIGKILL and no warning, so every
namespace operation in fs/fake.c can be cut between its host step and its meta.db commit.
This runs a file-churning guest workload on a copy of PRISTINE (APFS clone), kills the
emulator at a random moment, and after every kill checks:

  * meta.db: `PRAGMA integrity_check` is "ok" (sqlite replays the WAL as the next boot does)
  * host vs db, before the next boot: entries on disk without a meta.db row ("host-only",
    left by a cut create/mkdir/rename) and rows whose file is gone ("dangling", left by a
    cut unlink; invisible and harmless)
  * the guest's view after rebooting: every document saved with the write-temp-then-rename
    pattern exists and holds one complete version, `mkdir -p` succeeds on every directory,
    and `ls -lR` and `stat` see every entry
  * after that check, nothing on disk is still without a db row ("invisible": a file or
    directory Linux can never see, yet cannot create either)

Exit status 0 when every guest check passed. A JSON summary goes to DIR/killloop.json.
"""
import argparse
import json
import os
import random
import shutil
import signal
import sqlite3
import subprocess
import sys
import time

DOCS = 20

SETUP = r"""
set -e
rm -rf /root/w
mkdir -p /root/w
i=0
while [ $i -lt %(docs)d ]; do
    mkdir -p /root/w/d$i/sub
    printf 'v0 complete\n' > /root/w/d$i/doc
    i=$((i + 1))
done
sync
echo setup-ok
""" % {"docs": DOCS}

# Every operation fs/fake.c has: create (open O_CREAT), write, rename over an existing
# file, mkdir/rmdir, symlink, hard link, unlink, chmod, mknod (FIFO).
WORKLOAD = r"""
i=0
while :; do
    i=$((i + 1))
    d=/root/w/d$((i %% %(docs)d))
    printf 'v%%s complete\n' $i > $d/doc.tmp && mv -f $d/doc.tmp $d/doc
    echo $i > $d/f$((i %% 7))
    ln -sf f$((i %% 7)) $d/l$((i %% 5))
    ln -f $d/f$((i %% 7)) $d/h$((i %% 3)) 2>/dev/null
    rm -f $d/f$(((i + 3) %% 7))
    chmod 600 $d/f$((i %% 7)) 2>/dev/null
    mkdir -p $d/n$((i %% 4))/deep && rmdir $d/n$(((i + 2) %% 4))/deep $d/n$(((i + 2) %% 4)) 2>/dev/null
    [ -p $d/fifo ] || mkfifo $d/fifo 2>/dev/null
    mv $d/sub $d/sub2 2>/dev/null || mv $d/sub2 $d/sub 2>/dev/null
done
""" % {"docs": DOCS}

CHECK = r"""
bad=0
i=0
while [ $i -lt %(docs)d ]; do
    d=/root/w/d$i
    if [ ! -f $d/doc ]; then
        echo "MISSING $d/doc"; bad=$((bad + 1))
    elif ! grep -qx 'v[0-9]* complete' $d/doc; then
        echo "TORN $d/doc: $(head -c 80 $d/doc | tr '\n' ' ')"; bad=$((bad + 1))
    fi
    mkdir -p $d/sub/probe 2>/dev/null || mkdir -p $d/sub2/probe 2>/dev/null || { echo "MKDIR $d"; bad=$((bad + 1)); }
    for n in 0 1 2 3; do
        mkdir -p $d/n$n/deep || { echo "MKDIR $d/n$n"; bad=$((bad + 1)); }
    done
    i=$((i + 1))
done
ls -lR /root/w > /tmp/ls.out 2>/tmp/ls.err || true
if [ -s /tmp/ls.err ]; then echo "LS $(head -3 /tmp/ls.err | tr '\n' ' ')"; bad=$((bad + 1)); fi
for f in $(find /root/w 2>/dev/null); do
    stat -c %%n "$f" >/dev/null 2>&1 || [ -L "$f" ] || { echo "STAT $f"; bad=$((bad + 1)); }
done
echo "check bad=$bad"
""" % {"docs": DOCS}


def run_guest(ish, fs, script, timeout, log=False):
    env = dict(os.environ, ISH_LOG="1") if log else None
    return subprocess.run([ish, "-f", fs, "/bin/sh", "-c", script], capture_output=True,
                          text=True, errors="replace", timeout=timeout, env=env)


def host_vs_db(fs):
    """Host entries without a db row, and db rows without a host entry."""
    db = sqlite3.connect(os.path.join(fs, "meta.db"))
    integrity = db.execute("pragma integrity_check").fetchone()[0]
    rows = {row[0].decode(errors="replace") if isinstance(row[0], bytes) else row[0]
            for row in db.execute("select path from paths where cast(path as text) like '/root/w%'")}
    db.close()
    data = os.path.join(fs, "data")
    host = set()
    for root, dirs, files in os.walk(os.path.join(data, "root/w")):
        for name in dirs + files:
            host.add("/" + os.path.relpath(os.path.join(root, name), data))
    host.add("/root/w")
    return integrity, sorted(host - rows), sorted(rows - host)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ish", required=True)
    parser.add_argument("--fakefs", required=True, help="pristine fakefs, copied first")
    parser.add_argument("--work", required=True)
    parser.add_argument("--kills", type=int, default=200)
    parser.add_argument("--min-delay", type=float, default=0.3)
    parser.add_argument("--max-delay", type=float, default=2.5)
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    random.seed(args.seed)

    os.makedirs(args.work, exist_ok=True)
    fs = os.path.join(args.work, "fakefs")
    shutil.rmtree(fs, ignore_errors=True)
    subprocess.run(["cp", "-c", "-R", args.fakefs, fs], check=True)
    out = run_guest(args.ish, fs, SETUP, 120)
    if "setup-ok" not in out.stdout:
        sys.exit("setup failed: " + out.stdout + out.stderr)

    summary = {"kills": 0, "integrity_failures": 0, "host_only": 0, "dangling": 0,
               "guest_failures": 0, "adopted": 0, "invisible_after_check": 0, "examples": []}
    for n in range(1, args.kills + 1):
        proc = subprocess.Popen([args.ish, "-f", fs, "/bin/sh", "-c", WORKLOAD],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(random.uniform(args.min_delay, args.max_delay))
        proc.send_signal(signal.SIGKILL)
        proc.wait()
        summary["kills"] += 1

        integrity, host_only, dangling = host_vs_db(fs)
        if integrity != "ok":
            summary["integrity_failures"] += 1
        summary["host_only"] += len(host_only)
        summary["dangling"] += len(dangling)
        check = run_guest(args.ish, fs, CHECK, 300, log=True)
        lines = [line for line in check.stdout.strip().splitlines() if "fakefs: adopted" not in line]
        result = next((line for line in reversed(lines) if line.startswith("check bad=")), "check bad=?")
        adopted = "adopted=%d" % (check.stdout + check.stderr).count("fakefs: adopted")
        summary["adopted"] += int(adopted.split("=")[1])
        # The check listed and stat'ed every directory: whatever is still on disk without a
        # db row is invisible to Linux for good.
        _, invisible, _ = host_vs_db(fs)
        summary["invisible_after_check"] += len(invisible)
        failed = result != "check bad=0" or bool(invisible)
        if failed:
            summary["guest_failures"] += 1
        if failed or host_only or integrity != "ok":
            summary["examples"].append({"kill": n, "integrity": integrity, "host_only": host_only[:5],
                                        "dangling": dangling[:5], "invisible": invisible[:5], "guest": lines[-8:]})
        print(f"kill {n}: integrity={integrity} host_only={len(host_only)} dangling={len(dangling)} "
              f"{adopted} invisible={len(invisible)} {result}", flush=True)

    with open(os.path.join(args.work, "killloop.json"), "w") as f:
        json.dump(summary, f, indent=1)
    print(json.dumps({k: v for k, v in summary.items() if k != "examples"}))
    sys.exit(0 if summary["guest_failures"] == 0 and summary["integrity_failures"] == 0 else 1)


if __name__ == "__main__":
    main()
