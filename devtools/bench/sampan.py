#!/usr/bin/env python3
"""Summarise a macOS `sample` file of the ish process.

    sampan.py FILE [--threads N] [--funcs N] [--thread SUBSTR]

Busy samples are those whose leaf frame is not a blocking wait (condvar, mutex,
poll, kevent, read, sleep...). Per thread it prints busy samples; overall it prints
the functions with the most busy samples anywhere on the stack ("incl") and as
the leaf ("self"). Guest JIT code has no symbol and shows as "???".
"""
import argparse, collections, re

WAITS = ("__psynch_cvwait", "__psynch_mutexwait", "__psynch_rw_", "poll", "kevent", "__select",
         "__semwait_signal", "nanosleep", "mach_msg2_trap", "mach_msg_trap", "__workq_kernreturn",
         "__read_nocancel", "read", "__recvfrom", "__recvmsg", "__accept", "__wait4", "__sigsuspend",
         "__ulock_wait", "__ulock_wait2", "__pselect", "__open", "fsync", "__fsync")
LINE = re.compile(r"^([ +!:|]*)(\d+) (.+?)(?:  \(in ([^)]+)\).*)?$")


def parse(path):
    threads = {}
    cur = None
    stack = []
    in_graph = False
    for raw in open(path, errors="replace"):
        line = raw.rstrip("\n")
        if line.startswith("Call graph:"):
            in_graph = True
            continue
        if not in_graph:
            continue
        if line.startswith("Total number in stack") or line.startswith("Binary Images"):
            break
        m = LINE.match(line)
        if not m:
            continue
        depth = len(m.group(1))
        count = int(m.group(2))
        name = m.group(3).strip()
        if name.startswith("Thread_"):
            cur = threads.setdefault(name.split(" ", 1)[-1] if ":" in name else name, [])
            stack = [(depth, name)]
            continue
        while stack and stack[-1][0] >= depth:
            stack.pop()
        stack.append((depth, name))
        cur.append((depth, count, name, [s[1] for s in stack[1:]]))
    return threads


def leaves(nodes):
    """(own samples, frames) per node: its count minus its direct children's."""
    childsum = [0] * len(nodes)
    stack = []
    for i, (depth, count, _, _) in enumerate(nodes):
        while stack and nodes[stack[-1]][0] >= depth:
            stack.pop()
        if stack:
            childsum[stack[-1]] += count
        stack.append(i)
    return [(n[1] - childsum[i], n[3]) for i, n in enumerate(nodes) if n[1] > childsum[i]]


def fname(frame):
    return re.sub(r"\s+\+\s+\d+.*$", "", frame.split("  (in ")[0]).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--threads", type=int, default=25)
    ap.add_argument("--funcs", type=int, default=40)
    ap.add_argument("--thread", default=None)
    a = ap.parse_args()
    threads = parse(a.file)
    busy_by_thread = collections.Counter()
    incl, self_ = collections.Counter(), collections.Counter()
    total_busy = 0
    for tname, nodes in threads.items():
        if a.thread and a.thread not in tname:
            continue
        for own, path in leaves(nodes):
            leaf = fname(path[-1])
            if leaf.startswith(WAITS) or leaf in WAITS:
                continue
            busy_by_thread[tname] += own
            total_busy += own
            self_[leaf] += own
            for f in {fname(p) for p in path}:
                incl[f] += own
    print(f"busy samples: {total_busy}")
    print("\n# busy samples by thread")
    for t, c in busy_by_thread.most_common(a.threads):
        print(f"{c:7d} {100 * c / max(total_busy, 1):5.1f}%  {t}")
    print("\n# self")
    for f, c in self_.most_common(a.funcs):
        print(f"{c:7d} {100 * c / max(total_busy, 1):5.1f}%  {f}")
    print("\n# inclusive")
    for f, c in incl.most_common(a.funcs):
        print(f"{c:7d} {100 * c / max(total_busy, 1):5.1f}%  {f}")


if __name__ == "__main__":
    main()
