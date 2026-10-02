# Cutting a LinPad release

A release is a GitHub release `v<version>` on [fspecii/LinPad](https://github.com/fspecii/LinPad) with:

| Asset | What it is |
|---|---|
| `LinPad-<version>.ipa` | The app, with the Linux system inside. Ad-hoc signed, so SideStore, AltStore and iloader can re-sign it with the user's Apple ID |
| `LinPad-<version>.ipa.sha256` | Its checksum |
| `linpad-rootfs-<version>.tar.gz` | The Linux system alone, for updates from Settings › Updates without reinstalling the app |
| `linpad-rootfs-<version>.tar.gz.sha256` | Its checksum |
| `rootfs-manifest.json` | `version` (the system's stamp), `release`, `file`, `size`, `sha256`, `minAppVersion` |

`release/source.json` (on `main`) is the SideStore/AltStore source. Users add
`https://raw.githubusercontent.com/fspecii/LinPad/main/release/source.json`, and their sideloader
offers each new version from then on.

## What users get

- **App updates.** SideStore and AltStore read `source.json`. In the app, Settings › Updates
  shows "LinPad X is available" and offers:
  - **Update via SideStore / AltStore**: opens `sidestore://install?url=…` or `altstore://install?url=…`.
  - **Open Release on GitHub**.
  - The steps for iloader users.

  The app never installs an IPA itself.
- **Linux system updates.** The app checks
  `https://api.github.com/repos/fspecii/LinPad/releases/latest` at launch, then every 6 hours, and
  on "Check Now".
  - It sends no token and caches by ETag.
  - It skips automatic checks when offline or in Low Data Mode.
  - If the manifest's stamp is newer than the installed system, it offers "Update Linux system
    (N MB)".
  - The download runs in a background URLSession and can be resumed. The app checks the SHA-256.
  - The download goes through the same path as a bundled update (`Roots.updateDefaultRoot`).
    It installs at the next launch with the boot-splash progress, keeping `/root`, `/home`,
    `/opt`, the account files and the user's packages.
  - `minAppVersion` stops an older app from installing a system it cannot run. Such users are told
    to update the app first.
- **Alpine packages.** Settings › Updates › Linux packages runs `apk update` and `apk version -l '<'`
  weekly or on demand. **Upgrade** runs `apk upgrade` and shows its output, then re-pins Mesa's
  edge libraries, as `linpad-apps` does.

## Licensing: what may be in a public release

`publish.sh` builds the rootfs with `PUBLIC=1`. `release/check-public-rootfs.sh` then fails the
release if any of these is in the image:

| Component | Why it is out | How users get it |
|---|---|---|
| Visual Studio Code (`/opt/vscode`) | Microsoft's proprietary build | Settings › Apps › Visual Studio Code downloads it on the iPad |
| Claude Code (`@anthropic-ai/claude-code`) | Proprietary (Anthropic) | Settings › Apps › Claude Code runs `npm install -g @anthropic-ai/claude-code` on the iPad |
| Kylin logos (`distributor-logo-kylin*`, `kylin-startmenu*`, `openkylin*`) | Trademarks | Not offered. The UKUI theme itself (GPL) stays, with its license in `/usr/share/themes/licenses` |

The theme and icon licenses that `themes/` installs stay in the image. Builds for your own iPad
(`release/build-rootfs.sh` without `PUBLIC=1`) still include Claude Code.

## Steps

Run these on the Mac, one build at a time. Temporary data stays on `/Volumes/ExternalHD`.

1. Commit everything and push it to `main` on the public repo. The tag is made from `HEAD`, which
   must already be on `linpad/main`.

   ```sh
   git push linpad HEAD:main
   ```

2. Do a dry run. It builds nothing and uploads nothing. It writes the notes, the manifest and the
   would-be `source.json` to `release/out/<version>/`.

   ```sh
   release/publish.sh 1.4.0 --dry-run
   less release/out/1.4.0/RELEASE-NOTES.md
   ```

   Edit `RELEASE-NOTES.md` if you like. The publish step regenerates it, so pass `--from <tag>`
   to change the range, or edit the release on GitHub afterwards.

3. Publish.

   ```sh
   release/publish.sh 1.4.0 --publish
   ```

   - It builds the public rootfs (about an hour). To reuse one, pass `--rootfs FILE`; it must
     pass the public check, and `FILE.version` must be next to it.
   - It builds the IPA:
     - `xcodebuild` Release, `ISH_JIT_BUILD=enabled`, virtgpu on.
     - `MARKETING_VERSION=<version>` and `CURRENT_PROJECT_VERSION=<commit count>`.
     - `CODE_SIGNING_ALLOWED=NO`, so no team or certificate is needed.
     - It embeds the rootfs with `embed-rootfs.sh`, then ad-hoc signs with the app's
       entitlements (app group, user fonts, `get-task-allow`).
   - It writes the checksums and the manifest.
   - It runs `gh release create v1.4.0` with all the assets.
   - It updates `release/source.json`.

4. Commit and push `release/source.json`. SideStore and AltStore read it from `main`.

   ```sh
   git add release/source.json
   git commit -m "Release 1.4.0: source.json"
   git push linpad HEAD:main
   ```

5. Check the release:
   - Settings › Updates on an install of the previous version shows the new version, and "Check
     Now" fetches the release.
   - In SideStore, add the source and see the version.

### Options

| Option | Effect |
|---|---|
| `--prerelease` | A GitHub pre-release (needed for versions like `1.5.0-beta.1`). It is offered only to users on the Pre-release channel, and `source.json` is not changed |
| `--rootfs FILE` / `--ipa FILE` | Reuse an existing rootfs or IPA instead of building one |
| `--min-app VERSION` | The oldest app that may install this Linux system. The default is the oldest version in `source.json`; raise it when the system needs new app features |
| `--from REF` | The start of the changelog. The default is the previous `v*` tag, or the last 30 commits for the first release |

### Versions

- The app version is SemVer, compared with the tag (`v1.4.0`).
- Users' installs report `CFBundleShortVersionString`, which `publish.sh` sets from the version.
  Builds made outside `publish.sh` report `MARKETING_VERSION` from `app/Project.xcconfig` (1.3.3,
  inherited from iSH). Keep release numbers above that, or those builds will not be offered the
  update.
- The Linux system version is the build stamp, UTC `yyyymmddHHMM`. It is compared as a number
  with `/usr/share/ish/rootfs-version`.

## Testing without publishing

- **Unit tests** (versions, release JSON, the offer logic, SHA-256, scheduling, apk parsing,
  ETag caching):

  ```sh
  cd desktop/DesktopKit && xcodebuild test -scheme DesktopKit \
    -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M3)' \
    -only-testing:DesktopKitTests/ReleaseFeedTests
  ```

- **The UI against a mock release.** Set `linpad.updates.feedURL` to a local JSON file with a
  release object. Its asset URLs may be `file://`. Then open Settings › Updates.

  ```sh
  xcrun simctl spawn booted defaults write <bundle id> linpad.updates.feedURL /path/to/feed.json
  ```

  `desktop/DesktopKit/Tests/DesktopKitTests/Fixtures/github-release.json` is a starting point.
