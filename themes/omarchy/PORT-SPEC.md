# Omarchy theme system → LinPad: port spec

Source studied: `github.com/omacom/omarchy` (the old `basecamp/omarchy` URL redirects), shallow clone in
`themes/omarchy/src/` (git-ignored) at commit `821ae589059ffdadc970315f866c94b55d268af7`
(2026-10-02, `version` = `4.0.0.alpha`). Where the last stable line differs, tag `v3.8.4` is cited.
Paths below are relative to `src/`.

What to take: the design logic (one palette file, many generated per-app configs, atomic apply,
live retint, keyboard-first pickers). What to leave: Arch/Hyprland/Quickshell specifics.

---

## 1. How an Omarchy theme is structured

### 1.1 Theme folder (`themes/<name>/`)

| File | Required | Purpose |
|---|---|---|
| `colors.toml` | yes (since v3) | The single palette. Everything else is generated from it. |
| `backgrounds/` | yes in practice | Wallpapers, sorted by filename (`0-…`, `1-…`, `omarchy.webp`). Images or videos. |
| `preview.png` | first-party | Screenshot shown in the theme picker (fallback: first background). |
| `preview-unlock.png`, `unlock.png` | first-party | Boot-decryption (Plymouth) design for the theme. |
| `icons.theme` | optional | One line: GTK icon theme name (`Yaru-magenta`, …). Default `Yaru-blue`. |
| `vscode.json` | optional | `{"name": "<VS Code colorTheme label>", "extension": "<marketplace id>"}`. Absent → generated theme. |
| `neovim.lua` | optional | LazyVim colorscheme spec. |
| `hyprland.lua` | optional | Hand override of the generated border colours (e.g. `kanagawa`, `lumon`, `retro-82`). |
| `btop.theme`, `chromium.theme`, `shell.toml`, `shell.<section>.toml`, `keyboard.rgb` | optional | Hand overrides of a generated file / one shell section (`tokyo-night/shell.lock.toml`). |
| `light.mode` | legacy | Empty marker = light theme. Now `mode = "light"` inside `colors.toml`. |

Rule (`bin/omarchy-theme-set-templates`, `render_templates`): **a file the theme ships always wins over the
template of the same name**; templates fill in everything missing.

### 1.2 `colors.toml` schema (`docs/theming.md`, `bin/omarchy-theme-color`)

```
mode            dark | light
accent  selection  muted
background  dark_background  darker_background  lighter_background
foreground  dark_foreground  light_foreground  bright_foreground
red yellow orange green cyan blue magenta brown
bright_red bright_yellow bright_green bright_cyan bright_blue bright_magenta
hyprland_active_border / hyprland_inactive_border   (optional; solid or "rgba(..) rgba(..) 45deg")
```

Resolver (`bin/omarchy-theme-color`, one shared implementation for every consumer):
- ANSI map: `color0=background, 1=red, 2=green, 3=yellow, 4=blue, 5=magenta, 6=cyan, 7=foreground,
  8=muted, 9..14=bright_*, 15=bright_foreground`. Legacy `colorN`/`bg`/`fg` names accepted both ways.
- Derived when missing: `bright_X = mix(X, #fff, 20%)`, `dark_background = mix(bg, #000, 25%)`,
  `darker_background = mix(bg, #000, 50%)`, `orange = yellow`, `brown = mix(orange, #000, 50%)`,
  `selection_background = selection`, `selection_foreground = bright_foreground`, `cursor = bright_foreground`.
- Mode: `mode` key → legacy `theme_type` → `light.mode` file → luminance (`r+g+b > 382` ⇒ light) → dark.
- Neutral ramp contract: `darker_bg → dark_bg → bg → lighter_bg → selection → muted → dark_fg → fg → light_fg → bright_fg`
  reads monotonic (inverted for light themes).

### 1.3 Templates (`default/themed/*.tpl`)

Placeholders: `{{ key }}` → `#rrggbb`, `{{ key_strip }}` → `rrggbb`, `{{ key_rgb }}` → `r,g,b`,
`{{ mix a b 15% }}` (+`_strip`, `_rgb`), gradient helpers `hypr_gradient` / `shell_gradient` / `gradient_start`
with a fallback key (`{{ shell_gradient hyprland_active_border accent }}`). One awk pass renders all templates.
User templates in `~/.config/omarchy/themed/*.tpl` take precedence over built-ins.

Apps covered (v4 templates; v3.8.4 had the bar/launcher/notification set marked †):

| App | Template | Tokens actually used |
|---|---|---|
| Alacritty / Kitty / Ghostty / **foot** | `alacritty.toml.tpl`, `kitty.conf.tpl`, `ghostty.conf.tpl`, `foot.ini.tpl` | fg, bg, selection fg/bg, cursor, 16 ANSI |
| Hyprland borders | `hyprland.lua.tpl` | `active_border = hyprland_active_border ‖ accent`, `inactive = rgba(595959aa)` |
| Omarchy shell (bar, menu, launcher, notifications, OSD, lock, polkit, tooltips) | `shell.toml.tpl` | bg, fg, accent, red; alphas; spacing/font scale |
| btop | `btop.theme.tpl` | `main_bg=bg, main_fg=fg, hi_fg=accent, selected_bg=selection, selected_fg=accent, inactive_fg=muted`, … |
| VS Code / VSCodium / Cursor | `vscode-theme.json.tpl` (1,344 lines) | full workbench + semantic tokens |
| Chromium/Chrome/Brave/Edge | `chromium.theme.tpl` | `{{ background_rgb }}` → managed policy `BrowserThemeColor` |
| Neovim, Helix, tmux, Obsidian, gum, Claude/pi/hermes/t3code CLIs, keyboard RGB | respective `.tpl` | palette |
| † Waybar (v3) | `waybar.css.tpl` | **only** `@define-color foreground/background` |
| † Walker launcher (v3) | `walker.css.tpl` | `selected-text=accent, text=fg, base=bg, border=fg` |
| † Mako notifications (v3) | `mako.ini.tpl` | `text=fg, border=accent, background=bg` |
| † SwayOSD (v3) | `swayosd.css.tpl` | bg, border=fg, label=fg, progress=accent |
| † Hyprlock (v3) | `hyprlock.conf.tpl` | bg, inner=bg@0.8, outer=fg, font=fg, check=accent |
| GTK / GNOME | `bin/omarchy-theme-set-gnome` (no template) | `color-scheme prefer-dark/light`, `gtk-theme Adwaita[-dark]`, `icon-theme $(icons.theme)` |

Key observation: **v3's whole desktop chrome was themed from 3–4 tokens (bg, fg, accent, red).** v4 replaced
Waybar/Walker/Mako/SwayOSD/Hyprlock with one QML process (`shell/`) driven by `shell.toml`, still derived from
those same tokens plus alphas.

### 1.4 Applying a theme (`bin/omarchy-theme-set`)

State lives in `~/.local/state/omarchy/current/`: `theme/` (rendered), `theme.name`, `background` (symlink),
`next-theme/` (staging). User themes in `~/.config/omarchy/themes/<name>/`, user wallpapers per theme in
`~/.config/omarchy/backgrounds/<name>/`.

1. Normalise name (`"Tokyo Night"` → `tokyo-night`), reject `.`/`/`, `flock` a lock (theme changes queue, never race).
2. Remember the outgoing theme's current wallpaper in `~/.local/state/omarchy/theme-backgrounds/<theme>`.
3. `rm -rf next-theme`; copy built-in theme; overlay user theme (filtered if it came from git, §1.6).
4. No `colors.toml`? Derive it from a legacy `alacritty.toml`.
5. Pick the wallpaper: same theme → next in list; otherwise the one remembered for that theme; else first.
   Start decoding it in the shell *now* (`background prepare`) so the transition is ready.
6. `omarchy-theme-set-templates` renders into `next-theme/`.
7. Atomic swap: `rm -rf current/theme; mv next-theme current/theme`; write `theme.name`.
8. Push palette to the running shell over IPC (`shell applyTheme <base64 colors.toml> <base64 shell.toml>`) together
   with a **cross-fade wallpaper transition** (`background themeTransition old new`); update the `background` symlink.
9. Release the lock, then retint apps **in parallel**: restart terminals/btop/helix, `hyprctl reload`, foot retint by
   OSC, tmux, GNOME gsettings, browser policy, VS Code, Obsidian, keyboard RGB.
10. Fire user hook `~/.config/omarchy/hooks/theme-set <name>`; warm background-picker thumbnails in the background.

Live terminal retint without restart (`bin/omarchy-theme-set-foot`, `bin/omarchy-theme-osc`): write
`OSC 10/11/12/17/19` (fg, bg, cursor, selection bg/fg) and `OSC 4;i` (16 ANSI) to every pty owned by a foot child.

Other commands: `omarchy-theme-refresh` (re-render current theme, keep wallpaper), `omarchy-theme-bg-next`
(cycle `user backgrounds ∪ theme backgrounds`, sorted, wrap-around), `omarchy-theme-bg-set <file>`,
`omarchy-theme-switcher` (image grid of `preview.png`s with a signature cache), `omarchy-theme-list/current/remove`.

### 1.5 Keybindings (`default/hypr/bindings/utilities.lua`)

| Keys | Action |
|---|---|
| `Super+Space` | Omarchy menu (root) |
| `Super+Alt+Space` | Apps menu (launcher) |
| `Super+Ctrl+Space` | Background switcher (image carousel) |
| `Super+Shift+Ctrl+Space` | Theme picker (image carousel with previews) |
| `Super+Backspace` / `Super+Shift+Backspace` | Toggle window transparency / toggle gaps+borders+rounding off |
| `Super+Escape` | System (power) menu |
| `Super+K` | Keybinding cheat sheet (generated from the binding table) |
| `Super+,` / `Super+Shift+,` / `Super+Ctrl+,` | Dismiss one / all notifications / do-not-disturb |
| `Print` / `Alt+Print` / `Super+Ctrl+Print` / `Super+Ctrl+C` | Screenshot / record / OCR / capture menu |
| `Super+Ctrl+L` | Lock |

### 1.6 Installing themes from git (`bin/omarchy-theme-install`, `omarchy-theme-update`, `omarchy-theme-extras`)

- `omarchy theme install <git-url>`: validate URL (no git options / transport helpers), derive name from repo basename
  minus `omarchy-` prefix and `-theme` suffix, enforce `^[a-z0-9_][a-z0-9._+-]*$` (C locale), `git clone` into
  `~/.config/omarchy/themes/<name>`, then `omarchy-theme-set <name>`.
- **Trust model** (`omarchy-theme-set`, `INSTALLED_THEME_DENIED`): a theme dir containing `.git` came from a stranger.
  Staging drops every `*.lua`, every terminal config (`alacritty.toml foot.ini ghostty.conf kitty.conf` — they name
  the program to launch), `vscode.json` (installs arbitrary JS), and **all symlinks at any depth**; only colour data
  is kept and the dropped parts are regenerated from templates. Ignored files are reported on stderr.
- `omarchy theme update` does `git pull` on those; the filter runs at staging, so updates are covered too.
- Community catalogue: `https://omarchy.org/themes/`.

---

## 2. Built-in palettes (22 themes, from `themes/*/colors.toml` + `hyprland.lua`)

### 2.1 Semantic tokens

Border active = `hyprland_active_border` ‖ theme `hyprland.lua` ‖ `accent`. Inactive default `rgba(595959aa)`.
Gradients are 45°.

| theme | mode | background | foreground | accent | selection | muted (c8) | lighter_bg | dark_bg | bright_fg | border active | border inactive |
|---|---|---|---|---|---|---|---|---|---|---|---|
| catppuccin | dark | `#1e1e2e` | `#cdd6f4` | `#89b4fa` | `#45475a` | `#585b70` | `#313244` | `#161622` | `#cdd6f4` | #89b4fa | rgba(595959aa) |
| catppuccin-latte | light | `#eff1f5` | `#4c4f69` | `#1e66f5` | `#ccd0da` | `#acb0be` | `#dce0e8` | `#e3e4e8` | `#4c4f69` | #1e66f5 | rgba(595959aa) |
| ethereal | dark | `#060b1e` | `#ffcead` | `#7d82d9` | `#252e56` | `#6d7db6` | `#131a3a` | `#040816` | `#ffcead` | #7d82d9 | rgba(595959aa) |
| everforest | dark | `#2d353b` | `#d3c6aa` | `#7fbbb3` | `#3d484d` | `#475258` | `#343f44` | `#21272c` | `#d3c6aa` | #7fbbb3 | rgba(595959aa) |
| flexoki-light | light | `#fffcf0` | `#100f0f` | `#205ea6` | `#cecdc3` | `#b7b5ac` | `#e6e4d9` | `#f2efe4` | `#100f0f` | #205ea6 | rgba(595959aa) |
| gruvbox | dark | `#282828` | `#d4be98` | `#7daea3` | `#504945` | `#665c54` | `#3c3836` | `#1e1e1e` | `#d4be98` | #7daea3 | rgba(595959aa) |
| hackerman | dark | `#0b0c16` | `#ddf7ff` | `#82fb9c` | `#1f253a` | `#2d3450` | `#151828` | `#080910` | `#ddf7ff` | rgba(26a269ee) → rgba(2ec27eee) | rgba(595959aa) |
| kanagawa | dark | `#1f1f28` | `#dcd7ba` | `#dcd7ba` | `#363646` | `#54546d` | `#223249` | `#17171e` | `#dcd7ba` | rgb(dcd7ba) | rgba(595959aa) |
| last-horizon | dark | `#0c0b0c` | `#fafcfb` | `#b59790` | `#584e51` | `#584e51` | `#0c0b0c` | `#090809` | `#e2dddc` | rgba(8a8588ee) → rgba(e2dddcee) | rgba(584e51aa) |
| lumon | dark | `#16242d` | `#d6e2ee` | `#8bc9eb` | `#243d56` | `#304860` | `#1b2d40` | `#101b21` | `#f2fcff` | rgb(f2fcff) | rgba(30486099) |
| lupine | light | `#fafafa` | `#212121` | `#3264eb` | `#d0d0d0` | `#9e9e9e` | `#f5f5f5` | `#ececec` | `#000000` | #3264eb | rgba(595959aa) |
| matte-black | dark | `#121212` | `#bebebe` | `#e68e0d` | `#2a2a2a` | `#333333` | `#1e1e1e` | `#0d0d0d` | `#bebebe` | #e68e0d | rgba(595959aa) |
| miasma | dark | `#222222` | `#c2c2b0` | `#78824b` | `#383838` | `#666666` | `#2c2c2c` | `#191919` | `#c2c2b0` | #78824b | rgba(595959aa) |
| nord | dark | `#2e3440` | `#d8dee9` | `#81a1c1` | `#434c5e` | `#4c566a` | `#3b4252` | `#222730` | `#d8dee9` | #81a1c1 | rgba(595959aa) |
| osaka-jade | dark | `#111c18` | `#c1c497` | `#509475` | `#32473b` | `#53685b` | `#23372b` | `#0c1512` | `#f7e8b2` | #509475 | rgba(595959aa) |
| retro-82 | dark | `#05182e` | `#f6dcac` | `#faa968` | `#134e5a` | `#2a6b78` | `#0a2540` | `#031222` | `#f6dcac` | rgb(faa968) | rgba(595959aa) |
| ristretto | dark | `#2c2525` | `#e6d9db` | `#f38d70` | `#403e41` | `#72696a` | `#3d2f2a` | `#211b1b` | `#e6d9db` | #f38d70 | rgba(595959aa) |
| rose-pine (Dawn) | light | `#faf4ed` | `#575279` | `#56949f` | `#dfdad9` | `#cecacd` | `#f2e9e1` | `#ede7e1` | `#575279` | #56949f | rgba(595959aa) |
| solitude | dark | `#101315` | `#cacccc` | `#798186` | `#343d41` | `#4b4e55` | `#101315` | `#0c0e10` | `#a5aeb4` | rgba(798186ee) → rgba(caccccee) | rgb(1e1e1e) |
| tokyo-night | dark | `#1a1b26` | `#a9b1d6` | `#7aa2f7` | `#292e42` | `#414868` | `#24283b` | `#13141c` | `#c0caf5` | #7aa2f7 | rgba(595959aa) |
| vantablack | dark | `#000000` | `#ffffff` | `#8d8d8d` | `#1a1a1a` | `#7a7a7a` | `#1a1a1a` | `#090909` | `#ffffff` | #8d8d8d | rgba(595959aa) |
| white | light | `#ffffff` | `#000000` | `#6e6e6e` | `#c0c0c0` | `#808080` | `#c0c0c0` | `#f5f5f5` | `#000000` | #6e6e6e | rgba(595959aa) |

Selection text = `bright_foreground`; cursor = `bright_foreground` (all themes).

### 2.2 Terminal 16 colours (resolved, as `foot.ini.tpl` emits them)

`regular0..7` = bg red green yellow blue magenta cyan fg · `bright0..7` = muted bright_red … bright_cyan bright_fg.

| theme | regular0-7 | bright0-7 |
|---|---|---|
| catppuccin | 1e1e2e f38ba8 a6e3a1 f9e2af 89b4fa f5c2e7 94e2d5 cdd6f4 | 585b70 f38ba8 a6e3a1 f9e2af 89b4fa f5c2e7 94e2d5 cdd6f4 |
| catppuccin-latte | eff1f5 d20f39 40a02b df8e1d 1e66f5 ea76cb 179299 4c4f69 | acb0be d20f39 40a02b df8e1d 1e66f5 ea76cb 179299 4c4f69 |
| ethereal | 060b1e ed5b5a 92a593 e9bb4f 7d82d9 c89dc1 a3bfd1 ffcead | 6d7db6 faaaa9 c4cfc4 f7dc9c c2c4f0 ead7e7 dfeaf0 ffcead |
| everforest | 2d353b e67e80 a7c080 dbbc7f 7fbbb3 d699b6 83c092 d3c6aa | 475258 e67e80 a7c080 dbbc7f 7fbbb3 d699b6 83c092 d3c6aa |
| flexoki-light | fffcf0 d14d41 879a39 d0a215 205ea6 ce5d97 3aa99f 100f0f | b7b5ac d14d41 879a39 d0a215 4385be ce5d97 3aa99f 100f0f |
| gruvbox | 282828 ea6962 a9b665 d8a657 7daea3 d3869b 89b482 d4be98 | 665c54 ea6962 a9b665 d8a657 7daea3 d3869b 89b482 d4be98 |
| hackerman | 0b0c16 50f872 4fe88f 50f7d4 829dd4 86a7df 7cf8f7 ddf7ff | 2d3450 85ff9d 9cf7c2 a4ffec c4d2ed cddbf4 d1fffe ddf7ff |
| kanagawa | 1f1f28 c34043 76946a c0a36e 7e9cd8 957fb8 6a9589 dcd7ba | 54546d e82424 98bb6c e6c384 7fb4ca 938aa9 7aa89f dcd7ba |
| last-horizon | 0c0b0c c38b7b 87a9b0 6b5e73 b59790 c4d8e2 a5a0b6 fafcfb | 584e51 c38b7b 87a9b0 6b5e73 b59790 c4d8e2 a5a0b6 e2dddc |
| lumon | 16242d 4d86b0 5e95bc 6fa4c9 6fb8e3 8bc9eb b4e4f6 d6e2ee | 304860 73a6cb 86b7d8 9dcae5 f2fcff b1d8ee d1eef8 f2fcff |
| lupine | fafafa c900c4 4a2fd0 026fde 3264eb 8a4ad7 0c67de 212121 | 9e9e9e f930fb 9f85e0 358fff 5482ff b363ff 3986ff 000000 |
| matte-black | 121212 d35f5f ffc107 b91c1c e68e0d d35f5f bebebe bebebe | 333333 b91c1c ffc107 b90a0a f59e0b b91c1c eaeaea bebebe |
| miasma | 222222 685742 5f875f b36d43 78824b bb7744 c9a554 c2c2b0 | 666666 685742 5f875f b36d43 78824b bb7744 c9a554 c2c2b0 |
| nord | 2e3440 bf616a a3be8c ebcb8b 81a1c1 b48ead 88c0d0 d8dee9 | 4c566a bf616a a3be8c ebcb8b 81a1c1 b48ead 8fbcbb d8dee9 |
| osaka-jade | 111c18 ff5345 549e6a 459451 509475 d2689c 2dd5b7 c1c497 | 53685b db9f9c 63b07a e5c736 acd4cf 75bbb3 8cd3cb f7e8b2 |
| retro-82 | 05182e f85525 028391 e97b3c 3f8f8a 3f8f8a 8cbfb8 f6dcac | 2a6b78 f85525 028391 e97b3c faa968 3f8f8a 8cbfb8 f6dcac |
| ristretto | 2c2525 fd6883 adda78 f9cc6c f38d70 a8a9eb 85dacc e6d9db | 72696a ff8297 c8e292 fcd675 f8a788 bebffd 9bf1e1 e6d9db |
| rose-pine | faf4ed b4637a 286983 ea9d34 56949f 907aa9 d7827e 575279 | cecacd b4637a 286983 ea9d34 56949f 907aa9 d7827e 575279 |
| solitude | 101315 565d60 9fa5a9 d9dbdc 798186 aeaeae 707070 cacccc | 4b4e55 de6145 343d41 c9c2b4 5d6367 9a9a9a 707070 a5aeb4 |
| tokyo-night | 1a1b26 f7768e 9ece6a e0af68 7aa2f7 ad8ee6 449dab a9b1d6 | 414868 ff7a93 b9f27c ff9e64 7da6ff bb9af7 0db9d7 c0caf5 |
| vantablack | 000000 a4a4a4 b6b6b6 cecece 8d8d8d 9b9b9b b0b0b0 ffffff | 7a7a7a a4a4a4 b6b6b6 cecece 8d8d8d 9b9b9b b0b0b0 ffffff |
| white | ffffff 2a2a2a 3a3a3a 4a4a4a 1a1a1a 2e2e2e 3e3e3e 000000 | 808080 2a2a2a 3a3a3a 4a4a4a 1a1a1a 2e2e2e 3e3e3e 000000 |

Extras present in some files: `orange`, `brown` (derived when absent: last-horizon, solitude, white), and
`active_border_color` / `active_tab_background` (last-horizon, lumon, solitude; used by their hand-written `btop.theme`).

### 2.3 Icons, VS Code, wallpapers per theme

Wallpaper source URL pattern (pinned):
`https://raw.githubusercontent.com/omacom/omarchy/821ae589059ffdadc970315f866c94b55d268af7/themes/<theme>/backgrounds/<file>`.
**No licence or credit is stated for any wallpaper anywhere in the repo** (grep for credit/unsplash/artist: nothing).
`omarchy.webp` is Omarchy's own branded image. Treat all as *not redistributable* (see §5).

Open VSX column = HTTP 200 from `open-vsx.org/api/<ns>/<name>` on 2026-10-02 (IDs as Omarchy spells them; a 404 may only
mean a different id on Open VSX — verify before shipping).

| theme | icons.theme | VS Code (`name` · `extension`) | Open VSX | backgrounds/ |
|---|---|---|---|---|
| catppuccin | Yaru-purple | Catppuccin Mocha · catppuccin.catppuccin-vsc | yes | 1-totoro.webp 2-waves.webp 3-blue-eye.webp omarchy.webp |
| catppuccin-latte | Yaru-blue | Catppuccin Latte · catppuccin.catppuccin-vsc | yes | 1-color-fade.webp omarchy.webp |
| ethereal | Yaru-blue | (generated) | n/a | 1-cosmic.webp 2-meadow.webp omarchy.webp |
| everforest | Yaru-sage | Everforest Dark · reesew.everforest-theme | 404 | 1-tree-tops.webp omarchy.webp |
| flexoki-light | Yaru-blue | flexoki-light · shadesOfBuntu.flexoki-light | 404 | 1-orb.webp 2-omarchy.webp |
| gruvbox | Yaru-olive | Gruvbox Dark Medium · jdinhlife.gruvbox | yes | 1-the-backwater.jpg 2-flower-basket.webp 3-village-square.jpg 4-idyllic-procession.jpg 5-leaves.jpg omarchy.webp |
| hackerman | Yaru-blue | Hackerman · Bjarne.hackerman-omarchy | 404 | 1-synth-scape.jpg 2-geometric.webp omarchy.webp |
| kanagawa | Yaru-blue | Kanagawa · qufiwefefwoyn.kanagawa | 404 | 1-kanagawa.jpg omarchy.webp |
| last-horizon | Yaru-purple | Ship at Sea · rikkarth.ship-at-sea | yes | 1-eyes-wide.webp 2-blink.webp 3-bokeh.webp 4-new-horizons.jpg |
| lumon | Yaru-blue | Lumon · oldjobobo.lumon-theme | 404 | 01-united-in-severance.webp 02-opinions-equally.webp omarchy.webp |
| lupine | Yaru-purple | (generated) | n/a | 01-cherry-blossom-bokeh.webp 02-cherry-blossom-white.webp 03-pastel-clouds.webp 04-elegant-blue-wave.webp 05-abstract-wave.webp 06-omarchy.webp |
| matte-black | Yaru-red | Matte Black · TahaYVR.matteblack | yes | 0-ship-at-sea.jpg 1-dark-waters.webp 2-dot-hands.webp omarchy.webp |
| miasma | Yaru-wartybrown | (generated) | n/a | 01-nature-of-fear.webp 02-crowned.webp omarchy.webp |
| nord | Yaru-blue | Nord · arcticicestudio.nord-visual-studio-code | yes | 0-black-moon.jpg 1-city-view.webp 2-night-hawks.webp omarchy.webp |
| osaka-jade | Yaru-sage | Ocean Green: Dark · jovejonovski.ocean-green | 404 | 1-glowing-city.webp 2-shaded-entrance.webp 3-mountain-moon.webp omarchy.webp |
| retro-82 | Yaru-wartybrown | Retro'82 · oldjobobo.retro-82-theme | 404 | 1-in-the-groove.webp 2-dusk-guardian.webp 3-glassy-lines.webp 4-gateway.webp 5-zen-boat.webp 6-abstract-pyramids.webp 7-the-journey.webp 8-glitter-glass.webp omarchy.webp |
| ristretto | Yaru-yellow | (generated) | n/a | 0-launch.webp 1-color-curves.webp 2-coffee-beans.jpg 3-industrial-moon.webp omarchy.webp |
| rose-pine | Yaru-blue | Rosé Pine Dawn · mvllow.rose-pine | yes | 1-funky-shapes.webp 2-dot-map.webp 3-omarchy-plants.webp omarchy.webp |
| solitude | Yaru-sage-dark | Noctokai · farigab.noctokai-theme | 404 | 1-on-pole.webp 2-wreakage.webp 3-climb.jpg 4-ether.webp 5-eyed.jpg |
| tokyo-night | Yaru-magenta | Tokyo Night · enkia.tokyo-night | yes | 0-winding-road.webp 1-quattro.webp 2-swirl-buck.webp 3-sunset-lake.webp 4-omakub.webp 5-oma-cityscape.jpg 6-oma.webp omarchy.webp |
| vantablack | Yaru-gray | (generated) | n/a | 0-dot-hands.webp 1-twisted-stairs.webp 2-layers-deep.webp 3-layers-stacked.webp omarchy.webp |
| white | Yaru-grey | (generated) | n/a | 1-white.webp 2-white.webp 3-white.webp omarchy.webp |

Total `themes/` size 64 MB — another reason not to bundle.

---

## 3. Design principles worth porting → concrete LinPad mapping

| # | Omarchy principle (evidence) | LinPad mapping |
|---|---|---|
| P1 | **One palette, everything generated** (`colors.toml` + `default/themed/*.tpl`) | `ColorTheme` struct in DesktopKit = the exact `colors.toml` schema; guest renders per-app files from the same file. Native shell and guest read one source. |
| P2 | **Few tokens for chrome**: v3 bar/launcher/notifications/OSD/lock used only bg, fg, accent (+red) | Map DesktopTheme from 5 tokens (§4.1). Don't add per-surface colour knobs to the UI. |
| P3 | **Focus = coloured 2 px border**, inactive = neutral grey `rgba(595959aa)`; gradients allowed (`looknfeel.lua`: `border_size = 2`) | Add `borderActive` (Color or `[Color]` + angle) and `borderInactive`; draw a 2 pt stroke on the focused window in tiling mode (and optionally floating). Remove other focus cues when it's on. |
| P4 | **Consistent gaps**: `gaps_in = 5`, `gaps_out = 10`; shell edge gap = half of gaps_out; corner radius of every popup = Hyprland rounding (`shell/Commons/Style.qml`) | Split `WindowManager.tilingGap` (today one 8 pt value used inside *and* at the edge, `WindowGeometry.tileFrames` insets by `gap`) into `gapsIn`/`gapsOut`; derive panel/toast/launcher corner radius from `theme.cornerRadius` everywhere. |
| P5 | **Toggle gaps/borders/rounding off** in one key (`Super+Shift+Backspace` → `toggles/window-no-gaps.lua`) and window transparency (`Super+Backspace`, default opacity `0.985/0.96` active/inactive) | Shortcut `⌃⌥⇧⌫` "Zen tiling" (gaps 0, border 0, radius 0). Inactive-window dim (0.96) as an option, not default (iPad GPU cost). |
| P6 | **Restrained motion**: popin 87 % with easeOutQuint (`windowsIn` speed 4.1), fade-out linear, **workspace slide disabled**, border colour animates (`border` 5.39) | `DesktopMotion`: window open = scale 0.87→1 + fade, `timingCurve(0.23, 1, 0.32, 1, ~0.41 s)`; close faster (~0.15 s linear); animate border colour on focus change; keep workspace switch instant/crossfade. |
| P7 | **Typography**: one mono family (JetBrainsMono Nerd Font) for terminal and shell, size 9 in foot, shell base 12 px with a rem scale (caption 10 … display 28) | Add a `fontBase` token and a derived scale to DesktopTheme; offer "Mono UI" toggle. Ship JetBrains Mono (OFL) in the guest for foot (`MONO_FONT`). |
| P8 | **Minimalism**: no shadows, no blur (`decoration.shadow/blur = false`), rounding 0, solid opaque surfaces, square bar | Make a 6th layout style `omarchy` (tiling-first, thin top bar, radius 0, no shadow, solid panel) rather than bending existing styles. Colour themes apply to all styles. |
| P9 | **Keyboard-first menu tree** (`default/omarchy/omarchy-menu.jsonc`): root = Apps, Learn, Trigger, Style, Setup, Install, Remove, Update, About, System; dotted ids form the tree; every submenu is a deep-linkable route (`omarchy menu summon style.theme`); search across labels + descriptions; `checked` ✓ for current choice; `disabled` ✓ for installed | A data-driven `DesktopMenu` (JSON in bundle + user overlay) opened with `⌃⌥Space`; routes `style.theme`, `style.background`, `system`, `capture`. Reuse the launcher's search field. |
| P10 | **Image pickers for theme & wallpaper** (`omarchy-theme-switcher`: filterable grid of `preview.png`, current one pre-selected, thumbnails cached by mtime signature) | Theme picker = horizontal carousel of live previews (§4.7); Background picker = carousel filtered to the current theme's wallpapers + favourites. |
| P11 | **Wallpaper belongs to the theme**, remembered per theme (`theme-backgrounds/<theme>`), cycled with a key, cross-faded on theme change | WallpaperSettings gains `perTheme: [themeID: WallpaperSource]`; theme switch restores it; `⌃⌥⇧B` cycles; crossfade 0.35 s. |
| P12 | **Notifications**: top-right stack, 420 px wide, 2 px border = active-border colour, padding 10×15, timeouts 5 s/8 s/critical sticky, hover pauses, history of 10, DND with a narrow punch-through (own action confirmations, critical from CLI) | ToastStack: border = `borderActive`, bg = background, text = fg, countdown bar = accent; hover/long-press pauses; history (10) in a panel; DND toggle `⌃⌥,`. |
| P13 | **Lock screen**: wallpaper + centred input card bg@0.8, border = active border, red border + text on error, accent selection | LinPad lock / boot splash card uses same tokens. |
| P14 | **Screenshot UX**: one key, region/window/full, auto copy + save, 10 s preview with pin/edit, `R` = repeat last region | Native: `⌃⌥⇧4`-style capture of the desktop surface (UIGraphicsImageRenderer of the window view) → clipboard + Files + toast thumbnail. |
| P15 | **Live retint, no restarts where possible** (OSC to foot ptys; VS Code theme hot-reload via `_watch`; GTK only for new windows) | Same for LinPad: OSC retint of open foot terminals; native windows update instantly; offer "Restart Linux windows to apply" only for GTK/Qt apps (CONTRACT.md already says running apps keep their look). |
| P16 | **Atomic, serialized apply** (staging dir + `mv`, `flock`, state written last) | Mirror CONTRACT.md's pattern: build `.colors.tmp`, rename, write `current-colors` last; a single serial queue in the shell for apply requests. |
| P17 | **Theme = data; code from strangers is filtered** (§1.6) | LinPad installs accept only `colors.toml`, images, `icons.theme`, `vscode.json` *name only* (never auto-install its extension), static per-app colour files; reject symlinks and executables. |

---

## 4. LinPad implementation spec

### 4.1 New axis: Color Theme (independent of layout Style)

```
Layout style  (existing): ish | windows | macos | ubuntu | kylin   → shapes, panel layout, buttons, materials
Color theme   (new)     : style-default | tokyo-night | catppuccin | … | user themes
Appearance    (existing DesktopAppearance) → ignored when a color theme is active (theme `mode` decides)
```

Storage: `@AppStorage("desktop.colorTheme")`, empty = "Style colours" (today's behaviour, zero regression).
`DesktopSettings.accentColorKey` stays; when a colour theme is active the accent picker shows "From theme" + override.

Native model (DesktopKit `Core/Styles/ColorTheme.swift`):

```swift
struct ColorTheme: Codable, Identifiable {   // 1:1 with colors.toml
    var id: String; var name: String; var isDark: Bool
    var accent, selection, muted: RGB
    var background, darkBackground, darkerBackground, lighterBackground: RGB
    var foreground, darkForeground, lightForeground, brightForeground: RGB
    var ansi: [RGB]            // 16, resolved with Omarchy's fallback rules (§1.2)
    var borderActive: BorderPaint   // .solid(RGB) | .gradient([RGBA], angle)
    var borderInactive: RGBA
    var iconTheme: String?     // icons.theme
    var vscode: (name: String, extension: String?)?
    var wallpapers: [WallpaperRef]
}
```

Resolution order in `DesktopStyleSpec.theme(base:isDark:)` (DesktopStyle.swift): style palette → **colour theme overlay** →
user accent override. Shapes (`cornerRadius`, bar heights, button shapes) remain the style's.

### 4.2 DesktopTheme token mapping

| DesktopTheme (API.swift) | From colour theme | Notes |
|---|---|---|
| `accent` | `accent` | |
| `panelBackground` | `background` @ style's panel alpha (0.92 ish, 0.72 macos …) | keep each style's translucency, recolour only |
| `windowBackground` | `background` | |
| `titleBarActive` | `mix(background, foreground, 8%)` | Omarchy has no title bars; this keeps them quiet |
| `titleBarInactive` | `background` | |
| `primaryText` | `foreground` | |
| `secondaryText` | `mix(foreground, background, 34%)` | Omarchy's placeholder formula (`shell.toml.tpl [lock]`) |
| `separator` | `mix(background, foreground, 15%)` | |
| `cornerRadius` | unchanged (style) | `omarchy` layout style sets 0 |
| `monospacedFontSize` | unchanged | |
| **new** `selection` | `selection` | text/list selection, launcher highlight (fill α 0.18 like `[controls] selected`) |
| **new** `urgent` | `red` | badges, close-hover, error borders |
| **new** `borderActive` / `borderInactive` / `borderWidth` | §2.1 / 2 pt | focus ring (P3) |
| **new** `gapsIn` / `gapsOut` | 5 / 10 (style default) | replaces single `tilingGap`; Settings slider edits both proportionally |
| **new** `hoverFill` / `pressedFill` | `foreground` @ 0.08 / 0.22 | from `[controls]` alphas |
| **new** `scrim` | `background` @ 0.5 | launcher / overview / menu backdrop |

Because `DesktopTheme` is public API (API.swift: "Changes here affect all three"), add the new fields with defaults so
existing initialisers compile unchanged.

### 4.3 Guest: `ish-apply-colors` (new; sibling of `ish-apply-style`, same conventions as CONTRACT.md)

```
ish-apply-colors <theme-id> | --current | --list | --none
```

Theme sources: `/usr/share/ish/colors/themes/<id>/` (built-in: `colors.toml`, `icons.theme`, `vscode.json` only — no images)
and `~/.config/linpad/themes/<id>/` (user/git). Templates: `/usr/share/ish/colors/templates/*.tpl`, user
`~/.config/linpad/themed/*.tpl` first. Steps mirror §1.4: lock (`flock` or `mkdir` lock), stage
`~/.local/state/linpad/next-theme`, overlay, render, `mv` to `~/.local/state/linpad/current/theme`, then write
`/usr/share/ish/current-colors` (one line) **last**. Exit 0 = done. The shell watches `current-colors` mtime like
`current-style`. Rendering: port `omarchy-theme-set-templates` (bash+awk) to POSIX sh + awk (busybox), keep
placeholder syntax so Omarchy templates stay drop-in.

Generated files and how each app picks them up:

| App | Generated file | Hook-up | Live? |
|---|---|---|---|
| foot | `current/theme/foot.ini` (port `foot.ini.tpl`; section `[colors]` — Alpine foot may predate `[colors-dark]`, verify version) | `wl-bridge/guest/ish-terminal`: after `--config=/etc/ish/foot/<style>.ini`, the style ini gets `include=~/.local/state/linpad/current/theme/foot.ini` when a colour theme is active (style ini keeps font/padding; theme file only colours). | yes: OSC 10/11/12/17/19 + OSC 4;0-15 written to each foot child's pty (port `omarchy-theme-osc`; verify `/proc/<pid>/fd/1` readlink works under iSH, else track ptys in `ish-terminal`) |
| GTK 3 (Adwaita, `ish` style) | `~/.config/gtk-3.0/gtk.css` with `@define-color theme_bg_color / theme_fg_color / theme_selected_bg_color / theme_base_color / borders …` + header `/* linpad-colors */` | only when the style's GTK theme is Adwaita; for Fluent/WhiteSur/Yaru/UKUI keep the style's theme, set only `gtk-application-prefer-dark-theme` from `mode` | new windows |
| GTK 4 / libadwaita | `~/.config/gtk-4.0/gtk.css` with libadwaita named colours (`accent_bg_color`, `accent_color`, `window_bg_color`, `window_fg_color`, `view_bg_color`, `headerbar_bg_color`, `card_bg_color`, `popover_bg_color`, `sidebar_bg_color`) | **conflict:** `link_libadwaita()` in ish-apply-style symlinks the style's gtk.css there for non-Adwaita styles. Rule: colour layer writes a real file only when style GTK theme is Adwaita; marker header lets both scripts know who owns the file. | new windows |
| Qt / Kvantum | `/usr/share/Kvantum/LinPad-<id>/` made by recolouring KvGnomeDark (dark) / KvSimplicity (light) | reuse `mk_kvantum_ukui()` from `themes/guest/install.sh` (it already recolours KvSimplicity: window/base/button/text/disabled) → window=bg, base=darker_bg, button=lighter_bg, text=fg, disabled=muted, highlight=accent; write `kvantum.kvconfig theme=` | new windows |
| icons | `icons.theme` → `ish-apply-style --icons <name>` if installed, else nearest installed pack (Yaru-<colour> → Papirus folder colour via `papirus-folders`, or Tela Circle variant) | existing contract, cache rebuild included | yes (shell reloads cache) |
| VS Code (guest `code`) | (a) `vscode.json` extension present on Open VSX → install by id; (b) otherwise render `vscode-theme.json.tpl` into a local extension `local.linpad-theme` (port `omarchy-theme-set-vscode`: version = cksum so VS Code reloads; `"_watch": true`) | edit `workbench.colorTheme` in `~/.config/Code*/User/settings.json` in place (JSONC-safe sed, as Omarchy does) | yes (watch) |
| Firefox ESR | static theme WebExtension (manifest `theme.colors`: frame=dark_bg, toolbar=bg, toolbar_text=fg, tab_line/tab_selected accent, popup=bg, sidebar=bg) → `~/.mozilla/…/extensions` via `policies.json` `ExtensionSettings` (`installation_mode: force_installed`, `file://` URL) | content follows GTK `prefer-dark` → `prefers-color-scheme`; optional `user.js` `ui.systemUsesDarkTheme` = mode | restart |
| btop | `~/.config/btop/themes/linpad.theme` (port `btop.theme.tpl`) + `color_theme = "linpad"` | | next start |
| fastfetch | uses terminal ANSI → nothing to generate; set `display.color.keys = "blue"`, `title = "magenta"` in `wl-bridge/guest/fastfetch` config so logo/keys follow the theme | | automatic |
| neovim/helix (if installed) | port `neovim.lua` per theme (built-in themes only) / `helix.toml.tpl` | | restart |

### 4.4 Native shell surfaces

| Surface | Tokens |
|---|---|
| Panels / bars / dock | bg @ style alpha, fg, accent for active indicators, `urgent` for badges |
| Window chrome | titleBar*, focus ring `borderActive` 2 pt (tiling always; floating optional), inactive `borderInactive` |
| Launcher / Run dialog / menu | card bg, border = `borderActive` @0.25 (Omarchy `[menu] selected-border-alpha`), scrim bg@0.5, selected row fill fg@0.08, selected text accent |
| ToastStack | P12 |
| Overview / switcher | scrim bg@0.5; selected tile border accent 2 pt, others fg@0.28 (`[image-picker]`) |
| Built-in Terminal app (TerminalApp.swift) | 16 ANSI + fg/bg/cursor = `bright_fg`, selection |
| TextEditor syntax (SyntaxHighlighter.swift) | keyword=magenta, string=green, number=orange, comment=muted, type=yellow, function=blue (same mapping as `vscode-theme.json.tpl`) |

### 4.5 Wallpapers per theme

- Do not bundle Omarchy images. Each built-in theme ships a `wallpapers.json`: `[{file, sourceURL (pinned raw URL, §2.3), license: "unstated"}]`
  plus a **Wallhaven query**: `{q, colors: [nearest of WallhavenAPI.colors to background & accent], categories: "general", purity: "sfw", sorting: "toplist"}`.
- Picker shows "Theme wallpapers": Wallhaven results first (licence = Wallhaven uploader's, already handled by the
  existing browser with `attribution`/`sourceURL` on `WallpaperItem`), Omarchy originals behind an explicit
  "Download from Omarchy (personal use)" action — never in the App Store build.
- `WallpaperSettings.perTheme[themeID]`; slideshow gains `Source.theme`.

### 4.6 Shortcuts (add to `DesktopCommand` table; `windowKeys = ⌃⌥`)

| Keys | id | Action |
|---|---|---|
| `⌃⌥⇧Space` | `theme.picker` | Open theme picker (repeat = next theme while open) |
| `⌃⌥⇧T` | `theme.next` | Cycle to next theme without UI (toast "Theme: Nord") |
| `⌃⌥⇧B` | `background.next` | Next wallpaper of current theme |
| `⌃⌥Space` | `menu` | LinPad menu (P9). Check: `launcher` uses `⌘⇧Space` in ⌘ mode and `⌃⌥A` otherwise — no clash |
| `⌃⌥⇧⌫` | `tiling.zen` | Gaps/borders/radius off toggle |
| `⌃⌥K` | `help.keys` | Keybinding sheet generated from `DesktopCommand.all` (already a single table) |
| `⌃⌥,` / `⌃⌥⇧,` | `notifications.dismiss` / `.dnd` | |

In ⌘ mode use `⌘⇧⌥Space` etc.; verify none are swallowed by iPadOS (`⌘Space` is Spotlight).

### 4.7 Theme picker UI

- Settings → Appearance → "Color Theme" row + the `⌃⌥⇧Space` overlay. Horizontal carousel (Omarchy image-picker:
  scrim bg@0.5, selected border accent, unselected fg@0.28), filter field, current theme pre-selected, ✓ on current.
- **Live preview card rendered natively** (no screenshots needed): a mini desktop drawn with the candidate theme's
  tokens — panel strip, two tiled windows with focus border, a terminal snippet showing the 16 colours, accent button,
  current wallpaper thumbnail. Arrow keys move, Return applies, Esc reverts; hovering/arrowing applies a *native-only*
  preview (no guest work) and only Return runs `ish-apply-colors`.
- Sections: Dark · Light · Installed from Git. Footer: "Install from Git URL…", "Open themes folder", "Pair light/dark"
  (optional mapping so `Appearance = Automatic` can flip e.g. catppuccin ↔ catppuccin-latte).

### 4.8 Install from Git URL

`ish-apply-colors --install <url>` (guest, needs network): validate as Omarchy does (§1.6: https or `git@host:path`,
no leading `-`, no `ext::`/`fd::` transports), name = basename − `.git` − `omarchy-` − `-theme`, regex
`^[a-z0-9_][a-z0-9._+-]*$`; `git clone --depth 1` into `~/.config/linpad/themes/<name>`; staging copies only
`colors.toml` (or derives it from `alacritty.toml`, never copying that file), `backgrounds/*` (images only, size cap),
`preview.png`, `icons.theme`, `vscode.json` (name used to *select* an already-installed theme; extension never
auto-installed), `btop.theme`; drops symlinks, `*.lua`, terminal configs, anything executable. Omarchy community themes
(`omarchy.org/themes`) therefore work unmodified. `--update` = `git pull` for themes with `.git`; `--remove <name>`.

---

## 5. Licensing

| Item | Licence | Reuse in LinPad |
|---|---|---|
| Omarchy code, templates, scripts, `colors.toml` files | MIT, "Copyright (c) David Heinemeier Hansson" (`LICENSE`; GitHub reports MIT) | OK to port templates/scripts/palette files with the MIT notice. |
| Palettes (hex values) | facts / not copyrightable in themselves | OK; still credit the upstream theme authors below. |
| Wallpapers in `themes/*/backgrounds` | **not stated**; many are third-party art (e.g. `2-night-hawks.webp`, `1-totoro.webp`) | Do not copy into the repo or app bundle. Link by pinned URL; optional user-initiated download for personal use. |
| `preview*.png`, `unlock.png`, `omarchy.webp`, logo | Omarchy branding | Don't ship; render our own previews (§4.7). Don't use the "Omarchy" name in UI beyond attribution. |
| Upstream palettes | Tokyo Night — enkia/tokyo-night-vscode-theme (MIT); Catppuccin (MIT); Gruvbox — Omarchy's values match sainnhe/gruvbox-material (MIT), original morhetz/gruvbox (MIT); Nord — Arctic Ice Studio (MIT); Everforest — sainnhe (MIT); Kanagawa — rebelot/kanagawa.nvim (MIT); Rosé Pine (MIT); Flexoki — kepano (MIT); Miasma — xero/miasma.nvim (verify, MIT expected) | Credit in About → Acknowledgements. |
| Ristretto | Name and palette appear to follow Monokai Pro's "Ristretto" filter (not confirmed in the repo) — **Monokai Pro is a commercial theme** | Ship the palette under Omarchy's name "Ristretto" only if comfortable; safer to omit or rename and tweak. |
| Omarchy-original / community themes (Ethereal, Hackerman, Last Horizon, Lumon, Lupine, Matte Black, Osaka Jade, Retro-82, Solitude, Vantablack, White) | ship under Omarchy MIT in its repo; individual authors in Omarchy history (shallow clone: not checked) | OK under MIT with attribution; "Lumon" references *Severance* (Apple TV+) — rename for the App Store build. |
| JetBrains Mono / Nerd Font | OFL-1.1 / MIT | OK in guest. |
| VS Code extensions | each extension's own licence | Install from Open VSX at user request only. |

Attribution text (About → Acknowledgements, and `/usr/share/ish/colors/LICENSE`):

> Color themes and theme templates adapted from Omarchy (https://github.com/omacom/omarchy),
> Copyright (c) David Heinemeier Hansson, MIT License. Palettes originate from Tokyo Night (enkia),
> Catppuccin, Gruvbox Material (sainnhe), Nord (Arctic Ice Studio), Everforest (sainnhe),
> Kanagawa (rebelot), Rosé Pine, Flexoki (Steph Ango) and the Omarchy community; each under its
> own MIT licence.

---

## 6. Open questions / verify before building

1. foot version in the Alpine rootfs: `[colors]` vs `[colors-dark]` section name, and whether `include=` may follow a style ini.
2. `/proc/<pid>/fd/1` readlink under iSH for OSC retint; fallback = `ish-terminal` records its pty in `$XDG_RUNTIME_DIR`.
3. Which VS Code build is the guest `code` (Code-OSS vs Microsoft) → extension gallery (Open VSX vs Marketplace) and settings path.
4. Firefox ESR policy path in the guest (`/usr/lib/firefox-esr/distribution/policies.json`?) and whether forced local XPIs are accepted unsigned (ESR allows `xpinstall.signatures.required=false`).
5. Whether Yaru colour variants (`Yaru-magenta` …) are worth installing (~MBs each) vs mapping to Papirus folder colours.
