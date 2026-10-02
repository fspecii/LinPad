# Installing the `kylin` style into the Alpine aarch64 guest

This is for the themes agent. It follows the conventions of `themes/guest/install.sh` (the `fetch`, `extract_deb`, `prune_gtk_theme`, `put`, `installed` and `mark` helpers) and of `themes/CONTRACT.md`. The result is that `ish-apply-style kylin [light|dark]` works.

## Where the assets come from

**Alpine 3.21 has no UKUI packages.** Use Debian's `ukui-themes` 4.0.0.1-1 binaries, the same approach the `ubuntu` style takes with Yaru:

| Package | Size | URL | Contents used |
|---|---|---|---|
| `ukui-gtk-theme_4.0.0.1-1_all.deb` | 215 KB | `https://deb.debian.org/debian/pool/main/u/ukui-themes/ukui-gtk-theme_4.0.0.1-1_all.deb` | `/usr/share/themes/ukui-white` (light), `/usr/share/themes/ukui-black` (dark). GTK 2 + GTK 3, ~1 MB each, accent `#3790FA` |
| `ukui-icons-theme_4.0.0.1-1_all.deb` | 80 MB | `https://deb.debian.org/debian/pool/main/u/ukui-themes/ukui-icons-theme_4.0.0.1-1_all.deb` | `/usr/share/icons/ukui-icon-theme-default` (~14.6k files), `/usr/share/icons/dark-sense` (cursors, 1.8 MB) |

- **Licenses:** GPL-3 per `debian/copyright` (`sources.debian.org/src/ukui-themes/4.0.0.1-1/debian/copyright`). The icon theme's `index.theme` says "from moka", so keep the copyright file.
- I checked the GTK `.deb` by downloading and listing it. The icon `.deb` file list comes from `packages.debian.org/sid/all/ukui-icons-theme/filelist`.
- **Source fallback,** if Debian goes away: gitee `openkylin/ukui-themes` tag `debian/4.0.0.1-1` (same tree), or the older `openkylin/ukui-theme` `upstream` branch, which has `icons/ukui`, `dark-sense` and `themes/ukui-light/gtk-3.0/gtk.css`. That branch is precompiled, so no `sass` build is needed.
- **Qt:** the real UKUI Qt style (`qt5-ukui-platformtheme`) needs kysdk, peony libs and gsettings-qt, which are not on Alpine. Use a **Kvantum** theme derived from `KvSimplicity` / `KvSimplicityDark` (both present in Kvantum V1.1.3, already pinned as `KVANTUM_REF`) and recoloured with the UKUI tokens.
- **Font:** the UKUI system font ("方正雅意黑", 10pt) is proprietary. The token family is Noto Sans CJK SC.
  - Default: **Noto Sans 10** (`font-noto`, already installed).
  - Optional: `apk add font-noto-cjk` (72 MB, 89 MB installed) for CJK and the exact token family.

## 1. `themes/guest/versions.sh`

```sh
DEBIAN_POOL=https://deb.debian.org/debian/pool/main
UKUI_THEMES_VERSION=4.0.0.1-1
```

Add the same version to `MANIFEST.md`, with license **GPL-3.0** (icons: Moka-derived, attribution kept).

## 2. `themes/guest/styles/kylin.conf`

```sh
# Kylin (UKUI 4) look. ukui-themes 4.0.0.1 from Debian (GPL-3.0); Noto Sans stands in for
# the proprietary FounderType system font.
STYLE_NAME="Kylin"
DEFAULT_VARIANT=light
GTK_THEME_light=ukui-white
GTK_THEME_dark=ukui-black
ICON_THEME_light=ukui-icon-theme-default
ICON_THEME_dark=ukui-icon-theme-default
CURSOR_THEME_light=dark-sense
CURSOR_THEME_dark=dark-sense
KVANTUM_THEME_light=KvUKUI
KVANTUM_THEME_dark=KvUKUIDark
FONT="Noto Sans 10"
MONO_FONT="Noto Sans Mono 10"
CURSOR_SIZE=24
BUTTON_LAYOUT="menu:minimize,maximize,close"
```

- Use the same icon theme for light and dark. UKUI has no separate dark icon set; the symbolic icons are recoloured by GTK.
- `BUTTON_LAYOUT` matches the kwin UKUI decoration: app icon on the left, min/max/close on the right.

## 3. Block for `themes/guest/install.sh`

Put this after the Yaru block, which defines `extract_deb`.

```sh
# --- Kylin: UKUI themes (Debian's packages; Alpine has none) ---------------------------
if ! installed ukui; then
    for p in ukui-gtk-theme ukui-icons-theme; do
        fetch "$DEBIAN_POOL/u/ukui-themes/${p}_${UKUI_THEMES_VERSION}_all.deb" "$WORK/$p.deb"
        rm -rf "$WORK/$p"
        extract_deb "$WORK/$p.deb" "$WORK/$p"
    done
    for v in ukui-white ukui-black; do
        rm -rf "$THEMES/$v"
        cp -R "$WORK/ukui-gtk-theme/usr/share/themes/$v" "$THEMES/$v"
        prune_gtk_theme "$THEMES/$v"
    done
    for t in ukui-icon-theme-default dark-sense; do
        rm -rf "$ICONS/$t"
        cp -R "$WORK/ukui-icons-theme/usr/share/icons/$t" "$ICONS/$t"
    done
    # index.theme lists "NNxNN@2/<ctx>" but the directories are "NNxNN@2x": the @2x PNGs
    # are never looked up. Drop them (and the classical/fashion themes are not copied).
    rm -rf "$ICONS"/ukui-icon-theme-default/*@2x
    # Kylin-branded start-menu glyph: not ours to show (trademark).
    find "$ICONS/ukui-icon-theme-default" -name 'kylin-startmenu*' -delete
    for c in ukui-gtk-theme ukui-icons-theme; do
        [ -f "$WORK/$c/usr/share/doc/$c/copyright" ] &&
            put 644 "$WORK/$c/usr/share/doc/$c/copyright" "$SHARE/themes/licenses/$c.copyright"
    done
    rm -rf "$WORK/ukui-gtk-theme" "$WORK/ukui-icons-theme" "$WORK"/ukui-*.deb
    mark ukui "$UKUI_THEMES_VERSION"
fi

# Kvantum: KvUKUI / KvUKUIDark = KvSimplicity(Dark) recoloured with UKUI Light-Seeking tokens.
if ! installed kvantum-ukui; then
    [ -d "$WORK/kvantum-src" ] || github_tarball tsujan/Kvantum "$KVANTUM_REF" kvantum-src
    mk_kv() { # src dst window base button text disabled
        rm -rf "$KVANTUM/$2"; mkdir -p "$KVANTUM/$2"
        cp "$WORK/kvantum-src/Kvantum/themes/kvthemes/$1/$1.svg" "$KVANTUM/$2/$2.svg"
        sed -e "s/^window.color=.*/window.color=$3/" \
            -e "s/^base.color=.*/base.color=$4/" \
            -e "s/^alt.base.color=.*/alt.base.color=$3/" \
            -e "s/^button.color=.*/button.color=$5/" \
            -e "s/^\(window\.text\|text\|button\.text\)\.color=.*/\1.color=$6/" \
            -e "s/^disabled.text.color=.*/disabled.text.color=$7/" \
            -e "s/^highlight.color=.*/highlight.color=#3790FA/" \
            -e "s/^inactive.highlight.color=.*/inactive.highlight.color=#3790FA/" \
            -e "s/^highlight.text.color=.*/highlight.text.color=#FFFFFF/" \
            -e "s/^link.color=.*/link.color=#3790FA/" \
            "$WORK/kvantum-src/Kvantum/themes/kvthemes/$1/$1.kvconfig" > "$KVANTUM/$2/$2.kvconfig"
    }
    mk_kv KvSimplicity     KvUKUI     '#F6F6F6' '#FFFFFF' '#E6E6E6' '#262626' '#A6A6A6'
    mk_kv KvSimplicityDark KvUKUIDark '#2E2E2E' '#1E1E1E' '#4A4A4A' '#E6E6E6' '#6B6B6B'
    mark kvantum-ukui "$KVANTUM_REF"
fi
```

Then:
- Add `ukui-icon-theme-default dark-sense` to the `gtk-update-icon-cache` loop.
- Add `kylin` to the list `ish-apply-style --list` prints. In `rootfs-add-themes.sh`, add it to `for s in windows macos ubuntu ish` so its icon cache is pre-built.

**Colour sources** (all in `DESIGN-SPEC.md` §1):

| Role | Light | Dark |
|---|---|---|
| window | KGray-2 | `#2E2E2E` |
| base | KGray-0 | `#1E1E1E` |
| button | KGray-6 | `#4A4A4A` |
| text | KFont-Primary (black 0.85 on white = `#262626`) | white 0.9 = `#E6E6E6` |
| disabled | black 0.35 = `#A6A6A6` | white 0.3 on `#2E2E2E` = `#6B6B6B` |

## 4. Verify in the guest

```sh
ish-apply-style kylin light && ish-apply-style --current          # -> kylin
grep -E 'gtk-theme-name|gtk-icon-theme-name' /etc/xdg/gtk-3.0/settings.ini   # ukui-white, ukui-icon-theme-default
jq '.iconTheme, (.missing|length)' /usr/share/ish/icon-cache/kylin/index.json
ls /usr/share/ish/themes/licenses/ | grep ukui
ish-apply-style kylin dark                                          # ukui-black, KvUKUIDark
```

**Expected footprint:**
- GTK: ~2 MB.
- Icons: the Debian `ukui-icon-theme-default` directory minus its `@2x` copies. I didn't measure this because I only read the file list. Measure it with `du -sh` after the first run; the older `icons/ukui` tree in the cloned gitee repo is 50 MB including `@2x`.
- Cursors: 1.8 MB. The iPad pointer is native, so `dark-sense` only matters to apps that draw their own cursors. It is small enough to keep, unlike Yaru's.

## 5. Known gaps

- **GTK 4 / libadwaita apps** get Adwaita, plus the accent through the existing gtk-4.0 links. UKUI ships no GTK 4 theme.
- **The Qt look is approximate** (Kvantum, not the UKUI proxy style). Radii and 36px control heights will differ.
- **Wallpaper:** do not install `1-openkylin.jpg`, which is branded. If one is wanted, use Debian `ukui-wallpapers` 20.04.4 (CC-BY-SA-3.0), e.g. `sea.jpg`. Otherwise the native shell draws its own.
