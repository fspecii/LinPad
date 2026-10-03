#!/usr/bin/env python3
"""Low-memory scenarios for LinPad (devtools/bench/lowmem.sh runs this in the guest).

    lowmem.py SCENARIO OUT.json      SCENARIO: idle, ff5, ffcode, yt720, ffcodeyt

The desktop session is started the way the iPad starts it (ishwl-session: session bus,
PulseAudio, /etc/ishwl/session.d), headless, and apps are launched through ishwl's
"spawn" so they get the session's environment, as from the launcher.
  idle    the session alone for 45 s
  ff5     Firefox with five tabs (four real sites and a heavy local page), then every
          tab shown once more
  ffcode  ff5, then VS Code on a small TypeScript project
  yt720   Firefox playing a YouTube video at 720p for 60 s
  ffcodeyt  ffcode, then the YouTube video at 720p in the last tab (the heaviest case)
Every 2 s the guest's view is logged (MemAvailable, /proc/pressure/memory, the
processes), and at the end which processes died and how. The host footprint is
sampled outside (devtools/bench/memsample.c).
"""
import json, os, signal, subprocess, sys, time
from urllib.parse import quote

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from ffbench import Marionette, YOUTUBE_VIDEO  # noqa: E402

RT, XDG = "/tmp/lowmem-rt", "/tmp/lowmem-xdg"
PROFILE = "/tmp/lowmem-profile"
# The guest shares the Mac's network stack with every other emulator running there;
# Marionette's default port 2828 may belong to another run's Firefox.
MARIONETTE_PORT = int(os.environ.get("LOWMEM_MARIONETTE_PORT", "2947"))
TABS = [
    "https://en.wikipedia.org/wiki/Linux",
    "https://github.com/torvalds/linux",
    "https://www.theguardian.com/international",
    "https://www.youtube.com/",
    "file://" + HERE + "/pages/heavy.html",
]
T0 = time.time()
LOG = []


def mark(text):
    line = f"{time.time() - T0:7.1f} {text}"
    print(line, flush=True)
    LOG.append(line)


ENOMEM_SEEN = [0]


def read(path):
    # Without the OOM monitor, whichever process allocates when the emulator refuses
    # memory gets ENOMEM; this driver must survive that to keep measuring.
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""
    except MemoryError:
        ENOMEM_SEEN[0] += 1
        time.sleep(0.5)
        return ""


def processes():
    try:
        return _processes()
    except MemoryError:
        ENOMEM_SEEN[0] += 1
        time.sleep(0.5)
        return {}


def _processes():
    out = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        status = read(f"/proc/{pid}/status")
        if f"Tgid:\t{pid}\n" not in status:
            continue
        cmd = read(f"/proc/{pid}/cmdline").replace("\0", " ").strip()[:100]
        rss = next((l.split()[1] for l in status.splitlines() if l.startswith("VmRSS")), "0")
        out[int(pid)] = {"cmd": cmd, "rss_mb": int(rss) // 1024,
                         "adj": read(f"/proc/{pid}/oom_score_adj").strip()}
    return out


def snapshot(tag):
    mem = {l.split(":")[0]: int(l.split()[1]) // 1024 for l in read("/proc/meminfo").splitlines()[:3]}
    psi = read("/proc/pressure/memory").splitlines()
    mark(f"[{tag}] MemTotal={mem.get('MemTotal')}MB MemAvailable={mem.get('MemAvailable')}MB "
         f"psi={psi[0] if psi else '-'}")
    return mem


class Session:
    def __init__(self):
        for d in (RT, XDG, PROFILE):
            subprocess.run(["rm", "-rf", d])
            os.makedirs(d, mode=0o700)
        env = dict(os.environ, XDG_RUNTIME_DIR=XDG, HOME="/root")
        self.wl = subprocess.Popen(["ishwl-session", "-H", "-s", "wayland-b", "-r", RT, "-S", "2",
                                    "-g", "1180x780"], env=env, stdout=open("/tmp/lowmem-session.log", "w"),
                                   stderr=subprocess.STDOUT, preexec_fn=os.setsid)
        for _ in range(1200):
            if os.path.exists(XDG + "/wayland-b") and os.path.exists(RT + "/events"):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("session did not start: " + read("/tmp/lowmem-session.log")[-300:])
        self.ev = os.open(RT + "/events", os.O_WRONLY)
        mark("session up")

    def spawn(self, command):
        os.write(self.ev, ("spawn " + quote(command, safe="") + "\n").encode())


def firefox(session):
    with open(PROFILE + "/user.js", "w") as f:
        f.write('user_pref("media.autoplay.default", 0);\n'
                'user_pref("media.autoplay.blocking_policy", 0);\n'
                'user_pref("browser.shell.checkDefaultBrowser", false);\n'
                'user_pref("browser.startup.page", 0);\n'
                'user_pref("browser.tabs.warnOnClose", false);\n'
                'user_pref("browser.sessionstore.resume_from_crash", false);\n'
                f'user_pref("marionette.port", {MARIONETTE_PORT});\n')
    session.spawn(f"firefox-esr --no-remote --marionette --profile {PROFILE} about:blank")
    m = Marionette(port=MARIONETTE_PORT, timeout=300)
    m.cmd("WebDriver:NewSession", {"capabilities": {"alwaysMatch": {"pageLoadStrategy": "normal"}}})
    m.cmd("WebDriver:SetTimeouts", {"pageLoad": 120000, "script": 120000, "implicit": 0})
    mark("firefox up")
    return m


CHECKED_PREFS = ["dom.ipc.processCount", "fission.autostart", "browser.newtab.preload",
                 "browser.cache.memory.capacity", "image.mem.surfacecache.max_size_kb",
                 "browser.low_commit_space_threshold_percent", "browser.tabs.unloadOnLowMemory",
                 "browser.tabs.min_inactive_duration_before_unload", "media.memory_caches_combined_limit_kb"]


def firefox_prefs(m):
    """The values Firefox actually runs with (gecko-tune.sh's prefs, if they applied)."""
    try:
        m.cmd("Marionette:SetContext", {"value": "chrome"})
        # Marionette's recommended automation prefs turn tab unloading off; a user's
        # Firefox has it on (gecko-tune.sh), so put the default back.
        m.js("Services.prefs.clearUserPref('browser.tabs.unloadOnLowMemory');")
        values = m.js("""
            const out = {};
            for (const name of arguments[0]) {
              const t = Services.prefs.getPrefType(name);
              out[name] = t == Services.prefs.PREF_INT ? Services.prefs.getIntPref(name) :
                          t == Services.prefs.PREF_BOOL ? Services.prefs.getBoolPref(name) :
                          t == Services.prefs.PREF_STRING ? Services.prefs.getStringPref(name) : null;
            }
            return out;""", CHECKED_PREFS)
        m.cmd("Marionette:SetContext", {"value": "content"})
        return values
    except Exception as e:
        return {"error": str(e)[:200]}


def navigate(m, url):
    t = time.time()
    try:
        m.cmd("WebDriver:Navigate", {"url": url})
        mark(f"loaded {url} in {time.time() - t:.1f}s")
        return True
    except Exception as e:  # a killed tab process, a timeout
        mark(f"load {url} failed after {time.time() - t:.1f}s: {str(e)[:160]}")
        return False


def five_tabs(m, res):
    handles = []
    for i, url in enumerate(TABS):
        if i:
            try:
                h = m.cmd("WebDriver:NewWindow", {"type": "tab"})
                m.cmd("WebDriver:SwitchToWindow", {"handle": h["handle"] if isinstance(h, dict) else h})
            except Exception as e:
                mark(f"new tab failed: {str(e)[:160]}")
                res["errors"] += 1
                continue
        if not navigate(m, url):
            res["errors"] += 1
        handles.append(i)
        snapshot(f"tab {i + 1}")
    time.sleep(20)
    try:
        for h in m.cmd("WebDriver:GetWindowHandles"):
            m.cmd("WebDriver:SwitchToWindow", {"handle": h})
            time.sleep(4)
    except Exception as e:
        mark(f"tab cycle failed: {str(e)[:160]}")
        res["errors"] += 1
    snapshot("tabs cycled")


def youtube(m, res):
    navigate(m, "https://www.youtube.com/robots.txt")
    for name, value in (("SOCS", "CAESEwgDEgk0ODE3Nzk3MjQaAmVuIAEaBgiA_LyaBg"), ("CONSENT", "PENDING+987")):
        try:
            m.cmd("WebDriver:AddCookie", {"cookie": {"name": name, "value": value, "domain": ".youtube.com",
                                                     "path": "/", "secure": True}})
        except Exception:
            pass
    if not navigate(m, f"https://www.youtube.com/watch?v={YOUTUBE_VIDEO}"):
        res["errors"] += 1
        return
    try:
        state = m.js_async("""
            const done = arguments[arguments.length - 1], t0 = Date.now();
            (function poll() {
              const p = document.getElementById('movie_player'), v = document.querySelector('video');
              if (p && v && p.setPlaybackQualityRange) {
                p.setPlaybackQualityRange('hd720', 'hd720');
                if (v.paused) { p.playVideo && p.playVideo(); }
                if (v.currentTime > 1 && !v.paused) return done({ok: true});
              }
              if (Date.now() - t0 > 90000) return done({ok: false});
              setTimeout(poll, 250);
            })();""")
        mark(f"youtube playing: {state}")
        t_end = time.time() + 60
        while time.time() < t_end:
            time.sleep(10)
            q = m.js("const v = document.querySelector('video'), p = document.getElementById('movie_player');"
                     "const s = v.getVideoPlaybackQuality();"
                     "return [v.currentTime, s.totalVideoFrames, s.droppedVideoFrames,"
                     " p.getPlaybackQuality && p.getPlaybackQuality()];")
            mark(f"video t={q[0]:.1f} frames={q[1]} dropped={q[2]} quality={q[3]}")
            res["video"] = q
    except Exception as e:
        mark(f"youtube failed: {str(e)[:160]}")
        res["errors"] += 1


def vscode(session, res):
    project = "/root/projects/lowmem"
    os.makedirs(project + "/src", exist_ok=True)
    with open(project + "/src/index.ts", "w") as f:
        f.write("export function sum(...xs: number[]): number {\n    return xs.reduce((a, b) => a + b, 0);\n}\n")
    with open(project + "/tsconfig.json", "w") as f:
        f.write('{ "compilerOptions": { "target": "ES2022", "strict": true }, "include": ["src"] }\n')
    session.spawn(f"/usr/local/bin/code {project} {project}/src/index.ts")
    t = time.time()
    while time.time() - t < 240:
        if any("--type=renderer" in p["cmd"] for p in processes().values()):
            break
        time.sleep(2)
    mark(f"vscode renderer up after {time.time() - t:.0f}s")
    time.sleep(60)
    snapshot("vscode settled")


def main():
    scenario, out = sys.argv[1], sys.argv[2]
    res = {"scenario": scenario, "errors": 0}
    session = Session()
    before = processes()
    time.sleep(15)
    snapshot("idle")
    res["idle_processes"] = {p: v["cmd"] for p, v in processes().items()}
    seen = {}

    def watch():
        for pid, p in processes().items():
            seen.setdefault(pid, p)
    if scenario == "idle":
        for _ in range(15):
            time.sleep(2)
            watch()
    else:
        m = firefox(session)
        res["firefox_prefs"] = firefox_prefs(m)
        mark(f"prefs {res['firefox_prefs']}")
        watch()
        if scenario in ("ff5", "ffcode", "ffcodeyt"):
            five_tabs(m, res)
        watch()
        if scenario in ("ffcode", "ffcodeyt"):
            vscode(session, res)
        watch()
        if scenario in ("yt720", "ffcodeyt"):
            youtube(m, res)
        watch()
        try:
            res["firefox_alive"] = bool(m.cmd("WebDriver:GetWindowHandles"))
        except Exception as e:
            res["firefox_alive"] = False
            mark(f"firefox gone: {str(e)[:120]}")
    now = processes()
    watch()
    res["died"] = [f"{pid} {p['cmd'][:80]}" for pid, p in seen.items() if pid not in now and pid not in before]
    res["final_processes"] = {p: f"{v['rss_mb']}MB adj={v['adj']} {v['cmd'][:80]}" for p, v in now.items()}
    res["ish_memory"] = read("/proc/ish/memory")
    res["dmesg_oom"] = [l for l in subprocess.run(["dmesg"], capture_output=True, text=True).stdout.splitlines()
                        if "Out of memory" in l]
    snapshot("end")
    res["driver_enomem"] = ENOMEM_SEEN[0]
    res["log"] = LOG
    with open(out, "w") as f:
        json.dump(res, f, indent=1)
    os.killpg(session.wl.pid, signal.SIGTERM)


if __name__ == "__main__":
    main()
