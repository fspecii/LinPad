# Desktop styles: sources, versions, licences

Installed by `themes/guest/install.sh` (iSH-ARM64 repo); pinned in `versions.sh`.
No Microsoft or Apple fonts, icons or artwork are included. Segoe UI and SF Pro are
replaced by Noto Sans and Inter.

| Component | Used by | Source | Version | Licence |
|---|---|---|---|---|
| Fluent-gtk-theme (Fluent-Light, Fluent-Dark; GTK 3/4 only) | windows | https://github.com/vinceliuice/Fluent-gtk-theme | tag 2025-04-17 | GPL-3.0 |
| Fluent-icon-theme (Fluent, Fluent-light, Fluent-dark) + Fluent cursors | windows | https://github.com/vinceliuice/Fluent-icon-theme | tag 2026-07-27 | GPL-3.0 |
| Fluent Kvantum theme | windows (Qt) | https://github.com/vinceliuice/Fluent-kde | 44794f29c89de994b0179aebabd2f5776c90d236 | GPL-3.0 |
| WhiteSur-gtk-theme (WhiteSur-Light, WhiteSur-Dark; prebuilt release tarballs) | macos | https://github.com/vinceliuice/WhiteSur-gtk-theme/tree/2026-09-10/release | tag 2026-09-10 | MIT |
| WhiteSur-icon-theme (WhiteSur, WhiteSur-light, WhiteSur-dark) | macos | https://github.com/vinceliuice/WhiteSur-icon-theme | tag 2026-09-10 | GPL-3.0 |
| WhiteSur-cursors | macos | https://github.com/vinceliuice/WhiteSur-cursors | e190baf618ed95ee217d2fd45589bd309b37672b | GPL-3.0 |
| WhiteSur Kvantum theme | macos (Qt) | https://github.com/vinceliuice/WhiteSur-kde | cf4df59ce91004f7ea39358b1b8ff917d5c329f7 | GPL-3.0 |
| Yaru GTK theme (Yaru, Yaru-dark; from `yaru-theme-gtk_24.04.2-0ubuntu1_all.deb`) | ubuntu | http://archive.ubuntu.com/ubuntu/pool/main/y/yaru-theme/ | 24.04.2-0ubuntu1 | GPL-3.0 (themes), CC-BY-SA-4.0 (assets); `licenses/yaru-theme-gtk.copyright` |
| Yaru icons (Yaru, Yaru-dark; cursors dropped; from `yaru-theme-icon_24.04.2-0ubuntu1_all.deb`) | ubuntu | same | 24.04.2-0ubuntu1 | CC-BY-SA-4.0 / GPL-3.0; `licenses/yaru-theme-icon.copyright` |
| UKUI GTK themes (ukui-white, ukui-black; from `ukui-gtk-theme_4.0.0.1-1_all.deb`) | kylin | https://deb.debian.org/debian/pool/main/u/ukui-themes/ | 4.0.0.1-1 | GPL-3.0; `licenses/ukui-gtk-theme.copyright` |
| ukui-icon-theme-default (no @2x copies, Kylin start-menu glyph removed) + dark-sense cursors (from `ukui-icons-theme_4.0.0.1-1_all.deb`) | kylin | same | 4.0.0.1-1 | GPL-3.0 (Moka-derived); `licenses/ukui-icons-theme.copyright` |
| KvUKUI, KvUKUIDark (KvSimplicity recoloured with UKUI tokens) | kylin (Qt) | https://github.com/tsujan/Kvantum | tag V1.1.3 | GPL-3.0 |
| KvYaru, KvGnomeDark Kvantum themes | ubuntu, ish (Qt) | https://github.com/tsujan/Kvantum | tag V1.1.3 | GPL-3.0 |
| Adwaita (GTK built-in) + adwaita-icon-theme (cursors) | ish | Alpine 3.21 `gtk+3.0`, `adwaita-icon-theme` | Alpine 3.21 | LGPL-2.1 / CC-BY-SA-3.0 |
| Papirus, Papirus-Dark | ish | Alpine 3.21 `papirus-icon-theme` | 20231201-r0 | GPL-3.0 |
| Kvantum engine (Qt 5 and Qt 6 styles) | all (Qt) | Alpine 3.21 `kvantum`, `kvantum-qt5` | 1.1.3-r0 | GPL-3.0 |
| Inter | macos | Alpine 3.21 `font-inter` | 4.1-r0 | OFL-1.1 |
| Ubuntu font family | ubuntu | Alpine 3.21 `font-ubuntu` | 0.869-r0 | Ubuntu Font Licence 1.0 |
| Cantarell | ish | Alpine 3.21 `font-cantarell` | 0.303.1-r2 | OFL-1.1 |
| Noto Sans / Noto Sans Mono | windows, kylin, all (mono) | Alpine 3.21 `font-noto` | Alpine 3.21 | OFL-1.1 |

Pruned from every GTK theme: GNOME Shell, Cinnamon, Metacity, XFWM, Plank and GTK 2
directories (DesktopKit draws the window chrome; nothing under ishwl reads them).

## Audio and video

| Component | Source | Version | Licence |
|---|---|---|---|
| PulseAudio, pulseaudio-utils, alsa-plugins-pulse | Alpine 3.21 | 17.0-r4, 1.2.12-r0 | LGPL-2.1 |
| VLC, vlc-qt | Alpine 3.21 | 3.0.21-r3 | GPL-2.0 / LGPL-2.1 |
| `libwl_shm_plugin.so` (VLC's `modules/video_output/wayland/shm.c`, unchanged) | https://github.com/videolan/vlc/tree/3.0.21 | 3.0.21 | LGPL-2.1 |
| `libishxdg_plugin.so` (VLC's xdg-shell window provider ported to xdg_wm_base) | `themes/guest/vlc/xdg-wm-base.c` | — | LGPL-2.1 |
| FFmpeg (for test media) | Alpine 3.21 | 6.1.2-r1 | LGPL-2.1 / GPL-2.0 |
