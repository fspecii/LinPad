# Contributing to LinPad

LinPad is a Linux desktop for the iPad, built on the [iSH](https://github.com/ish-app/ish) /
[iSH-ARM64](https://github.com/meikis/ish-arm64) emulator. Bug reports, theme submissions and pull
requests are welcome. Please read the [Code of Conduct](CODE_OF_CONDUCT.md) first, and report
security problems [privately](SECURITY.md), not as issues.

## Where things live

| Path | What it is |
|---|---|
| `app/` | The iPadOS app (Objective-C): boot, root filesystems, iPad folder mounts, JIT hand-off |
| `desktop/DesktopKit/` | The desktop shell (SwiftUI package): windows, styles, themes, settings, built-in apps |
| `desktop/UXHarness/`, `desktop/DnDHarness/` | UI test harnesses that run DesktopKit on a mock Linux host |
| `kernel/`, `fs/`, `emu/`, `asbestos/`, `jit/` | The emulator: Linux syscalls on iOS, the ARM64 interpreter and the native JIT |
| `wl-bridge/` | `ishwl`, the Wayland compositor inside Linux, and its bridge to the iPad |
| `gpu/` | virtio-gpu → virglrenderer → MoltenVK |
| `release/` | The Alpine system image, the repair kit, the app catalog (`release/guest/linpad/catalog.json`) and release tooling |
| `themes/` | Desktop styles, colour themes and icon packs installed into the guest |
| `tests/` | Emulator tests (`tests/arm64-insn` is the ARM64 CPU conformance suite) |

## Building from source

You need a Mac with Apple Silicon, Xcode, and Homebrew:

```sh
brew install llvm lld meson ninja libarchive
export PATH=/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/llvm/bin:$PATH
```

**Emulator on the Mac** (fastest loop for kernel, filesystem and CPU work):

```sh
meson setup build -Dguest_arch=arm64 -Djit=enabled --buildtype=release
ninja -C build
build/tools/fakefsify alpine-minirootfs-3.21.0-aarch64.tar.gz alpine-fakefs   # from alpinelinux.org
ISH_JIT=1 build/ish -f alpine-fakefs /bin/sh                                   # drop ISH_JIT for the interpreter
```

**Desktop shell** (no emulator needed; runs in the iPad Simulator):

```sh
cd desktop/DesktopKit
xcodebuild test -scheme DesktopKit -destination 'platform=iOS Simulator,name=<an iPad simulator>'
```

`desktop/UXHarness/run-all.sh` runs the UI tests, one shard per desktop style.

**The app on an iPad**: follow [Quick start](README.md#-quick-start) in the README and
[release/INSTALL-DEVICE.md](release/INSTALL-DEVICE.md). Pass your own team on the command line
(`DEVELOPMENT_TEAM=<your team>`); never commit it. The Linux system image is built by
`release/build-rootfs.sh` (about 50 minutes); [release/RELEASING.md](release/RELEASING.md) covers
public builds and what may ship in them.

## Tests

| Change | Run |
|---|---|
| DesktopKit | `xcodebuild test -scheme DesktopKit` as above |
| Emulator, JIT, CPU | `ISH=build/ish FAKEFS=<fakefs with gcc musl-dev> tests/arm64-insn/smoke.sh` |
| Release tooling | `python3 -m unittest discover -s release/tests` |
| Guest scripts | `shellcheck --severity=warning <files>` (settings in `.shellcheckrc`) |

CI (`.github/workflows/linpad-ci.yml`) runs all of these on every pull request, plus the checks
below. Fixes for emulator bugs should come with a small reproducer under `tests/`.

## Rules

- **No AI attribution in commits.** No `Co-Authored-By` trailers or "Generated with" lines
  naming an AI tool, in commit messages or in files. You are the author of what you submit and
  responsible for it, however you wrote it. CI rejects such trailers.
- **No personal identifiers.** No Apple team IDs, device UDIDs, provisioning profiles,
  certificates, tokens or home-directory paths in committed files. CI checks for team IDs and
  UDIDs.
- **Keep the base system lean.** The image ships the desktop, a browser, a terminal, a file
  manager, an editor, Node, git and the tools the system itself needs. Everything else (mail,
  office, media, language toolchains, games) goes into the catalog
  (`release/guest/linpad/catalog.json`) as an optional pack that the user ticks. Do not add
  packages to the base set in `release/build-rootfs.sh` without discussing it in an issue first.
- **Free licences for everything bundled.** Themes, icon packs, wallpapers, fonts, sounds and
  screenshots must be under a licence that allows redistribution and modification (GPL, LGPL,
  MIT, BSD, Apache-2.0, CC0, CC BY, CC BY-SA, OFL and the like). "Free for personal use",
  non-commercial (CC BY-NC) and no-derivatives (CC BY-ND) licences, or unknown sources, are not
  accepted. Record the licence and source next to the files (see `themes/guest/MANIFEST.md`).
  No company logos or trade dress.
- **Bump the repair kit.** If you change anything under `release/guest`, `themes/guest`,
  `themes/omarchy/guest` or `wl-bridge/guest`, bump `release/guest/repair-kit-version`
  (`yyyymmddNN`), or existing installs will not get the change. CI checks this.
- **Match the code around you.** C follows the existing emulator style; Swift follows
  DesktopKit. Comments explain why, not what. Keep pull requests focused: a bug fix does not
  also refactor.
- **Keep upstream credit.** LinPad is a fork of iSH and iSH-ARM64. Do not remove their credits,
  `docs/README-iSH.md` or the licence files.

## Licence

LinPad is GPLv3 ([LICENSE.md](LICENSE.md)), with the App Store notice from iSH in
[LICENSE.IOS](LICENSE.IOS). By opening a pull request you agree that your
contribution is released under the same terms.
