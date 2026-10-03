#!/usr/bin/env python3
"""Median table of linpad-bench.sh results: summarize.py OUTDIR [OUTDIR2 ...]

Files are <suite>-jit<J>-<n>.json. Numeric leaves are flattened to dotted keys
(pages.github.load_s, youtube_large.dropped_pct, ...) and the median over runs is
printed per suite and engine. With two directories, a third column shows B/A.
"""
import collections, glob, json, os, re, statistics, sys


def flatten(d, prefix=""):
    for k, v in d.items():
        key = f"{prefix}{k}"
        if isinstance(v, dict):
            if k == "cpu_by_process":
                continue
            yield from flatten(v, key + ".")
        elif isinstance(v, (int, float)) and not isinstance(v, bool):
            yield key, v


def load(outdir):
    runs = collections.defaultdict(lambda: collections.defaultdict(list))
    for path in sorted(glob.glob(os.path.join(outdir, "*-jit*-*.json"))):
        m = re.match(r"(.+)-jit(\d)-\d+\.json$", os.path.basename(path))
        if not m:
            continue
        group = f"{m.group(1)} jit={m.group(2)}"
        for k, v in flatten(json.load(open(path))):
            runs[group][k].append(v)
    return {g: {k: (statistics.median(v), len(v)) for k, v in ks.items()} for g, ks in runs.items()}


def main():
    dirs = sys.argv[1:]
    tables = [load(d) for d in dirs]
    for group in sorted(set().union(*tables)):
        print(f"\n## {group}")
        keys = sorted(set().union(*(t.get(group, {}) for t in tables)))
        for k in keys:
            vals = [t.get(group, {}).get(k) for t in tables]
            cells = [f"{v[0]:.3g} (n={v[1]})" if v else "-" for v in vals]
            ratio = ""
            if len(vals) == 2 and vals[0] and vals[1] and vals[0][0]:
                ratio = f"  x{vals[1][0] / vals[0][0]:.2f}"
            print(f"{k:45s} " + "  ".join(f"{c:>16s}" for c in cells) + ratio)


if __name__ == "__main__":
    main()
