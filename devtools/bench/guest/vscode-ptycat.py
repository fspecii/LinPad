#!/usr/bin/env python3
"""A foreground `cat` (canonical tty) in VS Code's integrated terminal: keystrokes must
come back and the pty host must keep its heartbeat. Repro for "No ptyHost heartbeat".

    python3 vscode-ptycat.py [--program cat]
"""
import argparse, glob, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vscodebench as v  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--program", default="cat > /tmp/ptycat.out",
                    help="e.g. 'head -n1 > /tmp/ptycat.out' (canonical read of one line)")
    ap.add_argument("--project", default="/root/projects/vscb")
    ap.add_argument("--png", action="store_true")
    ap.add_argument("--code-args", default="")
    ap.add_argument("--scale", default="1")
    ap.add_argument("--extension", default="")
    ap.add_argument("--steps", default="")
    args = ap.parse_args()
    b = v.VSBench(args)
    b.t0 = time.time()
    bad = 0
    try:
        b.launch()
        b.terminal()
        for f in ("/tmp/ptycat.out",):
            try:
                os.unlink(f)
            except FileNotFoundError:
                pass
        b.text(args.program + "\n")
        time.sleep(3)
        line = "hello pty 12345"
        for ch in line:
            b.text(ch)
            time.sleep(0.4)
        b.text("\n")
        ok = b.wait(lambda: line in v.read("/tmp/ptycat.out"), 30, "line through cat")
        if not ok:
            print("BAD: the line did not reach cat:", repr(v.read("/tmp/ptycat.out")), flush=True)
            bad += 1
        b.key(v.CTRL, 46)  # Ctrl+C ends it (SIGINT from the line discipline)
        time.sleep(3)
        b.text("echo PTY-AFTER > /tmp/ptycat.after\n")
        if not b.wait(lambda: "PTY-AFTER" in v.read("/tmp/ptycat.after"), 30, "shell after cat"):
            print("BAD: the shell did not run a command after cat", flush=True)
            bad += 1
        logs = b.logs()
        beats = "".join(v.read(p) for p in glob.glob(logs + "**/*.log", recursive=True))
        n = beats.count("No ptyHost heartbeat")
        if n:
            print(f"BAD: {n} 'No ptyHost heartbeat' messages", flush=True)
            bad += 1
        print("ptyhost log tail:", v.read(logs + "ptyhost.log")[-600:], flush=True)
    finally:
        b.close()
    print(f"vscode-ptycat bad={bad}", flush=True)


if __name__ == "__main__":
    main()
