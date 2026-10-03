#!/usr/bin/env python3
"""Kills Firefox's content process (SIGKILL, as an OOM killer would) and checks that the
parent survives and shows the tab-crashed page. Repro for the soak's parent deaths.

    ffkillchild.py [--rounds 3]
"""
import argparse, os, signal, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ffbench  # noqa: E402
from ffbench import Bench  # noqa: E402


def content_pids():
    out = []
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            st = open(f"/proc/{p}/status").read()
            cmd = open(f"/proc/{p}/cmdline").read()
        except OSError:
            continue
        tgid = [l.split()[1] for l in st.splitlines() if l.startswith("Tgid:")]
        if tgid and tgid[0] == p and "-contentproc" in cmd and cmd.rstrip("\0").endswith("tab"):
            out.append(int(p))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--scale", default="2")
    ap.add_argument("--prefs")
    ap.add_argument("--url", help="page to kill the content process on (default: pages/heavy.html)")
    ap.add_argument("--play", action="store_true", help="start the page's <video> (unmuted: the audio path) first")
    args = ap.parse_args()
    b = Bench(args)
    bad = 0
    try:
        b.launch()
        for r in range(args.rounds):
            b.m.cmd("WebDriver:Navigate", {"url": args.url or "file://" + ffbench.HERE + "/pages/heavy.html"})
            time.sleep(3)
            if args.play:
                try:
                    b.m.js("const v = document.querySelector('video'); if (v) { v.muted = false; v.play(); }")
                except Exception as e:
                    print("play:", e)
                time.sleep(6)
            pids = content_pids()
            print("round", r, "content processes", pids, flush=True)
            for p in pids:
                os.kill(p, signal.SIGKILL)
            time.sleep(8)
            if b.ff.poll() is not None:
                print(f"BAD: round {r}: the parent died (returncode {b.ff.poll()})", flush=True)
                bad += 1
                break
            try:
                url = b.m.cmd("WebDriver:GetCurrentURL")
                print("round", r, "url after the kill:", url, flush=True)
            except Exception as e:
                print(f"BAD: round {r}: marionette: {e!r}", flush=True)
                bad += 1
                break
    finally:
        print("--- firefox log tail"); print(open(ffbench.PROFILE + "/../ffbench-ff.log", errors="replace").read()[-1500:] if os.path.exists("/tmp/ffbench-ff.log") else "")
        b.close()
    print(f"ffkillchild bad={bad}")


if __name__ == "__main__":
    main()
