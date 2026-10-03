# linpados.com

Static site for LinPad. No framework, no server: `build.py` writes plain HTML into `dist/`.

```sh
python3 site/build.py                  # build into site/dist
python3 site/build.py --refresh-media  # re-encode screenshots first (ImageMagick with AVIF/WebP, Google Chrome)
python3 -m http.server 4317 --directory site/dist
```

Generated from the app's own sources, so they stay in sync with the build:

- theme gallery and `themes/<id>/colors.toml`: `desktop/DesktopKit/.../ColorThemes/themes.json`
- manual shortcut tables and `data/keybindings.json`: `DesktopKeyboardShortcuts.swift` (the build fails if parsing finds too few bindings)
- manual app packs: `release/guest/linpad/catalog.json`

Optimised screenshots live in `src/media` (committed, about 4.6 MB) and Latin subsets of Inter and JetBrains Mono (SIL OFL 1.1) in `src/fonts`. Some sources sit outside the repo in `../ipad-jit`; only `--refresh-media` needs them. Screenshots come from `../ipad-jit/site-captures`, captured from the current app in the iPad simulator (Debug automation `preset|ID` applies each era look). `--refresh-media` also cuts the hero's home-screen layers into `.cache/` (blurred screen, LinPad icon) and subsets the fonts with `pyftsubset`. The app icon master is `src/brand/app-icon.svg`.

The home page hero is a scroll-driven sequence (home screen, tap, app-open zoom, launch screen, first-run frames, desktop): CSS drives `--p` with a scroll timeline where supported, `site.js` sets it elsewhere, and `prefers-reduced-motion` gets a static final frame.

Placeholders to fill before launch, at the top of `build.py`: `HERO_VIDEO`, `SPONSORS_URL`, `OPENCOLLECTIVE_URL`, `CHAT_URL`.

Deploy (not done yet): any static host. Cloudflare Pages: build command `python3 site/build.py`, output `site/dist`. `src/static/_headers` sets caching and security headers. Serve linpados.com as primary and 301 www.linpados.com to it with a Cloudflare redirect rule.
