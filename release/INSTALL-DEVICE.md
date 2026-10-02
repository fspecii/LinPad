# Installing Linux for iPad on the iPad

Target: iPad Air 11-inch (M3), UDID `<DEVICE_UDID>`, iPadOS 17 or later.
Team `<TEAM_ID>`; bundle id `com.valentinneagu.ish.arm64` (unchanged by the rename to "Linux for iPad": the home-screen name changes, the app keeps its data). The build output is still `iSH ARM64.app`.

## 1. What gets installed

`build-ios-release/Release-iphoneos/iSH ARM64.app`:
- Release build, virtgpu on (Venus → virglrenderer → MoltenVK), DesktopKit desktop.
- The native JIT is compiled in (`ISH_JIT_BUILD=enabled`).
  - It runs only when a debugger is attached (StikDebug); otherwise the app uses the
    gadget engine ("Compatibility mode").
  - The boot splash and Quick Settings show "Performance: Native JIT ✓" or "Compatibility
    mode".
  - With StikDebug installed and paired, the app requests the JIT from it at launch
    (Settings › Fast Mode, "Automatic"; section 3b). "Enable fast mode" in Quick Settings
    retries, or explains the setup.
  - The signature keeps `get-task-allow`, which StikDebug needs to attach.
- `root.tar.gz` is `release/out/ish-linux-rootfs-arm64.tar.gz`, built by
  `release/build-rootfs.sh` with `VSCODE=0`. It contains no Microsoft binaries; VS Code is
  downloaded on the iPad on first use. `root.version` holds its version stamp.
- Signed with "Apple Development: <Your Name> (<CERT_ID>)". The signing uses the
  entitlements from Xcode's build and its `embedded.mobileprovision`
  ("iOS Team Provisioning Profile: com.valentinneagu.ish.arm64", expires 2027-10-01). The
  profile lists the iPad's UDID.

To rebuild from scratch:

```sh
cd /Volumes/ExternalHD/Dev/ish-arm64
export PATH=/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/llvm/bin:$PATH
xcodebuild -project iSH.xcodeproj -target iSH-ARM64 -configuration Release -sdk iphoneos \
  -allowProvisioningUpdates SYMROOT=$PWD/build-ios-release IPHONEOS_DEPLOYMENT_TARGET=17.0 \
  DEVELOPMENT_TEAM=<TEAM_ID> ISH_JIT_BUILD=enabled build
release/embed-rootfs.sh --device "build-ios-release/Release-iphoneos/iSH ARM64.app" \
  release/out/ish-linux-rootfs-arm64.tar.gz
```

`embed-rootfs.sh --device` puts the rootfs and its version into the app. It then signs the
app again with the build's own identity, entitlements and profile, and runs
`codesign -v --strict`.

Before installing, check the signature and the profile:

```sh
APP="build-ios-release/Release-iphoneos/iSH ARM64.app"
codesign -v --strict "$APP" && echo signature ok
security cms -D -i "$APP/embedded.mobileprovision" | grep -c <DEVICE_UDID>   # 1
```

## 2. Install

Connect the iPad by USB, unlock it and trust the Mac. Then:

```sh
idevice_id -l                                    # <DEVICE_UDID>
ideviceinstaller -u <DEVICE_UDID> install "build-ios-release/Release-iphoneos/iSH ARM64.app"
```

Installing over an earlier build keeps the app's data, which means the installed Linux system
and `/root`. Then:
- If the installed system is older than the bundled one, or has no version stamp (every
  root made before this release), the desktop shows "A Linux system update … is
  available" with an **Update Linux system** button.
- The update installs on the next app launch.
- It replaces the system and keeps `/root`, `/home`, `/opt`, `/srv`, the account files
  (`/etc/passwd`, `group`, `shadow`, `hostname`, `hosts`) and the onboarding choices.
- The old system stays available as "default (before update …)" in Settings ›
  Filesystems until you delete it there.
- Packages you added yourself are reinstalled from the network in a terminal window that
  opens after the update.

For a clean first launch instead, uninstall first:
`ideviceinstaller -u <DEVICE_UDID> uninstall com.valentinneagu.ish.arm64`.
This deletes the Linux system and all files in it.

Developer Mode must be on (Settings › Privacy & Security). If the iPad says "Untrusted
Developer", trust the profile in Settings › General › VPN & Device Management.

## 3. What to check on the iPad

The iPad must be in landscape, with the Logitech keyboard and trackpad attached.

1. **First launch.**
   - The black launch screen gives way at once to the boot splash.
   - It shows "Unpacking Linux… N of 690 MB · N files" with a moving bar, then
     "Configuring…", then "Starting desktop…".
   - In the simulator on an M4 the unpacking took 23 s (217k files), and the desktop was
     up 28 s after launch. Expect longer on the iPad.
   - Switch to another app during the unpacking and back: it continues.
   - Force-quit during the unpacking: the next launch starts the unpacking again from zero
     and never boots a half-unpacked system.
2. **Onboarding.**
   - Pick a style and turn on "VS Code".
   - "Start Using the Desktop" opens a "Setting up Linux for iPad" terminal, which downloads and
     installs VS Code (about 250 MB; it needs Wi-Fi).
3. **Firefox** (dock/launcher): opens in 10–30 s. Load `https://example.com`.
4. **Terminal (foot)**: `fastfetch` should show "Linux for iPad (Alpine 3.21 base)" (after the next rootfs build; the embedded rootfs predates the rename and still says "iSH Linux Desktop"),
   "iPad Air", "Apple M3" and a GPU line that says "Venus, Vulkan".
   - `vulkaninfo --summary | grep deviceName` should show "Virtio-GPU Venus (Apple M3)".
     That is the first time the GPU path runs on real hardware.
5. **Thunar**, **VLC** (`/root/Videos/ish-test-720p.mp4`: the video plays and you hear a
   440 Hz tone), **Files**: drag a file onto "Desktop" in the sidebar.
6. **Keyboard** (⌃⌥ is Control-Option):

   | Keys | What should happen |
   |---|---|
   | ⌃⌥O | Overview |
   | ⌥Tab | Switcher |
   | ⌃⌥T | Auto-tiling, with 3 windows open |
   | ⌃⌥←/→ | Snap left / right |
   | ⌘⇧Space | Launcher |

7. **Styles.** Settings › Desktop › Style: switch to Kylin, then Windows. Each switch takes
   12–30 s and shows a progress toast.
8. **Power menu.**
   - Lock Screen: a tap or a key unlocks.
   - Restart Desktop Session: the Linux windows close, and a new app opens normally
     afterwards.
9. **Memory.** Turn on Settings › Desktop › Performance overlay (it shows phys_footprint).
   - With Firefox, Thunar and foot open, the simulator measured about 1.5–2 GB.
   - This build lacks the increased-memory-limit entitlement (see CHECKLIST.md), so
     jetsam may kill the app around 3 GB on an 8 GB iPad.
   - Note when that happens and what was open.

## 3b. Native JIT ("fast mode") on the iPad

This is the JIT agent's device test plan (`ipad-jit/jit-report.md`), adapted to this
build. The JIT has not run end to end on a TXM device yet, so run these steps first.

1. **Check the build.** It includes the JIT:
   `nm "build-ios-release/Release-iphoneos/iSH ARM64.app/iSH ARM64" | grep ish_jit_try_enable`
   prints one symbol.
2. **Baseline without the JIT.** Set Settings › Fast Mode to Off and relaunch from the
   Home Screen; Quick Settings shows
   "Performance: Compatibility mode". In foot:
   - `time sha256sum` of a 100 MB file (`head -c 100000000 /dev/urandom > /tmp/f` first)
   - `time node -e 'let s=0; for (let i=0;i<3e8;i++) s+=i; console.log(s)'`
   - `time sh -c 'i=0; while [ $i -lt 300000 ]; do i=$((i+1)); done'`
3. **One-time setup on the iPad** (outside iSH; iSH contains no debugger or tunnel code and
   only hands off to StikDebug through its URL scheme):
   - Install StikDebug and LocalDevVPN.
   - Make a pairing file for this iPad on a computer (for example with iloader) and import it
     into StikDebug, following StikDebug's instructions. Developer Mode must be on.
   - Connect LocalDevVPN.
4. **Automatic fast mode** (the default: Settings › Fast Mode › "Automatic (StikDebug)").
   - Launch iSH from the Home Screen. Before Linux starts, the splash says "Enabling fast
     mode via StikDebug…" and iSH opens
     `stikdebug://enable-jit?bundle-id=com.valentinneagu.ish.arm64&pid=<pid>&script-name=universal.js`.
     The `script-name` part is sent only on TXM devices (iPadOS 26+ on M2/A15 and later, all
     iPadOS 27 devices except iPad8,11/12); the M3 iPad Air has TXM.
   - StikDebug comes to the front, attaches with universal.js and switches back to iSH.
   - iSH then waits for CS_DEBUGGED (and, with TXM, for the debugger still attached),
     prepares its 128 MB code region with `brk #0xf00d` (x16=1), creates the writable
     alias, detaches (x16=0), and boots Linux with the JIT. It never executes a `brk`
     before the debugger is there.
   - It waits about 20 s of its own run time (time spent in StikDebug does not count).
     Then it boots in Compatibility mode and shows "Fast mode is off: … Retry fast mode".
   - It is skipped, with no delay, if the setting is Off, the build has no JIT, the
     install lacks `get-task-allow`, or StikDebug is not installed (`canOpenURL`,
     `LSApplicationQueriesSchemes` = `stikdebug`). Settings › Fast Mode › Status says
     which of these applies.
   - **Retry after Linux has started** works: the JIT starts, and programs started from
     then on (each new process or exec) use it. Programs that were already running stay
     in Compatibility mode until restarted.
   - Manual path, still supported: quit the app, select "Linux for iPad" in StikDebug with
     `universal.js`, and enable JIT; iSH detects the debugger at boot.
5. **Confirm.**
   - The splash and Quick Settings show "Performance: Native JIT ✓". Settings › Fast
     Mode › Status says "On" (or "On for programs started from now on" after a retry).
   - `idevicesyslog -u <DEVICE_UDID> -p "iSH ARM64" -m "fast mode"` shows
     `[fast mode] opening stikdebug://…`, or `[fast mode] not requested: <reason>`.
   - `-m "native JIT"` shows `ish: native JIT on: txm (StikDebug universal.js), 128 MB ...`.
   - `-m "[boot]"` shows `fast_mode=on`, or the failure message.
   - `cs_debugged dual mapping` in the JIT line means the device was taken as non-TXM.
   - No JIT line at all means the JIT is off.
6. **Rerun the step-2 commands.** Expected, from the Mac and the simulator: sha256 and the
   shell loop about 7x faster, the node loop about 10x. In this release's simulator run,
   the 200k-iteration shell loop took 9.84 s on the gadget engine and 1.28 s on the JIT.
7. **Correctness.**
   - `claude --help` 20 times, `cd /root/projects/demo && npx vite build`.
   - Firefox on example.com and Wikipedia.
   - The `tests/arm64-insn` equivalents (`neon`, `conv`, `mem`, `lane`) against
     `ipad-jit/tmp/jitwork/insn/*-native.txt`; `smc`, `pcre_jit_reuse` and `jitsig`
     (these need the guest gcc from the dev rootfs).
8. **Stress.** Leave Firefox or node running for 10+ minutes and watch memory (Performance
   overlay, or Xcode).
   - The debugger makes the 128 MB code arena resident.
   - If jetsam kills the app, lower the iOS default in `jit/codemem.c`. Environment
     variables cannot be set when StikDebug launches the app.
9. **Failure modes.**
   - StikDebug does not open, or shows an error: check LocalDevVPN and the pairing file
     in StikDebug. iSH boots in Compatibility mode after the wait. Use "Retry fast mode"
     once StikDebug works.
   - SIGTRAP at start: a `brk #0xf00d` was not serviced (wrong script, or StikDebug
     detached early). iSH only executes it with the debugger attached, so this should not
     happen. If it does, send the crash report and the `fast mode` log lines.
   - The JIT line says `cs_debugged dual mapping` on a TXM iPad: TXM detection missed this
     model. Report `uname -m` / `hw.machine` and the iPadOS version.
   - An arena above 64 GB is rejected, and the app falls back to the gadget engine.
   - In every failure case the app must still boot in Compatibility mode.

## 4. Logs and crash reports (no sysdiagnose needed)

Live log of the app only (the emulator, DesktopKit and NSLog; boot timing lines start with
`[boot]`):

```sh
idevicesyslog -u <DEVICE_UDID> -p "iSH ARM64" -o ~/ish-device.log
# only the interesting lines:
idevicesyslog -u <DEVICE_UDID> -p "iSH ARM64" -m "[boot]"
idevicesyslog -u <DEVICE_UDID> -p "iSH ARM64" -m LinuxGUI
```

The `[boot]` lines are:
- `case_sensitive_container=yes|no`: whether the iPad's app container is case-sensitive.
- `import_seconds=…`: first-launch unpacking.
- `update_seconds=…`: a system update.
- `boot_seconds=…`: the kernel start.

Jetsam kills (memory) and crashes:

```sh
mkdir -p ~/ish-crashes
idevicecrashreport -u <DEVICE_UDID> -e -k -f "iSH" ~/ish-crashes   # -k keeps them on the iPad
ls ~/ish-crashes; grep -l '"iSH ARM64"' ~/ish-crashes/JetsamEvent* 2>/dev/null
```

A JetsamEvent report with `"reason" : "per-process-limit"` next to the app's name means
memory. An `.ips` file named after the app is a crash; its first thread's backtrace and
`exception` block are what to send back.

Guest-side logs stay inside the Linux system. Read them in foot, or copy them out
through Files:
- `/tmp/ishwl.log`: the compositor.
- `/tmp/ishaudio/pulse.log`: audio.
- `/var/log/apk.log`: package installs, including VS Code.

## 5. Not on this build

- The native JIT without StikDebug. Without StikDebug and LocalDevVPN set up, every
  launch uses the gadget engine, and the app says why (Settings › Fast Mode).
- `com.apple.developer.kernel.increased-memory-limit`. It needs the updated Apple Program
  License Agreement accepted at developer.apple.com first. Then add it to
  `app/iSH.entitlements` and rebuild; Xcode refreshes the profile automatically.
