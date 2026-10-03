// Firefox defaults for the iSH desktop; make install puts this in
// /usr/lib/firefox-esr/browser/defaults/preferences/ishwl.js when Firefox is installed.
// (Not defaults/pref: that directory is read before Firefox's own browser defaults,
// which then override any pref they also set, such as browser.aboutwelcome.enabled.)
// No GPU: WebRender's software backend draws into wl_shm buffers.
pref("gfx.webrender.software", true);
pref("widget.dmabuf.force-enabled", false);
pref("media.hardware-video-decoding.enabled", false);
pref("browser.shell.checkDefaultBrowser", false);
pref("browser.startup.homepage_override.mstone", "ignore");
pref("datareporting.policy.dataSubmissionEnabled", false);
pref("toolkit.telemetry.reportingpolicy.firstRun", false);
pref("browser.aboutwelcome.enabled", false);
// DesktopKit draws the title bar: no tabs-in-titlebar client-side decorations.
pref("browser.tabs.inTitlebar", 0);
// iSH has no user namespaces; the sandbox warning bar would show on every start.
pref("security.sandbox.warn_unprivileged_namespaces", false);
