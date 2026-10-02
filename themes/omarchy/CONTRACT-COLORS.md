# Colour themes: native shell ↔ guest contract

A colour theme is an Omarchy `colors.toml` palette applied on top of the current desktop
style (`themes/CONTRACT.md`). The style keeps its shapes, widgets and fonts. The theme
replaces the colours of the terminal, GTK, Qt, btop, VS Code, Firefox's light/dark mode
and, optionally, the icon pack. The native shell only reads guest files and runs these
commands (e.g. through `LinuxHost.run`); it never writes guest files itself.

Sources:
- `themes/omarchy/guest/` (repo)
- design: `PORT-SPEC.md`
- palettes and templates regenerated from the Omarchy checkout with `make-palettes.py`

## Commands

```
ish-colors list --json                   # every theme, see "Theme JSON"
ish-colors list                          # id \t name \t dark|light
ish-colors show <id> --json              # one theme
ish-colors install <git-url>             # https:// or git@host:path; prints "installed: <id>"
ish-colors remove <id>                   # user themes only
ish-apply-colors <id> [--json]           # apply; see "Apply result"
ish-apply-colors none [--json]           # back to the style's own colours
ish-apply-colors --current               # active id, or "none"
ish-apply-colors --fonts <ui-font> <mono-family> <mono-size> <cursor-size>
                                         # e.g. "Inter 11" "JetBrains Mono" 12 32; stored in
                                         # /usr/share/ish/fonts.env (ish-apply-style honours it),
                                         # GTK settings.ini edited in place, foot via fonts.ini
ish-apply-colors --fonts default         # back to the style's fonts and cursor size
```

- Exit status 0 means done. On failure the last stderr line says why, and with `--json`
  stdout is `{"ok": false, "error": "…"}`.
- Applies are serialized (a lock in `~/.local/state/linpad/colors/.lock`), so a second
  request waits for the first to finish.
- **Timing:** an apply takes about 1 s (CLI emulator, M4). It takes 20–30 s when the icon
  pack changes, because `ish-apply-style --icons` rebuilds the icon cache.

## Files

```
/usr/share/ish/current-colors                one line: active theme id, or "none". Written LAST.
/usr/share/linpad/colors/<id>/colors.toml    built-in palettes (20; Ristretto and Lumon are excluded)
/usr/share/linpad/colors/<id>/theme.conf     name=, icons=, vscode_name=, vscode_extension=, wallhaven_q=
/usr/share/linpad/colors/templates/*.tpl     foot.ini, btop.theme, vscode-theme.json (Omarchy, MIT), gtk3.css, gtk4-colors.css
/usr/share/linpad/colors/LICENSE.omarchy, ATTRIBUTION
~/.config/linpad/colors/<id>/                user themes (ish-colors install); same id as a built-in wins
~/.config/linpad/themed/<name>.tpl           optional user template overrides (same names)
~/.local/state/linpad/colors/current/        the rendered theme: colors.toml, palette.tsv (key\tvalue,
                                             every resolved key), foot.ini, gtk3.css, …, id
```

Watch `current-colors` (mtime, or poll), as for `current-style`. When it changes, the
rendered files and the per-app hook-ups are complete. Re-read the theme with
`ish-colors show <id> --json`, or read `~/.local/state/linpad/colors/current/palette.tsv`.

A style switch (`ish-apply-style <style>`) and an icon-pack choice (`--icons`) re-apply
the active colour theme on their own (`ish-apply-colors --refresh`), so the shell does
not need to.

## Theme JSON (`ish-colors list --json` is an array of these)

```json
{"id": "tokyo-night", "name": "Tokyo Night", "source": "builtin", "appearance": "dark",
 "accent": "#7aa2f7", "background": "#1a1b26", "foreground": "#a9b1d6", "selection": "#292e42",
 "selectionForeground": "#c0caf5", "cursor": "#c0caf5", "muted": "#414868",
 "darkBackground": "#13141c", "darkerBackground": "#0e0e14", "lighterBackground": "#24283b",
 "brightForeground": "#c0caf5", "red": "#f7768e",
 "ansi": ["#1a1b26", "#f7768e", "…16 entries: color0..color15"],
 "iconTheme": "Tela-circle",
 "vscode": {"name": "Tokyo Night", "extension": "enkia.tokyo-night"},
 "wallhaven": {"q": "city night", "colors": ["424153", "0066cc"], "categories": "100",
               "purity": "100", "sorting": "toplist"}}
```

Field notes:

| Field | Meaning |
|---|---|
| `source` | `builtin` or `user` |
| `appearance` | `dark` or `light`; it decides the theme's dark preference, whatever the desktop appearance setting is |
| colour values | always `#rrggbb`, already resolved with Omarchy's fallback rules (PORT-SPEC 1.2) |
| `ansi` | `color0..15` = bg, red, green, yellow, blue, magenta, cyan, fg, muted, bright red … bright cyan, bright fg |
| `iconTheme` | base icon theme id, empty for none. The `-Dark`/`-Light` variant matching `appearance` is chosen at apply time. User themes carry Omarchy's `icons.theme` (e.g. `Yaru-red`), which is mapped to an installed pack |
| `vscode.name` | `generated` means a local theme labelled `LinPad` is generated |
| `wallhaven.colors` | the nearest Wallhaven search colours to background and accent |
| `wallhaven.categories` / `purity` | Wallhaven API strings, general only and SFW |

## Apply result (`--json`)

```json
{"ok": true, "id": "gruvbox", "appearance": "dark",
 "applied": ["icons", "foot", "gtk", "qt", "btop", "vscode", "firefox"],
 "iconTheme": "Qogir-Dark", "retintedTerminals": 1}
```

`applied` lists what was hooked up: `vscode` appears only when VS Code / Code-OSS /
VSCodium is installed, and `icons` only when the theme has a pack and the user has not
picked one. `iconTheme` is the pack the colour theme set (empty when it set none).
`none` returns `{"ok": true, "id": "none", "retintedTerminals": N}`.

## What each app gets

| App | How | Live? |
|---|---|---|
| foot (ish-terminal) | `~/.config/foot/colors.ini` plus `~/.config/foot/linpad.ini` (includes `/etc/ish/foot/foot.ini` and the colours). `ish-terminal` uses `linpad.ini` when it exists, the style's ini otherwise | yes: OSC 4/10/11/12/17/19 written to the pty of every foot child. `none` writes the style's foot palette |
| GTK 3 | `~/.config/gtk-3.0/gtk.css` (marker `linpad-colors`): recolours windows, views, header bars, buttons, entries, selection, menus, accents. Dark preference in `settings.ini` follows `appearance` | new windows |
| GTK 4 / libadwaita | `~/.config/gtk-4.0/gtk.css`: `@import` of the style's GTK 4 theme (when it has one), the libadwaita named colours, then the GTK 3 rules | new windows |
| Qt | Kvantum theme `~/.config/Kvantum/LinPad` (KvUKUI or KvUKUIDark recoloured) and `kvantum.kvconfig theme=LinPad` | new windows |
| btop | `~/.config/btop/themes/linpad.theme`, `color_theme = "linpad"` | next start |
| VS Code | `workbench.colorTheme` in `settings.json`. Open VSX theme: `--install-extension` runs in the background. Otherwise a local extension `local.linpad-theme` with `_watch: true`, which reloads live | yes once installed |
| Firefox | `/usr/lib/firefox-esr/defaults/pref/linpad-colors.js`: `ui.systemUsesDarkTheme` and `browser.theme.*` (light/dark only; no userChrome) | restart |
| fastfetch, ls, shells | use the terminal's ANSI colours | yes |
| icons | `ish-apply-style --icons <pack>`. A pack the user picked in Settings › Icons (the override differs from the one ish-apply-colors last set) is never replaced; `none` restores `match` only if the colour theme set it | yes (cache rebuilt) |

Files that are not ours are left alone, with a note on stderr. "Ours" means a file that
is missing, has the `linpad-colors` marker, or is the style's own symlink into
`/usr/share/themes`.

## Installing from git

`ish-colors install <url>` accepts only `https://…` and `git@host:path` URLs, with no
leading `-` and no `ext::`/`fd::` transports.

The id is the repo name without `.git`, `omarchy-` and `-theme`, lower-cased, and must
match `^[a-z0-9_][a-z0-9._+-]*$`.

It copies only:
- `colors.toml`;
- `icons.theme` and `light.mode`, both reduced to safe characters;
- image files (`jpg`, `jpeg`, `png`, `webp`, at most 20 MB each) from `backgrounds/`.

Never copied: symlinks, scripts, `*.lua`, terminal, editor, GTK or shell configs, and
anything executable. Omarchy community themes work unmodified (tested with
`catlee/omarchy-dracula-theme`). The theme's images are at
`~/.config/linpad/colors/<id>/backgrounds/`, for the native wallpaper picker.

## Not covered

- Live recolouring of already-open GTK/Qt windows: they need a restart, as with styles.
- Wallpapers for the built-in themes: Omarchy's images carry no stated licence and are not
  shipped. Use the Wallhaven query; see PORT-SPEC 4.5.
- neovim, helix and tmux templates (not installed in the image).
