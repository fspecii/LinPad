#!/bin/sh
# Runs INSIDE the guest (Alpine 3.21 aarch64). Installs the four desktop styles, the
# ishaudio PulseAudio bridge and VLC, then applies the default style.
#   sh /tmp/ish-themes-src/install.sh [default-style]
# Idempotent: every download is pinned and skipped when its target already exists.
# Called by themes/build-themes.sh, which copies this directory to /tmp/ish-themes-src.
set -eu
SRC=$(cd "$(dirname "$0")" && pwd)
DEFAULT_STYLE=${1:-ish}
. "$SRC/versions.sh"

ICONS=/usr/share/icons
THEMES=/usr/share/themes
KVANTUM=/usr/share/Kvantum
SHARE=/usr/share/ish
WORK=/tmp/ish-themes-work
mkdir -p "$WORK" "$ICONS" "$THEMES" "$KVANTUM" "$SHARE/themes" "$SHARE/icon-cache"

log() { echo "ish-themes: $*"; }

# The target is removed first: iSH lets open(O_DIRECTORY) succeed on a regular file, so
# a GNU install (if coreutils is installed) takes an existing file for a directory.
put() { # mode src dest
    mkdir -p "$(dirname "$3")"
    rm -f "$3"
    install -m "$1" "$2" "$3"
}

# A step counts as installed only once it finished: an interrupted run is redone.
STAMPS=$SHARE/themes/.installed
installed() { [ -f "$STAMPS/$1" ]; }
mark() { mkdir -p "$STAMPS"; echo "$2" > "$STAMPS/$1"; }

# Upstream install scripts run with upstream-env.bash as BASH_ENV (iSH argv limit and
# case-insensitive APFS workarounds, see that file). Success is judged by a file the
# script must have installed.
run_upstream() { # check-file dir command...
    check=$1 dir=$2
    shift 2
    (cd "$dir" && BASH_ENV="$SRC/upstream-env.bash" "$@") >"$WORK/upstream.log" 2>&1 || true
    if [ ! -f "$check" ]; then
        cat "$WORK/upstream.log" >&2
        echo "ish-themes: $* did not install $check" >&2
        exit 1
    fi
}

fetch() { # url dest
    [ -s "$2" ] && return 0
    log "fetch $1"
    curl -fsSL --retry 3 -o "$2.part" "$1"
    mv "$2.part" "$2"
}

github_tarball() { # repo ref dir -> extracts into $WORK/dir
    [ -d "$WORK/$3" ] && return 0
    fetch "https://codeload.github.com/$1/tar.gz/$2" "$WORK/$3.tar.gz"
    mkdir -p "$WORK/$3.x"
    tar -xzf "$WORK/$3.tar.gz" -C "$WORK/$3.x"
    mv "$WORK/$3.x"/* "$WORK/$3"
    rmdir "$WORK/$3.x"
}

# Keeps GTK 3/4 only. Shell, Cinnamon, Metacity, XFWM, Plank and GTK 2 assets are
# never used under ishwl (DesktopKit draws the window chrome).
prune_gtk_theme() {
    for d in gnome-shell cinnamon metacity-1 xfwm4 plank gtk-2.0 unity; do
        rm -rf "${1:?}/$d"
    done
}

log "packages"
# sassc only while the upstream scripts run (Fluent compiles its CSS).
apk add -q --virtual .ish-themes-build sassc
apk add -q \
    bash curl xz zstd binutils \
    rsvg-convert gdk-pixbuf \
    papirus-icon-theme adwaita-icon-theme hicolor-icon-theme \
    font-inter font-ubuntu font-cantarell font-noto \
    kvantum kvantum-qt5 \
    pulseaudio pulseaudio-utils alsa-plugins-pulse alsa-utils \
    vlc vlc-qt qt5-qtwayland qt6-qtwayland ffmpeg

# --- macOS: WhiteSur -------------------------------------------------------------------
if ! installed whitesur-gtk; then
    for v in Light Dark; do
        fetch "https://raw.githubusercontent.com/vinceliuice/WhiteSur-gtk-theme/$WHITESUR_GTK_REF/release/WhiteSur-$v.tar.xz" \
            "$WORK/WhiteSur-$v.tar.xz"
        tar -xJf "$WORK/WhiteSur-$v.tar.xz" -C "$THEMES"
        prune_gtk_theme "$THEMES/WhiteSur-$v"
    done
    mark whitesur-gtk "$WHITESUR_GTK_REF"
fi
if ! installed whitesur-icons; then
    github_tarball vinceliuice/WhiteSur-icon-theme "$WHITESUR_ICONS_REF" whitesur-icons
    run_upstream "$ICONS/WhiteSur/index.theme" "$WORK/whitesur-icons" bash ./install.sh -d "$ICONS" -t default
    mark whitesur-icons "$WHITESUR_ICONS_REF"
fi
if ! installed whitesur-cursors; then
    github_tarball vinceliuice/WhiteSur-cursors "$WHITESUR_CURSORS_REF" whitesur-cursors
    cp -R "$WORK/whitesur-cursors/dist" "$ICONS/WhiteSur-cursors"
    mark whitesur-cursors "$WHITESUR_CURSORS_REF"
fi
if ! installed whitesur-kvantum; then
    github_tarball vinceliuice/WhiteSur-kde "$WHITESUR_KDE_REF" whitesur-kde
    cp -R "$WORK/whitesur-kde/Kvantum/WhiteSur" "$KVANTUM/"
    mark whitesur-kvantum "$WHITESUR_KDE_REF"
fi

# --- Windows: Fluent -------------------------------------------------------------------
if ! installed fluent-gtk; then
    github_tarball vinceliuice/Fluent-gtk-theme "$FLUENT_GTK_REF" fluent-gtk
    run_upstream "$THEMES/Fluent-Light/gtk-3.0/gtk.css" "$WORK/fluent-gtk" \
        bash ./install.sh -d "$THEMES" -t default -c light dark -s standard
    for v in Light Dark; do prune_gtk_theme "$THEMES/Fluent-$v"; done
    mark fluent-gtk "$FLUENT_GTK_REF"
fi
if ! installed fluent-icons; then
    github_tarball vinceliuice/Fluent-icon-theme "$FLUENT_ICONS_REF" fluent-icons
    run_upstream "$ICONS/Fluent/index.theme" "$WORK/fluent-icons" bash ./install.sh -d "$ICONS" standard
    mark fluent-icons "$FLUENT_ICONS_REF"
fi
if ! installed fluent-cursors; then
    github_tarball vinceliuice/Fluent-icon-theme "$FLUENT_ICONS_REF" fluent-icons
    cp -R "$WORK/fluent-icons/cursors/dist" "$ICONS/Fluent-cursors"
    cp -R "$WORK/fluent-icons/cursors/dist-dark" "$ICONS/Fluent-dark-cursors"
    mark fluent-cursors "$FLUENT_ICONS_REF"
fi
if ! installed fluent-kvantum; then
    github_tarball vinceliuice/Fluent-kde "$FLUENT_KDE_REF" fluent-kde
    cp -R "$WORK/fluent-kde/Kvantum/Fluent" "$KVANTUM/"
    mark fluent-kvantum "$FLUENT_KDE_REF"
fi

# --- Ubuntu: Yaru (Ubuntu's own packages; Alpine has none) -----------------------------
extract_deb() { # deb dest
    mkdir -p "$2"
    (cd "$2" && ar x "$1" && for t in data.tar.*; do
        case $t in
        *.zst) zstd -dc "$t" | tar -x ;;
        *.xz) tar -xJf "$t" ;;
        *) tar -xf "$t" ;;
        esac
    done)
}
if ! installed yaru; then
    for p in yaru-theme-gtk yaru-theme-icon; do
        fetch "$UBUNTU_POOL/y/yaru-theme/${p}_${YARU_VERSION}_all.deb" "$WORK/$p.deb"
        rm -rf "$WORK/$p"
        extract_deb "$WORK/$p.deb" "$WORK/$p"
    done
    for v in Yaru Yaru-dark; do
        rm -rf "$THEMES/$v" "$ICONS/$v"
        cp -R "$WORK/yaru-theme-gtk/usr/share/themes/$v" "$THEMES/$v"
        prune_gtk_theme "$THEMES/$v"
        cp -R "$WORK/yaru-theme-icon/usr/share/icons/$v" "$ICONS/$v"
    done
    # 58 MB of X cursors that nothing shows: the iPad pointer is native. The ubuntu
    # style names Adwaita as its cursor theme instead.
    rm -rf "$ICONS/Yaru/cursors"
    for c in yaru-theme-icon yaru-theme-gtk; do
        if [ -f "$WORK/$c/usr/share/doc/$c/copyright" ]; then
            put 644 "$WORK/$c/usr/share/doc/$c/copyright" "$SHARE/themes/licenses/$c.copyright"
        fi
    done
    mark yaru "$YARU_VERSION"
fi

# --- Kylin: UKUI themes (Debian's packages; Alpine has none) ---------------------------
# Recipe: themes/kylin/guest-install.md.
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
    # index.theme lists "NNxNN@2/<ctx>" but the directories are "NNxNN@2x", so the @2x
    # PNGs are never looked up.
    rm -rf "$ICONS"/ukui-icon-theme-default/*@2x
    # The Kylin-branded start-menu glyph is a trademark, not ours to show.
    find "$ICONS/ukui-icon-theme-default" -name 'kylin-startmenu*' -exec rm -f {} +
    for c in ukui-gtk-theme ukui-icons-theme; do
        if [ -f "$WORK/$c/usr/share/doc/$c/copyright" ]; then
            put 644 "$WORK/$c/usr/share/doc/$c/copyright" "$SHARE/themes/licenses/$c.copyright"
        fi
    done
    rm -rf "$WORK/ukui-gtk-theme" "$WORK/ukui-icons-theme" "$WORK"/ukui-*.deb
    mark ukui "$UKUI_THEMES_VERSION"
fi

# Kvantum: KvUKUI / KvUKUIDark = KvSimplicity(Dark) recoloured with the UKUI
# Light-Seeking tokens (themes/kylin/DESIGN-SPEC.md, section 1).
mk_kvantum_ukui() { # src dst window base button text disabled
    rm -rf "${KVANTUM:?}/$2"
    mkdir -p "$KVANTUM/$2"
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
if ! installed kvantum-ukui; then
    github_tarball tsujan/Kvantum "$KVANTUM_REF" kvantum-src
    mk_kvantum_ukui KvSimplicity     KvUKUI     '#F6F6F6' '#FFFFFF' '#E6E6E6' '#262626' '#A6A6A6'
    mk_kvantum_ukui KvSimplicityDark KvUKUIDark '#2E2E2E' '#1E1E1E' '#4A4A4A' '#E6E6E6' '#6B6B6B'
    mark kvantum-ukui "$KVANTUM_REF"
fi

# --- ish: Adwaita-dark is built into GTK; Papirus is an Alpine package -----------------
# The package also ships ePapirus and ePapirus-Dark (elementary OS variants), ~20 MB and
# ~17k files the icon picker does not offer. An `apk upgrade` brings them back.
rm -rf "$ICONS/ePapirus" "$ICONS/ePapirus-Dark"

# Kvantum's own themes for the styles without one upstream (Yaru light, Adwaita dark).
# Alpine's kvantum package ships the engine only.
if ! installed kvantum-themes; then
    github_tarball tsujan/Kvantum "$KVANTUM_REF" kvantum-src
    for t in KvYaru KvGnomeDark; do
        cp -R "$WORK/kvantum-src/Kvantum/themes/kvthemes/$t" "$KVANTUM/"
    done
    mark kvantum-themes "$KVANTUM_REF"
fi

apk del -q .ish-themes-build

log "icon theme caches"
for t in WhiteSur WhiteSur-light WhiteSur-dark Fluent Fluent-light Fluent-dark Yaru Yaru-dark ukui-icon-theme-default; do
    [ -f "$ICONS/$t/index.theme" ] && gtk-update-icon-cache -qf "$ICONS/$t" 2>/dev/null || true
done

log "audio"
if [ ! -f /usr/local/lib/libishaudio-compat.so ] || [ "$SRC/audio/ishaudio-compat.c" -nt /usr/local/lib/libishaudio-compat.so ]; then
    apk add -q --virtual .ishaudio-build build-base
    gcc -O2 -fPIC -shared "$SRC/audio/ishaudio-compat.c" -o /usr/local/lib/libishaudio-compat.so -ldl
    apk del -q .ishaudio-build
fi
put 755 "$SRC/audio/ishaudio-session" /usr/local/bin/ishaudio-session
put 644 "$SRC/audio/ishaudio.pa" /etc/ishaudio/ishaudio.pa
put 644 "$SRC/audio/daemon.conf" /etc/pulse/daemon.conf.d/50-ishaudio.conf
put 644 "$SRC/audio/client.conf" /etc/pulse/client.conf.d/50-ishaudio.conf
put 644 "$SRC/audio/asound.conf" /etc/asound.conf

log "vlc"
sh "$SRC/vlc/build-vlc-wayland.sh"
put 755 "$SRC/vlc/ish-vlc" /usr/local/bin/ish-vlc
# Replaces the packaged entry (plain `vlc`, which refuses root and has no Wayland video).
# An `apk upgrade vlc` restores the original; re-run this script afterwards.
put 644 "$SRC/vlc/vlc.desktop" /usr/share/applications/vlc.desktop

log "session hooks"
put 644 "$SRC/session.d/10-style.sh" /etc/ishwl/session.d/10-style.sh
put 644 "$SRC/session.d/20-audio.sh" /etc/ishwl/session.d/20-audio.sh
# ishwl-session sources /etc/ishwl/session.d/*.sh (wl-bridge/ishwl-session). Older
# installs predate that hook; add it in front of the final exec.
if [ -f /usr/local/bin/ishwl-session ] && ! grep -q 'session.d' /usr/local/bin/ishwl-session; then
    sed -i 's|^exec ishwl "\$@"$|for f in /etc/ishwl/session.d/*.sh; do [ -r "$f" ] \&\& . "$f"; done\n\nexec ishwl "$@"|' \
        /usr/local/bin/ishwl-session
fi

log "styles"
put 755 "$SRC/ish-apply-style" /usr/local/bin/ish-apply-style
put 755 "$SRC/ish-icon-packs" /usr/local/bin/ish-icon-packs
put 644 "$SRC/upstream-env.bash" "$SHARE/themes/upstream-env.bash"
mkdir -p "$SHARE/themes/styles"
cp "$SRC"/styles/*.conf "$SHARE/themes/styles/"
put 644 "$SRC/MANIFEST.md" "$SHARE/themes/MANIFEST.md"

# Thunar ships /usr/bin/thunar plus a /usr/bin/Thunar symlink, which are one file on
# case-insensitive APFS. Package operations in this script have been seen to leave the
# guest with neither name; reinstalling restores the binary.
if apk info -e thunar >/dev/null 2>&1 && [ ! -x /usr/bin/thunar ]; then
    apk fix -q thunar
fi

# Colour themes (Omarchy colors.toml, themes/omarchy): palettes, templates, commands.
if [ -d "$SRC/omarchy/colors" ]; then
    log "colour themes"
    apk add -q jq
    LINPAD=/usr/share/linpad/colors
    rm -rf "$LINPAD.tmp"
    mkdir -p "$LINPAD.tmp"
    cp -R "$SRC/omarchy/colors/." "$LINPAD.tmp/"
    cp -R "$SRC/omarchy/templates" "$LINPAD.tmp/templates"
    cp "$SRC/omarchy/LICENSE.omarchy" "$SRC/omarchy/ATTRIBUTION" "$LINPAD.tmp/"
    rm -rf "$LINPAD"
    mv "$LINPAD.tmp" "$LINPAD"
    put 755 "$SRC/omarchy/ish-colors" /usr/local/bin/ish-colors
    put 755 "$SRC/omarchy/ish-apply-colors" /usr/local/bin/ish-apply-colors
    [ -s /usr/share/ish/current-colors ] || echo none > /usr/share/ish/current-colors
    # ish-terminal (wl-bridge/guest) gained the hook that points foot at the colour
    # theme; images built before that get it here.
    if [ -f /usr/local/bin/ish-terminal ] && ! grep -q linpad.ini /usr/local/bin/ish-terminal; then
        sed -i 's|^exec foot |[ -r "${HOME:-/root}/.config/foot/linpad.ini" ] \&\& config=${HOME:-/root}/.config/foot/linpad.ini\nexec foot |' \
            /usr/local/bin/ish-terminal
    fi
fi

# Icon packs for Settings › Icons. The rest of the catalogue (ish-icon-packs list) is
# installed on demand by the picker's "Get More Icon Packs…".
log "icon packs: $BASE_ICON_PACKS"
for p in $BASE_ICON_PACKS; do
    if ! ish-icon-packs list | awk -F'\t' -v p="$p" '$1 == p && $3 == 1 { found = 1 } END { exit !found }'; then
        ish-icon-packs install "$p"
    fi
done

rm -rf "$WORK" /var/cache/apk/*
ish-apply-style "$DEFAULT_STYLE"
ish-apply-style --icon-previews
# Previews for the shell's icon pack picker, so it opens without a wait.
ish-apply-style --icon-previews
log "done"
