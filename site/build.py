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
STUDIO = "https://webdesignstudio.london"
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

ONBOARDING = REPO / "build-sim-onboarding/shots"
SCREENSHOTS = REPO / "docs/screenshots"
THEME_SHOTS = IPAD_JIT / "theme-shots"
ICON_SHOTS = IPAD_JIT / "icon-shots"


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
    MEDIA_SET.append(Shot(f"era-{era_id}", THEME_SHOTS / f"{era_id}-desktop.png", (480, 960),
                          f"The {era_name} desktop look in LinPad"))

ERA_PALETTE_IDS = {"luna", "aero", "aero-night", "aqua", "berry", "classic-98", "dot-matrix", "dot-matrix-dark", "platinum"}
SHOT_BY_KEY = {shot.key: shot for shot in MEDIA_SET}


def esc(text: str) -> str:
    return html.escape(text, quote=True)


# ---------------------------------------------------------------- media


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)


def refresh_media() -> None:
    MEDIA.mkdir(parents=True, exist_ok=True)
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
    for key in ("hero", "firefox", "vscode", "fastfetch", "tiler", "theme-app"):
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
    hero = SHOT_BY_KEY["hero"].source.as_uri()
    og_logo = logo.replace("<svg ", '<svg width="76" height="76" ', 1)
    og_png = MEDIA / "og.png"
    chrome_shot(f"""<!doctype html><meta charset="utf-8"><style>
html,body{{margin:0;width:1200px;height:630px;overflow:hidden;background:#0a0c10;color:#e6e9ef;
font-family:-apple-system,"SF Pro Display","Helvetica Neue",sans-serif}}
.glow{{position:absolute;inset:0;background:radial-gradient(520px 320px at 20% 30%,rgba(74,163,255,.22),transparent 70%),
radial-gradient(520px 320px at 85% 70%,rgba(139,123,255,.22),transparent 70%)}}
.copy{{position:absolute;left:64px;top:64px;width:470px}}
.brand{{display:flex;align-items:center;gap:18px;font-size:44px;font-weight:700;letter-spacing:-.02em}}
.brand small{{display:block;font-size:22px;font-weight:500;color:#a1aab8;letter-spacing:0}}
h1{{font-size:60px;line-height:1.04;letter-spacing:-.035em;margin:70px 0 22px;font-weight:760}}
h1 span{{background:linear-gradient(100deg,#4aa3ff,#8b7bff);-webkit-background-clip:text;color:transparent}}
p{{font:500 24px/1.4 ui-monospace,"SF Mono",Menlo,monospace;color:#a1aab8;margin:0}}
.device{{position:absolute;left:560px;top:96px;width:720px;padding:12px;border-radius:30px;
background:linear-gradient(160deg,#2a2f3a,#0d0f14);border:1px solid #333a47;box-shadow:0 30px 80px rgba(0,0,0,.6)}}
.device img{{display:block;width:100%;border-radius:18px}}
</style><div class="glow"></div>
<div class="copy"><div class="brand">{og_logo}<div>LinPad<small>Linux for iPad</small></div></div>
<h1>A real Linux desktop <span>on your iPad.</span></h1><p>No VM. No jailbreak. GPLv3.</p></div>
<div class="device"><img src="{hero}"></div>""", og_png, 1200, 630)
    run(["magick", str(og_png), "-strip", "-quality", "84", str(MEDIA / "og.jpg")])
    og_png.unlink()


def manifest() -> dict:
    path = MEDIA / "manifest.json"
    if not path.exists():
        sys.exit("site/src/media is empty: run with --refresh-media once")
    return json.loads(path.read_text())


MANIFEST: dict = {}


def picture(key: str, sizes_attr: str, *, eager: bool = False, alt: str | None = None, cls: str = "") -> str:
    entry = MANIFEST[key]
    sizes = entry["sizes"]
    largest_w, largest_h = sizes[-1]
    fallback_w = sizes[min(1, len(sizes) - 1)][0]

    def srcset(ext: str) -> str:
        return ", ".join(f"/media/{key}-{w}.{ext} {w}w" for w, _ in sizes)

    loading = 'fetchpriority="high" decoding="async"' if eager else 'loading="lazy" decoding="async"'
    alt_text = esc(alt if alt is not None else SHOT_BY_KEY[key].alt)
    cls_attr = f' class="{cls}"' if cls else ""
    return (
        f"<picture{cls_attr}>"
        f'<source type="image/avif" srcset="{srcset("avif")}" sizes="{sizes_attr}">'
        f'<source type="image/webp" srcset="{srcset("webp")}" sizes="{sizes_attr}">'
        f'<img src="/media/{key}-{fallback_w}.webp" alt="{alt_text}" width="{largest_w}" height="{largest_h}" {loading}>'
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
        label = default_branch(match["label"]).strip('"').replace("\\u{FE0E}", "")
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
    ("/#features", "Features", "home"),
    ("/install/", "Install", "install"),
    ("/themes/", "Themes", "themes"),
    ("/manual/", "Manual", "manual"),
    ("/faq/", "FAQ", "faq"),
    ("/contribute/", "Contribute", "contribute"),
    ("/support/", "Support", "support"),
]

THEME_BOOT = ("<script>try{var t=localStorage.getItem('linpad-theme');"
              "if(t==='light'||t==='dark')document.documentElement.dataset.theme=t}catch(e){}</script>")


def page(*, path: str, title: str, description: str, body: str, active: str, og_image: str = "/media/og.jpg",
         extra_head: str = "") -> str:
    canonical = DOMAIN + path
    full_title = title if title.startswith("LinPad") else f"{title} · LinPad"
    current = ' aria-current="page"'
    nav_links = "".join(
        f'<a href="{href}"{current if key == active and key != "home" else ""}>{label}</a>'
        for href, label, key in NAV
    )
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(full_title)}</title>
<meta name="description" content="{esc(description)}">
<link rel="canonical" href="{canonical}">
<meta name="theme-color" content="#0a0c10" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#fbfbfd" media="(prefers-color-scheme: light)">
<meta property="og:type" content="website">
<meta property="og:site_name" content="LinPad">
<meta property="og:title" content="{esc(full_title)}">
<meta property="og:description" content="{esc(description)}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="{DOMAIN}{og_image}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="LinPad: a real Linux desktop on your iPad">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:site" content="@AmbsdOP">
<meta name="twitter:creator" content="@AmbsdOP">
<meta name="twitter:title" content="{esc(full_title)}">
<meta name="twitter:description" content="{esc(description)}">
<meta name="twitter:image" content="{DOMAIN}{og_image}">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="icon" href="/media/favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="/media/apple-touch-icon.png">
<link rel="stylesheet" href="/assets/site.css?v={ASSET_VERSION}">
{THEME_BOOT}
{extra_head}
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="site-header">
  <nav class="wrap nav" aria-label="Main">
    <a class="brand" href="/"><img src="/favicon.svg" alt="" width="30" height="30">LinPad <small>Linux for iPad</small></a>
    <div class="nav-links" id="nav-links">{nav_links}</div>
    <div class="nav-tools">
      <a class="icon-btn" href="{GITHUB}" aria-label="LinPad on GitHub">{ICONS["github"]}</a>
      <button class="icon-btn" id="theme-toggle" type="button" aria-label="Switch colour theme">{ICONS["sun"]}</button>
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
    <div class="foot-grid">
      <div>
        <a class="brand" href="/"><img src="/favicon.svg" alt="" width="30" height="30" loading="lazy">LinPad</a>
        <p style="margin-top:12px">A real Linux desktop on your iPad. Free and open source under the GPLv3.</p>
        <p>Built by Vali in London.</p>
      </div>
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
          <li><a href="{GITHUB}">GitHub</a></li>
        </ul>
      </div>
      <div>
        <h2>Follow</h2>
        <ul>
          <li><a href="{YOUTUBE}">YouTube</a></li>
          <li><a href="{X_URL}">X @AmbsdOP</a></li>
          <li><a href="{STUDIO}">Web Design Studio London</a></li>
        </ul>
      </div>
    </div>
    <div class="legal">
      <p>© {year} Vali and LinPad contributors. LinPad is licensed under the GNU GPLv3 and builds on <a href="https://github.com/ish-app/ish">iSH</a> and <a href="https://github.com/meikis/ish-arm64">iSH-ARM64</a>.</p>
      <p>iPad and iPadOS are trademarks of Apple Inc., registered in the U.S. and other countries. Linux® is the registered trademark of Linus Torvalds in the U.S. and other countries. Firefox is a trademark of the Mozilla Foundation. Visual Studio Code is a product of Microsoft. All other names belong to their owners. LinPad is an independent project and is not affiliated with or endorsed by any of them.</p>
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


def home(themes: list[dict]) -> str:
    if HERO_VIDEO:
        hero_media = (f'<video src="/{HERO_VIDEO}" autoplay muted loop playsinline preload="metadata" '
                      f'poster="/media/hero-1280.webp" aria-label="{esc(SHOT_BY_KEY["hero"].alt)}"></video>')
    else:
        hero_media = picture("hero", "(max-width: 1100px) 100vw, 1080px", eager=True)

    palettes = [t for t in themes if t["id"] not in ERA_PALETTE_IDS]
    features = "".join([
        feature_card("window", "A native desktop",
                     "Windows you move, resize from any edge, snap, minimise and pin on top. Workspaces, an overview, a window switcher, a notification centre and a lock screen. Written in SwiftUI, so it feels like an iPad app, because it is one."),
        feature_card("tile", "Tiling when you want it",
                     "Master-stack, columns, grid and monocle layouts, on or off per workspace. Float any window. Gaps, borders and rounding per theme, or turn them all off with one chord."),
        feature_card("cmd", "⌘K for everything",
                     "One fuzzy menu for windows, apps, commands, toggles, themes and looks, plus repair and reset. ⌘/ shows every shortcut. Desktop chords live on ⌃⌥ so ⌘ stays with your apps."),
        feature_card("palette", "Themes that reach the apps",
                     f"{len(palettes)} colour palettes from the Omarchy community plus era looks. A theme recolours the shell, the terminal, btop, GTK and Qt apps, VS Code and Firefox together."),
        feature_card("term", "Real Linux apps",
                     "Firefox, Visual Studio Code (Microsoft's build, downloaded on your iPad when you ask for it), Thunar, Mousepad, VLC and GIMP. Unmodified aarch64 Alpine Linux binaries with the full <code>apk</code> archive behind them."),
        feature_card("box", "A catalog, not bloat",
                     "The base system stays lean. Mail, PDF, office, image tools, media, extra browsers and developer toolchains are packs you tick in Settings › Apps."),
        feature_card("bolt", "Fast mode", "Hands off to StikDebug at launch and comes back with a native ARM64 JIT. About 4.8× faster than the interpreter in our Mac benchmarks; iPad numbers will be published once measured.", NEEDS),
        feature_card("chip", "GPU path", "Linux Vulkan through Mesa Venus, a virtio-gpu device, virglrenderer and MoltenVK onto Metal. OpenGL through zink tops out at GL 2.1 today.", EXP),
        feature_card("wine", "Windows apps via Wine", "ARM64 Windows programs like Notepad++, 7-Zip and PuTTY run in Wine 10. x86 programs work through Box64, slowly and with a big memory cost. Not for games.", EXP),
        feature_card("files", "Plays well with iPadOS",
                     "Clipboard and drag and drop both ways, iPad folders mounted into Linux, Quick Look on Space, text input for every language including CJK composition, and Linux audio through iOS."),
        feature_card("wrench", "Repair and updates",
                     "App updates through your sideloader. Linux system updates download in the background, are SHA-256 verified and keep /root and /home. Repair re-applies LinPad's files when a package upgrade breaks something."),
        feature_card("camera", "Made to be shown",
                     "Screenshots of the screen, an area or a window, and screen recording, all from the keyboard. Share a theme or a whole look as a <code>linpad://</code> link."),
    ])

    eras = "".join(
        f'<figure class="shot">{picture("era-" + era_id, "(max-width: 620px) 100vw, (max-width: 980px) 50vw, 280px")}'
        f"<figcaption><b>{esc(name)}</b>{esc(text)}</figcaption></figure>"
        for era_id, name, text in ERA_LOOKS[:4]
    )

    body = f"""
<section class="hero">
  <div class="wrap">
    <div class="eyebrow"><span class="pill"><span class="dot" aria-hidden="true"></span>Pre-release</span><span class="pill">Free and open source · GPLv3</span><span class="pill">iPad with M1 or newer</span></div>
    <h1>A real Linux desktop<br><span>on your iPad.</span></h1>
    <p class="lede">Firefox, VS Code, a tiling window manager and the whole Alpine Linux package archive, running on the iPad itself. No VM. No jailbreak. One app.</p>
    <div class="cta-row">
      <a class="btn btn-primary" href="/install/">Install guide</a>
      <a class="btn btn-ghost" href="{GITHUB}">{ICONS["github"]} Star on GitHub</a>
    </div>
    <p class="hero-note">The first public build is being prepared. Screenshots are from development builds in the iPad simulator.</p>
    <figure class="device">
      {hero_media}
      <figcaption>Firefox, a terminal and Files, tiled side by side. Demo video coming with v1.0.</figcaption>
    </figure>
  </div>
</section>

<section aria-labelledby="apps-h" style="padding-top:24px">
  <div class="wrap">
    <h2 id="apps-h" class="visually-hidden">Apps that run on LinPad</h2>
    <div class="marquee">
      <span>firefox</span><span>code</span><span>thunar</span><span>foot</span><span>node 22</span><span>git</span><span>python3</span><span>vite</span><span>vlc</span><span>gimp</span><span>btop</span><span>claude</span><span>apk add …</span>
    </div>
  </div>
</section>

<section id="how" aria-labelledby="how-h">
  <div class="wrap">
    <div class="section-head">
      <span class="kicker">How it works</span>
      <h2 id="how-h">Linux programs, iPad windows. One process.</h2>
      <p>LinPad is a single iPad app. It runs real ARM64 Linux binaries by translating their system calls to iPadOS, and it shows their windows as native windows next to its own.</p>
    </div>
    <div class="stack">
      <div class="layers" role="img" aria-label="Architecture: Linux apps talk to a Wayland compositor, a GPU driver and PulseAudio inside Alpine Linux; the LinPad app bridges those to native windows, Metal and iOS audio, all on top of the iSH-ARM64 syscall translator.">
        <div class="layer guest"><b>Alpine Linux, aarch64</b><span>firefox · code · thunar · foot · node · git</span></div>
        <div class="layer-row">
          <div class="layer guest"><b>ishwl</b><span>Wayland compositor</span></div>
          <div class="layer guest"><b>Mesa Venus</b><span>Vulkan driver</span></div>
          <div class="layer guest"><b>PulseAudio</b><span>sound</span></div>
        </div>
        <div class="arrow" aria-hidden="true">↓ shared memory · FIFOs · virtio-gpu ↓</div>
        <div class="layer-row">
          <div class="layer bridge"><b>Window bridge</b><span>frames · input · IME · clipboard</span></div>
          <div class="layer bridge"><b>virglrenderer</b><span>MoltenVK → Metal</span></div>
          <div class="layer bridge"><b>Audio bridge</b><span>AVAudioEngine</span></div>
        </div>
        <div class="layer host"><b>DesktopKit</b><span>SwiftUI desktop · one window manager for native and Linux windows</span></div>
        <div class="layer host"><b>iSH-ARM64</b><span>Linux syscalls → iPadOS · threaded interpreter · native ARM64 JIT</span></div>
      </div>
      <div class="how-list">
        <div><h3>Usermode Linux, not a VM</h3><p>A fork of iSH and iSH-ARM64 runs unmodified aarch64 programs and implements the Linux kernel interface they expect: processes, signals, sockets, futexes, memfd, inotify, netlink.</p></div>
        <div><h3>A Wayland bridge</h3><p>ishwl is a small Wayland compositor inside Linux. Each window's pixels are shared through memory-mapped files and handed to the native desktop, which sends input, text and clipboard back.</p></div>
        <div><h3>A native desktop</h3><p>DesktopKit is a SwiftUI shell with one window manager for native apps and Linux windows: tiling, workspaces, overview, themes and the command menu.</p></div>
        <div><h3>A GPU path <span class="tag tag-exp">experimental</span></h3><p>A virtio-gpu device feeds virglrenderer's Venus renderer, which runs on MoltenVK and Metal. Firefox still renders in software.</p></div>
      </div>
    </div>
  </div>
</section>

<section id="features" class="alt" aria-labelledby="features-h">
  <div class="wrap">
    <div class="section-head">
      <span class="kicker">Features</span>
      <h2 id="features-h">The computer the iPad hardware already is</h2>
      <p>An M-series iPad with a keyboard and trackpad is a laptop in everything but software. LinPad fills that gap.</p>
    </div>
    <div class="grid grid-3">{features}</div>
  </div>
</section>

<section aria-labelledby="shots-h">
  <div class="wrap">
    <div class="section-head">
      <span class="kicker">Screenshots</span>
      <h2 id="shots-h">The real apps, as iPad windows</h2>
    </div>
    <div class="grid grid-2">
      <figure class="shot">{picture("vscode", "(max-width: 620px) 100vw, 580px")}<figcaption><b>Visual Studio Code</b>A TypeScript project with git and the integrated terminal.</figcaption></figure>
      <figure class="shot">{picture("fastfetch", "(max-width: 620px) 100vw, 580px")}<figcaption><b>foot and fastfetch</b>Alpine Linux 3.21 with the full apk archive.</figcaption></figure>
      <figure class="shot">{picture("tiler", "(max-width: 620px) 100vw, 580px")}<figcaption><b>Keyboard-first tiling</b>Gaps, borders and a top bar, all themeable.</figcaption></figure>
      <figure class="shot">{picture("overview", "(max-width: 620px) 100vw, 580px")}<figcaption><b>Workspaces and overview</b>Switch with keys or a three-finger swipe.</figcaption></figure>
    </div>
  </div>
</section>

<section class="alt" aria-labelledby="themes-h">
  <div class="wrap">
    <div class="section-head">
      <span class="kicker">Themes</span>
      <h2 id="themes-h">From Tokyo Night to the late 90s</h2>
      <p>Colour palettes compatible with Omarchy community themes, retro era looks with matching Linux app themes, icon packs, wallpapers and 14 desktop layouts. Mix them, then share the result as a link.</p>
    </div>
    <div class="grid grid-4">{eras}</div>
    <p style="margin-top:24px"><a class="btn btn-ghost" href="/themes/">Browse all themes</a></p>
  </div>
</section>

<section aria-labelledby="limits-h">
  <div class="narrow">
    <div class="section-head">
      <span class="kicker">Honest limits</span>
      <h2 id="limits-h">What LinPad is not, yet</h2>
    </div>
    <div class="callout limits">
      <ul>
        <li><b>Not on the App Store.</b> You sideload it with your own Apple ID. A free Apple ID needs a refresh every 7 days, which SideStore can do for you.</li>
        <li><b>Emulated, so heavier apps are slow.</b> Without fast mode everything runs on an interpreter. Heavy web pages in Firefox can take many seconds to load.</li>
        <li><b>Memory is the ceiling.</b> VS Code alone wants about 2 GB or more. Running it with Firefox on an 8 GB iPad is the edge today.</li>
        <li><b>US keyboard layout in Linux apps</b> for now. Other layouts are the top item on the input backlog.</li>
        <li><b>No Docker, no Steam, no x86 games.</b> There are no namespaces or cgroups, and the GL path stops at 2.1.</li>
        <li><b>Not yet measured on an iPad.</b> Performance figures on this site come from a Mac or the simulator and are labelled that way. Device numbers come with v1.0.</li>
      </ul>
    </div>
  </div>
</section>

<section class="alt" aria-labelledby="start-h">
  <div class="wrap split">
    <div>
      <span class="kicker">Get started</span>
      <h2 id="start-h">Three steps once v1.0 ships</h2>
      <div class="steps">
        <div class="step"><h3>Add the source</h3><p>Add the LinPad source to SideStore or AltStore, or download the IPA from GitHub Releases.</p></div>
        <div class="step"><h3>Install and open</h3><p>LinPad unpacks its Linux system on first launch and walks you through a short setup.</p></div>
        <div class="step"><h3>Optional: fast mode</h3><p>Set up StikDebug and LocalDevVPN once for the native JIT.</p></div>
      </div>
      <p style="margin-top:20px"><a href="/install/">Read the full install guide →</a></p>
    </div>
    <figure class="shot">{picture("intro", "(max-width: 900px) 100vw, 560px")}<figcaption><b>First launch</b>Setup takes a couple of minutes, then you are at a desktop.</figcaption></figure>
  </div>
</section>

<section aria-labelledby="join-h">
  <div class="wrap">
    <div class="section-head center">
      <span class="kicker">Join in</span>
      <h2 id="join-h">Built in the open by one developer, for now</h2>
      <p>LinPad is a full-time project. It needs testers with iPads, people who know emulators, Wayland or SwiftUI, theme makers, and sponsors who want it to exist.</p>
    </div>
    <div class="grid grid-2">
      <article class="card"><h3>Contribute</h3><p>Good first issues are labelled, most work does not need an iPad, and themes are the easiest way in.</p><p style="margin-top:14px"><a class="btn btn-ghost btn-small" href="/contribute/">How to contribute</a></p></article>
      <article class="card"><h3>Support the project</h3><p>Sponsorships pay for test iPads, the Apple developer account and the time to keep shipping.</p><p style="margin-top:14px"><a class="btn btn-primary btn-small" href="/support/">Support LinPad</a></p></article>
    </div>
  </div>
</section>
"""
    json_ld = {
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        "name": "LinPad",
        "alternateName": "Linux for iPad",
        "description": "A real Linux desktop on the iPad: usermode Alpine Linux, a native SwiftUI desktop and real Linux apps as iPad windows.",
        "applicationCategory": "DeveloperApplication",
        "operatingSystem": "iPadOS 17 or later",
        "license": "https://www.gnu.org/licenses/gpl-3.0.html",
        "url": DOMAIN + "/",
        "codeRepository": GITHUB,
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
        "author": {"@type": "Person", "name": "Vali", "url": X_URL},
    }
    head = f'<script type="application/ld+json">{json.dumps(json_ld)}</script>'
    return page(path="/", title="LinPad: a real Linux desktop on your iPad",
                description="Firefox, VS Code, tiling windows and Alpine Linux running on the iPad itself. No VM, no jailbreak. Free and open source.",
                body=body, active="home", extra_head=head)


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
              "and is developed by Vali, a London-based developer.")


def press_page() -> str:
    downloads = "".join(
        f'<li><a href="/media/press/linpad-{key}.jpg" download>linpad-{key}.jpg</a></li>'
        for key in ("hero", "firefox", "vscode", "fastfetch", "tiler", "theme-app")
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
    <tr><th scope="row">Developer</th><td>Vali, London (<a href="{X_URL}">@AmbsdOP</a>, <a href="{YOUTUBE}">YouTube</a>)</td></tr>
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
    shutil.copytree(MEDIA, DIST / "media", ignore=shutil.ignore_patterns("manifest.json"))
    shutil.copy(SRC / "assets/logo.svg", DIST / "favicon.svg")
    for static in (SRC / "static").glob("*") if (SRC / "static").exists() else []:
        shutil.copy(static, DIST / static.name)

    import hashlib
    ASSET_VERSION = hashlib.sha256(
        (SRC / "assets/site.css").read_bytes() + (SRC / "assets/site.js").read_bytes()
    ).hexdigest()[:10]

    pages = {
        "index.html": home(themes),
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
