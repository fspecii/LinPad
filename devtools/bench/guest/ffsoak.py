#!/usr/bin/env python3
"""Firefox stability soak, run inside the guest (see ../ffsoak.sh).

    ffsoak.py OUT.json [--minutes 30] [--scale 2] [--minidumps]

Browses a fixed list of real sites in a loop for --minutes under a headless ishwl,
driven over Marionette (ffbench.py's harness): load, scroll, open and close tabs,
back and forward, and play a YouTube video. Every Firefox process that dies is
logged: from Firefox's own log ("process N exited on signal S", tab crashes), from
the kernel's crash log on the host (ISH_CRASHLOG=1, collected by ffsoak.sh), and
as relaunches when the parent process itself is gone. With --minidumps the crash
reporter is on and writes minidumps into the profile (no submission).
"""
import argparse, glob, json, os, random, re, shutil, signal, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ffbench  # noqa: E402
from ffbench import Bench, Marionette, guest_cpu  # noqa: E402

SITES = [
    ("wikipedia", "https://en.wikipedia.org/wiki/Linux"),
    ("wikipedia-main", "https://en.wikipedia.org/wiki/Main_Page"),
    ("bbc", "https://www.bbc.com/news"),
    ("guardian", "https://www.theguardian.com/international"),
    ("cnn", "https://edition.cnn.com/"),
    ("nytimes", "https://www.nytimes.com/"),
    ("hn", "https://news.ycombinator.com/"),
    ("github-linux", "https://github.com/torvalds/linux"),
    ("github-vscode", "https://github.com/microsoft/vscode/blob/main/README.md"),
    ("reddit", "https://www.reddit.com/r/programming/"),
    ("youtube", "https://www.youtube.com/"),
    ("youtube-watch", "https://www.youtube.com/watch?v=aqz-KE-bpKQ"),
    ("maps", "https://www.google.com/maps/@51.5072,-0.1276,13z"),
    ("x", "https://x.com/NASA"),
    ("amazon", "https://www.amazon.com/s?k=laptop"),
    ("ebay", "https://www.ebay.com/"),
    ("mdn", "https://developer.mozilla.org/en-US/docs/Web/JavaScript"),
    ("python-docs", "https://docs.python.org/3/library/asyncio.html"),
    ("react", "https://react.dev/learn"),
    ("stackoverflow", "https://stackoverflow.com/questions?tab=Votes"),
    ("google", "https://www.google.com/search?q=linux+kernel"),
    ("duckduckgo", "https://duckduckgo.com/?q=ipad"),
    ("imdb", "https://www.imdb.com/chart/top/"),
    ("twitch", "https://www.twitch.tv/directory"),
    ("apple", "https://www.apple.com/ipad-air/"),
    ("webgl-aquarium", "https://webglsamples.org/aquarium/aquarium.html"),
    ("threejs", "https://threejs.org/examples/#webgl_animation_keyframes"),
    ("excalidraw", "https://excalidraw.com/"),
    ("codepen", "https://codepen.io/trending"),
    ("speedometer-like", "https://todomvc.com/examples/react/dist/"),
]
FFLOG = "/tmp/ffbench-ff.log"
DEATH = re.compile(r"process (\d+) exited on signal (\d+)|exited with code (\d+)")


class Soak(Bench):
    def __init__(self, args):
        super().__init__(args)
        self.res.update({"events": [], "loads": 0, "load_errors": 0, "relaunches": 0, "tab_crashes": 0,
                         "child_deaths": 0, "iterations": 0, "sites": {}})
        self.flog_pos = 0
        self.t0 = time.time()
        if args.minidumps:
            self.env.pop("MOZ_CRASHREPORTER_DISABLE", None)
            self.env.update(MOZ_CRASHREPORTER="1", MOZ_CRASHREPORTER_NO_REPORT="1",
                            MOZ_CRASHREPORTER_SHUTDOWN="1")
        self.youtube_played = []

    def event(self, kind, **info):
        e = {"t": round(time.time() - self.t0, 1), "kind": kind, **info}
        self.res["events"].append(e)
        print("EVENT", json.dumps(e), flush=True)

    def scan_log(self):
        """New "process N exited on signal S" lines in Firefox's log."""
        try:
            with open(FFLOG, errors="replace") as f:
                f.seek(self.flog_pos)
                new = f.read()
                self.flog_pos = f.tell()
        except OSError:
            return
        for line in new.splitlines():
            m = DEATH.search(line)
            if m and (m.group(2) or (m.group(3) and m.group(3) != "0")):
                self.res["child_deaths"] += 1
                self.event("child_death", pid=m.group(1), signal=m.group(2), exit=m.group(3), line=line[:200])
            elif "out of memory" in line.lower() or "MOZ_CRASH" in line or "Assertion failure" in line:
                self.event("log", line=line[:240])

    def launch(self):
        super().launch()
        self.m.cmd("WebDriver:SetTimeouts", {"pageLoad": 60000, "script": 60000, "implicit": 0})

    def alive(self):
        return self.ff is not None and self.ff.poll() is None

    def relaunch(self, why):
        self.res["relaunches"] += 1
        self.event("parent_death", why=why[:200], returncode=self.ff.poll() if self.ff else None,
                   log_tail=open(FFLOG, errors="replace").read()[-600:] if os.path.exists(FFLOG) else "")
        try:
            os.killpg(self.ff.pid, signal.SIGKILL)
        except Exception:
            pass
        time.sleep(2)
        # Firefox's log restarts with the new process
        self.flog_pos = 0
        shutil.rmtree(ffbench.PROFILE + "/minidumps-saved", ignore_errors=True)
        self.launch()

    def handles(self):
        try:
            return self.m.cmd("WebDriver:GetWindowHandles")
        except Exception:
            return []

    def check_tab(self):
        try:
            url = self.m.cmd("WebDriver:GetCurrentURL")
        except Exception:
            return
        if isinstance(url, str) and url.startswith("about:tabcrashed"):
            self.res["tab_crashes"] += 1
            self.event("tab_crashed")

    def scroll_page(self, n=6):
        for i in range(n):
            self.send(f"axis {self.vid} 0 {25 if i < n - 1 else -40} 1")
            time.sleep(0.25)
        self.send(f"axis_stop {self.vid}")

    def visit(self, name, url):
        r = self.res["sites"].setdefault(name, {"loads": 0, "errors": 0, "load_s": []})
        t = time.time()
        try:
            self.m.cmd("WebDriver:Navigate", {"url": url})
        except Exception as e:
            r["errors"] += 1
            self.res["load_errors"] += 1
            if not self.alive() or "closed" in str(e).lower() or isinstance(e, (ConnectionError, OSError)):
                raise
        r["loads"] += 1
        self.res["loads"] += 1
        r["load_s"].append(round(time.time() - t, 1))
        self.wait_quiet(800, 15)
        self.scroll_page()
        if name == "youtube-watch":
            self.youtube_play()
        self.check_tab()

    def youtube_play(self):
        try:
            self.m.js("const v = document.querySelector('video'); if (v) { v.muted = true; v.play(); }")
            time.sleep(15)
            t = self.m.js("const v = document.querySelector('video'); return v ? v.currentTime : -1;")
            self.youtube_played.append(round(t, 1) if isinstance(t, (int, float)) else None)
        except Exception as e:
            self.youtube_played.append(str(e)[:80])

    def iteration(self, i):
        name, url = SITES[i % len(SITES)]
        action = i % 5
        if action == 1:
            # a new tab for this site; keep at most 3
            try:
                h = self.m.cmd("WebDriver:NewWindow", {"type": "tab"})
                self.m.cmd("WebDriver:SwitchToWindow", {"handle": h["handle"] if isinstance(h, dict) else h})
            except Exception as e:
                self.event("new_tab_failed", error=str(e)[:160])
            hs = self.handles()
            while len(hs) > 3:
                try:
                    self.m.cmd("WebDriver:SwitchToWindow", {"handle": hs[0]})
                    self.m.cmd("WebDriver:CloseWindow")
                except Exception:
                    break
                hs = self.handles()
                if hs:
                    self.m.cmd("WebDriver:SwitchToWindow", {"handle": hs[-1]})
        self.visit(name, url)
        if action == 3:
            for cmd in ("WebDriver:Back", "WebDriver:Forward"):
                try:
                    self.m.cmd(cmd)
                except Exception:
                    pass
                self.wait_quiet(800, 10)
            self.check_tab()

    def run(self):
        self.launch()
        end = self.t0 + self.args.minutes * 60
        i = 0
        while time.time() < end:
            try:
                self.iteration(i)
            except Exception as e:
                if not self.alive():
                    self.scan_log()
                    self.relaunch(repr(e))
                else:
                    self.event("error", site=SITES[i % len(SITES)][0], error=repr(e)[:200])
                    try:
                        self.m = Marionette(timeout=60)
                        self.m.cmd("WebDriver:NewSession", {"capabilities": {"alwaysMatch": {}}})
                    except Exception as e2:
                        self.relaunch("marionette lost: " + repr(e2))
            self.scan_log()
            i += 1
            self.res["iterations"] = i
            if i % 10 == 0:
                self.res["guest_cpu_s"] = round(guest_cpu(), 1)
                print("PROGRESS", i, round(time.time() - self.t0), "s", flush=True)
        self.res["youtube_played_s"] = self.youtube_played
        dumps = glob.glob(ffbench.PROFILE + "/minidumps/*.dmp")
        self.res["minidumps"] = [os.path.basename(d) for d in dumps]
        if dumps:
            os.makedirs("/root/bench/minidumps", exist_ok=True)
            for d in dumps:
                shutil.copy(d, "/root/bench/minidumps/")
                extra = d[:-4] + ".extra"
                if os.path.exists(extra):
                    shutil.copy(extra, "/root/bench/minidumps/")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--minutes", type=float, default=30)
    ap.add_argument("--scale", default="2")
    ap.add_argument("--prefs")
    ap.add_argument("--minidumps", action="store_true")
    args = ap.parse_args()
    random.seed(1)
    s = Soak(args)
    try:
        s.run()
    except Exception as e:
        s.res["fatal"] = repr(e)[:300]
    finally:
        s.scan_log()
        s.close()
    json.dump(s.res, open(args.out, "w"), indent=1)
    print(json.dumps({k: v for k, v in s.res.items() if k not in ("events", "sites")}))


if __name__ == "__main__":
    main()
