#!/usr/bin/env python3
"""VS Code cycle for LinPad, run inside the guest (see ../vscode-cycle.sh).

    vscodebench.py OUT.json [--project DIR] [--extension PUBLISHER.NAME] [--scale 1]

What a user does, in order, with a time stamp and the guest CPU for each step:
  launch    `code DIR` under a headless ishwl: first frame, workbench, extension host up
  open      Ctrl+P index.ts: the TypeScript server has loaded the project
  type      keystroke -> frame latency for each character typed into the editor, then a
            completion request (time until tsserver answered)
  terminal  Ctrl+` and a command in the integrated terminal
  extension download a VSIX from Open VSX and `code --install-extension` it from that
            terminal; the running window's extension host activates it
  git       Ctrl+Shift+G: Source Control lists the file saved in the type step (the file
            watcher reported the save: git_status_after_save_s)
  quit      Ctrl+Q until every VS Code process has exited
Frame times come from ishwl's ISHWL_FRAMELOG (helpers shared with ffbench.py).
With --png, a screenshot of each step goes to /tmp/vscb-png/<step>.png.
"""
import argparse, glob, json, os, re, shutil, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from ffbench import guest_cpu, mark, now_ms, proc_cpu, proc_delta  # noqa: E402

RT, XDG, FLOG, PNG = "/tmp/vscb-rt", "/tmp/vscb-xdg", "/tmp/vscb-frames.log", "/tmp/vscb-png"
ISHWL = os.environ.get("ISHWL", "/usr/local/bin/ishwl")
CODE = "/usr/local/bin/code"
USERDIR = "/root/.config/Code"

# evdev key codes
CTRL, SHIFT, ENTER, ESC, END, KEY_P, KEY_S, KEY_G, KEY_Q, GRAVE = 29, 42, 28, 1, 107, 25, 31, 34, 16, 41


def latest_logs():
    dirs = sorted(glob.glob(USERDIR + "/logs/*/"), key=os.path.getmtime)
    return dirs[-1] if dirs else None


def read(path):
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def code_pids():
    pids = []
    for pid in os.listdir("/proc"):
        if pid.isdigit():
            cmd = read(f"/proc/{pid}/cmdline")
            if cmd.startswith("/opt/vscode/code"):
                pids.append(int(pid))
    return pids


class VSBench:
    def __init__(self, args):
        self.args = args
        self.res = {"steps": {}}
        self.t0 = None
        for d in (RT, XDG, PNG):
            shutil.rmtree(d, ignore_errors=True)
            os.makedirs(d, mode=0o700)
        for f in (FLOG, "/tmp/vscb-term.txt", "/tmp/vscb-ext.txt", "/tmp/vscb-ext.sh"):
            try:
                os.unlink(f)
            except FileNotFoundError:
                pass
        os.makedirs("/dev/shm", exist_ok=True)
        self.env = dict(os.environ, XDG_RUNTIME_DIR=XDG, HOME="/root", NO_AT_BRIDGE="1",
                        GTK_A11Y="none", GIO_USE_VFS="local", GSETTINGS_BACKEND="memory",
                        ISHWL_FRAMELOG=FLOG)
        self.env.pop("LD_PRELOAD", None)
        dbus = subprocess.run(["dbus-daemon", "--session", "--fork", "--print-address=1"],
                              capture_output=True, text=True, env=self.env)
        self.env["DBUS_SESSION_BUS_ADDRESS"] = dbus.stdout.strip().splitlines()[0] if dbus.stdout.strip() else ""
        # PNGs (ishwl encodes one up to every 400 ms) cost ishwl CPU and frame time,
        # so the timed runs go without them (--png for screenshots)
        self.wl = subprocess.Popen([ISHWL, "-H", "-s", "wayland-b", "-r", RT, "-S", str(args.scale),
                                    "-g", "1280x800"] + (["-p", PNG] if args.png else []),
                                   env=self.env, stdout=open("/tmp/vscb-ishwl.log", "w"), stderr=subprocess.STDOUT)
        for _ in range(1200):
            if os.path.exists(XDG + "/wayland-b") and os.path.exists(RT + "/events"):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("ishwl did not start: " + read("/tmp/vscb-ishwl.log")[-300:])
        self.env["WAYLAND_DISPLAY"] = "wayland-b"
        self.ev = os.open(RT + "/events", os.O_WRONLY)
        self.vid = None
        self.code = None
        self.status_before_save = 0
        self.logdir = None

    # The window's log directory: the newest when the window started (a later
    # `code --install-extension` makes a newer one of its own).
    def logs(self):
        if self.logdir is None:
            d = latest_logs()
            if d is None or not os.path.exists(d + "window1"):
                return "/nonexistent/"
            self.logdir = d
        return self.logdir

    # --- ishwl helpers (as in ffbench.py) ---
    def send(self, line):
        os.write(self.ev, (line + "\n").encode())

    def frames(self):
        return [l.split() for l in read(FLOG).splitlines() if l.strip()]

    def wait_quiet(self, quiet_ms, limit_s):
        end = time.time() + limit_s
        last_n, last_change = -1, time.time()
        while time.time() < end:
            n = len(self.frames())
            if n != last_n:
                last_n, last_change = n, time.time()
            elif (time.time() - last_change) * 1000 >= quiet_ms:
                return True
            time.sleep(0.05)
        return False

    def first_frame_after(self, m, timeout=10):
        end = time.time() + timeout
        while time.time() < end:
            a = [int(f[0]) for f in self.frames()
                 if f[1] == self.vid and ((int(f[0]) - m) & 0xFFFFFFFF) < 0x7FFFFFFF]
            if a:
                return min((t - m) & 0xFFFFFFFF for t in a)
            time.sleep(0.005)
        return None

    def main_view(self):
        area = {}
        for f in self.frames():
            area[f[1]] = max(area.get(f[1], 0), int(f[3]) * int(f[4]))
        return max(area, key=area.get) if area else None

    def key(self, *codes):
        for c in codes:
            self.send(f"key {c} 1")
        for c in reversed(codes):
            self.send(f"key {c} 0")
        time.sleep(0.2)

    def text(self, s):
        self.send("text " + s.replace("%", "%25").replace(" ", "%20").replace("\n", "%0A"))

    def shot(self, name):
        src = sorted(glob.glob(PNG + "/*.png"), key=os.path.getsize)
        if src:
            shutil.copy(src[-1], f"{PNG}/{name}.png")

    def wait(self, cond, limit_s, what):
        end = time.time() + limit_s
        while time.time() < end:
            if cond():
                return True
            time.sleep(0.2)
        self.res.setdefault("timeouts", []).append(what)
        print("TIMEOUT", what, flush=True)
        return False

    # one step: wall time from its start, guest CPU, and the busiest processes
    def step(self, name, fn):
        mark("begin " + name)
        c0, p0, t = guest_cpu(), proc_cpu(), time.time()
        ok = fn()
        wall = time.time() - t
        self.res["steps"][name] = {
            "ok": bool(ok), "wall_s": round(wall, 2), "cpu_s": round(guest_cpu() - c0, 2),
            "at_s": round(time.time() - self.t0, 2), "busiest": dict(list(proc_delta(p0, proc_cpu(), wall).items())[:5]),
        }
        self.shot(name)
        print(name, json.dumps(self.res["steps"][name]), flush=True)
        mark("end " + name)
        return ok

    # --- steps ---
    def launch(self):
        self.code = subprocess.Popen([CODE] + self.args.code_args.split() + [self.args.project], env=self.env, stdin=subprocess.DEVNULL,
                                     stdout=open("/tmp/vscb-code.log", "w"), stderr=subprocess.STDOUT,
                                     preexec_fn=os.setsid)
        t = time.time()
        if not self.wait(lambda: self.frames(), 900, "first frame"):
            return False
        self.res["launch_first_frame_s"] = round(time.time() - t, 2)

        def workbench():
            v = self.main_view()
            return v is not None and any(f[1] == v and int(f[3]) * int(f[4]) > 500000 for f in self.frames())
        if not self.wait(workbench, 900, "workbench"):
            return False
        self.res["launch_workbench_s"] = round(time.time() - t, 2)
        self.vid = self.main_view()
        self.send(f"focus {self.vid}")
        ok = self.wait(lambda: "vscode.git" in read(self.logs() + "window1/exthost/exthost.log"),
                       900, "extension host")
        self.res["launch_exthost_s"] = round(time.time() - t, 2)
        self.wait_quiet(2000, 120)
        self.res["launch_quiet_s"] = round(time.time() - t, 2)
        return ok

    # The TypeScript language service: TypeScript 7 (tsgo, which install-vscode.sh sets up)
    # or the built-in tsserver. Readiness is the first semantic highlighting of the file
    # (tsgo) or projectLoadingFinish (tsserver); completions are counted in either log.
    TS_READY = re.compile(r"textDocument/semanticTokens/full'.{0,20}(?:in [0-9.]+|\()|projectLoadingFinish")
    TS_COMPLETION = re.compile(r"handled method 'textDocument/completion' \(\d+\) in ([0-9.]+)(µs|ms|s)"
                               r"|completionInfo: elapsed time \(in milliseconds\) ([0-9.]+)()")

    def ts_log(self):
        base = self.logs()
        logs = glob.glob(base + "window1/exthost/TypeScriptTeam.native-preview/*.log") + glob.glob(
            base + "window1/exthost/vscode.typescript-language-features/tsserver-log-*/tsserver.log")
        return "".join(read(p) for p in logs)

    def open_file(self):
        before = len(self.TS_READY.findall(self.ts_log()))
        self.key(CTRL, KEY_P)
        time.sleep(1.0)
        self.text("index.ts")
        time.sleep(1.5)
        self.key(ENTER)
        ok = self.wait(lambda: len(self.TS_READY.findall(self.ts_log())) > before, 600, "TypeScript ready")
        self.res["ts_service"] = "tsgo" if "semanticTokens" in self.ts_log() else "tsserver"
        self.wait_quiet(1500, 60)
        return ok

    def typing(self):
        self.key(CTRL, END)
        self.key(ENTER)
        self.wait_quiet(1000, 30)
        lat = []
        for ch in "const total = sum(1, 2) + 40;":
            m = now_ms()
            self.text(ch)
            l = self.first_frame_after(m, 5)
            if l is not None:
                lat.append(l)
            time.sleep(0.3)
        self.res["type_latency_ms"] = lat
        if lat:
            self.res["type_latency_ms_median"] = statistics.median(lat)
            self.res["type_latency_ms_p90"] = sorted(lat)[int(len(lat) * 0.9)]
        # completion: members of the Counter instance in src/index.ts
        self.key(ENTER)
        self.wait_quiet(800, 20)
        before = len(self.TS_COMPLETION.findall(self.ts_log()))
        t = time.time()
        self.text("counter.")
        ok = self.wait(lambda: len(self.TS_COMPLETION.findall(self.ts_log())) > before, 120, "completion")
        self.res["completion_s"] = round(time.time() - t, 2)
        found = self.TS_COMPLETION.findall(self.ts_log())
        if found:
            v1, u1, v2, _ = found[-1]
            self.res["completion_server_ms"] = float(v2) if v2 else float(v1) * {"µs": 0.001, "ms": 1, "s": 1000}[u1]
        self.wait_quiet(1000, 20)
        self.key(ESC)
        self.text("count;")
        self.status_before_save = self.git_log().count("git status")
        t = time.time()
        self.key(CTRL, KEY_S)
        # the file watcher reports the save and the git extension runs `git status`
        if self.wait(lambda: self.git_log().count("git status") > self.status_before_save, 60, "git status after the save"):
            self.res["git_status_after_save_s"] = round(time.time() - t, 2)
        self.wait_quiet(1000, 30)
        return ok and bool(lat)

    def terminal(self):
        self.key(CTRL, GRAVE)
        ok = self.wait(lambda: any(p for p in os.listdir("/proc") if p.isdigit()
                                   and read(f"/proc/{p}/cmdline").startswith("/bin/sh\0-l")), 120, "terminal shell")
        time.sleep(2)
        self.text("echo ISHTERM-OK > /tmp/vscb-term.txt\n")
        return ok and self.wait(lambda: "ISHTERM-OK" in read("/tmp/vscb-term.txt"), 120, "terminal command")

    def extension(self):
        pub, name = self.args.extension.split(".", 1)
        # The commands go through a script: ishwl cannot type '$' into Chromium apps yet
        # (it picks a keycode Chromium drops).
        with open("/tmp/vscb-ext.sh", "w") as f:
            f.write(f'url=$(curl -fsSL https://open-vsx.org/api/{pub}/{name}/latest | jq -r .files.download)\n'
                    'curl -fsSL -o /tmp/vscb-ext.vsix "$url" &&\n'
                    '    code --install-extension /tmp/vscb-ext.vsix > /tmp/vscb-ext.txt 2>&1\n'
                    'echo "rc=$?" >> /tmp/vscb-ext.txt\n')
        self.text("sh /tmp/vscb-ext.sh\n")
        ok = self.wait(lambda: "rc=" in read("/tmp/vscb-ext.txt"), 600, "extension install")
        out = read("/tmp/vscb-ext.txt")
        self.res["extension_output"] = out.strip()[-300:]
        ok = ok and "rc=0" in out and bool(glob.glob(f"/root/.vscode/extensions/{self.args.extension.lower()}-*"))
        # the running window picks it up without a reload
        t = time.time()
        active = self.wait(lambda: self.args.extension.lower() in read(
            self.logs() + "window1/exthost/exthost.log").lower(), 120, "extension in the extension host")
        self.res["extension_loaded_s"] = round(time.time() - t, 2) if active else None
        return ok

    def git_log(self):
        return read(self.logs() + "window1/exthost/vscode.git/Git.log")

    def git(self):
        # The edit was saved in the type step: the file watcher has to report it and the
        # git extension run `git status` again, so Source Control lists src/index.ts.
        self.key(CTRL, SHIFT, KEY_G)
        ok = self.wait(lambda: self.git_log().count("git status") > self.status_before_save, 120,
                       "git status after the save")
        # the view keeps repainting (its progress bar) on the JIT for a while; the
        # step ends once it is quiet or after 5 s
        self.wait_quiet(1000, 5)
        return ok

    def quit(self):
        self.key(CTRL, KEY_Q)
        ok = self.wait(lambda: not code_pids(), 180, "quit")
        return ok

    def run(self):
        self.t0 = time.time()
        steps = {"launch": self.launch, "open": self.open_file, "type": self.typing, "terminal": self.terminal,
                 "extension": self.extension, "git": self.git, "quit": self.quit}
        for name in self.args.steps.split(","):
            if not self.step(name, steps[name]) and name in ("launch", "open"):
                break
        self.res["total_s"] = round(time.time() - self.t0, 2)

    def close(self):
        for pid in code_pids():
            try:
                os.kill(pid, 9)
            except OSError:
                pass
        self.wl.terminate()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--project", default="/root/projects/vscb")
    ap.add_argument("--extension", default="usernamehw.errorlens")
    ap.add_argument("--scale", default="1")
    ap.add_argument("--png", action="store_true", help="screenshots (costs ishwl CPU: not for timing)")
    ap.add_argument("--code-args", default="", help="extra arguments for code, e.g. '--log trace'")
    ap.add_argument("--steps", default="launch,open,type,terminal,extension,git,quit")
    args = ap.parse_args()
    b = VSBench(args)
    try:
        b.run()
    except Exception as e:
        b.res["fatal"] = repr(e)[:300]
    finally:
        b.close()
    for name in ("/tmp/vscb-code.log", "/tmp/vscb-ishwl.log"):
        b.res.setdefault("log_tails", {})[name] = read(name)[-800:]
    json.dump(b.res, open(args.out, "w"), indent=1)
    print(json.dumps({k: v for k, v in b.res.items() if k != "log_tails"}))


if __name__ == "__main__":
    main()
