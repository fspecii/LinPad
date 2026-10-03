#!/usr/bin/env python3
"""CLI throughput benchmark for LinPad, run inside the guest (see ../linpad-bench.sh).

    clibench.py OUT.json [--reps 3]

Each case runs REPS times; the result is the median wall time and the median guest
CPU time of the child (getrusage RUSAGE_CHILDREN deltas).
"""
import argparse, json, os, resource, shutil, statistics, subprocess, time

WORK = "/tmp/clibench"
MEDIA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "media")


def setup():
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK + "/repo")
    for d in range(40):
        os.makedirs(f"{WORK}/repo/d{d}")
        for f in range(50):
            with open(f"{WORK}/repo/d{d}/f{f}.txt", "w") as fh:
                fh.write(f"file {d}/{f}\n" * 20)
    run("git init -q && git add -A && git -c user.name=b -c user.email=b@b commit -qm init", cwd=WORK + "/repo")
    with open(WORK + "/package.json", "w") as f:
        f.write('{"name":"b","version":"1.0.0","private":true}\n')


def run(cmd, cwd=WORK):
    return subprocess.run(cmd, shell=True, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode


CASES = [
    ("sh_loop_100k", "i=0; while [ $i -lt 100000 ]; do i=$((i+1)); done"),
    ("python_start", "python3 -c pass"),
    ("python_fib25", "python3 -c 'f=lambda n: n if n<2 else f(n-1)+f(n-2); f(25)'"),
    ("node_start", "node -e 0"),
    ("node_loop", "node -e 'let s=0; for (let i=0;i<3e7;i++) s+=i%7'"),
    ("npm_version", "npm --version"),
    ("npm_ls", "npm ls --json"),
    ("git_status_2k", "cd repo && git status --porcelain"),
    ("git_diff_touch", "cd repo && touch d1/f1.txt d7/f3.txt && git diff --stat"),
    ("find_stat_2k", "find repo -type f -newer package.json | wc -l"),
    ("tar_2k", "tar cf /tmp/clibench.tar repo"),
    ("ffmpeg_h264_720p", f"ffmpeg -nostdin -loglevel error -threads 0 -i {MEDIA}/h264-720p.mp4 -an -f null -"),
    ("ffmpeg_vp9_720p", f"ffmpeg -nostdin -loglevel error -threads 0 -i {MEDIA}/vp9-720p.webm -an -f null -"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--only")
    a = ap.parse_args()
    setup()
    res = {}
    for name, cmd in CASES:
        if a.only and name not in a.only.split(","):
            continue
        walls, cpus, rc = [], [], 0
        for _ in range(a.reps):
            r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
            t0 = time.time()
            rc |= run(cmd)
            walls.append(time.time() - t0)
            r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
            cpus.append(r1.ru_utime - r0.ru_utime + r1.ru_stime - r0.ru_stime)
        res[name] = {"wall_s": round(statistics.median(walls), 3), "cpu_s": round(statistics.median(cpus), 3)}
        if rc:
            res[name]["rc"] = rc
        print(name, json.dumps(res[name]), flush=True)
    json.dump(res, open(a.out, "w"), indent=1)


if __name__ == "__main__":
    main()
