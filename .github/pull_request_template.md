## What and why

<!-- What changes, and the problem it solves. Link the issue: "Fixes #123". -->

## How it was tested

<!-- Commands you ran and their result, devices or simulators used. Screenshots for visual changes. -->

- [ ] `xcodebuild test -scheme DesktopKit` (DesktopKit changes)
- [ ] `tests/arm64-insn/smoke.sh` (emulator or JIT changes)
- [ ] On an iPad (say which model and iPadOS version)

## Checklist

- [ ] Guest files changed (`release/guest`, `themes/guest`, `themes/omarchy/guest`, `wl-bridge/guest`) and `release/guest/repair-kit-version` is bumped.
- [ ] Nothing new is preinstalled in the base system; optional apps go into the catalog.
- [ ] New themes, icons, wallpapers or fonts are under a free licence, recorded next to them.
- [ ] No Apple team ID, device UDID, personal paths or secrets in the diff.
- [ ] Commit messages carry no AI tool attribution.
