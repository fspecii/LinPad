# Linux for iPad: release checklist

Release `202610020508 (rootfs)`, 2026-10-02. iPad Air M3 (landscape, Logitech keyboard and
trackpad, touch). Install steps are in `release/INSTALL-DEVICE.md`. Test evidence is in
`/Volumes/ExternalHD/Dev/ipad-jit/release-shots/`. Component reports are in
`/Volumes/ExternalHD/Dev/ipad-jit/*.md`.

## Build and ship

| Step | Command | State |
|---|---|---|
| Rootfs (shareable) | `release/build-rootfs.sh` → `release/out/ish-linux-rootfs-arm64.tar.gz` + `.version` + `SIZES-*.txt` | built: **589 MiB** (617 MB) compressed, 2.24 GiB unpacked, 216,952 entries, version 202610020508 |
| Rootfs with VS Code (local testing only, never publish) | `VSCODE=1 release/build-rootfs.sh` → `ipad-jit/release-work/ish-linux-rootfs-vscode-arm64.tar.gz` | built: 901 MiB, version 202610020522; it contains Microsoft's binary and stays in ipad-jit/ (not tested in the simulator this round) |
| Simulator app | `xcodebuild … -sdk iphonesimulator SYMROOT=$PWD/build-sim-rel` then `release/embed-rootfs.sh APP ROOTFS` | built, tested (below) |
| Device app | the `-sdk iphoneos` command in INSTALL-DEVICE.md, then `release/embed-rootfs.sh --device APP ROOTFS` | built with `ISH_JIT_BUILD=enabled`; rootfs embedded; `codesign -v --strict` ok; the profile lists the iPad. **Not installed** |
| End-to-end test | `release/ReleaseHarness` (XCUITest against the installed app) | run on a fresh simulator; results below |
| DesktopKit unit tests | `xcodebuild test -scheme DesktopKit` | 49/49 pass |

## Branding: "Linux for iPad"

- Home-screen name (CFBundleDisplayName and CFBundleName), launch screen, boot splash
  (Tux mark plus "Linux for iPad"), onboarding, About ("…, powered by iSH" credit), Settings
  › About ("System") and the fast-mode help all say "Linux for iPad".
- Guest: os-release (NAME "Linux for iPad", ID `linuxforipad`), fastfetch logo,
  `/etc/hostname` fallback, `/etc/motd`, and the first-run terminal title.
- Unchanged on purpose:
  - Bundle id `com.valentinneagu.ish.arm64`, app group, PRODUCT_NAME / `iSH ARM64.app`, and
    repo paths. Changing them would install a separate app or break scripts.
  - The "iSH" desktop style name, and "emulated by iSH" in fastfetch's CPU line.
- The rootfs embedded in today's device build predates the guest rename. The next
  `build-rootfs.sh` run picks it up, and roots already installed are re-branded by that
  rootfs's update.

## Optional apps (LinPad keeps lean: nothing below is preinstalled)

The catalog is `release/guest/linpad/catalog.json` → `/usr/share/linpad/catalog.json`.
Each entry has an id, name, description, category, size estimate, its apk packages or
installer script, a desktop entry, an icon, and "recommended" / "experimental" flags.

**`linpad-apps`** (`/usr/local/bin`; `ish-firstrun` is a compatibility wrapper):
- `list [--json]`, `install ID…`, `remove ID…`, `pending`, `firstrun`.
- Idempotent. A pack counts as installed when its packages are in apk's world, or when
  its check file exists.
- After every change it re-pins edge's libdrm, libxcb and wayland-libs-client, so Mesa 26
  keeps working, and refreshes the icon cache.
- Remove keeps packages that another installed pack still uses.

**VLC moved out of the base image.**
- finalize.sh stashes LinPad's prebuilt VLC Wayland plugins, compat library, `ish-vlc` and
  its desktop entry in `/usr/local/share/linpad/packs/vlc`, then runs
  `apk del vlc vlc-qt ffmpeg`.
- The Multimedia pack reinstalls VLC and puts the stashed files back, so nothing is
  compiled on the iPad.

**Native UI.**
- Onboarding shows the catalog as a checkbox list, grouped by category with sizes. Nothing
  is preselected.
- Ticked apps install in the background after "Start Using the Desktop", and a toast
  points to Settings › Apps.
- Settings › Apps (`Apps/SettingsApp.swift`, opened directly with `page=apps`) has
  Install and Remove buttons, per-app progress, installed state read from the guest, and
  a live log.
- Both use one `AppCatalogModel` per host (`Core/System/AppCatalog.swift`), which runs one
  `linpad-apps` at a time because apk locks its database.
- Linux systems without the catalog fall back to the old three-item list.

**Verified on the CLI.** Release emulator, current lean rootfs, each pack installed with
`linpad-apps install` and then launched under headless ishwl. The Mac's load average was
around 700–900, so install times are inflated:

| Pack | Install | Added | Launch | |
|---|---|---|---|---|
| Image viewer (Ristretto) | ok, 115 s | ~5 MB | **ok** | `release-shots/packs/image-viewer.png` |
| Archive manager (Xarchiver) | ok, 124 s | 3 MB | **ok** | `packs/archives.png` |
| PDF viewer (zathura + MuPDF) | ok, 487 s | 48 MB | **ok**: the sample PDF renders | `packs/pdf.png` |
| Claws Mail (recommended mail) | ok, 94 s | 177 MB | **ok**: setup wizard | `packs/mail-light.png` |
| Thunderbird | ok, 45 s | 214 MB | **ok**: account setup | `packs/mail.png` |
| VLC (Multimedia) | ok, 70 s | 92 MB | **ok**: video frames through the stashed Wayland plugin | `packs/multimedia.png` |
| GPU tools (mesa-utils) | ok, 65 s | ~0 | installs. The CLI emulator has no GPU node, so eglinfo can't initialise; check on the device | |
| GIMP | ok, 46 s | 89 MB | GIMP 2.10 is X11 only. The pack now adds xwayland and a `gimp x11` launch rule. **ok** after the rule: full GIMP window (`packs/image-editor.png`) | |
| Extra browsers (Falkon, Dillo) | ok, 130 s | 539 MB | Dillo needs its x11 rule (present); Falkon **did not start** (Qt 6 now offers only the "wayland-egl" buffer integration, and the session forces "none"). Pack marked **experimental** | |
| LibreOffice | not run (time and machine load) | | marked **experimental** | |
| Developer extras | not run | | marked **experimental** | |
| Visual Studio Code | existing installer, verified by the VS Code agent | | | |

**Verified in the simulator** (fresh iPad Air 11 M3; catalog injected into the current
rootfs; `ReleaseHarness` `test5AppCatalog` passes; screenshots `release-shots/60–64-*.png`):
- Onboarding lists the catalog, grouped by category with sizes and Recommended /
  Experimental tags. Nothing is ticked.
- Ticking Ristretto and starting the desktop installed it in the background.
- Settings › Apps showed "Installing Image viewer (Ristretto)", then a Remove button.
- `linpad-apps list` in the guest agreed. Remove brought the Install button back.

**Wine** (`wine`, `wine-x86`; both experimental):
- Backed by `devtools/install-wine.sh`, staged in `/usr/local/share/devtools` by
  `rootfs-add-devtools.sh`. Details in `ipad-jit/wine-report.md`.
- `packs/wine-uninstall.sh [--x86]` removes only Wine and Box64 files. Windows prefixes
  stay.
- The glibc libraries that VS Code and Wine share (`/usr/lib/aarch64-linux-gnu` and the
  loader) are now refcounted by `packs/glibc-island.sh prune`. They are deleted only when
  no VS Code, Wine or x86-Wine is installed; before this, the VS Code uninstaller always
  deleted them.
- Round trip on a clone of the Wine test fakefs (release emulator):
  - remove wine-x86 → remove wine (libraries kept, VS Code still links) → VS Code uninstall
    (libraries removed) → `linpad-apps install wine` (182 s, cached .debs, `wine --version`
    ok) → remove wine (libraries removed).

Notes:
- **Emulator bug: node output to a pipe can be lost in the app.** Under the app's process
  launcher, `node -e 'console.log(1)'` printed nothing to the desktop, while
  `fs.writeSync(1, …)` and stderr worked. `linpad-apps` therefore writes with
  `fs.writeSync`. It works on the CLI when redirected to a file.
- **Mail.** Geary needs WebKitGTK, which is blocked under the emulator, so Claws Mail is the
  light mail option.
- **PDF.** Papers/Evince were skipped in favour of zathura, which is smaller and works.
  Quick Look in Files also previews PDFs natively.

## Features in this release

**Desktop (DesktopKit, native SwiftUI)**
- Five styles (iSH, Windows 11, macOS, Ubuntu, Kylin/UKUI), each with light and dark.
- Snapping (halves, quarters, maximize) and auto-tiling: master-stack, columns, grid and
  monocle, per workspace.
- 4 workspaces, an overview, a switcher, the notification center and quick settings.
- Lock screen; a power menu with Restart Desktop Session.
- Session restore, onboarding, a performance overlay.
- Full keyboard control (⌃⌥ shortcuts, Settings › Keyboard Shortcuts), and touch, trackpad
  and pointer metrics.

**Linux apps as native windows (ishwl Wayland bridge)**
- Firefox ESR 128, Thunar, Mousepad, foot (with fastfetch), and VLC 3 (native Wayland
  video, sound through the ishaudio bridge).
- Clipboard both ways, drag and drop (Linux↔Files/desktop), and popups outside their window.
- HiDPI (scale 2).

**First launch.**
- The rootfs is unpacked off the main thread, and the boot splash shows real progress:
  "Unpacking Linux… N of M MB · N files" → "Configuring…" → "Starting desktop…".
- Safe against suspension and kills (staging directory, atomic move).

**System updates.**
- When the app bundles a newer rootfs (`root.version` greater than the root's
  `/usr/share/ish/rootfs-version`), the desktop offers "Update Linux system".
- The update installs on the next launch:
  - The system is replaced.
  - `/root`, `/home`, `/opt`, `/srv`, the account files and the onboarding choices are kept.
  - Packages the user added are reinstalled.
  - The old root is kept as a separate filesystem.

**CPU engines.**
- The native ARM64 JIT is compiled in: `ISH_JIT_BUILD=enabled` (geomean 4.84x per
  jit-report.md, 10x on the shell loop here).
- On the iPad it is on only when StikDebug launches the app.
- The boot splash and Quick Settings show "Performance: Native JIT ✓" or "Compatibility
  mode". "Enable fast mode" opens a help sheet.

**GPU.** Venus Vulkan → virglrenderer → MoltenVK → Metal, plus zink GL/GLES 2. It is on by
default. Firefox stays on software WebRender (see gpu-report.md).

**Files app.**
- Multi-select, trash (freedesktop spec), compress and extract, Open With, Quick Look,
  Properties.
- Import and export with iPadOS.

**Developer tools.**
- Node 22, npm, git and Claude Code (`claude`) are installed.
- A Vite + React + TypeScript demo is in `/root/projects/demo`.
- VS Code: the launcher entry "Install Visual Studio Code" downloads Microsoft's linux-arm64
  build on the device and shows progress in foot. So does the onboarding "VS Code" pack.

**Optional packs** (onboarding, or `ish-firstrun PACK` in a terminal): `vscode`,
`multimedia` (already installed), `gpu` (mesa-utils), and `browsers` (Falkon and Dillo,
moved out of the bundled image to keep it under 700 MB).

## Rootfs composition

`release/build-rootfs.sh`, from `alpine-minirootfs-3.21.0-aarch64.tar.gz`:
1. **base**: the GUI package set of the bridge agent's lean rootfs, plus Claude Code and
   ishwl built from `wl-bridge/` inside the guest.
2. **gpu**: `gpu/rootfs-add-gpu.sh`.
3. **themes**: `themes/rootfs-add-themes.sh`.
4. **devtools**: `devtools/rootfs-add-devtools.sh` with `VSCODE=0`.
5. **finalize**: `release/guest/finalize.sh`.
   - Branding (`/etc/os-release`: "Linux for iPad (Alpine 3.21 base)", ID `linuxforipad`), `/etc/hostname` fallback `linux-for-ipad`, `/etc/motd`.
   - The version stamp.
   - First-run hooks: `/usr/local/sbin/ish-firstrun` and
     `/etc/ishwl/session.d/90-firstrun.sh`, which read `/etc/ish/firstrun.json`.
   - The VS Code installer entry and its neutral icon (`ish-code`).
   - Case-collision cleanup.
   - Icon caches for all 5 styles.
   - Pruning and a sanity check of the shipped commands.

Sizes per stage are in `release/out/SIZES-ish-linux-rootfs-arm64.txt`:

| Stage | Output (compressed) |
|---|---|
| 1 base (from minirootfs) | 367 MB |
| 2 + gpu | 545 MB (host-side libarchive, lower compression than the guest tar used by the other stages) |
| 3 + themes, audio, VLC | 767 MB |
| 4 + devtools (installer and demo project, 85 MB unpacked) | 689 MB |
| 5 final | **589 MiB** (617,399,467 bytes), 2.24 GiB unpacked, 216,952 entries |

What was cut to get under 700 MB, and why:
- **Falkon, Dillo and Xwayland** (about 110 MB compressed in the bridge agent's full GUI
  rootfs) are on demand. Firefox is the default browser. No bundled app needs X11: VLC runs
  on Wayland through the themes agent's plugins.
- **Claude Code's native binary was in the image twice** (npm's platform package plus the
  `bin/claude.exe` copy, 225 MB each). It is now one file and a symlink.
- **The npm download cache** (106 MB) is dropped.
- **Kept:**
  - Papirus (101 MB uncompressed). It is the default style's icon theme, so dropping it
    would change the default look.
  - libLLVM (169 MB). Mesa's gallium needs it, including zink.

## Case sensitivity

- The app logs `[boot] case_sensitive_container=yes|no` on every launch.
- **The simulator is a hybrid.**
  - Lookups are case-sensitive. A test binary run with `simctl spawn` sees `.caseprobe`
    as missing after creating `.CaseProbe`, so the app logs `case_sensitive_container=yes`.
  - The Mac's case-insensitive APFS underneath still refuses a second name that differs
    only in case. In the guest, `/tmp/CaseT` and then `/tmp/caset` fails with EEXIST.
  - Natively on the Mac the same probe sees one inode for both names.
- iOS device data volumes are case-sensitive APFS. Confirm with the boot log line on the iPad.
- `fix-thunar.sh` (base stage and finalize) handles the only collision in the package set:
  - **The collision.** Thunar's `/usr/bin/Thunar` symlink and its `/usr/bin/thunar` binary
    share one backing file on a case-insensitive disk. The base image came out with only
    `Thunar`, holding the link text.
  - **The fix.** The script removes the alias and restores the ELF from the package.
- The archive is checked for remaining name pairs that differ only in case. Result:
  0 collisions in the final archive.

## Known issues (from all reports)

**Emulator / platform**
- No JIT. The guest runs on the threaded interpreter at about 20–30 host instructions per
  guest instruction. Firefox page loads take 10–30 s; VS Code's workbench takes 22–30 s
  (decoder-fixes.md Perf, vscode-report.md).
- `FUTEX_WAIT_BITSET` absolute timeouts: Rust timed waits spin a core in Firefox
  (wl-bridge/DESIGN.md).
- `claude --help` segfaults intermittently (3/12 on the reference tree). It is a
  pre-existing V8/Node flake (emulator-fixes.md); later fixes reported 20/20 passes.
- Debugging:
  - gdb in the guest crashes the emulator (`proc_seek`, gpu-report.md).
  - BRK logs nothing.
- `/proc/<pid>/exe` readlink on some tasks crashes the app, so `pidof`/`pkill`/`killall`
  must not be used (the desktop uses cmdline scans).
- Netlink is unavailable (EAFNOSUPPORT); `os.networkInterfaces()` throws.
- WebKitGTK is blocked in the socket layer, so it is not shipped.

**Rootfs**
- Firefox shows tofu (empty boxes) for CJK text: example.com served zh/ja copy during the
  test. CJK fonts are not bundled because of their size; add `font-noto-cjk` as an
  optional pack.
- **Mesa 26 needs edge's libraries.** Mesa comes from edge, so libdrm, libxcb and
  wayland-libs-client must come from edge too.
  - The themes stage moved wayland-libs-client back to 1.23. libEGL/libgallium then failed
    to relocate, and VLC's Qt interface ("unknown option --no-qt-privacy-ask") and every
    Qt app stopped loading.
  - finalize.sh now re-pins the three libraries last and fails the build if libgallium,
    libEGL, Qt5Gui, Qt6Gui, VLC's Qt plugin or libxul do not load.
  - `gpu/rootfs-add-gpu.sh` now upgrades libdrm too (a one-word change).
- **Thunar/thunar collision.** On the Mac and in the simulator (case-insensitive), apk
  leaves Thunar's binary overwritten. `fix-thunar.sh` restores it. That script is a build
  step and is not installed in the guest, so an `apk upgrade thunar` inside the simulator
  breaks Thunar again. iPadOS app containers should be case-sensitive; the
  `[boot] case_sensitive_container` line confirms it on the device.
- The VLC video window is closed when the 10 s clip ends; the controls window stays.

**Desktop / bridge**
- Characters typed right after a click that focuses a Firefox field can go to the previous
  focus (about 1 s).
- Linux apps keep their old theme until restarted after a style switch (no XSETTINGS). The
  desktop offers "Restart Linux Apps".
- Style switches take 12–23 s (icon rasterisation in the guest).
- The VLC video surface does not scale down to a smaller window (it is cropped) and takes no
  keyboard input.
- Multi-item drags to other iPadOS apps carry only the first file. A Linux→other-app drag
  goes through Files or the desktop.
- The app's Info.plist does not declare the UTTypes `com.valentinneagu.ish.guest-items` /
  `desktop-launcher`, which logs a "Type Declaration Issues" warning (dnd-report.md).
- On iPadOS 26 the hold-⌘ shortcut overlay is the menu bar. Shortcuts are listed in
  Settings instead.
- **Fixed in this release:**
  - Onboarding's VS Code probe checked `code-oss` instead of `code`.
  - `install-vscode.sh` runs `ish-apply-style --current` (prints the style) where
    `--cache-only` was meant. `ish-install-vscode` and `ish-firstrun` run `--cache-only`
    themselves. The devtools file is the VS Code agent's and was left unchanged.

**GPU**
- zink on MoltenVK is GL 2.1 / GLES 2.0. GtkGLArea (GL 3.2) fails, and full GPU WebRender
  in Firefox renders black.
- There is no zero-copy present: 3 copies per GPU frame.
- Untested on hardware: `shm_open` vs the TMPDIR fallback, and the jetsam effect of blob
  memory.

**VS Code**
- Memory: 2.7 GB idle in the simulator, 4.5 GB peak on the CLI. On an 8 GB iPad without
  the increased-memory-limit entitlement, expect jetsam kills with large projects.
- IntelliSense from the TypeScript server, and `claude` output in VS Code's terminal, are
  not visually confirmed.
- `extensions.verifySignature` is false: vsce-sign hangs under the emulator.

## Pending

1. **`com.apple.developer.kernel.increased-memory-limit`**: blocked until the account holder
   accepts Apple's updated Program License Agreement on developer.apple.com.
   - Then add the key to `app/iSH.entitlements` and rebuild with `-allowProvisioningUpdates`.
   - Re-check that the profile has the capability.
2. **JIT on hardware.** It is compiled in and was verified in the simulator (both engines
   boot the desktop). It has not run on a TXM device yet: run INSTALL-DEVICE.md §3b first.
3. **First test on the iPad**: import time, GPU (Venus on Apple M3), memory under Firefox,
   case sensitivity, audio route, and the Logitech keyboard shortcuts (INSTALL-DEVICE.md §3).
4. **Update path on the device**: install this build over the earlier device build, which
   has an unversioned root. "Update Linux system" should then appear. The simulator run is
   below.
5. **Other agents' work still landing**: syscalls (inotify/netlink/pty), VS Code, drag and
   drop, and JIT. Rebuild the rootfs and the app after they finish.

## Test results (simulator: iPad Air 11-inch M3, iOS 26.0, Release, virtgpu on, M4 Mac mini)

Fresh simulator "iPad Air 11 M3 release" (`0971D9DC…`). The run is in
`release/ReleaseHarness` (`test0`–`test4`). The app is built with
`DESKTOP_AUTOMATION` so the test can drive Linux windows.
- Screenshots: `ipad-jit/release-shots/` (XCUIScreen's native orientation; the content is
  landscape, rotated 90°).
- Step logs: `steps-run1.txt` and `steps.txt`.
- Host memory samples: `memory.txt`.

| Check | Result | Evidence |
|---|---|---|
| Cold first launch: unpacking off the main thread with live progress | **pass**. The splash showed "Unpacking Linux… 432 of 589 MB · 38,376 files" | `01-boot-splash-*.png` |
| First-launch import time | **22.7 s** (23.8 s in an earlier run); kernel boot 2.6 s. `[boot]` lines in `<app tmp>/boot-stats.txt` | boot-stats |
| Cold launch to desktop (splash gone) | **27.6 s** | steps.txt |
| Onboarding, then the desktop | **pass** | `02-onboarding.png`, `03-desktop-first.png` |
| Interrupted import | The staging dir is discarded at launch (code path). An import killed mid-way leaves no root, so the next launch re-imports | Roots.m; the earlier dev run's `roots-staging` was empty after relaunch |
| System update (0347 → 0508 rootfs, app installed over existing data) | **pass**: offered by toast, installed at the next launch with "Updating Linux…" progress (27.4 s). `/root` and `/home` markers were kept. The added package (htop) was listed and reinstalled by the first-run hook in a "Setting up iSH Linux" foot window. The old root was kept | `50-update-offered.png`, `51-updating-*.png`, `52-after-update.png` |
| foot + fastfetch | **pass**: "iSH Linux Desktop (Alpine 3.21 base)", iPad Air 11-inch (M3), Apple M3, "Venus, Vulkan" GPU | `11-foot-fastfetch.png` |
| Thunar | **pass**; it updates live when files change (inotify) | `12-thunar.png`, `18-files-dnd.png` |
| Firefox → https://example.com | **pass**: page rendered 27–47 s after launch | `13-firefox-example.png` |
| Auto-tiling, 3 windows | **pass**: master-stack layout | `14-tiling-3-windows.png` |
| Overview ⌃⌥O | **pass** by keyboard (run 2; run 1's chord was eaten by the on-screen keyboard) | `15-overview.png` |
| Switcher ⌥Tab | **pass**: it opens. In the simulator it stays open because the synthetic chord never releases Option | `16-switcher.png` |
| VLC test clip + audio | **pass** in run 2 (window in 9 s) and by hand. ishaudio stats: 810,806 frames received / 790,134 played, 2 underruns, 2.5 % dropped. Run 1 found no VLC window within 90 s (not reproduced) | `17-vlc.png`, `17b-vlc-manual.png` |
| Files drag and drop (file onto the Desktop place) | **pass** in run 1 (`/root/Desktop/release-dnd.txt` created). In run 2 the row was covered by VLC's windows ("not hittable"): a test layout problem | `18-files-dnd.png` |
| Lock / unlock | **pass** | `19-locked.png` |
| Restart Desktop Session (new `restartSession()`) | **pass**: Linux windows closed without the "stopped unexpectedly" notice, a new ishwl ran (new pid), and Thunar opened again | `20-session-restarted.png`, `21-thunar-after-restart.png` |
| Styles Kylin and Windows | **pass**: the guest theme switched (Thunar light UKUI / Fluent) | `30-style-kylin.png`, `30-style-windows.png` |
| CPU engines (ISH_JIT=1 / 0) | **pass**: both boot the desktop. Quick Settings shows "Native JIT ✓" / "Compatibility mode". A 200k-iteration shell loop took 0.89 s / 9.18 s (10.3x). The fast-mode help sheet opens | `41-quick-settings-jit1.png`, `41-quick-settings-jit0.png`, `42-fast-mode-help.png` |
| Memory, Firefox + Thunar + foot (+ the native shell) | app process **phys_footprint 1.15–1.26 GB, RSS 1.8–1.95 GB** (simulator on M4) | memory.txt |
| DesktopKit unit tests | 49/49 pass | |

The simulator has no hardware keyboard. A focused Linux window brings up the on-screen
keyboard, which covers half the screen in the screenshots and can swallow synthetic
chords.
