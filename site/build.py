#!/usr/bin/env python3
"""Builds the LinPad website (linpados.com) into site/dist as plain static files.

    python3 site/build.py                  # build from site/src (committed media)
    python3 site/build.py --refresh-media  # re-encode screenshots into site/src/media first

Data comes from the app itself: colour themes from DesktopKit's themes.json, keyboard
shortcuts from DesktopKeyboardShortcuts.swift, the app catalog from release/guest/linpad.
--refresh-media needs ImageMagick with AVIF and WebP support, and the screenshot folders
listed in MEDIA (some live outside the repo, in ../ipad-jit).
"""

from __future__ import annotations

import argparse
import base64
import html
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import date
from pathlib import Path

SITE = Path(__file__).resolve().parent
REPO = SITE.parent
SRC = SITE / "src"
DIST = SITE / "dist"
MEDIA = SRC / "media"
IPAD_JIT = REPO.parent / "ipad-jit"

DOMAIN = "https://linpados.com"
GITHUB = "https://github.com/fspecii/LinPad"
SOURCE_URL = "https://raw.githubusercontent.com/fspecii/LinPad/main/release/source.json"
YOUTUBE = "https://www.youtube.com/@Ambsd-yy7os"
X_URL = "https://x.com/AmbsdOP"
AUTHOR_SITE = "https://valineagu.com"
AUTHOR_GITHUB = "https://github.com/fspecii"
SPONSORS_URL = "https://github.com/sponsors/fspecii"
OPENCOLLECTIVE_URL = "https://opencollective.com/linpad"
CHAT_URL = "#chat-coming-soon"
GOOD_FIRST = GITHUB + "/issues?q=is%3Aopen+label%3A%22good+first+issue%22"
DISCUSSIONS = GITHUB + "/discussions"

# Set to a published file (e.g. "media/demo.mp4") once the demo video exists.
HERO_VIDEO: str | None = None

THEMES_JSON = REPO / "desktop/DesktopKit/Sources/DesktopKit/Resources/ColorThemes/themes.json"
SHORTCUTS_SWIFT = REPO / "desktop/DesktopKit/Sources/DesktopKit/Core/DesktopKeyboardShortcuts.swift"
WINDOW_MANAGER_SWIFT = REPO / "desktop/DesktopKit/Sources/DesktopKit/Core/WindowManager.swift"
CATALOG_JSON = REPO / "release/guest/linpad/catalog.json"
STORE_INDEX_JSON = REPO / "desktop/DesktopKit/Sources/DesktopKit/Resources/Store/store-index.json"

ONBOARDING = REPO / "build-sim-onboarding/shots"
SCREENSHOTS = REPO / "docs/screenshots"
THEME_SHOTS = IPAD_JIT / "theme-shots"
ICON_SHOTS = IPAD_JIT / "icon-shots"
STORE_SHOTS = IPAD_JIT / "store-shots"
VSCODE_SHOTS = IPAD_JIT / "vscode-shots/final"
CACHE = SITE / ".cache"
FONTS = SRC / "fonts"
SYSTEM_FONTS = IPAD_JIT / "fakefs-themes/data/usr/share/fonts"
FONT_LICENSE = REPO / "desktop/DesktopKit/Sources/DesktopKit/Resources/Fonts/OFL.txt"


@dataclass(frozen=True)
class Shot:
    key: str
    source: Path
    widths: tuple[int, ...]
    alt: str


MEDIA_SET = [
    Shot("hero", ONBOARDING / "onboarding-12-demo.png", (800, 1280, 1920),
         "LinPad desktop on an iPad: Firefox showing the LinPad GitHub page, a terminal and the Files app tiled side by side"),
    Shot("firefox", SCREENSHOTS / "02-firefox.jpg", (640, 1200), "Firefox rendering a Wikipedia article as a window on the LinPad desktop"),
    Shot("fastfetch", SCREENSHOTS / "03-foot-fastfetch.jpg", (640, 1200), "The foot terminal running fastfetch on Alpine Linux"),
    Shot("vscode", SCREENSHOTS / "04-vscode.jpg", (640, 1200), "Visual Studio Code editing a TypeScript project with its integrated terminal"),
    Shot("thunar", SCREENSHOTS / "10-thunar-native-window.jpg", (480, 900), "The Thunar file manager running as a native window"),
    Shot("wallhaven", SCREENSHOTS / "09-wallhaven.jpg", (640, 1200), "The built-in wallpaper browser"),
    Shot("overview", SCREENSHOTS / "07-style-ubuntu-overview.jpg", (640, 1200), "Workspace overview with live window thumbnails"),
    Shot("personalize", ONBOARDING / "onboarding-05-personalize-tokyo-night.png", (640, 1200), "The first-run personalise step with layout, theme and wallpaper choices"),
    Shot("themes-tour", ONBOARDING / "onboarding-03-tour-3-themes.png", (640, 1200), "Onboarding tour: themes in one keystroke"),
    Shot("intro", ONBOARDING / "onboarding-02-intro.png", (640, 1200), "LinPad first-run screen: Your iPad is a computer now"),
    Shot("keyboard", ONBOARDING / "onboarding-08-keyboard.png", (640, 1200), "Onboarding step showing keyboard and touch gestures"),
    Shot("tiler", ICON_SHOTS / "Qogir-tiler-desktop.png", (640, 1200), "The keyboard-first tiling layout with gaps and borders"),
    Shot("theme-app", THEME_SHOTS / "gallery.png", (640, 1200), "The Themes app gallery of desktop looks"),
    Shot("desk", CACHE / "desk.png", (720, 1200, 1800),
         "The LinPad desktop: Firefox on the LinPad GitHub page, a terminal showing fastfetch on Alpine Linux, and the Files app, tiled side by side"),
    Shot("app-firefox", CACHE / "app-firefox.png", (720, 1400), "Firefox showing the Wikipedia article on Linux, maximised on the LinPad desktop"),
    Shot("app-vscode", VSCODE_SHOTS / "app-tsx.png", (720, 1280),
         "Visual Studio Code editing a React and TypeScript project, with the file explorer and the integrated terminal"),
    Shot("store", STORE_SHOTS / "ish-01-home.png", (720, 1180),
         "The LinPad Store home page: a FileZilla banner, then developer essentials such as Visual Studio Code, Geany and Meld, and internet apps"),
    Shot("store-graphics", STORE_SHOTS / "ish-03-category-graphics.png", (720, 1180),
         "The Graphics category of the LinPad Store with GIMP, Inkscape, Krita, Blender and more"),
]

ERA_LOOKS = [
    ("luna", "Luna", "Inspired by the XP era: a blue taskbar, a green start button and rolling hills."),
    ("aero", "Aero", "Inspired by the late-2000s glass era: glass title bars and a light glass taskbar."),
    ("aero-night", "Aero Night", "The glass era after dark: glass windows over a black taskbar."),
    ("classic-98", "Classic 98", "Inspired by the late-90s desktop: grey bevels, navy title bars, a teal backdrop."),
    ("platinum", "Platinum", "Inspired by 90s desktop publishing machines: striped title bars and a menu bar on top."),
    ("aqua", "Aqua", "Inspired by the early 2000s: pinstripes, gel buttons and a white dock."),
    ("aqua-metal", "Aqua Metal", "Aqua with brushed-metal title bars."),
    ("modern-mac", "Modern", "A present-day look: traffic-light window buttons and a frosted dock, light or dark."),
    ("berry", "Berry", "Inspired by the handheld era: dark chrome bezels and blue focus rings."),
    ("dot-matrix", "Dot Matrix", "Monochrome with one red accent, dot-matrix type and desktop widgets."),
]
for era_id, era_name, _ in ERA_LOOKS:
    MEDIA_SET.append(Shot(f"era-{era_id}", THEME_SHOTS / f"{era_id}-desktop.png", (480, 960, 1366),
                          f"The {era_name} desktop look in LinPad"))

PRESS_SHOTS = ("desk", "app-firefox", "app-vscode", "store", "tiler", "theme-app")
ERA_PALETTE_IDS = {"luna", "aero", "aero-night", "aqua", "berry", "classic-98", "dot-matrix", "dot-matrix-dark", "platinum"}
SHOT_BY_KEY = {shot.key: shot for shot in MEDIA_SET}


def esc(text: str) -> str:
    return html.escape(text, quote=True)


# ---------------------------------------------------------------- media


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)


def make_composites() -> None:
    """Screens that need more than a resize.

    desk: the onboarding demo with the fastfetch output from docs/screenshots pasted into its empty terminal,
    so the hero shows a terminal that has run something. app-firefox: the Firefox window cropped to 16:10.
    """
    CACHE.mkdir(exist_ok=True)
    demo = ONBOARDING / "onboarding-12-demo.png"
    fastfetch, prompt = CACHE / "fastfetch.png", CACHE / "prompt.png"
    # Coordinates are for the 2732×2048 demo and the 1600×1112 fastfetch screenshot.
    run(["magick", str(SCREENSHOTS / "03-foot-fastfetch.jpg"), "-crop", "890x410+8+128", "+repage",
         "-fuzz", "9%", "-fill", "black", "-opaque", "rgb(21,24,43)", "-resize", "141%", str(fastfetch)])
    run(["magick", str(demo), "-crop", "222x58+1376+168", "+repage", str(prompt)])
    output_height = int(subprocess.run(["magick", "identify", "-format", "%h", str(fastfetch)],
                                       check=True, capture_output=True, text=True).stdout)
    next_prompt = 236 + output_height + 30
    run(["magick", str(demo), "-fill", "black", "-draw", "rectangle 1749,184 1772,222",
         str(fastfetch), "-geometry", "+1390+236", "-composite",
         str(prompt), "-geometry", f"+1376+{next_prompt}", "-composite",
         "-fill", "rgb(191,242,191)", "-draw", f"rectangle 1600,{next_prompt + 10} 1617,{next_prompt + 46}",
         str(CACHE / "desk.png")])
    run(["magick", str(IPAD_JIT / "r4-firefox-200s.png"), "-crop", "2124x1328+0+0", "+repage",
         str(CACHE / "app-firefox.png")])


FONT_FACES = [
    ("inter-400", "inter/Inter-Regular.otf"),
    ("inter-600", "inter/Inter-SemiBold.otf"),
    ("inter-display-700", "inter/InterDisplay-Bold.otf"),
    ("mono-400", "jetbrains-mono/JetBrainsMono-Regular.ttf"),
]
FONT_UNICODES = ("U+0020-007E,U+00A0-00FF,U+0131,U+0152-0153,U+02C6,U+02DA,U+02DC,U+2000-206F,U+20AC,U+2122,"
                 "U+2190-21FF,U+2212,U+2303,U+2318,U+2325,U+232B,U+2387,U+238B,U+23CE,U+2580-259F,U+25A0-25FF,U+2713")


def make_fonts() -> None:
    """Latin subsets of Inter and JetBrains Mono (both SIL OFL 1.1) as WOFF2, from the copies in the Linux image."""
    FONTS.mkdir(parents=True, exist_ok=True)
    for name, source in FONT_FACES:
        path = SYSTEM_FONTS / source
        if not path.exists():
            sys.exit(f"missing font: {path}")
        subprocess.run(["pyftsubset", str(path), f"--unicodes={FONT_UNICODES}", "--flavor=woff2",
                        "--layout-features=kern,liga,calt,ccmp,locl,mark,mkmk,tnum,case,cv11,ss01",
                        f"--output-file={FONTS / (name + '.woff2')}"], check=True)
    license_body = FONT_LICENSE.read_text().split("\n", 2)[2]
    (FONTS / "OFL.txt").write_text(
        "Inter: Copyright (c) 2016 The Inter Project Authors (https://github.com/rsms/inter)\n"
        "JetBrains Mono: Copyright 2020 The JetBrains Mono Project Authors (https://github.com/JetBrains/JetBrainsMono)\n"
        + license_body)


def refresh_media() -> None:
    MEDIA.mkdir(parents=True, exist_ok=True)
    make_fonts()
    make_composites()
    manifest: dict[str, dict] = {}
    for shot in MEDIA_SET:
        if not shot.source.exists():
            sys.exit(f"missing screenshot: {shot.source}")
        width, height = (int(v) for v in subprocess.run(
            ["magick", "identify", "-format", "%w %h", str(shot.source)], check=True, capture_output=True, text=True
        ).stdout.split())
        sizes = []
        for target in shot.widths:
            w = min(target, width)
            h = round(height * w / width)
            base = MEDIA / f"{shot.key}-{w}"
            run(["magick", str(shot.source), "-strip", "-resize", f"{w}x", "-quality", "78", f"{base}.webp"])
            run(["magick", str(shot.source), "-strip", "-resize", f"{w}x", "-quality", "55", f"{base}.avif"])
            sizes.append([w, h])
        manifest[shot.key] = {"sizes": sizes}
        print(f"media: {shot.key} {sizes}")
    press = MEDIA / "press"
    press.mkdir(exist_ok=True)
    for key in PRESS_SHOTS:
        run(["magick", str(SHOT_BY_KEY[key].source), "-strip", "-resize", "1920x>", "-quality", "84",
             str(press / f"linpad-{key}.jpg")])
    make_brand_images()
    (MEDIA / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")


CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")


def chrome_shot(html_text: str, out: Path, width: int, height: int, transparent: bool = False) -> None:
    """Renders a small HTML document to PNG with headless Chrome (ImageMagick's SVG renderer drops gradients)."""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        doc = Path(tmp) / "shot.html"
        doc.write_text(html_text)
        cmd = [str(CHROME), "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
               "--virtual-time-budget=4000",
               f"--window-size={width},{height}", f"--screenshot={out}"]
        if transparent:
            cmd.append("--default-background-color=00000000")
        subprocess.run(cmd + [doc.as_uri()], check=True, capture_output=True)


def make_brand_images() -> None:
    if not CHROME.exists():
        sys.exit(f"brand images need Google Chrome at {CHROME}")
    logo = (SRC / "assets/logo.svg").read_text()
    for size, name in ((32, "favicon-32.png"), (180, "apple-touch-icon.png"), (512, "press/linpad-logo-512.png")):
        sized = logo.replace("<svg ", f'<svg width="{size}" height="{size}" ', 1)
        chrome_shot(f"<!doctype html><style>html,body{{margin:0;background:transparent}}svg{{display:block}}</style>{sized}",
                    MEDIA / name, size, size, transparent=True)
    hero = SHOT_BY_KEY["desk"].source.as_uri()
    og_logo = logo.replace("<svg ", '<svg width="56" height="56" ', 1)
    og_png = MEDIA / "og.png"
    font_faces = "".join(
        f"@font-face{{font-family:{family};font-weight:{weight};src:url(data:font/woff2;base64,{base64.b64encode((FONTS / (name + '.woff2')).read_bytes()).decode()})}}"
        for name, family, weight in (("inter-400", "Inter", 400), ("inter-display-700", "InterDisplay", 700),
                                     ("mono-400", "Mono", 400))
    )
    chrome_shot(f"""<!doctype html><meta charset="utf-8"><style>{font_faces}
html,body{{margin:0;width:1200px;height:630px;overflow:hidden;background:#000;color:#f5f5f7;font-family:Inter,sans-serif}}
.glow{{position:absolute;inset:0;background:radial-gradient(560px 360px at 78% 64%,rgba(122,162,247,.30),transparent 70%),
radial-gradient(420px 300px at 96% 20%,rgba(187,154,247,.22),transparent 70%)}}
.copy{{position:absolute;left:64px;top:60px;width:500px}}
.brand{{display:flex;align-items:center;gap:16px;font:700 34px InterDisplay;letter-spacing:-.02em}}
h1{{font:700 62px/1.04 InterDisplay;letter-spacing:-.04em;margin:84px 0 26px}}
h1 span{{background:linear-gradient(95deg,#7aa2f7,#bb9af7 60%,#f7768e);-webkit-background-clip:text;color:transparent}}
p{{font:400 22px/1.4 Mono,monospace;color:#a1a1aa;margin:0}} p b{{color:#9ece6a;font-weight:400}}
.device{{position:absolute;left:590px;top:120px;width:760px;padding:16px;border-radius:40px;background:#0b0b0d;
box-shadow:0 0 0 2px #3a3a40,0 0 0 3px #111,0 40px 90px rgba(0,0,0,.7)}}
.device img{{display:block;width:100%;border-radius:24px}}
</style><div class="glow"></div>
<div class="copy"><div class="brand">{og_logo}LinPad</div>
<h1>Linux, on your iPad.<br><span>Smarter. And free.</span></h1><p><b>$</b> no VM · no jailbreak · GPLv3</p></div>
<div class="device"><img src="{hero}"></div>""", og_png, 1200, 630)
    run(["magick", str(og_png), "-strip", "-quality", "84", str(MEDIA / "og.jpg")])
    og_png.unlink()


def manifest() -> dict:
    path = MEDIA / "manifest.json"
    if not path.exists():
        sys.exit("site/src/media is empty: run with --refresh-media once")
    return json.loads(path.read_text())


MANIFEST: dict = {}


def srcset(key: str, ext: str) -> str:
    return ", ".join(f"/media/{key}-{w}.{ext} {w}w" for w, _ in MANIFEST[key]["sizes"])


def picture(key: str, sizes_attr: str, *, eager: bool = False, lazy: bool = True, alt: str | None = None,
            cls: str = "", img_id: str = "") -> str:
    """eager: fetchpriority high (above the fold). lazy=False: load with the page at normal priority."""
    sizes = MANIFEST[key]["sizes"]
    largest_w, largest_h = sizes[-1]
    fallback_w = sizes[min(1, len(sizes) - 1)][0]
    if eager:
        loading = 'fetchpriority="high" decoding="async"'
    elif lazy:
        loading = 'loading="lazy" decoding="async"'
    else:
        loading = 'decoding="async"'
    alt_text = esc(alt if alt is not None else SHOT_BY_KEY[key].alt)
    cls_attr = f' class="{cls}"' if cls else ""
    id_attr = f' id="{img_id}"' if img_id else ""
    return (
        f"<picture{cls_attr}>"
        f'<source type="image/avif" srcset="{srcset(key, "avif")}" sizes="{sizes_attr}">'
        f'<source type="image/webp" srcset="{srcset(key, "webp")}" sizes="{sizes_attr}">'
        f'<img{id_attr} src="/media/{key}-{fallback_w}.webp" alt="{alt_text}" width="{largest_w}" height="{largest_h}" {loading}>'
        "</picture>"
    )


# ---------------------------------------------------------------- data


def load_themes() -> list[dict]:
    return json.loads(THEMES_JSON.read_text())


MOD_SYMBOLS = {
    "windowKeys": "⌃⌥",
    "[.control, .option, .shift]": "⌃⌥⇧",
    ".command": "⌘",
    "[.command, .shift]": "⌘⇧",
    ".option": "⌥",
    "[.option, .shift]": "⌥⇧",
}


def default_branch(expr: str) -> str:
    """The table is built for the default ⌃⌥ modifier: `onCommand ? a : b` resolves to b."""
    expr = expr.strip()
    if expr.startswith("onCommand ?"):
        return expr.split(":", 1)[1].strip()
    return expr


def parse_shortcuts() -> list[tuple[str, str, str]]:
    text = SHORTCUTS_SWIFT.read_text()
    rows: list[tuple[str, str, str]] = []
    pattern = re.compile(
        r'DesktopCommand\(id: "(?P<id>[^"]+)", title: "(?P<title>[^"]+)", group: \.(?P<group>\w+),\s*'
        r'key: (?P<key>.+?),\s*modifiers: (?P<mods>.+?), keyLabel: (?P<label>"[^"]*"|onCommand \? "[^"]*" : "[^"]*")',
        re.S,
    )
    for match in pattern.finditer(text):
        mods = default_branch(" ".join(match["mods"].split()))
        label = default_branch(match["label"]).strip('"').replace("\\u{FE0E}", "").replace("\\\\", "\\")
        symbol = MOD_SYMBOLS.get(mods)
        if symbol is None:
            sys.exit(f"unknown modifier expression in {SHORTCUTS_SWIFT.name}: {mods}")
        rows.append((match["group"].capitalize(), match["title"].replace("…", "…"), symbol + label))
    workspaces = int(re.search(r"maximumWorkspaces = (\d+)", WINDOW_MANAGER_SWIFT.read_text())[1])
    rows.append(("Workspaces", f"Go to workspace 1 to {workspaces}", f"⌃⌥1 … ⌃⌥{workspaces}"))
    rows.append(("Workspaces", f"Move window to workspace 1 to {workspaces}", f"⌃⌥⇧1 … ⌃⌥⇧{workspaces}"))
    if len(rows) < 30:
        sys.exit(f"only {len(rows)} shortcuts parsed from {SHORTCUTS_SWIFT}; the parser needs updating")
    return rows


def load_catalog() -> list[dict]:
    data = json.loads(CATALOG_JSON.read_text())
    return data if isinstance(data, list) else data.get("packs", data.get("apps", []))


def colors_toml(theme: dict) -> str:
    ansi = theme.get("ansi") or []
    keys = ["background", "red", "green", "yellow", "blue", "magenta", "cyan", "foreground", "muted",
            "bright_red", "bright_green", "bright_yellow", "bright_blue", "bright_magenta", "bright_cyan",
            "bright_foreground"]
    lines = [f"# {theme['name']}: LinPad colour theme (colors.toml, the format Omarchy community themes use).",
             f'mode = "{theme["appearance"]}"', ""]
    for key in ("accent", "selection", "cursor"):
        if theme.get(key):
            lines.append(f'{key} = "{theme[key].lower()}"')
    lines.append("")
    for index, key in enumerate(keys):
        value = theme["background"] if key == "background" else theme["foreground"] if key == "foreground" else (
            ansi[index] if index < len(ansi) else None)
        if value:
            lines.append(f'{key} = "{value.lower()}"')
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- layout

ICONS = {
    "github": '<svg viewBox="0 0 16 16" aria-hidden="true" fill="currentColor"><path d="M8 0a8 8 0 0 0-2.53 15.59c.4.07.55-.17.55-.38v-1.33c-2.23.48-2.7-1.07-2.7-1.07-.36-.92-.89-1.17-.89-1.17-.73-.5.06-.49.06-.49.8.06 1.23.83 1.23.83.72 1.23 1.88.87 2.34.67.07-.52.28-.87.5-1.07-1.78-.2-3.65-.89-3.65-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.22 2.2.82a7.6 7.6 0 0 1 4 0c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.28.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48v2.2c0 .21.15.46.55.38A8 8 0 0 0 8 0Z"/></svg>',
    "sun": '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>',
    "menu": '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 7h16M4 12h16M4 17h16"/></svg>',
    "window": '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18"/></svg>',
    "tile": '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="8" height="18" rx="1.5"/><rect x="13" y="3" width="8" height="8" rx="1.5"/><rect x="13" y="13" width="8" height="8" rx="1.5"/></svg>',
    "cmd": '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3Z"/></svg>',
    "palette": '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 3a9 9 0 1 0 0 18c1.1 0 1.5-.8 1.5-1.6 0-1.2-1-1.4-1-2.5 0-.9.7-1.4 1.6-1.4H17a4 4 0 0 0 4-4c0-4.7-4-8.5-9-8.5Z"/><circle cx="7.5" cy="11" r="1"/><circle cx="10" cy="7" r="1"/><circle cx="15" cy="7" r="1"/></svg>',
    "term": '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 9 3 3-3 3M13 15h4"/></svg>',
    "box": '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2"><path d="m3 7 9-4 9 4-9 4-9-4Zm0 0v10l9 4 9-4V7M12 11v10"/></svg>',
    "bolt": '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M13 2 4 14h7l-1 8 9-12h-7l1-8Z"/></svg>',
    "chip": '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2"><rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/></svg>',
    "wine": '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M8 2h8l-1 7a3 3 0 0 1-6 0L8 2ZM12 12v8M8 22h8"/></svg>',
    "wrench": '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M14.7 6.3a4 4 0 0 0 5 5L21 13l-8 8-3-3 8-8-1.3-1.3a4 4 0 0 1-5-5l2.6 2.6 2.4-.6.6-2.4-2.6-2.6Z"/></svg>',
    "files": '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 6a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6Z"/></svg>',
    "camera": '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="6" width="18" height="14" rx="2"/><circle cx="12" cy="13" r="3.5"/><path d="M8 6l1.5-2h5L16 6"/></svg>',
}

NAV = [
    ("/install/", "Install", "install"),
    ("/themes/", "Themes", "themes"),
    ("/manual/", "Manual", "manual"),
    ("/faq/", "FAQ", "faq"),
    ("/contribute/", "Contribute", "contribute"),
    ("/support/", "Support", "support"),
]

# Runs before first paint: marks JS as available (the hero scroll sequence starts from its first frame
# instead of the static final frame) and applies a stored light theme. Dark is the default.
HEAD_BOOT = ("<script>document.documentElement.classList.add('js');try{if(localStorage.getItem('linpad-theme')==='light')"
             "document.documentElement.dataset.theme='light'}catch(e){}</script>")

FONT_PRELOADS = "".join(
    f'<link rel="preload" href="/fonts/{name}.woff2" as="font" type="font/woff2" crossorigin>'
    for name in ("inter-400", "inter-display-700")
)


CURRENT = ' aria-current="page"'
MEAN = ' class="mean"'


def page(*, path: str, title: str, description: str, body: str, active: str, og_image: str = "/media/og.jpg",
         extra_head: str = "", body_class: str = "") -> str:
    canonical = DOMAIN + path
    full_title = title if title.startswith("LinPad") else f"{title} · LinPad"
    nav_links = "".join(
        f'<li><a href="{href}"{CURRENT if key == active else ""}>{label}</a></li>'
        for href, label, key in NAV
    )
    body_attr = f' class="{body_class}"' if body_class else ""
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{esc(full_title)}</title>
<meta name="description" content="{esc(description)}">
<link rel="canonical" href="{canonical}">
<meta name="theme-color" content="#000000">
<meta name="color-scheme" content="dark light">
<meta property="og:type" content="website">
<meta property="og:site_name" content="LinPad">
<meta property="og:title" content="{esc(full_title)}">
<meta property="og:description" content="{esc(description)}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="{DOMAIN}{og_image}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="LinPad: Linux on your iPad. Smarter. And free.">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:site" content="@AmbsdOP">
<meta name="twitter:creator" content="@AmbsdOP">
<meta name="twitter:title" content="{esc(full_title)}">
<meta name="twitter:description" content="{esc(description)}">
<meta name="twitter:image" content="{DOMAIN}{og_image}">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="icon" href="/media/favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="/media/apple-touch-icon.png">
{FONT_PRELOADS}
<link rel="stylesheet" href="/assets/site.css?v={ASSET_VERSION}">
{HEAD_BOOT}
{extra_head}
</head>
<body{body_attr}>
<a class="skip" href="#main">Skip to content</a>
<header class="gnav{" dark-scope" if active == "home" else ""}">
  <nav class="gnav-inner" aria-label="Main">
    <a class="brand" href="/"{CURRENT if active == "home" else ""}><img src="/favicon.svg" alt="" width="24" height="24">LinPad</a>
    <ul class="gnav-links" id="nav-links">{nav_links}</ul>
    <div class="gnav-tools">
      <a class="icon-btn" href="{GITHUB}" aria-label="LinPad on GitHub">{ICONS["github"]}</a>
      <button class="icon-btn" id="theme-toggle" type="button" aria-label="Switch to light theme">{ICONS["sun"]}</button>
      <a class="gnav-cta" href="/install/">Get LinPad</a>
      <button class="icon-btn menu-btn" id="menu-toggle" type="button" aria-label="Menu" aria-controls="nav-links" aria-expanded="false">{ICONS["menu"]}</button>
    </div>
  </nav>
</header>
<main id="main">
{body}
</main>
{footer()}
<script src="/assets/site.js?v={ASSET_VERSION}" defer></script>
</body>
</html>
"""


def footer() -> str:
    year = date.today().year
    return f"""<footer class="site-footer">
  <div class="wrap">
    <div class="foot-top">
      <div class="foot-brand">
        <a class="brand" href="/"><img src="/favicon.svg" alt="" width="24" height="24" loading="lazy">LinPad</a>
        <p>Linux for iPad. Free and open source under the GPLv3.</p>
        <p>Built by <a href="{AUTHOR_SITE}">Vali Neagu</a> in London.</p>
        <p class="foot-status"><span class="dot" aria-hidden="true"></span>Pre-release. Screenshots are from development builds.</p>
      </div>
      <div class="foot-cols">
        <div>
          <h2>Project</h2>
          <ul>
            <li><a href="/install/">Install</a></li>
            <li><a href="/themes/">Themes</a></li>
            <li><a href="/manual/">Manual</a></li>
            <li><a href="/faq/">FAQ</a></li>
            <li><a href="{GITHUB}/releases">Releases</a></li>
          </ul>
        </div>
        <div>
          <h2>Community</h2>
          <ul>
            <li><a href="/contribute/">Contribute</a></li>
            <li><a href="/support/">Support the project</a></li>
            <li><a href="/press/">Press kit</a></li>
            <li><a href="{GITHUB}">Source on GitHub</a></li>
          </ul>
        </div>
        <div>
          <h2>Author</h2>
          <ul>
            <li><a href="{AUTHOR_SITE}">valineagu.com</a></li>
            <li><a href="{X_URL}">X @AmbsdOP</a></li>
            <li><a href="{AUTHOR_GITHUB}">GitHub @fspecii</a></li>
            <li><a href="{YOUTUBE}">YouTube</a></li>
          </ul>
        </div>
      </div>
    </div>
    <div class="legal">
      <p>© {year} Vali Neagu and LinPad contributors. LinPad is licensed under the GNU GPLv3 and builds on <a href="https://github.com/ish-app/ish">iSH</a> and <a href="https://github.com/meikis/ish-arm64">iSH-ARM64</a>. Inter and JetBrains Mono are used under the <a href="/fonts/OFL.txt">SIL Open Font License</a>.</p>
      <p>iPad and iPadOS are trademarks of Apple Inc., registered in the U.S. and other countries. Linux® is the registered trademark of Linus Torvalds in the U.S. and other countries. Firefox is a trademark of the Mozilla Foundation. Visual Studio Code is a product of Microsoft. All other names belong to their owners. LinPad is an independent project and is not affiliated with or endorsed by any of them. The device on this site is a drawing, not a photo of a real product.</p>
    </div>
  </div>
</footer>"""


ASSET_VERSION = "1"


# ---------------------------------------------------------------- pages


def feature_card(icon: str, title: str, text: str, tag: str = "") -> str:
    return (f'<article class="card"><div class="ico">{ICONS[icon]}</div>'
            f"<h3>{title}{tag}</h3><p>{text}</p></article>")


EXP = ' <span class="tag tag-exp">experimental</span>'
BETA = ' <span class="tag">beta</span>'
NEEDS = ' <span class="tag">needs StikDebug</span>'


def tablet(screen: str, *, cls: str = "", screen_cls: str = "") -> str:
    """A generic tablet drawn in CSS around a screen: no product artwork."""
    return (f'<div class="tablet-cq {cls}"><div class="tablet"><div class="tablet-screen {screen_cls}">{screen}</div></div></div>')


BOOT_LOG: list[tuple[str, str]] = [
    ("LinPad boot · iSH-ARM64 usermode Linux · aarch64", "hd"),
    ("[    0.000000] Linux version 4.20.69-ish (linpad) #1 SMP", ""),
    ("[    0.000000] Machine: iPad, Apple silicon, iPadOS app sandbox", "x"),
    ("[    0.000731] mm: memory allowance read, low-memory guard on", ""),
    ("[    0.002114] jit: native ARM64 translator ready (fast mode)", ""),
    ("[    0.004380] fakefs: / mounted, Alpine Linux 3.21 aarch64", ""),
    ("[    0.004912] fakefs: /mnt/ipad mounted, iPad folders linked", "x"),
    ("[    0.010277] gpu: virtio-gpu → Venus → MoltenVK → Metal", ""),
    ("[    0.011653] snd: PulseAudio → iOS audio bridge", "x"),
    ("[    0.013090] net: sockets through iPadOS, DNS ok", "x"),
    (" * Mounting /proc, /sys and /dev ...", "ok"),
    (" * Starting ishwl Wayland compositor ...", "ok"),
    (" * Starting PulseAudio sound server ...", "ok"),
    (" * Applying colour theme tokyo-night ...", "ok"),
    (" * Restoring session: 3 windows ...", "ok"),
    ("", "x"),
    ("Welcome to Alpine Linux 3.21 on LinPad", "hd"),
    ("Kernel 4.20.69-ish on aarch64 (tty1)", "x"),
    ("Starting LinPad desktop…", "go"),
]
BOOT_START, BOOT_END = 0.13, 0.52


def boot_lines() -> tuple[str, str]:
    """The boot log twice: as scroll-typed lines inside the hero screen, and as a static block for reduced motion."""
    width = max(len(text) for text, kind in BOOT_LOG if kind == "ok") + 3
    step = (BOOT_END - BOOT_START) / (len(BOOT_LOG) - 1)
    typed, static = [], []
    for index, (text, kind) in enumerate(BOOT_LOG):
        if kind == "ok":
            shown = f'{esc(text.ljust(width))}<span class="ok">[ ok ]</span>'
            length = width + 6
        elif text.startswith("["):
            stamp, rest = text[:14], text[14:]
            shown = f'<span class="ts">{esc(stamp)}</span>{esc(rest)}'
            length = len(text)
        else:
            shown, length = esc(text), len(text)
        classes = " ".join(c for c in ("bl", kind if kind in ("hd", "go") else "", "x" if kind == "x" else "") if c)
        start = BOOT_START + index * step
        typed.append(f'<span class="{classes}" style="--s:{start:.3f};--n:{length + 3}">{shown or "&nbsp;"}</span>')
        static.append(f'<span class="{classes}">{shown}</span>')
    return "".join(typed), "".join(static)


FASTFETCH = r"""<span class="c4">root@ish</span>:<span class="c6">~</span># fastfetch
<span class="c4"> _  ____  _   _ </span>  <span class="c4">root</span>@<span class="c4">iPad Air 11-inch (M3)</span>
<span class="c4">(_)/ ___|| | | |</span>  -------------------------
<span class="c4">| |\___ \| |_| |</span>  <span class="c4">OS</span>: iSH Linux Desktop (Alpine 3.21 base) aarch64
<span class="c4">| | ___) |  _  |</span>  <span class="c4">Kernel</span>: Linux 4.20.69-ish
<span class="c4">|_||____/|_| |_|</span>  <span class="c4">Packages</span>: 189 (apk)
<span class="c4">  Linux on iPad </span>  <span class="c4">Terminal</span>: foot 1.19.0
                  <span class="c4">CPU</span>: Apple M3 (10 cores, emulated by iSH)
                  <span class="c4">GPU</span>: Apple iOS simulator GPU (Venus, Vulkan)
                  <span class="c4">Memory</span>: 4.01 GiB / 4.10 GiB (98%)

                  <span class="sw"><i class="b0"></i><i class="b1"></i><i class="b2"></i><i class="b3"></i><i class="b4"></i><i class="b5"></i><i class="b6"></i><i class="b7"></i></span>
<span class="c4">root@ish</span>:<span class="c6">~</span># <span class="cur"></span>"""


def term_window(title: str, content: str, *, label: str, cls: str = "") -> str:
    return (f'<div class="term-win {cls}" role="img" aria-label="{esc(label)}">'
            f'<div class="term-bar" aria-hidden="true"><i></i><i></i><i></i><span>{esc(title)}</span></div>'
            f'<pre class="term-body" aria-hidden="true">{content}</pre></div>')


def keycaps(keys: str) -> str:
    """'⌃⌥⇧T' → separate caps for each modifier, then the key name."""
    mods, rest = [], keys
    while rest and rest[0] in "⌘⌃⌥⇧":
        mods.append(rest[0])
        rest = rest[1:]
    names = {"⌘": "Command", "⌃": "Control", "⌥": "Option", "⇧": "Shift"}
    caps = "".join(f'<kbd title="{names[m]}">{m}</kbd>' for m in mods)
    wide = " wide" if len(rest) > 1 else ""
    return caps + f'<kbd class="key{wide}">{esc(rest)}</kbd>'


def store_stats() -> tuple[int, int, list[tuple[str, int]]]:
    data = json.loads(STORE_INDEX_JSON.read_text())
    apps = data["apps"]
    tested = sum(1 for app in apps if app.get("compat") == "works")
    counts: dict[str, int] = {}
    for app in apps:
        counts[app.get("category") or "Other"] = counts.get(app.get("category") or "Other", 0) + 1
    return len(apps), tested, sorted(counts.items(), key=lambda kv: -kv[1])


KEY_FEATURES = [
    ("Command Menu", "One menu for windows, apps, commands, themes and settings."),
    ("Keyboard Shortcuts", "Every shortcut, searchable, one chord away."),
    ("Clipboard History", "Everything you copied, in Linux apps and iPad apps."),
    ("New Terminal", "A shell, wherever you are."),
    ("Toggle Auto-Tiling", "Tiling per workspace: master-stack, columns, grid, monocle."),
    ("Next Color Theme", "Recolour the desktop and every Linux app at once."),
    ("Overview", "Every workspace and window, live."),
    ("Snap Left Half", "Halves and quarters without touching the screen."),
]

APP_STEPS = [
    ("firefox", "Firefox. The real one.",
     "The Firefox that Alpine Linux ships for aarch64, in a window you can move, tile and snap. Tabs, extensions, developer tools: it is just Firefox."),
    ("vscode", "VS Code, with a terminal that means it.",
     "Microsoft's build, downloaded on your iPad when you ask for it. Node 22, npm, git and Python are already installed, so <code>npm run dev</code> just runs."),
    ("term", "A shell with the whole archive behind it.",
     "foot, fastfetch, btop and every package in Alpine's aarch64 repositories, one <code>apk add</code> away. You are root in your own sandbox."),
]

PALETTE_DEFAULT = "tokyo-night"


def home(themes: list[dict], shortcuts: list[tuple[str, str, str]]) -> str:
    typed_boot, static_boot = boot_lines()
    palettes = [t for t in themes if t["id"] not in ERA_PALETTE_IDS]
    app_count, tested_count, categories = store_stats()
    keys_by_title = {title: keys for _, title, keys in shortcuts}
    missing = [title for title, _ in KEY_FEATURES if title not in keys_by_title]
    if missing:
        sys.exit(f"home page shortcuts not found in {SHORTCUTS_SWIFT.name}: {missing}")

    desk = picture("desk", "(max-width: 700px) 92vw, (max-width: 1400px) 74vw, 1100px", lazy=False)
    seq = f"""
<section class="seq dark-scope" aria-labelledby="seq-h">
  <div class="seq-stage">
    <div class="seq-intro">
      <p class="seq-badges"><span class="pill pill-pre"><span class="dot" aria-hidden="true"></span>Pre-release</span><span class="pill">Free · GPLv3</span></p>
      <h1 id="seq-h" class="display">Linux, on your iPad.</h1>
      <p class="seq-sub">Firefox, VS Code and the whole Alpine Linux archive, running on the iPad itself. <span class="nowrap">No VM. No jailbreak.</span></p>
      <p class="seq-hint" aria-hidden="true"><span>scroll to boot</span></p>
    </div>
    <div class="seq-device">
      {tablet(f'<pre class="boot" aria-hidden="true">{typed_boot}</pre><div class="seq-desk">{desk}</div><div class="seq-dim"></div>', cls="tablet-hero")}
    </div>
    <div class="seq-final">
      <p class="seq-line">From now on, your iPad is <span class="grad">smarter.</span><br><span class="grad grad-2">And free.</span></p>
      <div class="cta-row">
        <a class="btn btn-primary" href="/install/">Get LinPad</a>
        <a class="btn btn-ghost" href="{GITHUB}">{ICONS["github"]} Star on GitHub</a>
      </div>
      <p class="seq-note">Development build in the iPad simulator. Boot text is illustrative; the fastfetch output in the terminal comes from a separate real run.</p>
    </div>
  </div>
  <div class="seq-static" aria-hidden="true"><pre class="boot-static">{static_boot}</pre></div>
</section>"""

    statement = """
<section class="statement" aria-label="What LinPad is">
  <div class="wrap">
    <p class="statement-line">One app. A real Linux userland. <span class="muted">Native iPad windows, a tiling desktop, a store of Linux apps and themes that reach all of them.</span></p>
    <ul class="ticker" aria-label="Some of the software that runs on LinPad">
      <li>firefox</li><li>code</li><li>gimp</li><li>filezilla</li><li>libreoffice</li><li>inkscape</li><li>thunar</li><li>foot</li><li>btop</li><li>node 22</li><li>git</li><li>python3</li><li>vlc</li><li>apk add …</li>
    </ul>
  </div>
</section>"""

    terminal = term_window("foot · ~", FASTFETCH, label="A terminal running fastfetch on Alpine Linux, transcribed from a development build", cls="pal-tokyo")
    screens = {
        "firefox": picture("app-firefox", "(max-width: 1000px) 92vw, 640px"),
        "vscode": picture("app-vscode", "(max-width: 1000px) 92vw, 640px"),
        "term": f'<div class="screen-term">{terminal}</div>',
    }
    mobile_screens = {
        "firefox": picture("app-firefox", "92vw"),
        "vscode": picture("app-vscode", "92vw"),
        "term": terminal,
    }
    story_screens = "".join(
        f'<div class="story-screen{" is-active" if i == 0 else ""}" data-step="{i}">{screens[key]}</div>'
        for i, (key, _, _) in enumerate(APP_STEPS)
    )
    story_steps = "".join(
        f'<li class="story-step" data-step="{i}"><div class="story-shot">{mobile_screens[key]}</div>'
        f'<h3>{title}</h3><p>{text}</p></li>'
        for i, (key, title, text) in enumerate(APP_STEPS)
    )
    apps = f"""
<section class="sec" id="apps" aria-labelledby="apps-h">
  <div class="wrap">
    <header class="sec-head">
      <p class="kicker"><span aria-hidden="true">$</span> apk add firefox code gimp</p>
      <h2 id="apps-h" class="h-xl">Real Linux apps.<br><span class="muted">As real iPad windows.</span></h2>
      <p class="lede">Not ports, not remote desktops. Unmodified aarch64 Linux programs, translated to iPadOS system calls inside one app, drawn as native windows next to everything else.</p>
    </header>
    <div class="story">
      <div class="story-media">{tablet(story_screens, cls="tablet-wide")}</div>
      <ol class="story-steps">{story_steps}</ol>
    </div>
    <p class="fineprint">Screenshots from development builds in the iPad simulator. The terminal is a transcription of a real fastfetch run.</p>
  </div>
</section>"""

    era_buttons = "".join(
        f'<li><button type="button" class="chip" aria-pressed="{"true" if i == 0 else "false"}" '
        f'data-look="era-{era_id}" data-avif="{srcset("era-" + era_id, "avif")}" data-webp="{srcset("era-" + era_id, "webp")}" '
        f'data-alt="{esc(SHOT_BY_KEY["era-" + era_id].alt)}" data-caption="{esc(text)}">{esc(name)}</button></li>'
        for i, (era_id, name, text) in enumerate(ERA_LOOKS)
    )
    first_era = ERA_LOOKS[0]

    def palette_data(theme: dict) -> str:
        ansi = (theme.get("ansi") or [])[:8]
        return esc(json.dumps({"bg": theme["background"], "fg": theme["foreground"],
                               "accent": theme.get("accent") or theme["foreground"], "ansi": ansi}, separators=(",", ":")))

    palette_buttons = "".join(
        f'<li><button type="button" class="chip chip-pal" aria-pressed="{"true" if t["id"] == PALETTE_DEFAULT else "false"}" '
        f'data-palette="{palette_data(t)}"><span class="pal-dots" aria-hidden="true">'
        + "".join(f'<i style="background:{esc(c)}"></i>' for c in [t["background"]] + (t.get("ansi") or [])[1:5])
        + f'</span>{esc(t["name"])}</button></li>'
        for t in palettes
    )
    default_palette = next(t for t in palettes if t["id"] == PALETTE_DEFAULT)
    palette_vars = ";".join(
        [f"--t-bg:{default_palette['background']}", f"--t-fg:{default_palette['foreground']}"]
        + [f"--t-c{i}:{c}" for i, c in enumerate((default_palette.get("ansi") or [])[:8])]
    )
    themes_html = f"""
<section class="sec sec-themes" id="themes" aria-labelledby="themes-h">
  <div class="wrap">
    <header class="sec-head">
      <p class="kicker"><span aria-hidden="true">⌃⌥⇧C</span> next theme</p>
      <h2 id="themes-h" class="h-xl">Make it yours.<br><span class="muted">Down to the last pixel of the 90s.</span></h2>
      <p class="lede">{len(ERA_LOOKS)} desktop looks with matching window chrome, wallpapers and Linux app themes. {len(palettes)} colour palettes in the same <code>colors.toml</code> format Omarchy community themes use.</p>
    </header>
    <div class="looks">
      <figure class="looks-stage">
        {tablet(picture("era-" + first_era[0], "(max-width: 1000px) 92vw, 980px", img_id="look-img"), cls="tablet-look")}
        <figcaption id="look-caption" aria-live="polite"><b id="look-name">{esc(first_era[1])}</b> <span id="look-text">{esc(first_era[2])}</span></figcaption>
      </figure>
      <ul class="chips" aria-label="Desktop looks">{era_buttons}</ul>
    </div>
    <div class="palettes">
      <div class="palettes-copy">
        <h3 class="h-md">Palettes that reach every app.</h3>
        <p>A colour theme recolours the shell, the terminal, btop, GTK and Qt apps, VS Code and Firefox together. Try one: press <kbd>T</kbd> to cycle, like on Omarchy.</p>
        <ul class="chips chips-pal" aria-label="Colour palettes">{palette_buttons}</ul>
        <p class="sr-status" id="pal-status" aria-live="polite"></p>
        <p><a class="link-arrow" href="/themes/">Every look and palette, with colors.toml downloads</a></p>
      </div>
      <div class="palettes-term" id="pal-term" style="{esc(palette_vars)}">
        {term_window("foot · ~/projects", PALETTE_SAMPLE, label="Terminal preview in the selected colour palette")}
      </div>
    </div>
  </div>
</section>"""

    category_rows = "".join(
        f'<li><span>{esc(name)}</span><span class="bar" style="--w:{count / categories[0][1]:.3f}" aria-hidden="true"></span><b>{count}</b></li>'
        for name, count in categories
    )
    store = f"""
<section class="sec sec-store" id="store" aria-labelledby="store-h">
  <div class="wrap">
    <header class="sec-head">
      <p class="kicker"><span aria-hidden="true">$</span> linpad store</p>
      <h2 id="store-h" class="h-xl">The Store.<br><span class="muted">{app_count} Linux apps, one tap each.</span></h2>
      <p class="lede">GIMP, Inkscape, Krita, LibreOffice, FileZilla, Thunderbird and hundreds more, packaged from Alpine Linux and described with Flathub's metadata. Installs run in the background while you work.</p>
    </header>
    <figure class="store-shot">
      {tablet(picture("store", "(max-width: 1100px) 92vw, 1040px"), cls="tablet-wide")}
      <figcaption>The LinPad Store, development build.</figcaption>
    </figure>
    <div class="store-facts">
      <div class="big-stat"><b>{app_count}</b><span>apps in the catalog</span></div>
      <div class="big-stat"><b>{tested_count}</b><span>marked “works well” after testing on LinPad. The rest are untested, and say so.</span></div>
      <ul class="cat-bars" aria-label="Apps per category">{category_rows}</ul>
    </div>
  </div>
</section>"""

    key_cards = "".join(
        f'<li class="keycard"><div class="caps">{keycaps(keys_by_title[title])}</div><h3>{esc(title)}</h3><p>{esc(text)}</p></li>'
        for title, text in KEY_FEATURES
    )
    keyboard = f"""
<section class="sec sec-keys dark-scope" id="keyboard" aria-labelledby="keys-h">
  <div class="wrap">
    <header class="sec-head">
      <p class="kicker"><span aria-hidden="true">⌘/</span> show all shortcuts</p>
      <h2 id="keys-h" class="h-xl">Keyboard first.<br><span class="muted">Touch when you want it.</span></h2>
      <p class="lede">Desktop chords live on <kbd>⌃</kbd><kbd>⌥</kbd>, so <kbd>⌘</kbd> stays with your apps: <kbd>⌘</kbd><kbd>S</kbd> still saves in VS Code. Trackpad, mouse and touch all work too.</p>
    </header>
    <ul class="keygrid">{key_cards}</ul>
    <p class="fineprint">From the app's own key binding table. <a href="/manual/#keyboard">All {len(shortcuts)} shortcuts in the manual</a>.</p>
  </div>
</section>"""

    bars = [("Node.js", 12.0), ("TypeScript tsc", 5.4), ("Geometric mean", 4.8), ("vite build", 3.5)]
    bar_rows = "".join(
        f'<li{MEAN if label == "Geometric mean" else ""}><span>{esc(label)}</span>'
        f'<span class="bar" style="--w:{value / 12:.3f}" aria-hidden="true"></span><b>{value:g}×</b></li>'
        for label, value in bars
    )
    fast = f"""
<section class="sec sec-fast" id="fast" aria-labelledby="fast-h">
  <div class="wrap fast-grid">
    <div>
      <p class="kicker"><span aria-hidden="true">$</span> jit on <span class="tag">needs StikDebug</span></p>
      <h2 id="fast-h" class="h-xl">Fast mode.<br><span class="muted">Native ARM64, just in time.</span></h2>
      <p class="lede">iPadOS lets an app generate native code only while a debugger is attached. LinPad asks StikDebug to attach at launch, then runs Linux programs as native ARM64 code instead of interpreting them. Without it, everything still works, slower.</p>
      <p class="fineprint">Speed-up of the JIT over LinPad's interpreter, measured on an M4 Mac with the command-line build. Not measured on an iPad yet; device numbers come with v1.0.</p>
    </div>
    <div class="fast-num">
      <p class="mega" aria-label="About 4.8 times faster"><span class="grad">4.8×</span></p>
      <p class="mega-cap">faster on average, in our Mac benchmarks</p>
      <ul class="speed-bars" aria-label="Speed-up per workload">{bar_rows}</ul>
    </div>
  </div>
</section>"""

    safe = f"""
<section class="sec sec-safe" id="safety" aria-labelledby="safe-h">
  <div class="wrap">
    <header class="sec-head">
      <p class="kicker"><span aria-hidden="true">$</span> linpad backup --all</p>
      <h2 id="safe-h" class="h-xl">Never lose work.<br><span class="muted">Even when iPadOS gets impatient.</span></h2>
    </header>
    <ul class="bento">
      <li class="tile tile-wide"><div class="ico">{ICONS["box"]}</div><h3>Backups in one file.</h3><p>Your Linux home folders, the list of apps you installed and the desktop's settings, in a single file. See what it holds before you restore it, on this iPad or another one.</p></li>
      <li class="tile"><div class="ico">{ICONS["chip"]}</div><h3>Low-memory guard.</h3><p>When memory runs short, LinPad closes a Linux app itself, before iPadOS closes all of LinPad.</p></li>
      <li class="tile"><div class="ico">{ICONS["window"]}</div><h3>Your windows come back.</h3><p>If iPadOS closes LinPad in the background, your session reopens where it was.</p></li>
      <li class="tile"><div class="ico">{ICONS["wrench"]}</div><h3>Repair, not reinstall.</h3><p>A package upgrade broke something? Repair puts LinPad's own files back and leaves yours alone.</p></li>
      <li class="tile"><div class="ico">{ICONS["files"]}</div><h3>Updates keep your files.</h3><p>Linux system updates download in the background, are verified with SHA-256 and install at the next launch. <code>/root</code> and <code>/home</code> stay as they were.</p></li>
    </ul>
  </div>
</section>"""

    free = f"""
<section class="sec sec-free" id="open-source" aria-labelledby="free-h">
  <div class="wrap">
    <h2 id="free-h" class="display free-line">Free.<br><span class="grad">Open source.</span><br>GPLv3.</h2>
    <ul class="free-facts">
      <li><b>No price.</b> No subscription, no account, no paid tier.</li>
      <li><b>No tracking.</b> No analytics. LinPad talks to GitHub for updates and to package mirrors when you install something.</li>
      <li><b>No secrets.</b> Every line is on GitHub. A fork of iSH by way of iSH-ARM64, GPLv3 like them.</li>
    </ul>
    <div class="cta-row cta-left">
      <a class="btn btn-ghost" href="{GITHUB}">{ICONS["github"]} Read the source</a>
      <a class="btn btn-ghost" href="/contribute/">Contribute</a>
      <a class="btn btn-ghost" href="/support/">Sponsor</a>
    </div>
  </div>
</section>"""

    limits = """
<section class="sec sec-limits" id="limits" aria-labelledby="limits-h">
  <div class="wrap limits-grid">
    <header>
      <p class="kicker"><span aria-hidden="true">#</span> known issues</p>
      <h2 id="limits-h" class="h-lg">What LinPad is not, yet.</h2>
      <p class="muted">Straight answers, including the ones that are “not yet”. More in the <a href="/faq/">FAQ</a>.</p>
    </header>
    <ul class="limits-list">
      <li><b>Not on the App Store.</b> You sideload it with your own Apple ID. A free Apple ID needs a refresh every 7 days, which SideStore can do for you.</li>
      <li><b>Emulated, so heavy apps are slow.</b> Without fast mode everything runs on an interpreter. Heavy web pages can take many seconds.</li>
      <li><b>Memory is the ceiling.</b> VS Code alone wants about 2 GB. VS Code plus Firefox on an 8 GB iPad is the edge today.</li>
      <li><b>US keyboard layout in Linux apps</b> for now. Other layouts are next on the input backlog.</li>
      <li><b>No Docker, no Steam, no x86 games.</b> There are no namespaces or cgroups, and the GL path stops at 2.1.</li>
      <li><b>Not measured on an iPad yet.</b> Performance figures come from a Mac or the simulator and say so.</li>
    </ul>
  </div>
</section>"""

    install = f"""
<section class="sec sec-install" id="get" aria-labelledby="get-h">
  <div class="wrap">
    <div class="install-card">
      <p class="kicker"><span aria-hidden="true">$</span> v1.0 is being prepared</p>
      <h2 id="get-h" class="h-xl">Get LinPad.</h2>
      <p class="lede">For iPads with M1 or newer, on iPadOS 17 or later. When v1.0 ships: add the source to SideStore or AltStore, install, open. Until then, build it from source.</p>
      <div class="copy"><code id="source-url">{SOURCE_URL}</code><button class="btn btn-ghost btn-small" type="button" data-copy="source-url">Copy</button></div>
      <div class="cta-row cta-left">
        <a class="btn btn-primary" href="/install/">Read the install guide</a>
        <a class="btn btn-ghost" href="{GITHUB}/releases">Watch releases</a>
      </div>
    </div>
  </div>
</section>"""

    body = seq + statement + apps + themes_html + store + keyboard + fast + safe + free + limits + install
    json_ld = {
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        "name": "LinPad",
        "alternateName": ["LinPad OS", "Linux for iPad"],
        "description": "Linux for iPad: usermode Alpine Linux, a native SwiftUI desktop and real Linux apps as iPad windows. Free and open source.",
        "applicationCategory": "DeveloperApplication",
        "operatingSystem": "iPadOS 17 or later",
        "license": "https://www.gnu.org/licenses/gpl-3.0.html",
        "url": DOMAIN + "/",
        "image": DOMAIN + "/media/og.jpg",
        "codeRepository": GITHUB,
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
        "author": AUTHOR_LD,
    }
    head = (f'<script type="application/ld+json">{json.dumps(json_ld)}</script>'
            f'<link rel="preload" as="image" type="image/avif" imagesrcset="{srcset("desk", "avif")}" '
            f'imagesizes="(max-width: 700px) 92vw, (max-width: 1400px) 74vw, 1100px">')
    return page(path="/", title="LinPad: Linux for iPad. Smarter. And free.",
                description=f"LinPad runs real Linux apps on your iPad: Firefox, VS Code, GIMP and the rest of a {app_count}-app store, in native windows with a tiling desktop and themes. No VM, no jailbreak. Free and open source.",
                body=body, active="home", extra_head=head, body_class="home")


AUTHOR_LD = {"@type": "Person", "name": "Vali Neagu", "url": AUTHOR_SITE, "sameAs": [X_URL, AUTHOR_GITHUB]}

PALETTE_SAMPLE = """<span class="t2">root@linpad</span>:<span class="t4">~/projects</span># git status
On branch <span class="t5">main</span>
Changes not staged for commit:
  <span class="t1">modified:   src/app.ts</span>
  <span class="t3">new file:   themes/colors.toml</span>
<span class="t2">root@linpad</span>:<span class="t4">~/projects</span># ls ~
<span class="t4">Desktop  Documents  projects</span>  hello.py  notes.txt
<span class="t2">root@linpad</span>:<span class="t4">~/projects</span># btop <span class="t6">--theme</span> <span class="t5">current</span>
<span class="t2">root@linpad</span>:<span class="t4">~/projects</span># <span class="cur"></span>"""


def install_page() -> str:
    body = f"""
<div class="narrow page-head">
  <span class="kicker">Install</span>
  <h1>Install LinPad</h1>
  <p>LinPad is sideloaded: you install it with your own Apple ID. It is not on the App Store and does not need a jailbreak.</p>
</div>
<div class="narrow prose" style="padding-bottom:88px">
  <div class="callout info"><p><b>Status:</b> the first public release (v1.0) is being prepared. The source below starts listing LinPad when it is published on <a href="{GITHUB}/releases">GitHub Releases</a>. Until then you can build it from source.</p></div>

  <h2 id="requirements">Requirements</h2>
  <div class="table-wrap"><table>
    <tr><th scope="row">iPad</th><td>Apple Silicon (M1 or newer). Developed on an iPad Air with M3. 8 GB of memory is recommended for VS Code.</td></tr>
    <tr><th scope="row">iPadOS</th><td>17 or later.</td></tr>
    <tr><th scope="row">Storage</th><td>Several GB free: the Linux system unpacks to about 2.3 GB, and apps you add take more.</td></tr>
    <tr><th scope="row">Apple ID</th><td>Free or paid. A free Apple ID's apps expire after 7 days unless refreshed.</td></tr>
    <tr><th scope="row">Keyboard</th><td>Optional but recommended. Trackpad, mouse and touch all work.</td></tr>
  </table></div>

  <h2 id="sidestore">Option A: SideStore or AltStore</h2>
  <div class="steps">
    <div class="step"><h3>Set up your sideloader</h3><p>Install <a href="https://sidestore.io">SideStore</a> or <a href="https://altstore.io">AltStore</a> following their own guides.</p></div>
    <div class="step"><h3>Add the LinPad source</h3>
      <div class="copy"><code id="source-url">{SOURCE_URL}</code><button class="btn btn-ghost btn-small" type="button" data-copy="source-url">Copy</button></div>
      <p>In SideStore: Sources › Add, paste the URL.</p></div>
    <div class="step"><h3>Install LinPad</h3><p>Install it from the source. Updates appear in the sideloader, and LinPad also tells you about them in Settings › Updates.</p></div>
  </div>

  <h2 id="ipa">Option B: install the IPA</h2>
  <p>Each <a href="{GITHUB}/releases">release</a> has <code>LinPad-&lt;version&gt;.ipa</code>. Install it with <a href="https://github.com/nab138/iloader">iloader</a>, Sideloadly or Xcode, signed with your own Apple ID. Releases are not signed with the project's certificate on purpose.</p>

  <h2 id="first-launch">First launch</h2>
  <p>LinPad unpacks its Linux system once, then opens a short setup: pick a layout, a colour theme and a wallpaper, tick the optional apps you want, and try the keyboard shortcuts. At the end, "Show Me" opens a browser, a terminal and Files tiled side by side.</p>

  <h2 id="fast-mode">Fast mode (native JIT)</h2>
  <p>iPadOS only lets an app generate native code while a debugger is attached. LinPad asks <a href="https://github.com/StikDebug/StikDebug">StikDebug</a> to attach at launch, then runs Linux programs as native ARM64 code. Without it everything still works, more slowly, in compatibility mode.</p>
  <ol>
    <li>Install StikDebug and LocalDevVPN.</li>
    <li>Turn on Developer Mode on the iPad.</li>
    <li>Make a pairing file for the iPad on a computer (iloader can do it) and import it into StikDebug, following StikDebug's guide.</li>
    <li>Connect LocalDevVPN.</li>
    <li>In LinPad, open Settings › Fast Mode. It checks each step, has a button for each, and a "Test now" button.</li>
  </ol>
  <div class="callout"><p>LocalDevVPN uses the iPad's single VPN slot, so it conflicts with another VPN while connected. Fast mode has not been benchmarked on an iPad yet; the 4.8× figure is the geometric mean of our benchmarks on an M4 Mac.</p></div>

  <h2 id="updates">Updates and your files</h2>
  <ul>
    <li><b>Never delete the app to reinstall it.</b> Deleting LinPad deletes its Linux system and your files in it. Install the new version over the old one with the same Apple ID.</li>
    <li>Linux system updates download in the background, are verified with SHA-256, and install at the next launch. <code>/root</code>, <code>/home</code> and your packages are kept.</li>
    <li>If something breaks after a package upgrade, Settings › Maintenance › Repair puts LinPad's own files back.</li>
  </ul>

  <h2 id="source">Option C: build from source</h2>
  <p>You need a Mac with Xcode, Homebrew <code>llvm lld meson ninja libarchive</code>, and <code>libimobiledevice</code>.</p>
<pre><code>export PATH=/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/llvm/bin:$PATH

gpu/build-third-party.sh          # virglrenderer + MoltenVK (once)
release/build-rootfs.sh           # the Alpine system image (~50 min)

xcodebuild -project iSH.xcodeproj -target iSH-ARM64 -configuration Release -sdk iphoneos \\
  -allowProvisioningUpdates SYMROOT=$PWD/build-ios-release IPHONEOS_DEPLOYMENT_TARGET=17.0 \\
  DEVELOPMENT_TEAM=&lt;your team&gt; ISH_JIT_BUILD=enabled build

release/embed-rootfs.sh --device "build-ios-release/Release-iphoneos/iSH ARM64.app" \\
  release/out/ish-linux-rootfs-arm64.tar.gz
ideviceinstaller install "build-ios-release/Release-iphoneos/iSH ARM64.app"</code></pre>
  <p>The full guide is <a href="{GITHUB}/blob/main/release/INSTALL-DEVICE.md">release/INSTALL-DEVICE.md</a>.</p>
  <p class="callout info">Visual Studio Code and Claude Code are not part of LinPad's releases. They are downloaded on your iPad from Settings › Apps when you choose them.</p>
</div>
"""
    return page(path="/install/", title="Install", body=body, active="install",
                description="How to install LinPad on an iPad with SideStore, AltStore or an IPA, set up fast mode with StikDebug, and build from source.")


def themes_page(themes: list[dict]) -> str:
    palettes = [t for t in themes if t["id"] not in ERA_PALETTE_IDS]
    era_palettes = [t for t in themes if t["id"] in ERA_PALETTE_IDS]

    def palette_card(theme: dict, kind: str) -> str:
        ansi = theme.get("ansi") or []
        bg, fg = theme["background"], theme["foreground"]
        a = lambda i, fallback: ansi[i] if i < len(ansi) else fallback  # noqa: E731
        swatches = "".join(f'<span style="background:{esc(c)}"></span>' for c in (ansi[:8] or [bg, fg]))
        accent = theme.get("accent", fg)
        lines = [
            [(a(2, fg), "root@ipad"), (fg, ":"), (a(4, fg), "~/projects"), (fg, "$ git status")],
            [(fg, "On branch "), (accent, "main")],
            [(a(1, fg), "modified: src/app.ts")],
            [(a(3, fg), "warning"), (fg, " 2 files changed")],
            [(a(5, fg), "const"), (fg, " theme = "), (a(6, fg), f'"{theme["name"]}"')],
        ]
        texts = "".join(
            f'<text x="14" y="{24 + 22 * row}">'
            + "".join(f'<tspan fill="{esc(color)}">{esc(part)}</tspan>' for color, part in parts)
            + "</text>"
            for row, parts in enumerate(lines)
        )
        # SVG text: real palettes are shown as they are, low-contrast colours included.
        term = (
            f'<svg class="term" viewBox="0 0 300 130" role="img" aria-label="{esc(theme["name"])} terminal preview" '
            f'style="background:{esc(bg)}" font-family="ui-monospace, SF Mono, Menlo, monospace" font-size="12.5">'
            f"{texts}</svg>"
        )
        return (
            f'<article class="palette" data-kind="{kind} {theme["appearance"]}">'
            f"{term}"
            f'<div class="swatches" aria-hidden="true">{swatches}</div>'
            f'<div class="meta"><span><b>{esc(theme["name"])}</b> <span class="tag">{theme["appearance"]}</span></span>'
            f'<span class="actions"><a href="/themes/{theme["id"]}/colors.toml" download="colors.toml" aria-label="Download colors.toml for {esc(theme["name"])}">colors.toml</a></span></div>'
            "</article>"
        )

    era_cards = "".join(
        f'<figure class="shot" data-kind="era {"dark" if era_id in ("aero-night", "berry") else "light"}">'
        f'{picture("era-" + era_id, "(max-width: 620px) 100vw, (max-width: 980px) 50vw, 380px")}'
        f"<figcaption><b>{esc(name)}</b>{esc(text)}</figcaption></figure>"
        for era_id, name, text in ERA_LOOKS
    )
    body = f"""
<div class="wrap page-head">
  <span class="kicker">Themes</span>
  <h1>Theme gallery</h1>
  <p>Every look and palette that ships in LinPad. A colour theme recolours the desktop, the terminal, btop, GTK and Qt apps, VS Code and Firefox at once. Press <kbd>⌃⌥⇧Space</kbd> in LinPad to pick one, or <kbd>⌃⌥⇧C</kbd> to cycle.</p>
</div>
<div class="wrap" style="padding-bottom:88px">
  <div class="theme-filters" role="group" aria-label="Filter themes">
    <button type="button" data-filter="all" aria-pressed="true">All</button>
    <button type="button" data-filter="era" aria-pressed="false">Era looks</button>
    <button type="button" data-filter="palette" aria-pressed="false">Palettes</button>
    <button type="button" data-filter="dark" aria-pressed="false">Dark</button>
    <button type="button" data-filter="light" aria-pressed="false">Light</button>
  </div>

  <h2 id="looks">Desktop looks</h2>
  <p style="color:var(--muted);max-width:760px">A look sets the layout, window chrome, colours, wallpaper, fonts and the matching GTK theme together. Era looks are original recreations of a period's feel and use open-source GTK themes (B00merang, Chicago95) that download on first use; their Linux app theming is still being tested.</p>
  <div class="grid grid-3" style="margin-bottom:56px">{era_cards}</div>

  <h2 id="palettes">Colour palettes</h2>
  <p style="color:var(--muted);max-width:760px">{len(palettes)} palettes adapted from <a href="https://github.com/omacom/omarchy">Omarchy</a>'s community themes (MIT), plus {len(era_palettes)} that pair with the era looks. LinPad reads and writes the same <code>colors.toml</code> format, so the files below also work on Omarchy.</p>
  <div class="grid grid-4">{"".join(palette_card(t, "palette") for t in palettes)}{"".join(palette_card(t, "era") for t in era_palettes)}</div>

  <h2 id="community" style="margin-top:56px">Community themes</h2>
  <div class="split" style="align-items:start">
    <div>
      <p>LinPad can install a colour theme from a git repository in the Omarchy theme format: Themes › Install from URL, or a link like this one, which asks before doing anything:</p>
      <pre><code>linpad://theme/install?url=https://github.com/you/your-theme</code></pre>
      <p>A community gallery with previews rendered by LinPad will live here. Want your theme listed? See <a href="/contribute/#themes">submitting a theme</a>.</p>
    </div>
    <figure class="shot">{picture("theme-app", "(max-width: 900px) 100vw, 560px")}<figcaption><b>The Themes app</b>Looks, palettes, a theme editor and sharing, inside LinPad.</figcaption></figure>
  </div>
  <p style="color:var(--muted);font-size:.86rem;margin-top:32px">Palette credits: Tokyo Night (enkia), Catppuccin, Gruvbox Material (sainnhe), Nord (Arctic Ice Studio), Everforest (sainnhe), Kanagawa (rebelot), Rosé Pine, Flexoki (Steph Ango) and the Omarchy community, each under its own MIT licence. Omarchy is © David Heinemeier Hansson, MIT License. LinPad is not affiliated with Omarchy.</p>
</div>
"""
    return page(path="/themes/", title="Theme gallery", body=body, active="themes",
                description="Every desktop look and colour palette in LinPad: era looks, Omarchy-compatible palettes and colors.toml downloads.")


def manual_page(shortcuts: list[tuple[str, str, str]], catalog: list[dict]) -> str:
    groups: dict[str, list[tuple[str, str]]] = {}
    for group, title, keys in shortcuts:
        groups.setdefault(group, []).append((title, keys))
    tables = "".join(
        f"<h3>{esc(group)}</h3><div class=\"table-wrap\"><table><tr><th scope=\"col\">Action</th><th scope=\"col\">Keys</th></tr>"
        + "".join(f"<tr><td>{esc(t)}</td><td class=\"keys\"><kbd>{esc(k)}</kbd></td></tr>" for t, k in rows)
        + "</table></div>"
        for group, rows in groups.items()
    )
    packs = "".join(
        f"<tr><td>{esc(p.get('name') or p.get('title') or p.get('id'))}"
        f"{EXP if p.get('experimental') else ''}</td>"
        f"<td>{esc((p.get('summary') or p.get('description') or '').split('. ')[0].rstrip('.'))}.</td></tr>"
        for p in catalog
    )
    chapters = [
        ("start", "Getting started"), ("desktop", "The desktop"), ("keyboard", "Keyboard and trackpad"),
        ("tiling", "Tiling and workspaces"), ("themes", "Themes and looks"), ("apps", "Apps and packages"),
        ("files", "Files and iPad folders"), ("fast", "Fast mode"), ("updates", "Updates and repair"),
        ("dev", "Developer setup"), ("trouble", "Troubleshooting"),
    ]
    toc = "".join(f'<li><a href="#{cid}">{esc(name)}</a></li>' for cid, name in chapters)
    draft = ' <span class="tag">draft</span>'
    body = f"""
<div class="wrap page-head">
  <span class="kicker">Manual</span>
  <h1>The LinPad manual</h1>
  <p>How to use the desktop, the keyboard, themes, apps and fast mode. The shortcut tables are generated from the app's own key binding table, so they match the build.</p>
</div>
<div class="wrap doc">
  <nav class="toc" aria-label="Manual chapters"><ol>{toc}</ol></nav>
  <div class="prose">
    <h2 id="start">Getting started</h2>
    <p>Install LinPad with the <a href="/install/">install guide</a>. On first launch it unpacks its Linux system, then a setup walks you through a layout, a colour theme, a wallpaper, optional apps, fast mode and the keyboard.</p>
    <p>The desktop has a terminal, Files, Themes and Trash on it. <kbd>⌃⌥A</kbd> opens Applications, <kbd>⌃⌥T</kbd> a terminal, <kbd>⌘K</kbd> the command menu and <kbd>⌘/</kbd> every shortcut.</p>

    <h2 id="desktop">The desktop{draft}</h2>
    <p>Windows move by their title bar and resize from any edge. Drag a title bar to a screen edge to snap it to a half or a quarter. Double-tap a title bar to maximise. Touch and hold, or a two-finger click, opens a context menu anywhere: the desktop, Files, title bars, the taskbar and inside Linux apps.</p>
    <p>The panel holds quick settings (volume, brightness, appearance, layout, tiling, battery, network, fast mode), the notification centre with Do Not Disturb, and the lock screen.</p>

    <h2 id="keyboard">Keyboard and trackpad</h2>
    <p>Desktop shortcuts use <kbd>⌃⌥</kbd> (Control-Option), which neither iPadOS nor shells use much. <kbd>⌘</kbd> belongs to the focused app: <kbd>⌘S</kbd> saves, <kbd>⌘W</kbd> closes a tab in VS Code. iPadOS keeps <kbd>⌘Tab</kbd>, <kbd>⌘Space</kbd> and <kbd>⌘H</kbd>. You can move the general commands to <kbd>⌘</kbd> in Settings › Keyboard Shortcuts; this table shows the default.</p>
    {tables}
    <h3>Gestures</h3>
    <div class="table-wrap"><table>
      <tr><th scope="col">Gesture</th><th scope="col">Action</th></tr>
      <tr><td>Two-finger click</td><td>Right-click</td></tr>
      <tr><td>Three-finger swipe up</td><td>Overview</td></tr>
      <tr><td>Three-finger swipe sideways</td><td>Switch workspace</td></tr>
      <tr><td>Drag a title bar to an edge</td><td>Snap to a half or quarter</td></tr>
      <tr><td>Touch and hold</td><td>Context menu</td></tr>
    </table></div>
    <p>Linux apps currently receive a US keyboard layout regardless of the iPad's layout. Following the iPad's layout is planned.</p>

    <h2 id="tiling">Tiling and workspaces{draft}</h2>
    <p>Turn auto-tiling on per workspace with <kbd>⌃⌥⇧T</kbd>. Layouts: master-stack, columns, grid and monocle; cycle with <kbd>⌃⌥\\</kbd>. <kbd>⌃⌥H</kbd> <kbd>J</kbd> <kbd>K</kbd> <kbd>L</kbd> move focus, add <kbd>⇧</kbd> to move the tile. <kbd>⌃⌥F</kbd> floats a window. <kbd>⌃⌥⇧⌫</kbd> turns gaps, borders and rounding off.</p>
    <p>There are up to nine workspaces. The overview (<kbd>⌃⌥O</kbd>) shows them all; drag a window onto another workspace to move it.</p>

    <h2 id="themes">Themes and looks</h2>
    <p>A <b>look</b> sets layout, window chrome, colours, wallpaper and fonts together. A <b>colour theme</b> recolours the desktop and Linux apps. An <b>icon pack</b> is independent of both. See the <a href="/themes/">theme gallery</a>.</p>
    <ul>
      <li>Pick a colour theme: <kbd>⌃⌥⇧Space</kbd>. Next theme: <kbd>⌃⌥⇧C</kbd>. Next wallpaper: <kbd>⌃⌥⇧B</kbd>.</li>
      <li>Install a theme from a git URL in Omarchy's format, or open a <code>linpad://theme/install?url=…</code> link.</li>
      <li>Share your colour theme or your whole look from the Themes app as a link or a <code>colors.toml</code>.</li>
    </ul>
    <p>Linux apps that are already open keep their old GTK theme until restarted. A layout switch can take tens of seconds while caches rebuild.</p>

    <h2 id="apps">Apps and packages</h2>
    <p>The base system includes Firefox, the foot terminal, Thunar, Mousepad, Node 22, npm, git and Python. Everything else is a pack in Settings › Apps, or any Alpine package with <code>apk add</code> in a terminal or the Packages app.</p>
    <div class="table-wrap"><table><tr><th scope="col">Pack</th><th scope="col">What it adds</th></tr>{packs}</table></div>

    <h2 id="files">Files and iPad folders{draft}</h2>
    <p>Files is a Thunar-style file manager with Trash, Open With and Properties. The desktop is a real folder. Add iPad folders (iCloud Drive, On My iPad, other apps' folders) and they appear under <code>/mnt/ipad/&lt;name&gt;</code> in Linux. Press <kbd>Space</kbd> on a file for Quick Look. Drag and drop and the clipboard work between Linux apps, LinPad and other iPad apps.</p>

    <h2 id="fast">Fast mode</h2>
    <p>Fast mode runs Linux programs as native ARM64 code through a JIT. iPadOS allows that only while a debugger is attached, so LinPad hands off to StikDebug at launch. Setup is in the <a href="/install/#fast-mode">install guide</a>; Settings › Fast Mode checks each step and can test it. The splash screen and Quick Settings show whether the JIT is on.</p>

    <h2 id="updates">Updates and repair</h2>
    <ul>
      <li><b>App:</b> LinPad checks GitHub at launch and every 6 hours (never in Low Data Mode) and opens your sideloader to update.</li>
      <li><b>Linux system:</b> downloads in the background, verified with SHA-256, installed at the next launch. <code>/root</code>, <code>/home</code>, <code>/opt</code> and <code>/srv</code> are kept.</li>
      <li><b>Packages:</b> <code>apk upgrade</code> with one tap, with a weekly check.</li>
      <li><b>Repair:</b> Settings › Maintenance › Repair re-applies LinPad's own files, for example after an upgrade overwrote a patched package. Reset can keep your files.</li>
    </ul>

    <h2 id="dev">Developer setup{draft}</h2>
    <p>Node 22, npm, git and Python are in the base system. Visual Studio Code (Microsoft's build, about 900 MB) and Claude Code install from Settings › Apps. Developer extras adds a C/C++ toolchain, Go and Rust <span class="tag tag-exp">experimental</span>. A Vite demo project lives in <code>/root/projects/demo</code>.</p>
    <p>To be written: SSH keys and remotes, reaching a dev server from Safari, memory tips for VS Code.</p>

    <h2 id="trouble">Troubleshooting{draft}</h2>
    <ul>
      <li><b>LinPad closed by itself.</b> iPadOS closes apps that use too much memory. Close Firefox tabs or VS Code windows you do not need.</li>
      <li><b>An app looks broken after an upgrade.</b> Settings › Maintenance › Repair.</li>
      <li><b>Fast mode does not turn on.</b> Check LocalDevVPN is connected and StikDebug has a pairing file, then Settings › Fast Mode › Test now.</li>
      <li><b>The app expired.</b> Refresh it in SideStore, or reinstall the IPA over it. Do not delete it first.</li>
      <li>Still stuck? Ask in <a href="{DISCUSSIONS}">GitHub Discussions</a> or open an issue.</li>
    </ul>
  </div>
</div>
"""
    return page(path="/manual/", title="Manual", body=body, active="manual",
                description="The LinPad manual: desktop, keyboard shortcuts, tiling, themes, apps, iPad folders, fast mode, updates and troubleshooting.")


FAQ = [
    ("Is LinPad on the App Store?",
     "<p>No, and there are no plans to submit it. LinPad generates native code (the JIT) and downloads executable software, which App Store rules do not allow. It is sideloaded with your own Apple ID instead, like UTM and other developer tools.</p>"),
    ("Is this a virtual machine?",
     "<p>No. LinPad runs Linux programs directly inside one iPad app by translating their Linux system calls to iPadOS, building on iSH. There is no guest kernel and no hypervisor. That is why it works on iPadOS without special entitlements, and why some kernel features (namespaces, cgroups) are missing.</p>"),
    ("Do I need a jailbreak?", "<p>No. LinPad is a normal app that you sideload.</p>"),
    ("What is JIT and do I need it?",
     "<p>A JIT turns Linux programs into native ARM64 code as they run. iPadOS only allows that while a debugger is attached, so LinPad uses StikDebug for it. Without it, LinPad runs everything on an interpreter: it works, but it is several times slower. We measured about 4.8× on a Mac; iPad figures are not measured yet.</p>"),
    ("Which iPads work?",
     "<p>iPads with Apple Silicon, M1 or newer, on iPadOS 17 or later. It is developed on an iPad Air with M3. VS Code needs a lot of memory, so 8 GB or more is recommended for it.</p>"),
    ("What about battery life?",
     "<p>Not measured yet, and we would rather publish a real number than guess. Emulation costs more CPU than a native app, so expect heavy work (compiling, Firefox on big pages) to drain faster than native iPad apps. An idle desktop does little. We will publish device measurements with v1.0.</p>"),
    ("Is it safe?",
     "<p>LinPad runs inside the normal iPadOS app sandbox: Linux programs can only see LinPad's own files and the iPad folders you choose to add. Inside that sandbox you are root, so a Linux program you run can change your Linux system, as on any computer. System updates are verified with SHA-256, theme installs from git refuse executables, and the source is public. You sign the app yourself, so no third party's certificate is involved.</p><p>Found a security problem? Please report it privately through GitHub's security advisories rather than in a public issue.</p>"),
    ("Does LinPad collect data?",
     "<p>There is no analytics or tracking. LinPad contacts GitHub to check for updates (not in Low Data Mode), package mirrors when you install software, and services you use on purpose, such as the Wallhaven wallpaper browser.</p>"),
    ("Will I lose my files when I update?",
     "<p>Not if you update in place. App updates, Linux system updates and repairs keep <code>/root</code> and <code>/home</code>. Deleting the app deletes everything in it, so never delete LinPad to reinstall it.</p>"),
    ("My Apple ID is free. Is that a problem?",
     "<p>It works. Apps signed with a free Apple ID expire after 7 days and need a refresh, which SideStore can do in the background. Free accounts are also limited to a few sideloaded apps at once.</p>"),
    ("Can it run Windows apps or games?",
     "<p>Some Windows apps, experimentally: ARM64 builds of Notepad++, 7-Zip and PuTTY run in Wine. x86 programs run through Box64, slowly and with a large memory cost. Steam, Proton and modern games are not realistic: the GPU path does not support what they need.</p>"),
    ("Can I run Docker?",
     "<p>No. Docker needs Linux namespaces, cgroups and overlayfs, which a usermode Linux on iPadOS does not have. You can install any Alpine package directly instead.</p>"),
    ("Does my keyboard layout work?",
     "<p>In the native desktop, yes. Linux apps currently receive a US layout. Following the iPad's keyboard layout is high on the backlog.</p>"),
    ("Does it keep running in the background?",
     "<p>iPadOS suspends apps in the background, so long jobs like <code>npm install</code> pause when you switch away. A keep-alive option is being worked on.</p>"),
    ("How is this related to iSH?",
     "<p>LinPad is a fork of <a href=\"https://github.com/ish-app/ish\">iSH</a> by way of <a href=\"https://github.com/meikis/ish-arm64\">iSH-ARM64</a>, with a native ARM64 JIT, many kernel fixes, a Wayland bridge, a GPU path and a full desktop added. It is GPLv3 like iSH.</p>"),
]


def faq_page() -> str:
    items = "".join(f"<details><summary>{esc(q)}</summary><div>{a}</div></details>" for q, a in FAQ)
    json_ld = {
        "@context": "https://schema.org",
        "@type": "FAQPage",
        "mainEntity": [
            {"@type": "Question", "name": q,
             "acceptedAnswer": {"@type": "Answer", "text": re.sub(r"<[^>]+>", "", a)}}
            for q, a in FAQ
        ],
    }
    body = f"""
<div class="narrow page-head">
  <span class="kicker">FAQ</span>
  <h1>Questions people ask</h1>
  <p>Straight answers, including the ones that are "not yet".</p>
</div>
<div class="narrow" style="padding-bottom:88px">{items}
  <p style="margin-top:28px">Something missing? Ask in <a href="{DISCUSSIONS}">GitHub Discussions</a>.</p>
</div>
"""
    return page(path="/faq/", title="FAQ", body=body, active="faq",
                description="LinPad FAQ: App Store, JIT, battery, safety, privacy, Windows apps, Docker and keeping your files across updates.",
                extra_head=f'<script type="application/ld+json">{json.dumps(json_ld)}</script>')


SPONSOR_TIERS = [
    ("$5 / month", "Supporter", "Your name in the supporters list on this site and in the app's About screen."),
    ("$15 / month", "Backer", "The above, plus a monthly sponsors' dev log: what shipped, what broke, what is next."),
    ("$50 / month", "Patron", "The above, plus your name in the release notes and the credits of release videos."),
    ("$250 / month", "Company sponsor", "A small linked logo on this site and in the README."),
    ("$1,000 / month", "Lead sponsor", "A large logo at the top of the site and README, and thanks in every release post and video."),
]


def support_page() -> str:
    tiers = "".join(
        f'<article class="card"><h3>{esc(name)} <span class="tag">{esc(price)}</span></h3><p>{esc(text)}</p></article>'
        for price, name, text in SPONSOR_TIERS
    )
    body = f"""
<div class="narrow page-head">
  <span class="kicker">Support</span>
  <h1>Support the project</h1>
  <p>LinPad is built full-time by one developer. Sponsorship decides how fast it gets to a stable 1.0 and how many iPads it is tested on.</p>
</div>
<div class="narrow prose" style="padding-bottom:88px">
  <div class="callout info"><p>Sponsorship pages are being set up. The links below go live when they are approved; until then, starring the repo and sharing LinPad help most.</p></div>

  <h2 id="where">Where the money goes</h2>
  <ul>
    <li><b>Test devices.</b> LinPad is developed on one iPad Air M3. It needs an 8 GB and a 16 GB iPad Pro, an M1 and an M2 iPad to test memory limits, the JIT and the GPU path.</li>
    <li><b>Apple developer account</b> ($99 a year) for longer-lived test builds and the increased-memory entitlement.</li>
    <li><b>Time.</b> Device verification, memory safety, keyboard layouts, backups, documentation and releases.</li>
    <li><b>Upstream.</b> A share for the projects LinPad stands on, such as iSH and StikDebug, once there is something to share.</li>
  </ul>
  <p>Income and spending will be published, through Open Collective once it is set up.</p>

  <h2 id="ways">Ways to give</h2>
  <div class="grid grid-2">
    <article class="card"><h3>GitHub Sponsors <span class="tag">coming soon</span></h3><p>Monthly or one-time, from your GitHub account.</p><p style="margin-top:12px"><a href="{SPONSORS_URL}">github.com/sponsors/fspecii</a></p></article>
    <article class="card"><h3>Open Collective <span class="tag">coming soon</span></h3><p>For companies that need invoices, and transparent spending.</p><p style="margin-top:12px"><a href="{OPENCOLLECTIVE_URL}">opencollective.com/linpad</a></p></article>
  </div>

  <h2 id="tiers">Planned tiers</h2>
  <div class="grid">{tiers}</div>
  <p style="margin-top:14px;color:var(--muted)">One-time gifts will be welcome too. Sponsorships are unrestricted donations: they do not buy roadmap decisions or support time, and LinPad stays free for everyone.</p>

  <h2 id="hardware">Hardware and company sponsors</h2>
  <p>If you make iPad keyboards, cases, docks or developer tools, a loaned device or a sponsorship of a release is the most direct help. Your logo appears only after an agreement, and LinPad does not endorse products in its software.</p>
  <p>Contact: a direct message to <a href="{X_URL}">@AmbsdOP on X</a>.</p>

  <h2 id="sponsors">Sponsors</h2>
  <p style="color:var(--muted)">No sponsors yet. Yours could be the first name here.</p>

  <h2 id="free">Free ways to help</h2>
  <ul>
    <li>Star <a href="{GITHUB}">the repository</a>.</li>
    <li>Test a release on your iPad and report what breaks.</li>
    <li>Make a theme, write a manual page, or record a video of your setup.</li>
  </ul>
</div>
"""
    return page(path="/support/", title="Support the project", body=body, active="support",
                description="Support LinPad through GitHub Sponsors or Open Collective. What sponsorship pays for: test iPads, the Apple developer account and development time.")


def contribute_page() -> str:
    areas = "".join(card for card in [
        feature_card("chip", "Emulator and JIT", "C and ARM64 assembly: syscalls, signals, memory, the native JIT. <code>kernel/</code>, <code>jit/</code>, <code>emu/</code>, <code>asbestos/</code>."),
        feature_card("window", "Wayland bridge", "C: ishwl, the in-guest compositor, input, text input, clipboard. <code>wl-bridge/</code>."),
        feature_card("tile", "Desktop (SwiftUI)", "Window manager, tiling, styles, command menu, apps. <code>desktop/DesktopKit</code>, with unit tests that run in the simulator."),
        feature_card("palette", "Themes and icons", "Colour palettes, era looks, icon packs. The easiest first contribution. <code>themes/</code>."),
        feature_card("box", "Linux system and releases", "The Alpine rootfs, the app catalog, repair kit and release scripts. <code>release/</code>."),
        feature_card("files", "Docs and testing", "Manual pages, device test reports, translations. A physical iPad helps here more than anywhere."),
    ])
    body = f"""
<div class="wrap page-head">
  <span class="kicker">Contribute</span>
  <h1>Help build LinPad</h1>
  <p>Most of LinPad can be worked on without an iPad: the desktop runs in the iPad simulator and the emulator builds as a command-line tool on a Mac.</p>
  <div class="cta-row" style="justify-content:flex-start;margin-top:22px">
    <a class="btn btn-primary" href="{GOOD_FIRST}">Good first issues</a>
    <a class="btn btn-ghost" href="{DISCUSSIONS}">Discussions</a>
    <a class="btn btn-ghost" href="{CHAT_URL}">Chat (coming soon)</a>
  </div>
</div>
<div class="wrap" style="padding-bottom:88px">
  <h2 style="margin-top:40px">Areas</h2>
  <div class="grid grid-3">{areas}</div>

  <div class="narrow prose" style="margin:56px 0 0;width:auto;max-width:780px">
    <h2 id="first">Your first 30 minutes</h2>
    <ol>
      <li>Fork and clone <a href="{GITHUB}">fspecii/LinPad</a>.</li>
      <li>Open <code>desktop/DesktopKit</code> and run its tests in an iPad simulator. No Apple developer account is needed.</li>
      <li>Read the design notes for the part you care about: <code>jit/DESIGN.md</code>, <code>wl-bridge/DESIGN.md</code>, <code>gpu/DESIGN.md</code>, <code>themes/omarchy/PORT-SPEC.md</code>, <code>release/RELEASING.md</code>.</li>
      <li>Pick an issue labelled <code>good first issue</code> and say in the issue that you are on it.</li>
    </ol>
    <p>Issues labelled <code>needs-device</code> need someone with an iPad to run something and report back. That is a real contribution, not a lesser one.</p>

    <h2 id="themes">Submitting a theme</h2>
    <ol>
      <li>Make a colour theme in LinPad's Themes app, or write a <code>colors.toml</code> by hand. The format is the same one Omarchy community themes use.</li>
      <li>Put it in a public git repository with a licence and a screenshot you made yourself.</li>
      <li>Check it installs: Themes › Install from URL.</li>
      <li>Open a pull request adding it to the community list. It will appear in the <a href="/themes/">gallery</a> with an install link.</li>
    </ol>
    <p>Please do not submit wallpapers or artwork you do not have the rights to, or themes named after commercial products.</p>

    <h2 id="rules">Ground rules</h2>
    <ul>
      <li>Be kind and specific. Harassment is not tolerated.</li>
      <li>Small pull requests with a clear reason get merged fastest.</li>
      <li>Performance claims need a measurement and say where it was measured.</li>
      <li>By contributing you agree your work is licensed under the GPLv3, like the rest of LinPad.</li>
    </ul>
    <p>Every release lists the people who contributed to it.</p>
  </div>
</div>
"""
    return page(path="/contribute/", title="Contribute", body=body, active="contribute",
                description="Contribute to LinPad: good first issues, areas (emulator, Wayland bridge, SwiftUI desktop, themes, docs), first steps without an iPad, and theme submission.")


PRESS_SHORT = "LinPad is a free, open-source app that runs a real Linux desktop on M-series iPads, with Firefox, VS Code and tiling windows, without a VM or a jailbreak."
PRESS_LONG = ("LinPad turns an M-series iPad into a Linux workstation. It runs unmodified ARM64 Alpine Linux programs inside a single iPad app "
              "by translating their system calls to iPadOS, building on the open-source iSH project. Linux apps such as Firefox, Visual Studio Code, "
              "Thunar and VLC appear as native windows in a SwiftUI desktop with tiling, workspaces, a command menu and themes compatible with Omarchy's "
              "community palettes. An optional native ARM64 JIT, enabled through StikDebug, makes it several times faster, and an experimental GPU path "
              "maps Linux Vulkan onto Metal. LinPad is sideloaded rather than distributed through the App Store, is licensed under the GPLv3, "
              "and is developed by Vali Neagu, a London-based developer.")


def press_page() -> str:
    downloads = "".join(
        f'<li><a href="/media/press/linpad-{key}.jpg" download>linpad-{key}.jpg</a></li>'
        for key in PRESS_SHOTS
    )
    body = f"""
<div class="narrow page-head">
  <span class="kicker">Press</span>
  <h1>Press kit</h1>
  <p>Descriptions, facts, a logo and screenshots you may use when writing about LinPad.</p>
</div>
<div class="narrow prose" style="padding-bottom:88px">
  <h2 id="short">In one sentence</h2>
  <p class="callout info">{esc(PRESS_SHORT)}</p>
  <h2 id="long">In one paragraph</h2>
  <p class="callout info">{esc(PRESS_LONG)}</p>

  <h2 id="facts">Facts</h2>
  <div class="table-wrap"><table>
    <tr><th scope="row">Name</th><td>LinPad (subtitle: Linux for iPad)</td></tr>
    <tr><th scope="row">Status</th><td>Pre-release; first public version in preparation</td></tr>
    <tr><th scope="row">Platform</th><td>iPadOS 17+, iPads with M1 or newer</td></tr>
    <tr><th scope="row">Distribution</th><td>Sideloaded (SideStore, AltStore, IPA). Not on the App Store.</td></tr>
    <tr><th scope="row">Licence</th><td>GNU GPLv3</td></tr>
    <tr><th scope="row">Based on</th><td>iSH and iSH-ARM64</td></tr>
    <tr><th scope="row">Linux</th><td>Alpine Linux 3.21, aarch64</td></tr>
    <tr><th scope="row">Source</th><td><a href="{GITHUB}">{GITHUB.replace("https://", "")}</a></td></tr>
    <tr><th scope="row">Website</th><td>linpados.com</td></tr>
    <tr><th scope="row">Developer</th><td>Vali Neagu, London (<a href="{AUTHOR_SITE}">valineagu.com</a>, <a href="{X_URL}">@AmbsdOP</a>, <a href="{AUTHOR_GITHUB}">GitHub</a>, <a href="{YOUTUBE}">YouTube</a>)</td></tr>
  </table></div>
  <p>Performance figures published so far were measured on a Mac or in the iPad simulator. Please do not quote them as iPad results; device measurements will be added here.</p>

  <h2 id="logo">Logo</h2>
  <div class="split" style="grid-template-columns:auto 1fr;align-items:center">
    <img src="/favicon.svg" alt="The LinPad logo: a tablet outline with a terminal prompt and two tiled windows" width="120" height="120" loading="lazy">
    <ul><li><a href="/favicon.svg" download="linpad-logo.svg">linpad-logo.svg</a></li><li><a href="/media/press/linpad-logo-512.png" download>linpad-logo-512.png</a></li></ul>
  </div>
  <p>Please do not combine the logo with Apple, Linux (Tux) or other companies' marks.</p>

  <h2 id="shots">Screenshots</h2>
  <ul>{downloads}</ul>
  <p>Screenshots come from development builds in the iPad simulator. Device photos and a demo video will follow.</p>

  <h2 id="contact">Contact</h2>
  <p>Direct message <a href="{X_URL}">@AmbsdOP on X</a>. A press email address will be added here.</p>
</div>
"""
    return page(path="/press/", title="Press kit", body=body, active="press",
                description="LinPad press kit: one-sentence and one-paragraph descriptions, facts, logo and screenshots.")


def not_found_page() -> str:
    body = """
<div class="narrow page-head" style="padding-bottom:120px">
  <span class="kicker">404</span>
  <h1>No such page</h1>
  <p><code>ls: cannot access: No such file or directory</code></p>
  <p><a class="btn btn-primary" href="/">Back home</a></p>
</div>
"""
    return page(path="/404.html", title="Page not found", body=body, active="",
                description="This page does not exist on linpados.com.")


# ---------------------------------------------------------------- output


def minify_css(css: str) -> str:
    """Comments and layout whitespace only; spaces inside values (calc, grid lines) are kept."""
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    css = re.sub(r"\s+", " ", css)
    css = re.sub(r"\s*([{};,>])\s*", r"\1", css)
    css = re.sub(r":\s+", ":", css)
    return css.replace(";}", "}").strip() + "\n"


def write(rel: str, text: str) -> None:
    target = DIST / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)


def build() -> None:
    global MANIFEST, ASSET_VERSION
    MANIFEST = manifest()
    themes = load_themes()
    shortcuts = parse_shortcuts()
    catalog = load_catalog()

    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir()
    shutil.copytree(SRC / "assets", DIST / "assets")
    (DIST / "assets/site.css").write_text(minify_css((SRC / "assets/site.css").read_text()))
    shutil.copytree(MEDIA, DIST / "media", ignore=shutil.ignore_patterns("manifest.json"))
    shutil.copytree(FONTS, DIST / "fonts")
    shutil.copy(SRC / "assets/logo.svg", DIST / "favicon.svg")
    for static in (SRC / "static").glob("*") if (SRC / "static").exists() else []:
        shutil.copy(static, DIST / static.name)

    import hashlib
    ASSET_VERSION = hashlib.sha256(
        (SRC / "assets/site.css").read_bytes() + (SRC / "assets/site.js").read_bytes()
    ).hexdigest()[:10]

    pages = {
        "index.html": home(themes, shortcuts),
        "install/index.html": install_page(),
        "themes/index.html": themes_page(themes),
        "manual/index.html": manual_page(shortcuts, catalog),
        "faq/index.html": faq_page(),
        "support/index.html": support_page(),
        "contribute/index.html": contribute_page(),
        "press/index.html": press_page(),
        "404.html": not_found_page(),
    }
    for rel, text in pages.items():
        write(rel, text)
    for theme in themes:
        write(f"themes/{theme['id']}/colors.toml", colors_toml(theme))

    urls = [p for p in pages if p != "404.html"]
    today = date.today().isoformat()
    sitemap = "".join(
        f"<url><loc>{DOMAIN}/{p.removesuffix('index.html')}</loc><lastmod>{today}</lastmod></url>" for p in urls
    )
    write("sitemap.xml", f'<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">{sitemap}</urlset>\n')
    write("robots.txt", f"User-agent: *\nAllow: /\nSitemap: {DOMAIN}/sitemap.xml\n")
    write("data/keybindings.json", json.dumps([{"group": g, "action": t, "keys": k} for g, t, k in shortcuts], ensure_ascii=False, indent=1) + "\n")

    total = sum(f.stat().st_size for f in DIST.rglob("*") if f.is_file())
    print(f"built {len(pages)} pages, {len(themes)} themes, {len(shortcuts)} shortcuts into {DIST} ({total / 1e6:.1f} MB)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--refresh-media", action="store_true", help="re-encode screenshots into site/src/media")
    args = parser.parse_args()
    if args.refresh_media:
        refresh_media()
    build()


if __name__ == "__main__":
    main()
