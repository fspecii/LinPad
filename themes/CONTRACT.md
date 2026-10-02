# Desktop style and icon cache contract (guest → native shell)

The guest command `ish-apply-style` (installed from `themes/guest/ish-apply-style`) owns
these files. The native SwiftUI shell only reads them, through the fakefs data
directory: guest path `/usr/share/ish/...` is host path
`<LinuxGraphicsHost.guestRootURL>/usr/share/ish/...`. The shell must never create or
write files there (host-created files have no fakefs metadata and are invisible to the
guest).

## Styles

| id | look | GTK theme (light / dark) | icon theme | cursor | font | Kvantum (Qt) |
|---|---|---|---|---|---|---|
| `windows` | Windows 11 | Fluent-Light / Fluent-Dark | Fluent / Fluent-dark | Fluent-cursors | Noto Sans 10 | Fluent / FluentDark |
| `macos` | macOS | WhiteSur-Light / WhiteSur-Dark | WhiteSur / WhiteSur-dark | WhiteSur-cursors | Inter 10 | WhiteSur / WhiteSur-Dark |
| `ubuntu` | Ubuntu 24.04 | Yaru / Yaru-dark | Yaru / Yaru-dark | Adwaita | Ubuntu 11 | KvYaru / KvGnomeDark |
| `kylin` | Kylin / UKUI 4 | ukui-white / ukui-black | ukui-icon-theme-default | dark-sense | Noto Sans 10 | KvUKUI / KvUKUIDark |
| `ish` (default) | iSH dark | Adwaita (dark) | Papirus / Papirus-Dark | Adwaita | Cantarell 11 | KvGnomeDark |
| `tiler` | minimal tiling | Adwaita (dark) | Papirus / Papirus-Dark | Adwaita | JetBrains Mono 10 | KvGnomeDark |
| `luna` | desktop theme Luna (XP era) | LinPad-Luna* / Adwaita | Papirus / Papirus-Dark | Adwaita | DejaVu Sans 9 | Fluent / KvGnomeDark |
| `aero` | desktop theme Aero (7 era) | LinPad-Aero* / Adwaita | Fluent / Fluent-dark | Fluent-cursors | Noto Sans 9 | Fluent / FluentDark |
| `aeronight` | desktop theme Aero Night (Vista era) | LinPad-AeroNight* / Adwaita | Fluent / Fluent-dark | Fluent-cursors | Noto Sans 9 | Fluent / FluentDark |
| `classic` | desktop theme Classic 98 | LinPad-Classic* | Papirus | Adwaita | DejaVu Sans 9 | KvYaru |
| `platinum` | desktop theme Platinum (classic Mac era) | LinPad-Platinum* | Qogir (else Papirus) | Adwaita | DejaVu Sans Condensed 9 | KvYaru |
| `aqua` | desktop theme Aqua (early OS X) | LinPad-Aqua* / WhiteSur-Dark | WhiteSur / WhiteSur-dark | WhiteSur-cursors | DejaVu Sans 9 | WhiteSur |
| `berry` | desktop theme Berry (dark) | Adwaita (recoloured) | Papirus-Dark | Adwaita | Noto Sans 10 | KvGnomeDark |
| `dotmatrix` | desktop theme Dot Matrix | Adwaita (recoloured) | kora-pgrey (else Papirus) | Adwaita | Noto Sans Mono 10 | KvUKUI / KvUKUIDark |

\* Installed on first use by `ish-style-packs` (the conf's `STYLE_PACKS`): `ish-apply-style`
downloads the pack (pinned, sha256-checked, a few MB; Chicago95 28 MB) and falls back to
Adwaita when it cannot. `ish-style-packs list | install <id> | ensure <style> | remove <id>`.
A conf may also name `ICON_FALLBACK` for an icon pack that is not in every image. The
desktop themes' colour palettes (`themes/desktop-themes/colors`) carry `widgets=style` in
theme.conf where the GTK theme's own bevels are the look: `ish-apply-colors` then leaves GTK
and Kvantum to the style and colours terminals, btop, VS Code and Firefox only.

Default variant: `light` for windows, macos, ubuntu and kylin; `dark` for ish.

## Switching

Run in the guest (e.g. `LinuxHost.run`):

```
ish-apply-style <windows|macos|ubuntu|kylin|ish> [light|dark]
```

Exit status 0 means settings and cache are both written. It takes a few seconds (one
SVG rasterisation per icon and size). `ish-apply-style --current` prints the active id,
`--list` the ids, `--cache-only` rebuilds the cache for the active style (run it after
installing an app so its icon is cached).

### Icon pack independent of the style

```
ish-apply-style --icons <icon-theme|match>   # e.g. Papirus-Dark; "match" follows the style again
ish-apply-style --icon-themes                # installed icon themes: "<id>\t<Name=>" per line
ish-apply-style --icon-previews              # 64 px previews per theme (see Files)
```

`--icons` stores the choice in `/usr/share/ish/icon-theme`, rewrites the GTK/Qt settings
and rebuilds the cache under the *current style's* key, then rewrites `current-style`, so
readers reload exactly as after a style switch. The choice survives style switches (each
switch uses it while the theme stays installed); without the file, or after `match`, the
style's own icon theme is used. `index.json` gains `"styleIconTheme"`, the style's own
theme, next to `"iconTheme"`, the one actually rendered.

Linux apps that are already running keep their old look (no XSETTINGS on Wayland, and
the session's GSettings backend is `memory`); apps started afterwards use the new one.
The shell may offer to restart open Linux windows.

### More icon packs ("Get More Icon Packs…")

```
ish-icon-packs list              # id \t name \t installed(0|1) \t approx MB \t theme ids (space-separated) \t licence
ish-icon-packs install <id>...   # needs network; prints "progress: installing <id>" / "progress: installed <id>"
ish-icon-packs remove <id>...    # packs owned by a desktop style (whitesur, fluent, yaru, ukui) are refused
```

Exit status 0 means done; on failure the last stderr line says why. `install` ends by
running `ish-apply-style --icon-previews`, so new themes have previews once it returns.
Installing a pack can take minutes under emulation (Tela Circle about 9 min, Candy about
30 s on an M4 host), so run it in the background and show the progress lines. After that,
`ish-apply-style --icons <theme id>` selects one of the pack's themes. Packs in the image
by default: adwaita, papirus, breeze, tela-circle, colloid, qogir, numix-circle, kora;
candy, reversal, tela-circle-purple and tela-circle-green install on demand.

## Files

```
/usr/share/ish/current-style                 one line: the active style id, e.g. "macos\n"
/usr/share/ish/current-style.env             ISH_STYLE, ISH_STYLE_VARIANT, XCURSOR_* (shell var syntax)
/usr/share/ish/icon-cache/<style>/index.json
/usr/share/ish/icon-cache/<style>/<icon-name>.png      128 px
/usr/share/ish/icon-cache/<style>/<icon-name>@2x.png   256 px
/usr/share/ish/icon-theme                    optional: the icon pack override (one line)
/usr/share/ish/icon-previews/<theme>/<name>.png   64 px: folder utilities-terminal system-file-manager
                                             accessories-text-editor web-browser user-trash
```

`current-style` is written last, after the cache for that style is complete, so a
reader that sees a new value there finds a finished cache. Each cache directory is
replaced in one rename (built in `.<style>.tmp`, then moved), so a reader never sees a
half-written one. Watch `current-style` (its mtime, or poll) to notice a switch.

PNGs are RGBA. The icon fits inside the N×N box with its aspect ratio kept; almost all
icons are square, but a few are not, so draw them aspect-fit.

### index.json

```json
{
  "version": 1,
  "style": "macos",
  "variant": "light",
  "iconTheme": "WhiteSur",
  "gtkTheme": "WhiteSur-Light",
  "generated": "2026-10-02T12:00:00Z",
  "sizes": {"1x": 128, "2x": 256},
  "icons": {
    "utilities-terminal": {"1x": "utilities-terminal.png", "2x": "utilities-terminal@2x.png",
                           "source": "/usr/share/icons/WhiteSur/apps/scalable/utilities-terminal.svg"},
    "org.xfce.thunar": {"1x": "org.xfce.thunar.png", "2x": "org.xfce.thunar@2x.png", "source": "..."}
  },
  "desktopEntries": {
    "thunar.desktop": "org.xfce.thunar",
    "vlc.desktop": "vlc"
  },
  "missing": ["some-icon-name"]
}
```

- `icons` keys are icon names exactly as they appear in `Icon=` lines or in the list
  below. File names are relative to the cache directory. A key that is an absolute path
  (`Icon=/opt/app/icon.png`) maps to a file named after its basename without extension;
  any character outside `[A-Za-z0-9._+-]` becomes `_`. Always use the file names from
  the JSON, never build them yourself.
- `desktopEntries` maps each `.desktop` file name (in `/usr/share/applications` or
  `/usr/local/share/applications`) to its `Icon=` value, so the shell can go from a
  launcher entry to `icons[...]` in two lookups.
- `missing` lists names the theme chain could not resolve; fall back to an SF Symbol.
- `source` is informational (the guest file that was rasterised).
- `"symbolic": true` marks a symbolic icon (a one-colour mask from a `-symbolic` file or a
  symbolic directory): draw it as a template tinted with the text colour. Absent means a
  full-colour icon, drawn as is.
- `2x` may name the same file as `1x`: names from `EXACT_ICONS` (below) that are not also
  in `NATIVE_ICONS` are rendered at 128 px only.
- `icons` is authoritative: a name that is not a key is not in the cache, so readers
  need not probe the disk for it.
- New keys may be added; unknown keys must be ignored. `version` changes only for
  incompatible changes.

### Names always present (when the theme has them)

Every `Icon=` of `/usr/share/applications/*.desktop` and
`/usr/local/share/applications/*.desktop`, plus:

`utilities-terminal system-file-manager accessories-text-editor web-browser
utilities-system-monitor system-software-install preferences-system folder user-home
text-x-generic image-x-generic video-x-generic audio-x-generic application-x-executable
user-trash multimedia-video-player`

the app icons the shell asks for (`preferences-desktop-theme`, `preferences-desktop-wallpaper`,
`firefox`, `vscode`, `foot`, … — the full list is `NATIVE_ICONS` in `ish-apply-style`), and the places set: `folder-open folder-documents folder-download folder-music
folder-pictures folder-videos folder-desktop folder-publicshare folder-templates
folder-remote user-desktop user-trash-full user-bookmarks network-workgroup
network-server drive-harddisk drive-removable-media drive-optical media-removable
computer start-here`.

The shell's own controls, places and file types (`EXACT_ICONS` in `ish-apply-style`; the
native names are in DesktopKit `ThemeIconNames` and `FileTypeIcons`, and a DesktopKit unit
test fails when the shell asks for a name the guest does not render):

- places: `user-home folder-home user-desktop drive-harddisk drive-harddisk-system
  folder-temp folder-recent user-trash user-trash-full folder-pictures folder-remote
  drive-removable-media inode-directory`, …
- file types: freedesktop mimetype icon names (`text-x-python`, `image-png`,
  `application-pdf`, `application-vnd.oasis.opendocument.text`, …) and the
  shared-mime-info generic icons (`text-x-script`, `package-x-generic`,
  `x-office-document`, `font-x-generic`, …); the shell walks the chain type → alias
  spellings → generic icon → `<media>-x-generic` → `text-x-generic`.
- actions, symbolic first: `go-previous go-next go-up folder-new document-new view-refresh
  view-grid view-list view-app-grid open-menu view-more sidebar-show document-edit
  edit-clear-all user-trash media-eject drive-harddisk list-add start-here
  window-minimize window-maximize window-restore window-close`, each as `<name>-symbolic`
  and (where it exists) the full-colour `<name>`.

### Lookup rules (what the guest does)

Theme chain: the style's icon theme, its `Inherits=` chain, then `hicolor`, then
`/usr/share/pixmaps`. In the first theme that has the name: a scalable or ≥48 px SVG,
else a ≥128 px PNG, else any SVG, else the largest PNG. Symbolic directories are skipped
unless the name ends in `-symbolic`; such a name takes the file in a symbolic directory
first (some packs keep a coloured icon of the same name in their sized directories). If
nothing matches, the last `-component` is dropped and the lookup repeats
(`multimedia-video-player` → `multimedia-video` → `multimedia`), as GTK does. Names in
`EXACT_ICONS` skip that fallback (the shell has its own chain, and `text-x-python` must
not become `text`); a `-symbolic` one may fall back to the full-colour name only. SVGs are rasterised with `rsvg-convert`, PNG/XPM with
`gdk-pixbuf-thumbnailer`.

## Window chrome hints for the native shell

The GTK `gtk-decoration-layout` each style writes, for matching the native title bar:
windows/ubuntu/kylin/ish `menu:minimize,maximize,close` (buttons right), macos
`close,minimize,maximize:menu` (buttons left).
