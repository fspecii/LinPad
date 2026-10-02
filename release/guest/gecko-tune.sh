#!/bin/sh
# Firefox ESR defaults tuned for iSH (software rendering, emulated CPU, one shared
# translated-code cache). Run inside the guest, as root, after firefox-esr is installed:
#   sh gecko-tune.sh            (release/guest/finalize.sh runs it)
#   ISH_FIREFOX_SCALE=1 sh gecko-tune.sh   also render Firefox at scale 1 (blurrier text,
#                                          about a third less CPU per frame)
# The prefs are pref() defaults, so about:config and user.js still override them.
# Measured under the native JIT (ipad-jit/jit-report.md, round 3).
set -eu

dir=/usr/lib/firefox-esr/defaults/pref
[ -d "$dir" ] || { echo "gecko-tune: firefox-esr not installed, nothing to do"; exit 0; }

cat > "$dir/ish-tune.js" <<'EOF'
// iSH: Firefox tuning for the emulated CPU (written by gecko-tune.sh).
// One content process and no site isolation: every process translates its own copy of
// libxul, and all of them share one translated-code cache (128-256 MB on an iPad).
pref("dom.ipc.processCount", 1);
pref("dom.ipc.processCount.webIsolated", 1);
pref("fission.autostart", false);
pref("dom.ipc.processPrelaunch.enabled", false);
pref("dom.ipc.keepProcessesAlive.web", 1);
// No extension, privileged-content or socket processes: their work runs in the main or
// the content process, which cuts the number of Firefox processes and code-cache churn.
// The media-decoder (RDD) and utility processes must stay: with
// media.rdd-process.enabled and media.utility-process.enabled false, Firefox 128 has no
// video or audio decoder at all (canPlayType "" for H.264, VP9, AV1, AAC and Opus,
// "Failed to init decoder"), and YouTube says "Your browser can't play this video".
pref("extensions.webextensions.remote", false);
pref("browser.tabs.remote.separatePrivilegedContentProcess", false);
pref("browser.tabs.remote.separatePrivilegedMozillaWebContentProcess", false);
pref("browser.tabs.remote.separateFileUriProcess", false);
pref("network.process.enabled", false);
// Video under emulation (CLI, native JIT, software decoding through system FFmpeg):
// H.264 854x480 26.6 fps shown, VP9 854x480 21.7 fps, H.264 1920x1080 14.7 fps.
// H.264 is the cheapest, so sites that offer a choice (YouTube) get H.264: no WebM or
// AV1 through Media Source Extensions (plain <video> WebM still plays).
pref("media.mediasource.webm.enabled", false);
pref("media.av1.enabled", false);
// Background work that competes with the page for the CPU.
pref("browser.newtabpage.activity-stream.feeds.topsites", false);
pref("browser.newtabpage.activity-stream.feeds.section.topstories", false);
pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
pref("browser.newtabpage.activity-stream.telemetry", false);
pref("browser.newtabpage.activity-stream.showSponsored", false);
pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);
pref("extensions.pocket.enabled", false);
pref("browser.discovery.enabled", false);
pref("app.normandy.enabled", false);
pref("app.shield.optoutstudies.enabled", false);
pref("browser.urlbar.speculativeConnect.enabled", false);
pref("browser.urlbar.suggest.trending", false);
pref("browser.urlbar.quicksuggest.enabled", false);
pref("network.prefetch-next", false);
pref("network.predictor.enabled", false);
pref("browser.sessionstore.interval", 60000);
// Fewer frames for decoration: animations cost a full software repaint each.
pref("toolkit.cosmeticAnimations.enabled", false);
pref("ui.prefersReducedMotion", 1);
EOF
echo "gecko-tune: wrote $dir/ish-tune.js"


if [ "${ISH_FIREFOX_SCALE:-}" = 1 ]; then
    mkdir -p /etc/ishwl
    touch /etc/ishwl/app-scale
    grep -q '^firefox-esr ' /etc/ishwl/app-scale || echo 'firefox-esr 1' >> /etc/ishwl/app-scale
    echo "gecko-tune: Firefox renders at scale 1 (/etc/ishwl/app-scale)"
fi
