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
- New keys may be added; unknown keys must be ignored. `version` changes only for
  incompatible changes.

### Names always present (when the theme has them)

Every `Icon=` of `/usr/share/applications/*.desktop` and
`/usr/local/share/applications/*.desktop`, plus:

`utilities-terminal system-file-manager accessories-text-editor web-browser
utilities-system-monitor system-software-install preferences-system folder user-home
text-x-generic image-x-generic video-x-generic audio-x-generic application-x-executable
user-trash multimedia-video-player`

and the places set: `folder-open folder-documents folder-download folder-music
folder-pictures folder-videos folder-desktop folder-publicshare folder-templates
folder-remote user-desktop user-trash-full user-bookmarks network-workgroup
network-server drive-harddisk drive-removable-media drive-optical media-removable
computer start-here`.

### Lookup rules (what the guest does)

Theme chain: the style's icon theme, its `Inherits=` chain, then `hicolor`, then
`/usr/share/pixmaps`. In the first theme that has the name: a scalable or ≥48 px SVG,
else a ≥128 px PNG, else any SVG, else the largest PNG. Symbolic directories are skipped
unless the name ends in `-symbolic`. If nothing matches, the last `-component` is
dropped and the lookup repeats (`multimedia-video-player` → `multimedia-video` →
`multimedia`), as GTK does. SVGs are rasterised with `rsvg-convert`, PNG/XPM with
`gdk-pixbuf-thumbnailer`.

## Window chrome hints for the native shell

The GTK `gtk-decoration-layout` each style writes, for matching the native title bar:
windows/ubuntu/kylin/ish `menu:minimize,maximize,close` (buttons right), macos
`close,minimize,maximize:menu` (buttons left).
