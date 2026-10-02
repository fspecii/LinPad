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

## Icon packs (Settings › Icons)

Managed by `ish-icon-packs` (catalogue inside the script; GitHub tarballs are pinned to a
tag or commit and checked against the sha256 below). Every pack is stripped to scalable +
16–256 px (real `@2x`/`@3x` copies and 512+ px directories removed). Sizes are apparent
sizes after stripping. "Base" packs are in the image; the others install on demand.

| Pack (id) | Themes | Source | Version / sha256 of tarball | Licence | MB | Files | In image |
|---|---|---|---|---|---|---|---|
| Adwaita (`adwaita`) | Adwaita | Alpine `adwaita-icon-theme` | 47.0-r0 | LGPL-3.0 / CC-BY-SA-3.0 | 12 | 0.9k | base |
| Papirus (`papirus`) | Papirus, Papirus-Dark, Papirus-Light | Alpine `papirus-icon-theme` | 20231201-r0 | GPL-3.0 | 154 | 97k | base |
| Breeze (`breeze`) | breeze, breeze-dark | Alpine `breeze-icons` | 6.8.0-r0 | LGPL-3.0 | 69 | 33k | base |
| Tela Circle (`tela-circle`) | Tela-circle(-light/-dark) | github vinceliuice/Tela-circle-icon-theme | 2026-07-07 / 0a8aee6e95f19ff96cc497d804c75e2af4271a5e6472c55891fb8ac5b099b59b | GPL-3.0 | 42 | 46k | base |
| Colloid (`colloid`) | Colloid(-Light/-Dark) | github vinceliuice/Colloid-icon-theme | 2026-08-10 / 367c3ce3ab85721e41ca9aa4fccd1761ec236d1b8cd7daf65f5e9ec88c1a8a15 | GPL-3.0 | 52 | 41k | base |
| Qogir (`qogir`) | Qogir(-Light/-Dark) | github vinceliuice/Qogir-icon-theme | 2025-02-15 / b0d07cad5601e0341a53a62df0ed111823b75fc38741d435486620a59fb239ee | GPL-3.0 | 57 | 46k | base |
| Numix Circle (`numix-circle`) | Numix-Circle(-Light), Numix(-Light) | Alpine `numix-icon-theme-circle`, `-circle-light`, `numix-icon-theme-light` | 23.05.15-r0 / 23.01.12-r0 | GPL-3.0 | 55 | 41k | base |
| Kora (`kora`) | kora, kora-pgrey | github bikass/kora | v2.0.6 / 159bdb7a09409a12e54a71136ec8889c51b0bf7c145c8b20e3509dc1e90089bd | GPL-3.0 | 27 | 24k | base |
| Candy (`candy`) | candy-icons | github EliverLara/candy-icons | 83512fbcadcb7e1015ebbe1729a1894946b021be / 1de25126c50da4edf4b49623993c1ca5f626d5be1020e5bd1b1c683cd724721b | GPL-3.0 | 7 | 3.8k | on demand |
| Reversal (`reversal`) | Reversal, Reversal-dark | github yeyushengfan258/Reversal-icon-theme | 2c8122287e3bad5a6bf860ddd8c7e3b78cf4d451 / 3053cef3034a424be0dc5a81a70550c6f9653e8839b1a1bdc13fbd19fb11c344 | GPL-3.0 | 51 | 37k | on demand |
| Tela Circle Purple / Green (`tela-circle-purple`, `tela-circle-green`) | Tela-circle-<color>(-light/-dark) | same as Tela Circle | same | GPL-3.0 | 42 each | 46k each | on demand |
| WhiteSur, Fluent, Yaru, UKUI | (see the styles table) | | | | | | with their style |

## Audio and video

| Component | Source | Version | Licence |
|---|---|---|---|
| PulseAudio, pulseaudio-utils, alsa-plugins-pulse | Alpine 3.21 | 17.0-r4, 1.2.12-r0 | LGPL-2.1 |
| VLC, vlc-qt | Alpine 3.21 | 3.0.21-r3 | GPL-2.0 / LGPL-2.1 |
| `libwl_shm_plugin.so` (VLC's `modules/video_output/wayland/shm.c`, unchanged) | https://github.com/videolan/vlc/tree/3.0.21 | 3.0.21 | LGPL-2.1 |
| `libishxdg_plugin.so` (VLC's xdg-shell window provider ported to xdg_wm_base) | `themes/guest/vlc/xdg-wm-base.c` | — | LGPL-2.1 |
| FFmpeg (for test media) | Alpine 3.21 | 6.1.2-r1 | LGPL-2.1 / GPL-2.0 |
