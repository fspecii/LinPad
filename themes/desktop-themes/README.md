# Desktop themes

One-tap looks in Themes › Gallery › Desktop Themes: an era style drawn natively by DesktopKit,
a colour theme (with a dark partner where it fits), styling, an original wallpaper, and the
GTK/Qt/icon/font set Linux apps get.

| Theme | Style id | Colour themes | Wallpaper | Linux GTK (pack) |
|---|---|---|---|---|
| Luna | `luna` | luna | meadow | LinPad-Luna (`luna`) |
| Aero | `aero` | aero / aero-night | aurora / aurora-night | LinPad-Aero (`aero`) |
| Aero Night | `aeronight` | aero / aero-night | aurora-night | LinPad-AeroNight (`aeronight`) |
| Classic 98 | `classic` | classic-98 | solid teal | LinPad-Classic (`classic`) |
| Platinum | `platinum` | platinum | platinum | LinPad-Platinum (`platinum`) |
| Aqua, Aqua Metal | `aqua` | aqua | aqua | LinPad-Aqua (`aqua`) |
| Modern Mac | `macos` | style colours, light/dark follows the iPad | sonora | WhiteSur |
| Berry | `berry` | berry | berry | Adwaita, recoloured |
| Dot Matrix | `dotmatrix` | dot-matrix / dot-matrix-dark | dots-light / dots-dark | Adwaita, recoloured |

- Native: `desktop/DesktopKit/Sources/DesktopKit/Core/Styles/Era*.swift`,
  `DesktopThemePresets.swift`.
- Guest: `themes/guest/styles/<style>.conf`, `themes/guest/ish-style-packs` (sources,
  licences and checksums in `themes/guest/MANIFEST.md`).
- Palettes: `colors/` (CC0), copied into `themes/omarchy/guest/colors` by
  `themes/omarchy/make-palettes.py`; `widgets=style` in theme.conf keeps the style's GTK.
- Wallpapers: `make-wallpapers.py` (CC0, procedural).

No vendor names, logos, fonts or artwork are shipped; the panels use the LinPad mark.
