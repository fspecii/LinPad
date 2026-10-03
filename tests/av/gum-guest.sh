#!/bin/sh
# Guest half of the Firefox getUserMedia test: headless Firefox on gum.html (copied to
# /tmp/av by run.sh) with permission prompts off, against /dev/video0 and ipad_mic.
export PULSE_SERVER=unix:/tmp/ishaudio/native HOME=/root MOZ_CRASHREPORTER_DISABLE=1
[ -r /usr/local/lib/libishaudio-compat.so ] && export LD_PRELOAD=/usr/local/lib/libishaudio-compat.so
mkdir -p /dev/shm
ishaudio-session
rm -rf /tmp/gumprof && mkdir -p /tmp/gumprof
cat > /tmp/gumprof/user.js <<'PREFS'
user_pref("media.navigator.permission.disabled", true);
user_pref("media.autoplay.default", 0);
user_pref("media.autoplay.block-webaudio", false);
user_pref("browser.dom.window.dump.enabled", true);
user_pref("media.cubeb.backend", "pulse");
// Shipped by release/guest/gecko-tune.sh: sandboxed cubeb records zeros under iSH.
user_pref("media.cubeb.sandbox", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
PREFS
MOZ_LOG=${GUM_MOZ_LOG:-} /usr/lib/firefox-esr/firefox-esr --headless --no-remote --profile /tmp/gumprof file:///tmp/av/gum.html > /tmp/av/gum.log 2>&1 &
FP=$!
for i in $(seq 1 ${WAIT:-150}); do
  sleep 1
  grep -q "GUM DONE\|GUM ERROR" /tmp/av/gum.log && break
  kill -0 $FP 2>/dev/null || break
done
echo "@@ t=$i"
grep "^GUM" /tmp/av/gum.log
kill $FP 2>/dev/null; sleep 2; kill -9 $FP 2>/dev/null
grep -iv "^GUM" /tmp/av/gum.log | tail -15
