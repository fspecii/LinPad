#!/bin/sh
# Firefox ESR defaults tuned for iSH (software rendering, emulated CPU, one shared
# translated-code cache). Run inside the guest, as root, after firefox-esr is installed:
#   sh gecko-tune.sh            (release/guest/finalize.sh runs it)
#   ISH_FIREFOX_SCALE=1 sh gecko-tune.sh   render Firefox at scale 1 everywhere (blurrier
#                                          text, about a third less CPU per frame); the
#                                          default is scale 2, and scale 1 in fullscreen
# The prefs are pref() defaults, so about:config and user.js still override them.
# They go in browser/defaults/preferences: that directory is read after Firefox's own
# browser defaults (omni.ja firefox.js). defaults/pref is read before them, so a pref
# that firefox.js also sets (newtab preload, the extension and privileged-content
# processes, process prelaunch, tab unloading) silently kept Firefox's value there.
# Measured under the native JIT (ipad-jit/jit-report.md, round 3).
set -eu

ff=/usr/lib/firefox-esr
dir=${GECKO_PREFS_DIR:-$ff/browser/defaults/preferences}
[ -x "$ff/firefox-esr" ] || { echo "gecko-tune: firefox-esr not installed, nothing to do"; exit 0; }
mkdir -p "$dir"
[ -n "${GECKO_PREFS_DIR:-}" ] || rm -f "$ff/defaults/pref/ish-tune.js"

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
// Launch child processes from the fork server, a small process forked at startup, instead
// of fork()ing the large parent. iSH copies every page the parent writes after a fork
// (copy-on-write, one host mmap per 4 KB page), so each RDD/utility/content launch cost
// the parent seconds of CPU. Measured (devtools/bench, speed-report.md): YouTube 480p
// 17.6 -> 23.9 fps (30% -> 0% dropped), watch page 26.6 -> 15.3 s, start 31 -> 15 s.
pref("dom.ipc.forkserver.enable", true);
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
// Memory. The iPad app has a per-process limit of a few GB (no increased-memory-limit
// entitlement) shared by every guest process and the emulator. Firefox sizes these
// caches from physical RAM, which is far too much here. Measured on the Mac with H.264
// MSE playback (ipad-jit/emulator-fixes.md, row 59): one process and ~40 threads fewer,
// peak footprint down about 10%.
// No preloaded about:newtab (it costs a whole extra content process).
pref("browser.newtab.preload", false);
// No first-run / what's-new page: it opens in a privileged content process of its own.
pref("browser.startup.homepage_override.mstone", "ignore");
pref("startup.homepage_welcome_url", "");
pref("startup.homepage_welcome_url.additional", "");
pref("browser.aboutwelcome.enabled", false);
// Fewer threads: each guest thread costs the emulator about 1.3 MB of host memory.
pref("layout.css.stylo-threads", 2);
pref("gfx.webrender.enable-low-priority-pool", false);
pref("javascript.options.mem.gc_max_helper_threads", 2);
// Caches and buffers.
pref("browser.sessionhistory.max_total_viewers", 0);
pref("browser.cache.memory.capacity", 16384);
pref("media.memory_caches_combined_limit_kb", 65536);
pref("media.mediasource.eviction_threshold.video", 52428800);
pref("media.mediasource.eviction_threshold.audio", 10485760);
pref("media.video-queue.default-size", 4);
pref("image.mem.surfacecache.max_size_kb", 131072);
// /proc/meminfo reports the app's allowance as MemTotal and what is left of it as
// MemAvailable. Below 20% Firefox's low-memory watcher fires memory-pressure (GC,
// cache purges) and unloads background tabs, before the kernel starts refusing mmap.
pref("browser.low_commit_space_threshold_percent", 20);
pref("browser.tabs.unloadOnLowMemory", true);
// Fewer frames for decoration: animations cost a full software repaint each.
pref("toolkit.cosmeticAnimations.enabled", false);
pref("ui.prefersReducedMotion", 1);
EOF
echo "gecko-tune: wrote $dir/ish-tune.js"


# /etc/ishwl/app-scale: "PROGRAM SCALE [FULLSCREEN_SCALE]". By default Firefox keeps
# scale 2 (sharp text) and drops to scale 1 while a window is fullscreen (fullscreen
# video: a quarter of the pixels, about half the CPU; devtools/bench, speed-report.md).
mkdir -p /etc/ishwl
touch /etc/ishwl/app-scale
if [ "${ISH_FIREFOX_SCALE:-}" = 1 ]; then
    line='firefox-esr 1'
else
    line='firefox-esr 2 1'
fi
if ! grep -q '^firefox-esr ' /etc/ishwl/app-scale; then
    echo "$line" >> /etc/ishwl/app-scale
    echo "gecko-tune: Firefox output scale '$line' (/etc/ishwl/app-scale)"
fi
