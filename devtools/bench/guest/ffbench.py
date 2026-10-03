#!/usr/bin/env python3
"""Firefox benchmark for LinPad, run inside the guest (see ../linpad-bench.sh).

    ffbench.py OUT.json [--suites launch,pages,scroll,type,tabs,video,youtube]
                        [--scale 2] [--prefs FILE] [--pages name=url,...]

Firefox runs under a headless ishwl (no host app; frames are acked at once) and is
driven over Marionette (navigation, scripts) and ishwl's input FIFO (scroll, keys).
Frame times come from ishwl's ISHWL_FRAMELOG. Guest CPU is the sum of utime+stime of
all live processes (/proc/PID/stat), so it is comparable between the Mac and the iPad.
"""
import argparse, json, os, shutil, signal, socket, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
RT, XDG, FLOG = "/tmp/ffbench-rt", "/tmp/ffbench-xdg", "/tmp/ffbench-frames.log"
PROFILE = "/tmp/ffbench-profile"
ISHWL = os.environ.get("ISHWL", "/usr/local/bin/ishwl")
FIREFOX = "/usr/lib/firefox-esr/firefox-esr"
TICK = os.sysconf("SC_CLK_TCK")

DEFAULT_PAGES = [
    ("heavy_local", "file://" + HERE + "/pages/heavy.html"),
    ("wikipedia", "https://en.wikipedia.org/wiki/Linux"),
    ("github", "https://github.com/torvalds/linux"),
    ("news", "https://www.theguardian.com/international"),
    ("youtube_home", "https://www.youtube.com/"),
]
YOUTUBE_VIDEO = os.environ.get("FFBENCH_YT", "eRsGyueVLvQ")  # Sintel (Blender, CC BY), 24 fps


_LEADER = {}


def _is_leader(pid):
    """iSH lists threads in /proc too, each with its group's times: count groups once.
    The answer never changes for a pid, so status is read once per pid."""
    v = _LEADER.get(pid)
    if v is None:
        try:
            with open(f"/proc/{pid}/status") as f:
                v = f"\nTgid:\t{pid}\n" in f.read()
        except OSError:
            return False
        _LEADER[pid] = v
    return v


def proc_cpu():
    """{pid: (comm, cpu seconds)} of thread groups."""
    out = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or not _is_leader(pid):
            continue
        try:
            with open(f"/proc/{pid}/stat") as f:
                head, rest = f.read().rsplit(")", 1)
            fields = rest.split()
            out[pid] = (head.split("(", 1)[1], (int(fields[11]) + int(fields[12])) / TICK)
        except (OSError, IndexError, ValueError):
            pass
    return out


def proc_delta(a, b, wall):
    by = {}
    for pid, (comm, cpu) in b.items():
        d = cpu - (a[pid][1] if pid in a else 0)
        if d > 0.005 * wall:
            by[comm] = round(by.get(comm, 0) + d / wall, 2)
    return dict(sorted(by.items(), key=lambda kv: -kv[1]))


def guest_cpu():
    return sum(cpu for _, cpu in proc_cpu().values())


def mark(text):
    """Phase marks for host-side tools (linpad-bench.sh sample): FFBENCH_PHASE file."""
    path = os.environ.get("FFBENCH_PHASE")
    if path:
        with open(path, "a") as f:
            f.write(f"{time.time():.3f} {text}\n")


def now_ms():
    return int(time.monotonic() * 1000) & 0xFFFFFFFF


class Marionette:
    def __init__(self, port=2828, timeout=120):
        end = time.time() + timeout
        while True:
            try:
                self.s = socket.create_connection(("127.0.0.1", port), timeout=600)
                break
            except OSError:
                if time.time() > end:
                    raise
                time.sleep(0.2)
        self.buf = b""
        self.id = 0
        self._read()

    def _read(self):
        while b":" not in self.buf:
            self.buf += self._recv()
        n, rest = self.buf.split(b":", 1)
        n = int(n)
        while len(rest) < n:
            rest += self._recv()
        self.buf = rest[n:]
        return json.loads(rest[:n])

    def _recv(self):
        d = self.s.recv(65536)
        if not d:
            raise ConnectionError("marionette closed")
        return d

    def cmd(self, name, params=None):
        self.id += 1
        data = json.dumps([0, self.id, name, params or {}]).encode()
        self.s.sendall(str(len(data)).encode() + b":" + data)
        while True:
            msg = self._read()
            if msg[0] == 1 and msg[1] == self.id:
                if msg[2]:
                    raise RuntimeError(f"{name}: {msg[2]}")
                r = msg[3]
                return r.get("value", r) if isinstance(r, dict) else r

    def js(self, script, *args):
        return self.cmd("WebDriver:ExecuteScript", {"script": script, "args": list(args)})

    def js_async(self, script, *args):
        return self.cmd("WebDriver:ExecuteAsyncScript", {"script": script, "args": list(args)})


class Bench:
    def __init__(self, args):
        self.args = args
        self.res = {"scale": args.scale}
        for d in (RT, XDG, PROFILE):
            shutil.rmtree(d, ignore_errors=True)
            os.makedirs(d, mode=0o700)
        try:
            os.unlink(FLOG)
        except FileNotFoundError:
            pass
        os.makedirs("/dev/shm", exist_ok=True)
        self.env = dict(os.environ, XDG_RUNTIME_DIR=XDG, HOME="/root", NO_AT_BRIDGE="1",
                        GTK_A11Y="none", GIO_USE_VFS="local", GSETTINGS_BACKEND="memory",
                        MOZ_ENABLE_WAYLAND="1", MOZ_CRASHREPORTER_DISABLE="1", ISHWL_FRAMELOG=FLOG)
        if os.path.exists("/usr/local/lib/libishwl-scm.so"):
            self.env["LD_PRELOAD"] = "/usr/local/lib/libishwl-scm.so"
        dbus = subprocess.run(["dbus-daemon", "--session", "--fork", "--print-address=1"],
                              capture_output=True, text=True, env=self.env)
        self.env["DBUS_SESSION_BUS_ADDRESS"] = dbus.stdout.strip().splitlines()[0] if dbus.stdout.strip() else ""
        self.wl = subprocess.Popen([ISHWL, "-H", "-s", "wayland-b", "-r", RT, "-S", str(args.scale), "-g", "1180x780"],
                                   env=self.env, stdout=open("/tmp/ffbench-ishwl.log", "w"), stderr=subprocess.STDOUT)
        for _ in range(1200):
            if os.path.exists(XDG + "/wayland-b") and os.path.exists(RT + "/events"):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("ishwl did not start: " + open("/tmp/ffbench-ishwl.log").read()[-300:])
        self.env["WAYLAND_DISPLAY"] = "wayland-b"
        self.ev = os.open(RT + "/events", os.O_WRONLY)
        with open(PROFILE + "/user.js", "w") as f:
            f.write('user_pref("media.autoplay.default", 0);\n'
                    'user_pref("media.autoplay.blocking_policy", 0);\n'
                    'user_pref("browser.shell.checkDefaultBrowser", false);\n'
                    'user_pref("browser.startup.page", 0);\n'
                    'user_pref("browser.tabs.warnOnClose", false);\n'
                    'user_pref("browser.sessionstore.resume_from_crash", false);\n'
                    'user_pref("full-screen-api.allow-trusted-requests-only", false);\n'
                    'user_pref("full-screen-api.transition-duration.enter", "0 0");\n'
                    'user_pref("full-screen-api.transition-duration.leave", "0 0");\n'
                    'user_pref("full-screen-api.warning.timeout", 0);\n')
            if args.prefs:
                f.write(open(args.prefs).read())
        self.vid = None

    # --- ishwl helpers ---
    def send(self, line):
        os.write(self.ev, (line + "\n").encode())

    def frames(self):
        try:
            with open(FLOG) as f:
                return [l.split() for l in f.read().splitlines() if l.strip()]
        except FileNotFoundError:
            return []

    def frames_between(self, m0, m1, view=None):
        out = []
        for f in self.frames():
            t = int(f[0])
            if ((t - m0) & 0xFFFFFFFF) < 0x7FFFFFFF and ((m1 - t) & 0xFFFFFFFF) < 0x7FFFFFFF:
                if view is None or f[1] == view:
                    out.append(f)
        return out

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

    def key_combo(self, *codes):
        for c in codes:
            self.send(f"key {c} 1")
        for c in reversed(codes):
            self.send(f"key {c} 0")

    # --- phases ---
    def launch(self):
        c0, t0 = guest_cpu(), time.time()
        self.ff = subprocess.Popen([FIREFOX, "--no-remote", "--marionette", "--profile", PROFILE, "about:blank"],
                                   env=self.env, stdout=open("/tmp/ffbench-ff.log", "w"),
                                   stderr=subprocess.STDOUT, preexec_fn=os.setsid)
        while not self.frames() and time.time() - t0 < 180:
            time.sleep(0.05)
        self.res["launch_first_frame_s"] = round(time.time() - t0, 2)
        self.m = Marionette(timeout=180)
        self.m.cmd("WebDriver:NewSession", {"capabilities": {"alwaysMatch": {"pageLoadStrategy": "normal"}}})
        self.m.cmd("WebDriver:SetTimeouts", {"pageLoad": 180000, "script": 180000, "implicit": 0})
        self.res["launch_marionette_s"] = round(time.time() - t0, 2)
        self.wait_quiet(1500, 60)
        self.res["launch_cpu_s"] = round(guest_cpu() - c0, 2)
        self.vid = self.main_view()
        self.send(f"focus {self.vid}")
        self.send(f"configure {self.vid} 1180 780 1")
        time.sleep(0.5)
        self.wait_quiet(1000, 30)
        self.send(f"motion {self.vid} 600 450")

    def load(self, name, url):
        mark("begin load " + name)
        c0, t0 = guest_cpu(), time.time()
        err = None
        try:
            self.m.cmd("WebDriver:Navigate", {"url": url})
        except Exception as e:  # a timeout still leaves a usable page
            err = str(e)[:200]
        t_load = time.time() - t0
        self.wait_quiet(1000, 60)
        r = {"load_s": round(t_load, 2), "settled_s": round(time.time() - t0 - 1.0, 2),
             "cpu_s": round(guest_cpu() - c0, 2)}
        try:
            nav = self.m.js("""
                const n = performance.getEntriesByType('navigation')[0];
                const p = performance.getEntriesByName('first-contentful-paint')[0];
                return {dcl: n ? n.domContentLoadedEventEnd : null, onload: n ? n.loadEventEnd : null,
                        fcp: p ? p.startTime : null, title: document.title,
                        nodes: document.getElementsByTagName('*').length};""")
            r.update({k: (round(v) if isinstance(v, float) else v) for k, v in nav.items()})
        except Exception as e:
            r["js_error"] = str(e)[:200]
        if err:
            r["error"] = err
        self.res.setdefault("pages", {})[name] = r
        print(name, json.dumps(r), flush=True)

    def scroll(self, label, dy=25, secs=3.0):
        def once(d, s):
            c0 = guest_cpu()
            mark("begin scroll " + label)
            m0 = now_ms()
            end = time.time() + s
            while time.time() < end:
                self.send(f"axis {self.vid} 0 {d} 1")
                time.sleep(1 / 60)
            self.send(f"axis_stop {self.vid}")
            fs = self.frames_between(m0, now_ms(), self.vid)
            cpu = guest_cpu() - c0
            return len(fs) / s, (cpu * 1000 / len(fs)) if fs else None
        once(dy, 1.0)
        self.wait_quiet(1500, 30)
        runs = []
        for i in range(3):
            runs.append(once(dy if i % 2 == 0 else -dy, secs))
            self.wait_quiet(1500, 30)
        fps = statistics.median(r[0] for r in runs)
        cpf = [r[1] for r in runs if r[1] is not None]
        self.res[f"scroll_{label}_fps"] = round(fps, 1)
        self.res[f"scroll_{label}_cpu_ms_per_frame"] = round(statistics.median(cpf), 1) if cpf else None

    def typing(self):
        self.key_combo(29, 38)  # Ctrl+L
        time.sleep(1.0)
        self.wait_quiet(800, 20)
        lat = []
        for ch in "wikipedia linux kernel":
            m = now_ms()
            self.send("text " + ch.replace(" ", "%20"))
            l = self.first_frame_after(m, 5)
            if l is not None:
                lat.append(l)
            time.sleep(0.35)
        self.key_combo(1)  # Escape
        self.key_combo(1)
        self.wait_quiet(1000, 20)
        self.res["type_latency_ms_median"] = statistics.median(lat) if lat else None
        self.res["type_latency_ms_p90"] = sorted(lat)[int(len(lat) * 0.9)] if lat else None

    def tabs(self):
        self.key_combo(29, 20)  # Ctrl+T
        time.sleep(1.5)
        self.wait_quiet(1500, 30)
        tl = []
        for i in range(6):
            m = now_ms()
            self.key_combo(29, 104 if i % 2 == 0 else 109)  # Ctrl+PgUp / PgDn
            l = self.first_frame_after(m, 10)
            self.wait_quiet(800, 20)
            if l is not None:
                tl.append(l)
        self.key_combo(29, 17)  # Ctrl+W
        self.wait_quiet(1000, 20)
        self.res["tab_switch_ms_median"] = statistics.median(tl) if tl else None

    VIDEO_STATS = """
        const v = document.querySelector('video');
        if (!v) return null;
        const q = v.getVideoPlaybackQuality();
        return {t: v.currentTime, paused: v.paused, w: v.videoWidth, h: v.videoHeight,
                total: q.totalVideoFrames, dropped: q.droppedVideoFrames,
                parsed: v.mozParsedFrames, decoded: v.mozDecodedFrames,
                presented: v.mozPresentedFrames, painted: v.mozPaintedFrames,
                delay: v.mozFrameDelay, ready: v.readyState,
                audio: v.mozHasAudio};"""

    def play_window(self, key, secs, extra=None):
        """Stats over `secs` of playback; the page must have a playing <video>."""
        procs0 = proc_cpu()
        a = self.m.js(self.VIDEO_STATS)
        m0, t0 = now_ms(), time.time()
        mark("begin " + key)
        time.sleep(secs)
        mark("end " + key)
        b = self.m.js(self.VIDEO_STATS)
        wall, m1 = time.time() - t0, now_ms()
        procs1 = proc_cpu()
        c_delta = sum(c for _, c in procs1.values()) - sum(c for _, c in procs0.values())
        fs = self.frames_between(m0, m1, self.vid)
        if not a or not b:
            self.res[key] = {"error": "no video element"}
            return
        r = {"res": f"{b['w']}x{b['h']}", "media_s_per_s": round((b["t"] - a["t"]) / wall, 2),
             "decoded_fps": round((b["decoded"] - a["decoded"]) / wall, 1),
             "presented_fps": round((b["presented"] - a["presented"]) / wall, 1),
             "painted_fps": round((b["painted"] - a["painted"]) / wall, 1),
             "composited_fps": round(len(fs) / wall, 1),
             "dropped": b["dropped"] - a["dropped"], "total": b["total"] - a["total"],
             "cpu_s_per_s": round(c_delta / wall, 2), "audio": b["audio"],
             "cpu_by_process": proc_delta(procs0, procs1, wall)}
        r["dropped_pct"] = round(100 * r["dropped"] / r["total"], 1) if r["total"] else None
        if extra:
            r.update(extra)
        self.res[key] = r
        print(key, json.dumps(r), flush=True)

    def fullscreen_window(self, key, selector):
        """Element fullscreen (what a page's fullscreen button does), then measure."""
        ok = self.m.js_async("""
            const done = arguments[arguments.length - 1];
            document.querySelector(arguments[0]).requestFullscreen()
                .then(() => setTimeout(() => done(!!document.fullscreenElement), 3000), e => done(String(e)));""",
                             selector)
        if ok is not True:
            self.res[key] = {"error": str(ok)}
            return
        m0 = now_ms()
        self.play_window(key, self.args.video_secs)
        fs = self.frames_between(m0, now_ms(), self.vid)
        if fs and isinstance(self.res.get(key), dict):
            self.res[key]["damage_px"] = f"{fs[-1][3]}x{fs[-1][4]}"
        self.m.js_async("""const done = arguments[arguments.length - 1];
            document.exitFullscreen().then(() => setTimeout(done, 2000), () => done());""")

    def video_local(self):
        for f in self.args.videos.split(","):
            if not os.path.exists(f"{self.args.media}/{f}"):
                continue
            url = "file://" + HERE + "/pages/player.html?src=" + f"file://{self.args.media}/{f}"
            self.m.cmd("WebDriver:Navigate", {"url": url})
            ok = self.m.js_async("""
                const done = arguments[arguments.length - 1];
                const v = document.querySelector('video');
                v.play().then(() => setTimeout(() => done(true), 2000), e => done(String(e)));""")
            if ok is not True:
                self.res["video_" + f] = {"error": str(ok)}
                continue
            self.play_window("video_" + f, self.args.video_secs)
            if self.args.fullscreen:
                self.fullscreen_window("video_" + f + "_fs", "video")

    def youtube(self):
        self.m.cmd("WebDriver:Navigate", {"url": "https://www.youtube.com/robots.txt"})
        for name, value in (("SOCS", "CAESEwgDEgk0ODE3Nzk3MjQaAmVuIAEaBgiA_LyaBg"), ("CONSENT", "PENDING+987")):
            try:
                self.m.cmd("WebDriver:AddCookie", {"cookie": {"name": name, "value": value, "domain": ".youtube.com",
                                                                "path": "/", "secure": True}})
            except Exception as e:
                print("cookie", e)
        for quality in self.args.yt_quality.split(","):
            c0, t0 = guest_cpu(), time.time()
            try:
                self.m.cmd("WebDriver:Navigate", {"url": f"https://www.youtube.com/watch?v={YOUTUBE_VIDEO}"})
                nav_s = round(time.time() - t0, 1)
            except Exception as e:
                self.res["youtube_" + quality] = {"error": str(e)[:200]}
                continue
            state = self.m.js_async("""
                const done = arguments[arguments.length - 1], q = arguments[0], t0 = Date.now();
                (function poll() {
                  const p = document.getElementById('movie_player'), v = document.querySelector('video');
                  if (p && v && p.setPlaybackQualityRange) {
                    if (q !== 'auto') p.setPlaybackQualityRange(q, q);
                    if (v.paused) { v.muted = false; p.playVideo && p.playVideo(); }
                    if (v.currentTime > 1 && !v.paused) return done({ok: true, ms: Date.now() - t0});
                  }
                  if (Date.now() - t0 > 90000)
                    return done({ok: false, why: p ? (v ? 'not playing' : 'no video') : 'no player',
                                 ad: p ? p.classList.contains('ad-showing') : null});
                  setTimeout(poll, 250);
                })();""", quality)
            if not state or not state.get("ok"):
                self.res["youtube_" + quality] = {"error": state}
                continue
            time.sleep(4)  # let the quality switch land
            info = self.m.js("""
                const p = document.getElementById('movie_player');
                return {quality: p.getPlaybackQuality && p.getPlaybackQuality(),
                        ad: p.classList.contains('ad-showing'),
                        codec: (p.getStatsForNerds && p.getStatsForNerds().codecs) || null};""")
            if self.args.fullscreen:
                self.fullscreen_window("youtube_" + quality + "_fs", "#movie_player")
            self.play_window("youtube_" + quality, self.args.video_secs,
                             {"nav_s": nav_s, "start_to_play_s": round(state["ms"] / 1000, 1),
                              "yt": info, "cpu_until_play_s": round(guest_cpu() - c0, 1)})

    def run(self):
        suites = self.args.suites.split(",")
        self.launch()
        if "scroll" in suites:
            self.m.cmd("WebDriver:Navigate", {"url": "file://" + HERE + "/pages/long.html"})
            self.wait_quiet(1500, 30)
            self.scroll("local")
        if "type" in suites:
            self.typing()
        if "pages" in suites:
            pages = DEFAULT_PAGES
            if self.args.pages:
                pages = [tuple(p.split("=", 1)) for p in self.args.pages.split(",")]
            for name, url in pages:
                self.load(name, url)
            if "scroll" in suites:
                self.scroll("web")
        if "tabs" in suites:
            self.tabs()
        if "video" in suites:
            self.video_local()
        if "youtube" in suites:
            self.youtube()
        self.res["frames_total"] = len(self.frames())

    def close(self):
        try:
            os.killpg(self.ff.pid, signal.SIGTERM)
            time.sleep(2)
            os.killpg(self.ff.pid, signal.SIGKILL)
        except Exception:
            pass
        try:
            self.send("quit")
        except OSError:
            pass
        time.sleep(0.3)
        self.wl.kill()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--suites", default="launch,scroll,type,pages,tabs,video,youtube")
    ap.add_argument("--scale", default="2")
    ap.add_argument("--prefs")
    ap.add_argument("--pages")
    ap.add_argument("--media", default="/root/bench/media")
    ap.add_argument("--videos", default="h264-480p.mp4,h264-720p.mp4,vp9-480p.webm,vp9-720p.webm")
    ap.add_argument("--video-secs", type=float, default=10)
    ap.add_argument("--yt-quality", default="large,hd720")
    ap.add_argument("--fullscreen", action="store_true", help="also measure each video in element fullscreen")
    args = ap.parse_args()
    b = Bench(args)
    try:
        b.run()
    except Exception as e:
        b.res["fatal"] = repr(e)[:300]
        for name in ("/tmp/ffbench-ff.log", "/tmp/ffbench-ishwl.log"):
            try:
                with open(name, errors="replace") as f:
                    b.res.setdefault("fatal_logs", {})[name] = f.read()[-1500:]
            except OSError:
                pass
    finally:
        b.close()
    json.dump(b.res, open(args.out, "w"), indent=1)
    print(json.dumps(b.res))


if __name__ == "__main__":
    main()
