#!/usr/bin/env python3
"""Markdown before/after table from two linpad-bench.sh output directories.

    compare.py BEFORE_DIR AFTER_DIR [suite ...]

One row per metric that exists in both: median before, median after, change. For
"lower is better" metrics (times, CPU, dropped frames, latency) the change is the
ratio after/before; for frame rates it is after/before too, so read the direction
from the metric name.
"""
import sys

from summarize import load

SKIP = (".w", ".h", "title", "nodes", ".total", ".dropped", "frames_total", "media_s_per_s", ".decoded_fps",
        ".painted_fps", "host_load")


def main():
    before, after = load(sys.argv[1]), load(sys.argv[2])
    suites = sys.argv[3:]
    print("| suite | metric | before | after | after/before |")
    print("|---|---|---|---|---|")
    for group in sorted(set(before) & set(after)):
        if suites and group.split()[0] not in suites:
            continue
        for k in sorted(set(before[group]) & set(after[group])):
            if any(k.endswith(s) or s in k for s in SKIP) and not k.endswith("dropped_pct"):
                continue
            b, a = before[group][k][0], after[group][k][0]
            ratio = f"{a / b:.2f}" if b else "-"
            print(f"| {group} | {k} | {b:.3g} | {a:.3g} | {ratio} |")
    for label, t in (("before", before), ("after", after)):
        loads = [t[g]["host_load_1m_before"][0] for g in t if "host_load_1m_before" in t[g]]
        if loads:
            print(f"\nHost load (1-min average before each run, median per suite), {label}: "
                  + ", ".join(f"{l:.0f}" for l in loads))


if __name__ == "__main__":
    main()
