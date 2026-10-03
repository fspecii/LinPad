#!/bin/sh
# Last step of release/build-rootfs.sh, run inside the guest:
#   sh finalize.sh ROOTFS_VERSION
# Branding, version stamp, first-run hooks, the VS Code installer entry, case-collision
# cleanup, icon caches for every style, pruning and a sanity check of the shipped apps.
set -eu
version=${1:?usage: finalize.sh ROOTFS_VERSION}
src=$(cd "$(dirname "$0")" && pwd)

echo "finalize: base directories"
for d in /dev /proc /sys /run /tmp /var/tmp /root /home /mnt /media /srv /var/lib/ish; do
    [ -d "$d" ] || mkdir -p "$d"
done
chmod 1777 /tmp /var/tmp
chmod 700 /root

echo "finalize: branding and version $version"
sh "$src/os-release.sh" /etc/os-release
mkdir -p /usr/share/ish /etc/ish
printf '%s\n' "$version" > /usr/share/ish/rootfs-version
# The kernel reports the iPad's own name as the host name; this is the fallback.
echo linux-for-ipad > /etc/hostname
cat > /etc/motd <<'MOTD'
Welcome to Linux for iPad (Alpine Linux base, powered by iSH).

  apk add <package>      install software (https://pkgs.alpinelinux.org)
  ish-firstrun           install the optional packs chosen at setup
  ish-install-vscode     install Visual Studio Code

MOTD

echo "finalize: Firefox tuning"
sh "$src/gecko-tune.sh"
# This image already has everything the app's repair kit (linpad-repair) puts back, so
# the app does not run its silent repair after the first launch.
install -D -m 644 "$src/repair-kit-version" /usr/share/ish/repair-kit-version

echo "finalize: first-run hooks"
install -D -m 755 "$src/ish-firstrun" /usr/local/sbin/ish-firstrun
install -D -m 755 "$src/ish-install-vscode" /usr/local/bin/ish-install-vscode
install -D -m 755 "$src/ish-preview" /usr/local/bin/ish-preview
install -D -m 644 "$src/90-firstrun.sh" /etc/ishwl/session.d/90-firstrun.sh
install -D -m 644 "$src/15-lowmem.sh" /etc/ishwl/session.d/15-lowmem.sh
# Leaving the screen and iPadOS ending LinPad (ipad-jit/lifecycle-report.md): the app runs
# linpad-lifecycle; apps get autosave and crash-restore defaults.
install -D -m 755 "$src/lifecycle/linpad-lifecycle" /usr/local/bin/linpad-lifecycle
install -D -m 755 "$src/lifecycle/linpad-autosave-defaults" /usr/local/sbin/linpad-autosave-defaults
install -D -m 755 "$src/lifecycle/linpad-tmux-attach" /usr/local/bin/linpad-tmux-attach
install -D -m 755 "$src/lifecycle/mousepad" /usr/local/bin/mousepad
[ -e /etc/linpad/lifecycle.conf ] || install -D -m 644 "$src/lifecycle/lifecycle.conf" /etc/linpad/lifecycle.conf
mkdir -p /etc/linpad/lifecycle.d
install -D -m 644 "$src/org.a11y.Bus.service" /usr/local/share/dbus-1/services/org.a11y.Bus.service
install -D -m 644 "$src/ish-code.svg" /usr/share/icons/hicolor/scalable/apps/ish-code.svg

# Optional apps (linpad/catalog.json): nothing in the catalog ships preinstalled. The
# desktop's onboarding and Settings › Apps install packs with linpad-apps.
echo "finalize: optional apps catalog"
install -D -m 644 "$src/linpad/catalog.json" /usr/share/linpad/catalog.json
install -D -m 755 "$src/linpad/linpad-apps" /usr/local/bin/linpad-apps
install -D -m 755 "$src/linpad/linpad" /usr/local/bin/linpad
mkdir -p /usr/local/share/linpad/packs/vlc
install -m 644 "$src/linpad/sample.pdf" "$src/ish-install-vscode.desktop" /usr/local/share/linpad/
install -m 755 "$src/linpad/packs/vscode-uninstall.sh" "$src/linpad/packs/x11-rule.sh" \
    "$src/linpad/packs/wine-uninstall.sh" "$src/linpad/packs/glibc-island.sh" /usr/local/share/linpad/packs/
install -m 755 "$src/linpad/packs/vlc/postinstall.sh" "$src/linpad/packs/vlc/postremove.sh" \
    /usr/local/share/linpad/packs/vlc/
for f in "$src"/linpad/packs/*/*; do
    case $f in "$src"/linpad/packs/vlc/*) continue ;; esac
    [ -f "$f" ] || continue
    if [ -x "$f" ]; then mode=755; else mode=644; fi
    install -D -m "$mode" "$f" "/usr/local/share/linpad/packs/${f#"$src"/linpad/packs/}"
done
# LinPad Store: the app index the desktop also bundles, its curation, the generator that
# `linpad-apps refresh-index` runs, and the fixups some apps need on iSH.
install -D -m 644 "$src/linpad/store/store-index.json" /usr/share/linpad/store-index.json
install -D -m 644 "$src/linpad/store/curation.json" /usr/share/linpad/store-curation.json
install -D -m 644 "$src/linpad/store/store-icons.txt" /usr/share/linpad/store-icons.txt
install -D -m 644 "$src/linpad/store/linpad-store-index.mjs" /usr/local/share/linpad/store/linpad-store-index.mjs
mkdir -p /usr/local/share/linpad/store/fixups
install -m 755 "$src"/linpad/store/fixups/*.sh /usr/local/share/linpad/store/fixups/
# VLC came in with the themes stage, which also compiled LinPad's Wayland plugins for it.
# Keep those (a few hundred KB) for the Multimedia pack and take VLC itself out.
if apk info -e vlc >/dev/null 2>&1 && [ -f /usr/local/bin/ish-vlc ]; then
    stash=/usr/local/share/linpad/packs/vlc
    cp /usr/lib/vlc/plugins/video_output/libwl_shm_plugin.so /usr/lib/vlc/plugins/video_output/libishxdg_plugin.so \
        /usr/local/lib/libish-vlc-compat.so /usr/local/bin/ish-vlc "$stash/"
    cp /usr/share/applications/vlc.desktop "$stash/vlc.desktop"
    rm -f /usr/local/bin/ish-vlc /usr/local/lib/libish-vlc-compat.so /usr/share/applications/vlc.desktop
    apk del -q vlc vlc-qt ffmpeg 2>/dev/null || apk del -q vlc vlc-qt
    rm -rf /usr/lib/vlc
    echo "  VLC moved to the Multimedia pack"
fi
if [ -x /usr/local/bin/code ]; then
    rm -f /usr/share/applications/ish-install-vscode.desktop
else
    install -D -m 644 "$src/ish-install-vscode.desktop" /usr/share/applications/ish-install-vscode.desktop
fi

# The app container on the iPad and the Mac's disks used while building and in the
# simulator differ in case sensitivity; two names that differ only in case share one
# backing file on a case-insensitive disk. Drop symlinks that only alias another
# spelling (Thunar -> thunar) and report anything else.
echo "finalize: case collisions"
find / \( -path /proc -o -path /sys -o -path /dev -o -path /tmp \) -prune -o -print 2>/dev/null |
    awk '{ k = tolower($0); n[k]++; m[k] = m[k] "\n" $0 } END { for (k in n) if (n[k] > 1) print substr(m[k], 2) "\n--" }' \
    > /tmp/case-collisions.txt
removed=0
kept=0
group=
while IFS= read -r line; do
    if [ "$line" != "--" ]; then
        group="$group$line
"
        continue
    fi
    resolved=
    IFS='
'
    for p in $group; do
        if [ -L "$p" ]; then
            target=$(readlink "$p")
            case $target in /*) ;; *) target=$(dirname "$p")/$target ;; esac
            for q in $group; do
                if [ "$q" != "$p" ] && [ "$q" = "$target" ]; then
                    echo "  removing alias $p -> $(readlink "$p")"
                    rm -f "$p"
                    removed=$((removed + 1))
                    resolved=1
                fi
            done
        fi
    done
    IFS=' 	
'
    if [ -z "$resolved" ]; then
        echo "  unresolved: $(printf '%s' "$group" | tr '\n' ' ')"
        kept=$((kept + 1))
    fi
    group=
done < /tmp/case-collisions.txt
echo "  $removed alias(es) removed, $kept collision group(s) left"
sh "$src/fix-thunar.sh"

# Mesa 26 comes from edge (gpu stage) and needs edge's libdrm, libxcb and
# wayland-libs-client. Later stages' apk runs can move those back to 3.21's versions
# (wayland-libs-client 1.23 was back after the themes stage), and then libEGL/libgallium
# fail to relocate and everything that links GL (Qt 5/6, so VLC's and Falkon's
# interfaces) stops loading. Put them back here, at the end of the build; the load check
# below enforces it.
echo "finalize: edge libraries for Mesa 26"
# Every image has the gpu stage's Mesa; without it GL, Qt and Xwayland apps cannot run.
gallium=$(ls /usr/lib/libgallium-*.so 2>/dev/null | head -1)
if [ -z "$gallium" ] || ! apk info -e mesa-gbm >/dev/null 2>&1; then
    echo "finalize: Mesa (gpu stage) is missing: no /usr/lib/libgallium-*.so or mesa-gbm" >&2
    exit 1
fi
apk update -q
apk add -q --upgrade --repository https://dl-cdn.alpinelinux.org/alpine/edge/main \
    libdrm libxcb wayland-libs-client
# From here on apk itself keeps them: every package newer than the v3.21 repositories
# (the edge stack) gets a version floor in /etc/apk/world. Users' `apk add`, `apk upgrade`
# (-a) and the Store then never move them back, with no re-pin after the fact.
install -D -m 755 "$src/linpad-pin-edge" /usr/local/sbin/linpad-pin-edge
/usr/local/sbin/linpad-pin-edge

# A published image (build-rootfs.sh PUBLIC=1) carries nothing LinPad may not redistribute:
# Claude Code is proprietary (the "Claude Code" catalog item installs it from npm on the
# iPad) and the Kylin logos are trademarks. release/check-public-rootfs.sh verifies.
if [ "${LINPAD_PUBLIC:-0}" = 1 ]; then
    echo "finalize: public image"
    npm uninstall -g --no-audit --no-fund @anthropic-ai/claude-code >/dev/null 2>&1 || true
    rm -rf /usr/local/lib/node_modules/@anthropic-ai/claude-code /usr/local/bin/claude /root/.claude /root/.claude.json
    find /usr/share/icons /usr/share/pixmaps /usr/share/ish \( -iname 'distributor-logo-kylin*' \
        -o -iname 'kylin-startmenu*' -o -iname 'openkylin*.png' -o -iname 'openkylin*.svg' \) -exec rm -f {} + 2>/dev/null || true
fi

echo "finalize: icon caches"
current=$(ish-apply-style --current 2>/dev/null || echo ish)
for style in windows macos ubuntu kylin ish; do
    [ "$style" = "$current" ] && continue
    ish-apply-style "$style" >/dev/null
done
ish-apply-style "$current" >/dev/null

echo "finalize: pruning"
# npm installs Claude Code's native binary twice (the platform package and the copy its
# install script makes as bin/claude.exe, which /usr/local/bin/claude runs): 225 MB each.
cc=/usr/local/lib/node_modules/@anthropic-ai/claude-code
musl=$cc/node_modules/@anthropic-ai/claude-code-linux-arm64-musl/claude
if [ -f "$cc/bin/claude.exe" ] && [ -f "$musl" ] && [ ! -L "$musl" ] && cmp -s "$cc/bin/claude.exe" "$musl"; then
    rm -f "$musl"
    ln -s ../../../bin/claude.exe "$musl"
    echo "  Claude Code: duplicate native binary replaced by a link"
fi
rm -rf /root/.cache /root/.npm/_cacache /root/.dbus /root/fixt /root/gt /root/t /var/cache/apk/* \
    /var/cache/vscode-install /usr/share/ish/themes/cache 2>/dev/null || true

echo "finalize: autosave defaults"
/usr/local/sbin/linpad-autosave-defaults

echo "finalize: sanity"
missing=
for cmd in ishwl ishwl-session ish-terminal foot fastfetch firefox-esr thunar mousepad node npm \
        git curl ish-apply-style ishaudio-session vulkaninfo ish-firstrun linpad-apps \
        ish-install-vscode; do
    command -v "$cmd" >/dev/null || missing="$missing $cmd"
done
for f in /etc/profile.d/gpu.sh /usr/local/share/devtools/install-vscode.sh \
        /usr/share/ish/icon-cache/ish/index.json /usr/share/ish/current-style \
        /usr/lib/firefox-esr/browser/defaults/preferences/ishwl.js /root/Videos/ish-test-720p.mp4; do
    [ -e "$f" ] || missing="$missing $f"
done
[ "${LINPAD_PUBLIC:-0}" = 1 ] || command -v claude >/dev/null || missing="$missing claude"
if [ -n "$missing" ]; then
    echo "finalize: MISSING:$missing" >&2
    exit 1
fi
for lib in "$gallium" /usr/lib/libEGL.so.1 /usr/lib/vlc/plugins/gui/libqt_plugin.so \
        /usr/lib/libQt5Gui.so.5 /usr/lib/libQt6Gui.so.6 /usr/lib/firefox-esr/libxul.so; do
    [ -e "$lib" ] || continue
    if ldd "$lib" 2>&1 | grep -q "Error relocating\|not found"; then
        echo "finalize: $lib does not load:" >&2
        ldd "$lib" 2>&1 | grep "Error relocating\|not found" | head -5 >&2
        exit 1
    fi
done
# Firefox plays video and audio through the system FFmpeg libraries (dependencies of
# firefox-esr; only the ffmpeg command left with VLC) and needs its media processes.
ls /usr/lib/libavcodec.so.* >/dev/null 2>&1 || { echo "finalize: libavcodec missing (Firefox video)" >&2; exit 1; }
if grep -qs 'media.rdd-process.enabled", false\|media.utility-process.enabled", false' /usr/lib/firefox-esr/defaults/pref/*.js; then
    echo "finalize: Firefox prefs disable the media processes (no video/audio decoders)" >&2
    exit 1
fi
grep -q '^ID=linuxforipad' "$(readlink -f /etc/os-release)" || { echo "finalize: os-release not branded" >&2; exit 1; }
if command -v claude >/dev/null; then echo "finalize: claude $(timeout 120 claude --version 2>&1 | head -n1)"; fi
echo "finalize: ok ($(cat /etc/alpine-release), $(du -sh / 2>/dev/null | cut -f1) apparent)"
