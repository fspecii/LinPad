#!/usr/bin/env python3
"""Regenerates guest/colors/<id>/ (colors.toml + theme.conf) and guest/templates/ from the
Omarchy checkout in src/ (git-ignored; see PORT-SPEC.md for the pinned commit).
Run on the host after updating src/; the output is committed."""
import json, os, re, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "src")
OUT = os.path.join(HERE, "guest", "colors")
TPL = os.path.join(HERE, "guest", "templates")

# Licensing/trademark (PORT-SPEC.md section 5): Ristretto follows a commercial palette,
# Lumon references Severance.
EXCLUDED = {"ristretto", "lumon"}

# Omarchy's VS Code extensions that resolve on Open VSX (PORT-SPEC.md 2.3); the rest
# get the generated theme.
OPEN_VSX = {"catppuccin", "catppuccin-latte", "gruvbox", "last-horizon", "matte-black",
            "nord", "rose-pine", "tokyo-night"}

NAMES = {"rose-pine": "Rosé Pine Dawn", "flexoki-light": "Flexoki Light",
         "catppuccin-latte": "Catppuccin Latte", "osaka-jade": "Osaka Jade",
         "retro-82": "Retro 82", "last-horizon": "Last Horizon", "matte-black": "Matte Black"}

# Omarchy names Yaru colour variants, which are not installed; the nearest installed
# icon pack (themes/guest/ish-icon-packs, base image) is used instead. The suffix
# -dark/-light is chosen by the theme's mode at apply time.
ICONS = {"Yaru-blue": "Papirus", "Yaru-purple": "Tela-circle", "Yaru-magenta": "Tela-circle",
         "Yaru-sage": "Qogir", "Yaru-olive": "Qogir", "Yaru-sage-dark": "Qogir",
         "Yaru-red": "Colloid", "Yaru-yellow": "Colloid", "Yaru-wartybrown": "kora",
         "Yaru-gray": "Numix-Circle", "Yaru-grey": "Numix-Circle"}

WALLHAVEN_Q = {"catppuccin": "pastel", "catppuccin-latte": "pastel", "ethereal": "space",
    "everforest": "forest", "flexoki-light": "abstract", "gruvbox": "landscape painting",
    "hackerman": "cyberpunk", "kanagawa": "japanese art", "last-horizon": "ocean",
    "lupine": "flowers", "matte-black": "minimalist dark", "miasma": "dark forest",
    "nord": "nordic landscape", "osaka-jade": "japan night", "retro-82": "synthwave",
    "rose-pine": "minimalist", "solitude": "minimalist", "tokyo-night": "city night",
    "vantablack": "black minimalist", "white": "white minimalist"}

def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    for tid in sorted(os.listdir(os.path.join(SRC, "themes"))):
        if tid in EXCLUDED:
            continue
        d = os.path.join(SRC, "themes", tid)
        colors = os.path.join(d, "colors.toml")
        if not os.path.isfile(colors):
            continue
        os.makedirs(os.path.join(OUT, tid))
        shutil.copy(colors, os.path.join(OUT, tid, "colors.toml"))
        icons = open(os.path.join(d, "icons.theme")).read().strip() if os.path.exists(os.path.join(d, "icons.theme")) else ""
        vs_name = vs_ext = ""
        if tid in OPEN_VSX and os.path.exists(os.path.join(d, "vscode.json")):
            v = json.load(open(os.path.join(d, "vscode.json")))
            vs_name, vs_ext = v.get("name", ""), v.get("extension", "")
        name = NAMES.get(tid, tid.replace("-", " ").title())
        with open(os.path.join(OUT, tid, "theme.conf"), "w") as f:
            f.write(f"name={name}\n")
            f.write(f"icons={ICONS.get(icons, '')}\n")
            f.write(f"vscode_name={vs_name or 'generated'}\n")
            f.write(f"vscode_extension={vs_ext}\n")
            f.write(f"wallhaven_q={WALLHAVEN_Q.get(tid, '')}\n")
    os.makedirs(TPL, exist_ok=True)
    for t in ("btop.theme.tpl", "vscode-theme.json.tpl"):
        shutil.copy(os.path.join(SRC, "default", "themed", t), os.path.join(TPL, t))
    # foot 1.19 (Alpine 3.21) has no [colors-dark] section.
    foot = open(os.path.join(SRC, "default", "themed", "foot.ini.tpl")).read()
    # foot 1.19 also keeps the cursor colour in [cursor], not [colors].
    foot = foot.replace("[colors-dark]", "[colors]")
    cursor = re.search(r"^cursor=(.*)$", foot, re.M).group(1)
    foot = re.sub(r"^cursor=.*\n\n?", "", foot, flags=re.M) + "\n[cursor]\ncolor=" + cursor + "\n"
    open(os.path.join(TPL, "foot.ini.tpl"), "w").write(foot)
    shutil.copy(os.path.join(SRC, "LICENSE"), os.path.join(HERE, "guest", "LICENSE.omarchy"))
    print(len(os.listdir(OUT)), "themes")

main()
