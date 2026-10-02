# LinPad growth plan: what Omarchy teaches, and what to build and ship next

Research date: 2026-10-02. Owner: Vali. Status: plan, nothing posted.

How to read this: every claim about Omarchy or another project carries a source link. Lines marked **[inference]** are my reading of the facts, not facts. Lines marked **[verify]** are LinPad claims that need a run on the iPad before they go into public copy.

---

## TL;DR

1. Omarchy did not grow on technology. It grew on a **person with reach** (DHH), a **name for a feeling** ("omakase": someone with taste chose everything for you), **screenshots that sell themselves** (themes, tiling, keyboard flow), **one-step install**, and a **steady drumbeat of releases and blog posts**. The heaviest single spikes came from third parties: YouTubers (typecraft, NetworkChuck), a Cloudflare sponsorship post (776 HN points), and, later, the funding news and criticism threads.
2. The cleanest signal for LinPad: **"Omarchy on Apple hardware without wiping it" is a proven want.** `themartiano/try-omarchy` (Omarchy as a Mac app) reached about 2,450 stars in 5 weeks, and DHH answered with an official "Omarchy M" team on 2026-09-11. LinPad is the iPad version of that wish, and it already installs Omarchy community themes unmodified.
3. LinPad's launch currency is **the video**. A 60-second clip of an iPad with a keyboard running real Firefox, VS Code and a tiled terminal in a Tokyo Night theme is the whole pitch. Build the features that make that clip easy to make and easy to remix: screenshot/rice mode, in-app screen recording, one-tap theme share, a keyboard command menu, and a fastfetch that shows off the iPad.
4. The biggest risks are **expectations** (Firefox takes tens of seconds to load a heavy page in the simulator; most perf numbers are not from the iPad yet), **install friction** (sideloading + StikDebug + LocalDevVPN), and **support load**. All three are mitigated by being blunt in the README and the video.

Top 10 features to build next are at the end of section D.

---

## A. Omarchy case study

### A1. Timeline (facts)

| Date | Event | Source |
|---|---|---|
| 2024-06-05 | Precursor: **Omakub** (DHH's opinionated Ubuntu setup) hits HN, 130 points. Repo now 8.1k stars. | [HN 40591112](https://news.ycombinator.com/item?id=40591112), `gh api repos/omacom/omakub` |
| 2025-06-01 | `basecamp/omarchy` repo created (now `omacom/omarchy`). | `gh api repos/omacom/omarchy` |
| 2025-06-26 | Launch. Blog post "Omarchy is out" (pitched as a love letter to Linux, sister project to Omakub). X post: "Omarchy is ready! ... six beautiful themes in the box". | [world.hey.com](https://world.hey.com/dhh/omarchy-is-out-4666dd31), [X](https://x.com/dhh/status/1938369883617861849) |
| 2025-07-01 | typecraft interview with DHH (DHH: he first learned about Hyprland from typecraft's channel). Second typecraft intro video around 2025-07-30. | [X](https://x.com/dhh/status/1940098954596950428), [X](https://x.com/dhh/status/1950604747909603434) |
| 2025-07-05 to 08-02 | Releases v1.1 to v1.9, roughly every 3 to 5 days. | `gh api repos/omacom/omarchy/releases` |
| 2025-08-06 | HN: "Omarchy, a Linux Distribution by DHH" (omarchy.org), 159 points, 82 comments. | [HN 44811905](https://news.ycombinator.com/item?id=44811905) |
| 2025-08-09 | "All-in on Omarchy at 37signals": company moves Ops/Ruby teams from MacBooks to Framework + Linux; HEY test suite almost 2x faster than M4 Max. HN 78 points. | [world.hey.com](https://world.hey.com/dhh/all-in-on-omarchy-at-37signals-68162450), [HN 44847419](https://news.ycombinator.com/item?id=44847419) |
| 2025-08-24 | HN: "Omarchy Is Out", 215 points, 135 comments. | [HN 45001434](https://news.ycombinator.com/item?id=45001434) |
| 2025-08-25 | **Omarchy 2.0**: real ISO with online installer, AUR-free install, "400 other changes from 45 committers", released on Linux's birthday. | [X](https://x.com/dhh/status/1959990860923449619), [world.hey.com](https://world.hey.com/dhh/omarchy-2-0-16fefc15) |
| 2025-09-04 | Rails World keynote (Amsterdam): DHH installs Omarchy on a fresh Framework laptop and builds a Rails app in about six minutes, on stage. | [rubyonrails.org](https://rubyonrails.org/world/2025/day-1/david-hansson), [testdouble field report](https://testdouble.com/insights/field-report-rails-world-2025) |
| 2025-09-17 | v3.0.0. | releases API |
| 2025-09-22 | **Cloudflare sponsors Ladybird and Omarchy** (CDN, R2, DDoS for ISO/package delivery). HN 776 points, 483 comments: the biggest Omarchy HN thread ever. | [Cloudflare blog](https://blog.cloudflare.com/supporting-the-future-of-the-open-web/), [HN 45332860](https://news.ycombinator.com/item?id=45332860) |
| 2025-10 | Framework criticised for backing Omarchy/DHH/Hyprland. | [crimier.github.io](https://crimier.github.io/posts/Framework-Omarchy/), [Notebookcheck](https://www.notebookcheck.net/Controversy-erupts-over-Framework-s-backing-of-alleged-divisive-open-source-figures.1135468.0.html) |
| 2025-10-16 | "A petabyte worth of Omarchy in a month": ~1 PB of ISOs in 30 days, ~150,000 installs. DHH credits Windows 10 end of support, macOS frustration, Hyprland, and "preconfigured but every configuration changeable". | [world.hey.com](https://world.hey.com/dhh/a-petabyte-worth-of-omarchy-in-a-month-a1fc538e) |
| 2025-10 / 2025-11 | Critical essays: "Thoughts on Omarchy" (Tedium, HN 58), "A Word on Omarchy" (HN 139), "DHH and Omarchy: Midlife Crisis" (GNOME blog, HN 37). | [Tedium](https://tedium.co/2025/10/13/omarchy-linux-distro-commentary/), [HN 45667615](https://news.ycombinator.com/item?id=45667615), [GNOME blogs](https://blogs.gnome.org/alatiera/2025/11/06/dhh-and-omarchy-midlife-crisis/) |
| 2026-05-03 | Dell blog: "Year of the Linux Laptop: Omarchy on XPS" (hardware OEM endorsement). | [HN 47992726](https://news.ycombinator.com/item?id=47992726) |
| 2026-05-24 | "Omarchy Is Not A Distro" (dotfiles critique), HN 186 points. | [HN 48257612](https://news.ycombinator.com/item?id=48257612) |
| 2026-08-14 | **v4.0.0 "Quattro"**: Quickshell rewrite, pitched as built almost entirely by agents; "agentic Linux". | [release](https://github.com/basecamp/omarchy/releases/tag/v4.0.0), [The Register](https://www.theregister.com/software/2026/09/17/omarchy-gains-185m-in-backing-fresh-converts-and-fierce-critics/5296780) |
| 2026-08-21 | NetworkChuck intro video, 430k+ views per search snippet; DHH calls it the best Omarchy intro. | [X](https://x.com/dhh/status/2090827442365612075) |
| 2026-08 | Lex Fridman Podcast #501 with DHH (programming, agents, Linux, Omarchy). | [lexfridman.com/dhh-2](https://lexfridman.com/dhh-2/) |
| 2026-08-23 | `themartiano/try-omarchy` (Omarchy as a hardware-accelerated Mac app) created; about 2,450 stars by 2026-10-02. | `gh api repos/themartiano/try-omarchy`, [HN 49539913](https://news.ycombinator.com/item?id=49539913) |
| 2026-08-26 / 08-30 | Security threads: "development practices lead to predictable security issues" (HN 297/445 comments) and "Any user process can escalate to root" via default `docker` group (HN 536/548). Fixed in 4.0.1 (2026-08-24 per the author). | [HN 49447682](https://news.ycombinator.com/item?id=49447682), [HN 49499854](https://news.ycombinator.com/item?id=49499854), [0xcc.io](https://0xcc.io/posts/omarchy-root-creds/) |
| 2026-08 / 09 | Omacom Foundation: ~$18.5M pledged (1Password, 37signals, DigitalOcean $3M, 12 individual backers). Omarchy.org now claims $21.7M. | [The Register](https://www.theregister.com/software/2026/09/17/omarchy-gains-185m-in-backing-fresh-converts-and-fierce-critics/5296780), [Wikipedia](https://en.wikipedia.org/wiki/Omarchy), [omarchy.org](https://omarchy.org/) |
| 2026-09-11 | **Omarchy M**: official team for Apple Silicon Macs, "keep the machine, lose the OS", plus "Try Omarchy" as a native Mac app. Same week: "Stop Omarchy" and "Omarchy Is a Power Grab" (HN 46 and 98). | [Omarchy M](https://omarchy.us/news/2026/09/introducing-omarchy-m/), [HN 49658869](https://news.ycombinator.com/item?id=49658869) |
| 2026-10-02 | 43,827 stars, 5,164 forks, 66 releases, omarchy.org claims 1.22M+ ISO downloads in year one; r/omarchy has 32.5k members. | `gh api`, [omarchy.org](https://omarchy.org/), reddit API |

### A2. Star growth curve

GitHub no longer lists stargazers with timestamps for this repo through the API (REST returned 404; GraphQL returned no edges), so the curve is assembled from Wayback snapshots of the repo page (exact counts at that moment) plus OSS Insight (event-derived, and the API itself flags its data as a lower bound since 2025-05).

| Date | Stars | Source |
|---|---|---|
| 2025-07-06 | 1,013 | Wayback snapshot |
| 2025-08-22 | 4,769 | Wayback snapshot |
| 2025-09-02 | 6,470 (804 forks) | Wayback snapshot |
| 2025-09 to 2026-08 | slow climb (OSS Insight shows +1k/month falling to ~+100/month by mid 2026) | [OSS Insight API](https://api.ossinsight.io/v1/repos/omacom/omarchy/stargazers/history/?per=month) |
| 2026-09 | a second step: OSS Insight shows its largest month since launch (+7.5k events) | same |
| 2026-10-02 | 43,827 | `gh api` |
| this week | ~800 new stars/week | [star-history](https://www.star-history.com/omacom/omarchy/) |

**[inference]** Two waves. Wave 1 (Jul to Sep 2025) tracks the ISO release, Rails World and the Cloudflare post: about 5,500 stars in the 2 months after the first fetchable snapshot. Wave 2 (Aug to Sep 2026) tracks Quattro, the funding news, NetworkChuck and the controversy, which all landed within four weeks. Between the waves, growth was slow but steady, carried by releases and the theme community. The stars-to-installs ratio is low (43.8k stars vs 1.22M ISO downloads): most users are not GitHub people. For LinPad the inverse is likely, since installing a sideloaded IPA means visiting GitHub.

### A3. Distribution channels DHH used (facts, with frequency as inference)

- **His own blog (world.hey.com)**: launch, 2.0, adoption numbers ("petabyte"), company migration ("all-in at 37signals"). Each post doubled as an HN submission.
- **X**: release announcements with a screenshot or short clip on nearly every release; quote-posts of creators' videos (typecraft, NetworkChuck).
- **YouTube via other creators**: typecraft (interview + intro), NetworkChuck (430k+ views), LinuxBTW, Alex Finn; omarchy.org embeds these videos on the home page.
- **Podcasts**: Lex Fridman #501.
- **Conference stage**: Rails World 2025 live install demo.
- **Corporate proof**: 37signals switching, Framework, Dell XPS blog, Cloudflare/DigitalOcean/1Password sponsorship. Each partner post was a fresh news cycle.
- **Community**: r/omarchy (32.5k), Discord, worldwide meetups (listed on omarchy.org), billboards in Copenhagen (top r/omarchy post).

**[inference]** The rhythm mattered more than any single post: a release every few days in the first two months gave every channel something new to share.

### A4. The narrative

- **"Omakase"** (chef's choice): the user does not configure; someone with taste already did. Repo tagline: "Beautiful, Modern & Opinionated Linux".
- **Beautiful by default**: launch post sold aesthetics first ("six beautiful themes in the box").
- **Keyboard-first**: Hyprland tiling, no title bars, a single menu on Super+Alt+Space.
- **Leave macOS/Windows**: framed around Windows 10 end of life and macOS quality, then made literal with Omarchy M ("keep the machine, lose the OS").
- **2026 pivot: "agentic"**: Quattro and the homepage now say "the malleable OS for the age of agents" and "agents that debug all issues".
- **Developer identity**: Rails app in under six minutes on stage; Neovim, Docker, databases preinstalled.

### A5. Community mechanics

- **Themes as shareable artifacts.** A theme is a git repo; `omarchy-theme-install <url>` or the menu installs it. A community list (awesome-omarchy) and galleries (108+ themes on omarchy.deepakness.com; "+200 Omarchy themes" is a top r/omarchy post). Sources: [omarchy.org/themes](https://omarchy.org/themes/), [awesome-omarchy](https://github.com/Wheel-Smith/awesome-omarchy).
- **Screenshots as marketing.** r/unixporn's month top is almost all `[Hyprland]` posts (1,000 to 1,600 upvotes each, reddit API, 2026-10-02). Omarchy rides that culture.
- **Install in one step.** First a `curl | bash` on Arch, then (2.0) an ISO; today the homepage advertises a 35-second install and VM trials for Mac/Windows.
- **Visible momentum.** Release notes with contributor counts ("45 committers"), download numbers, patrons.

### A6. Criticism and how it was handled

| Criticism | Handling | Source |
|---|---|---|
| "Just dotfiles / a fancy install script, not a distro" | Shipped an ISO, own package repo, then a full shell rewrite (Quattro). Answered with product, not argument. | [HN 48257612](https://news.ycombinator.com/item?id=48257612), [Omarchy 2.0](https://world.hey.com/dhh/omarchy-2-0-16fefc15) |
| Too opinionated (Neovim default, wipes the disk, no torrent) | Kept the opinion as the brand ("omakase"), added escape hatches over time (themes, menus, VM trials). | [Tedium](https://tedium.co/2025/10/13/omarchy-linux-distro-commentary/) |
| Ships proprietary apps (1Password, Obsidian, Typora) | Kept them. | Tedium, The Register |
| Security (docker group root, sudo retries, shellcheck errors) | Fixed the docker-group issue quickly through responsible disclosure (author credits the speed) but critics say the decision process is the problem. | [0xcc.io](https://0xcc.io/posts/omarchy-root-creds/), [HN 49447682](https://news.ycombinator.com/item?id=49447682) |
| DHH's politics; sponsors pressured (Framework, 1Password; Anthropic later removed from the patron list) | DHH framed it as a cancellation attempt; the project kept growing and funding grew. | [The Register](https://www.theregister.com/software/2026/09/17/omarchy-gains-185m-in-backing-fresh-converts-and-fierce-critics/5296780), [Cloudzy summary](https://cloudzy.com/blog/why-omarchy-is-hyped-and-hated/) |

**[inference]** For LinPad: controversy brought Omarchy attention, but it is tied to DHH personally and is not something to copy. What is worth copying: answer technical criticism with a release, publish the fix fast, credit the reporter.

### A7. What people talked about most (from the thread titles and top community posts)

1. How it looks (themes, ricing, wallpapers).
2. How fast it installs and how little you configure.
3. Running it on Apple hardware (r/omarchy top post "Omarchy running on M3", try-omarchy, Omarchy M).
4. Keyboard workflow and tiling.
5. Agents fixing the system ("Omarchy uses webcam in mirror to fix its own drivers", 315 upvotes).
6. DHH himself, and security.

---

## B. Comparable launches

| Project | Peak attention | What drove it | Lesson for LinPad |
|---|---|---|---|
| **iSH** (2018) | "iSH: A Linux shell on iOS" HN 153 (2018-11), "Alpine Linux shell on iOS" HN 193 (2020-03); 20.5k stars | Impossible-sounding claim ("Linux on iOS") + a free TestFlight; then the App Store fight: Apple threatened removal 4 days after launch (Oct 2020) and reversed after appeal, which became its own story. | The "impossible on iPad" angle works. Apple drama gets coverage but you cannot plan it. LinPad builds on iSH: credit it loudly. [ish.app blog](https://ish.app/blog/app-store-removal), [HN 18421016](https://news.ycombinator.com/item?id=18421016) |
| **UTM** (2019 onward) | HN 342 (2023-08); 35.7k stars | Real VMs (Windows, Linux) on iPad; sideloading + JIT story; UTM SE rejected then approved for the App Store (2024-07) without JIT. | The JIT vs no-JIT story is understood by this audience. LinPad's "no VM" is the differentiator against UTM: show both side by side. [iPhone in Canada](https://www.iphoneincanada.ca/2024/07/15/apple-approves-utm-se-the-first-pc-emulator-app-for-ios-following-initial-rejection/) |
| **Asahi Linux** | HN 826 (GPU drivers, 2022-12), 944 (AAA gaming, 2024-10) | Hard engineering milestones explained in long, generous blog posts by the developers; each milestone was news. | Write milestone posts ("How we got Firefox running as a native iPad window", "A JIT on iPadOS 27 with TXM"). Engineering depth is marketing on HN. [Asahi GPU post](https://asahilinux.org/2022/12/gpu-drivers-now-in-asahi-linux/) |
| **Termux** | HN 338 to 468 over years; 61.8k stars | Utility that never goes away; store removal drama (Play Store, 2020-2021) and F-Droid distribution. | Long-tail growth comes from being the default answer to "how do I X on my device". Write the FAQ pages people search for. [HN 25644964](https://news.ycombinator.com/item?id=25644964) |
| **Omakub** (2024) | HN 130 | DHH's name + one command. Moderate. | Omakub was the rehearsal; Omarchy added visual identity and an ISO. Visual identity is the multiplier. |
| **Linux on iPad** (ipadlinux.org, 2020; Linux on A7 devices, 2022) | HN 469 and 426 | Pure curiosity: "it runs Linux!" even with no usable desktop. | The curiosity ceiling alone is ~400 to 500 HN points. A usable desktop with real apps should beat it. [HN 25172883](https://news.ycombinator.com/item?id=25172883), [HN 31679293](https://news.ycombinator.com/item?id=31679293) |
| **Hyprland / rice culture** | Hyprland HN 144; r/unixporn top posts are all Hyprland | Screenshots; animations; "my desktop" identity. | Make a LinPad desktop look like a rice in one tap, and make the screenshot easy. |
| **try-omarchy** (2026-08) | ~2,450 stars in 5 weeks; HN posts small (24 to 28 points) | Rode Omarchy's audience; "try it on your Mac without wiping". | Most of the attention for "Omarchy-like desktop on Apple hardware" comes from the Omarchy community, not HN. Post to r/omarchy. |

---

## C. LinPad positioning and messaging

### C1. One-liners (pick one, test on X)

- **"A real Linux desktop on your iPad. No VM. No jailbreak."** (closest to the README, clearest)
- "Your iPad is a laptop now. Real Firefox, real VS Code, tiling windows."
- "I bought an iPad Air M3 and a keyboard. It couldn't run a terminal. So I built LinPad."

### C2. Hero claims and how solid they are

| Claim | Status | Evidence |
|---|---|---|
| Runs unmodified aarch64 Alpine Linux apps on the iPad, no VM, no jailbreak | Solid | Architecture; installed on the owner's iPad Air M3 |
| Real Firefox and VS Code as native windows | Solid, show it on video | README screenshots |
| Installs Omarchy community themes from a git URL | Solid in code (`ColorThemeStore.install`, PORT-SPEC 4.8) **[verify]** one community theme end to end on the iPad |
| "~4.8x faster with the JIT" | **[verify]**: geometric mean 4.84x measured on an M4 Mac CLI, not yet on the iPad (hub note) |
| "GPU acceleration via Metal" | **[verify]**: Venus over MoltenVK measured on Mac and simulator; zink tops out at GL 2.1 / GLES 2.0; Firefox stays on software WebRender | `gpu/DESIGN.md` |
| "Firefox scrolls at 30 to 50 fps" | **[verify]** on device; simulator shows 5 to 21 fps scroll bursts before the JIT code-cache fixes, Wikipedia load ~30 s | `wl-bridge/DESIGN.md` |
| Free and open source (GPLv3) | Solid | LICENSE |

Rule: a number only goes into public copy once it was measured on the iPad and the measurement is in the repo.

### C3. Audiences (ordered by how fast they share)

1. **Omarchy / Hyprland / r/unixporn ricers**: want their theme and tiling everywhere. Hook: "your Omarchy theme, on your iPad".
2. **Developers with an M-series iPad + keyboard** who feel they bought a toy. Hook: VS Code + Claude Code + git + Node on the couch.
3. **Sideloading / jailbreak-adjacent tinkerers** (SideStore, StikDebug, UTM users). Hook: no VM, JIT via StikDebug, one source URL.
4. **Linux press and YouTubers** looking for the next "it runs Linux" story.
5. Later: students who own only an iPad.

### C4. Launch narrative

The founder story is already in the README and it is the best asset: a laptop-class iPad, a Logitech keyboard, and nothing to do with it except Netflix. Structure for every channel:

1. Problem (5 s): iPad + keyboard, Stage Manager, no terminal.
2. Turn (5 s): open LinPad, desktop appears.
3. Proof (40 s): Firefox, VS Code with a TypeScript project, a tiled terminal with fastfetch, theme switch in one keypress, drag a file from iPadOS Files.
4. How (10 s): "no VM: a Linux syscall translator with an ARM64 JIT, Wayland windows become iPad windows".
5. Ask: star + SideStore source URL.

**[inference]** Do not lead with "for geeks". Lead with the before/after of the iPad. Geeks self-select.

---

## D. Viral feature roadmap

Impact = how likely the feature produces a shareable post or removes a reason not to install. Effort: S (days), M (1 to 2 weeks), L (weeks+). Feasibility is checked against `wl-bridge/DESIGN.md`, `gpu/DESIGN.md`, `jit/DESIGN.md`, `themes/omarchy/PORT-SPEC.md` and the current DesktopKit sources.

### D1. Scored list

| # | Feature | Impact | Effort | Feasible? Notes |
|---|---|---|---|---|
| 1 | **Rice shot mode**: one shortcut hides cursor/notifications/debug noise, renders the desktop at native resolution, optional device frame + caption ("LinPad · theme · style"), saves to Photos and opens the share sheet | Very high | S | Yes. DesktopKit is SwiftUI; Linux windows are already `CALayer` contents in-process, so an `UIGraphicsImageRenderer` snapshot captures them. No screenshot feature exists today (grep). |
| 2 | **Screen recording of the desktop** with ReplayKit (`RPScreenRecorder`), optional key-press overlay, saves an MP4 | Very high | S to M | Yes, ReplayKit records the app's own UI with no extra entitlement. The key overlay is what makes keyboard-workflow clips readable. |
| 3 | **First-run "wow in 60 seconds"**: after install, one button lays out Firefox + VS Code (or Mousepad if VS Code not installed) + foot with fastfetch, tiled, in a hand-picked theme | Very high | M | Yes, uses the existing tiling + prewarm. This is literally the demo video, reproducible by every user, so every user can post the same clip. |
| 4 | **Fast-mode setup wizard**: detects StikDebug/LocalDevVPN/pairing file, walks through each step with screenshots, tests JIT, and falls back cleanly | High (conversion) | M | Yes. JIT path is documented in `jit/DESIGN.md` §10. Install friction is the #1 reason people will bounce. |
| 5 | **Omarchy-compatible theme gallery + one-tap install**: a static site (GitHub Pages) listing compatible community themes with previews rendered by LinPad, each with an "Open in LinPad" `linpad://theme/install?url=` link | High | M | Yes, install-from-git exists; add a URL scheme handler. Do not copy Omarchy wallpapers or previews (PORT-SPEC §5). |
| 6 | **Theme share/export**: export the current colour theme as a `colors.toml` repo-shaped folder or `.linpadtheme` file through the share sheet; import via AirDrop/Files | High | S to M | Yes, `ThemeEditor` exists; the format already matches Omarchy's `colors.toml`, so LinPad themes also work on Omarchy. Two-way compatibility is the story. |
| 7 | **Keyboard command menu** (Omarchy-style single menu): `⌃⌥Space` opens a fuzzy, nested menu: apps, themes, styles, layouts, workspaces, "capture", "update", "install package" | High | S to M | Yes, native SwiftUI. `⌘` goes to the app, so keep it on `⌃⌥`. |
| 8 | **Window animations** (Hyprland-like): spring open/close, workspace slide, tile reflow, optional gaps/rounded borders/active-border gradient per theme | High (video quality) | S to M | Yes, native SwiftUI animations; costs nothing in the guest. Make them toggleable for low-power. |
| 9 | **fastfetch flex**: LinPad ASCII logo, iPad model and chip, "JIT: on (StikDebug)", "GPU: Venus → Metal", theme name; `linpad-fetch` alias | Medium-high | S | Yes, fastfetch already ships (README screenshot). The fetch screenshot is the most-posted image in r/unixporn culture. |
| 10 | **Rice packs**: one file bundling style + colour theme + icon pack + cursor + font + wallpaper URL + tiling settings; import/export/share | Medium-high | M | Yes, all axes exist separately (styles, colour themes, icon packs, wallpapers). Wallpapers by URL only (licensing). |
| 11 | **Local AI bridge**: run a small model natively in the iOS process (llama.cpp Metal or MLX) and expose an OpenAI-compatible endpoint on `localhost` to the guest, so Linux tools (shell helpers, VS Code extensions, `aichat`) use it offline | High (2026 "agentic" wave) | M to L | Plausible. Native inference avoids emulation and Venus entirely. Memory is the constraint (iPad Air M3 has 8 GB and the app already uses 1.2 to 2.3 GB): 1B to 3B Q4 models. **Spike first.** |
| 12 | llama.cpp **inside** Linux: CPU under the JIT, or Vulkan via Venus → MoltenVK | Medium | M (spike) | CPU path should work (aarch64 NEON through the JIT) but tokens/s unknown; Vulkan compute via Venus is unproven on device and adds copies. Only a demo, not a feature. |
| 13 | **"It runs Doom"** demo: chocolate-doom / ScummVM / DOSBox as Linux windows | Medium-high (meme) | S | Likely: 2D/software rendering through Wayland SHM works today. Cheap viral clip. |
| 14 | iPad **Files & Photos access** from Linux (already on roadmap) | Medium | M | Yes; reduces "how do I get my files in" support. |
| 15 | **External display** as a second LinPad screen | Medium-high (the "laptop/desktop replacement" shot) | M | Probably (UIScene external display); needs a spike on iPadOS 27. |
| 16 | **Achievements / onboarding quests** ("First rice", "Installed a package", "Compiled with JIT") | Low | S | Easy but reads as gimmick to this audience. Skip unless onboarding needs it. |
| 17 | **Steam / Wine / AAA games** | Would be huge, but | XL | **Not realistic.** zink on MoltenVK only reaches GL 2.1 / GLES 2.0 (`gpu/DESIGN.md`), x86 needs box64/FEX on top of an emulator, and memory is tight. Do not tease it. |
| 18 | **Docker-like containers** | Medium | XL | **Not realistic** as Docker: iSH has no namespaces/cgroups/overlayfs. A realistic cousin: multiple Alpine rootfs "boxes" switchable per terminal (chroot-style). Low priority. |
| 19 | "**Omarchy mode**" (exact Omarchy look) | High short-term | S | Technically easy (palettes, tiling, no title bars), but **do not name it Omarchy** or ship its logo/wallpapers (PORT-SPEC §5). Ship it as a "Tiling Dark" or "Keyboard" style that happens to read Omarchy themes, and say "compatible with Omarchy community themes" with attribution. |

### D2. Top 10 to build next (ranked)

1. **Rice shot mode** (S, very high): every user becomes a marketer.
2. **In-app screen recording with key overlay** (S to M, very high): makes clips trivial.
3. **First-run "wow in 60 seconds" layout** (M, very high): the demo, reproducible.
4. **Fast-mode setup wizard** (M, high): removes the biggest install drop-off.
5. **Keyboard command menu `⌃⌥Space`** (S to M, high): the Omarchy feel, and great on video.
6. **Window animations + per-theme gaps/borders** (S to M, high): turns screenshots into rices.
7. **Theme share/export + `linpad://` install links** (S to M, high): themes become shareable artifacts.
8. **Theme gallery site** with "Open in LinPad" buttons (M, high): the Omarchy themes page, for iPad.
9. **fastfetch flex** (S, medium-high): cheapest viral image.
10. **Local AI bridge spike** (M to L, high): rides the 2026 "agentic OS" wave; ship only if tokens/s look good on the iPad.

Honourable mention: "It runs Doom" clip (S), rice packs (M), external display (M).

---

## E. Launch plan

### E0. Before anything is posted (blockers)

1. **Publish a real release.** `release/source.json` has `"apps": []` today and the repo has 0 stars, created 2026-10-02. Cut v1.0.0 with `release/publish.sh` and test the SideStore source on a clean device.
2. **Measure on the iPad**: JIT speedup, Firefox launch/page load/scroll, VS Code memory, GPU. Replace simulator numbers in README.
3. **Commit hygiene**: the hub note says most work was uncommitted. The public repo must build from a tag.
4. **GPL compliance** (see E5).
5. **README top**: an autoplaying GIF (5 to 8 s: open LinPad, tiled Firefox + VS Code + terminal, theme switch) above the screenshots; a "Install in 3 steps" block; a "Known limitations" block; a "Compatible with Omarchy community themes" line with attribution.
6. **Issue templates** (bug with diagnostics export, device/iPadOS/StikDebug version), GitHub Discussions on, FAQ.

### E1. Assets

| Asset | Spec |
|---|---|
| 60 s video (X, Shorts, Reels) | Script in C4. Real iPad filmed from above + screen recording overlay. No music voice-over needed; captions. |
| 3 min YouTube demo | Before/after, install walkthrough (SideStore source, StikDebug), Firefox, VS Code + Claude Code, tiling + workspaces, themes (install an Omarchy community theme from URL), honest "what's slow" section, how it works diagram. |
| 8 to 10 min "how it works" video/blog | iSH → ARM64 JIT on TXM via StikDebug → Wayland bridge → Venus/Metal. This is the HN/Asahi-style engineering post. |
| GIF | 5 to 8 s, <5 MB, for README and Reddit. |
| Screenshots | 1) Hero: iPad on a desk with keyboard, tiled Firefox + VS Code + foot. 2) fastfetch. 3) Theme grid (4 themes). 4) Five styles. 5) VS Code with Claude Code. 6) Overview/workspaces. 7) Drag-and-drop from Files. 8) Before/after Stage Manager vs LinPad. |
| Press kit | `docs/press/`: logo (own artwork, no Apple/Tux marks), 6 screenshots, 60 s video, 100-word and 25-word descriptions, founder bio, contact, facts table with measured numbers. |
| Blog post | "I bought an iPad Air M3 and a keyboard. It was useless. So I built LinPad." On webdesignstudio.london or dev.to, linked from everything. |

### E2. Channel order and timing

Pick a Tuesday to Thursday, not an Apple event week. Times in US Eastern.

| When | Channel | Notes |
|---|---|---|
| Day -7 to -1 | Seed: 5 to 10 trusted testers (SideStore/StikDebug users) install and report | Avoid launching with an install bug. |
| Day 0, 08:30 | **X thread** from @AmbsdOP with the 60 s video natively uploaded; tweet 2 the "how it works" diagram; tweet 3 the install link. Pin it. | The video is the post. Reply to your own thread with the GIF and the GitHub link (links in tweet 1 reduce reach, per common practice, **[inference]**). |
| Day 0, 08:30 | **YouTube** 3 min demo live on @Ambsd-yy7os, Shorts cut same day | Link in the README. |
| Day 0, 09:00 | **Show HN**: "Show HN: LinPad, a real Linux desktop on the iPad (no VM, no jailbreak)" linking the GitHub repo; first comment = founder story + how it works + honest limits | Stay in the thread for 6 hours. HN rewards depth and candour; Asahi-style. |
| Day 0 to 1 | **r/sideloaded** (sideloading talk is redirected there by r/ipad's own rules), **r/omarchy** ("I Made a Thing": Omarchy themes on an iPad), **r/iPadPro** | r/omarchy is the try-omarchy lesson: the most receptive audience. |
| Day 1 to 2 | **r/unixporn**: a real rice (not defaults; rule 3), correct tag, busy screenshot, details comment (rules 2, 5, 6) | Title pattern from the sub's top posts: `[LinPad] ...` style tag in brackets; check with mods first which tag fits a non-WM desktop. |
| Day 2 | **r/linux** (flair "Mobile Linux" or "Software Release"), **r/ipad** only inside the General Discussion thread (self-promo rule) | Do not post a standalone r/ipad self-promo. |
| Day 2 to 3 | **Mastodon / Fediverse** (fosstodon.org), Lemmy linux communities | FOSS crowd; lead with GPL and credits to iSH. |
| Day 3 to 7 | **Creator outreach**: typecraft, NetworkChuck, Brodie Robertson, The Linux Experiment, DistroTube, Christopher Lawley (iPad), and the try-omarchy author | Send a 60 s video + IPA + a pre-configured rice pack. |
| Day 3 to 7 | **Press tips**: OMG! Linux, Phoronix, It's FOSS, Notebookcheck (covered try-omarchy), 9to5Mac, iDownloadBlog, MacRumors, The Register | One-paragraph pitch + press kit link. |
| Week 2 | **Product Hunt** | Lower fit for a sideloaded app; do it once the install is smooth. |
| Ongoing | Release every 1 to 2 weeks with a short clip and changelog ("what's new in 60 s") | Omarchy's v1.x cadence (every 3 to 5 days) kept every channel fed. |

### E3. README improvements (concrete)

- Add a GIF hero and a "Watch the 60 s demo" link at the top.
- Add "Install in 3 steps" (SideStore source → install → optional fast mode) before the build-from-source section; move the Xcode build to `docs/BUILD.md`.
- Add "Honest limits": iPad M1+ only, sideloaded, Firefox loads heavy pages slowly, VS Code needs ~2+ GB, GPU is GL 2.1/Vulkan via Venus, no x86, no Docker.
- Add "Themes": "Install any Omarchy community theme from its git URL" + attribution.
- Replace style names that are trademarks with descriptive labels in public copy ("Windows-like", "macOS-like"), and keep Kylin out of marketing (see E5).
- Add Discussions, FAQ, and a short "How it works" link to a long-form post.

### E4. What NOT to do

- **Do not submit to the App Store** and do not market it as coming there. JIT and downloading executable code violate guidelines 2.5.2/4.7 (iSH and UTM SE history), and GPLv3 sits badly with App Store terms.
- **Do not sign and distribute the IPA with your own developer certificate** for the public. Keep releases ad-hoc signed so each user signs with their own Apple ID (already the case in `release/RELEASING.md`). Distributing with your team cert risks revocation of your developer account.
- **Do not use "Omarchy" as a feature or mode name**, the Omarchy logo, its previews or wallpapers. Nominative use only: "compatible with Omarchy community themes", with the MIT attribution from PORT-SPEC §5.
- **Do not use the Apple logo or Tux in the LinPad logo**; avoid "iPadOS" or "Apple" in the app name. "Linux for iPad" as a descriptive subtitle is lower risk than putting the mark in the name; keep "LinPad" as the name.
- **Kylin, Ubuntu, Windows, macOS style names** are trademarks: use them only descriptively, keep Kylin logos out (already enforced by `check-public-rootfs.sh`).
- **Do not promise games, Steam, Wine or Docker.**
- **Do not inflate numbers** from the Mac/simulator as iPad numbers. HN will measure.
- **Do not tag DHH or Omarchy accounts asking for a retweet**; let the r/omarchy post and creators carry it. Do not enter the political fight around Omarchy in any thread.
- **Do not crosspost the same text everywhere on the same hour**; Reddit spam filters and moderators will remove it. Write each post for its sub.

### E5. Licensing obligations to close before launch

- LinPad is GPLv3 (iSH). Each IPA release must have its **corresponding source** at the same tag: emulator, app, DesktopKit, scripts, and the build scripts for the rootfs.
- The rootfs redistributes Alpine packages, many GPL/LGPL. Provide an **offer of source**: the exact `apk` package list with versions per release, plus a mirror or pinned links to the matching Alpine aports sources (Alpine's own mirrors rotate old versions out). Today `RELEASING.md` covers what is excluded (VS Code, Claude Code, Kylin logos) but not this.
- MoltenVK (Apache-2.0), virglrenderer/Mesa (MIT): include notices in the app's About → Acknowledgements.
- Firefox: ship Alpine's unmodified `firefox-esr` build; configure only through supported prefs/policies, and do not use the Firefox logo in LinPad marketing beyond saying it runs Firefox. **[verify]** that LinPad's prefs change nothing Mozilla's trademark policy treats as a modified build.
- Theme palettes and Omarchy templates: MIT attribution as written in PORT-SPEC §5; rename or drop "Ristretto" (Monokai Pro) and "Lumon" (Severance) in public builds.

---

## F. Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **Apple closes the JIT path** (StikDebug's debugger-written pages under TXM on iOS 26+/27; Apple has broken JIT methods before) | Medium | High (speed) | The threaded-code engine still works without JIT (~4.8x slower); say so up front; keep fast mode optional; track StikDebug releases; keep the persistent translation cache (jit/DESIGN.md §13) to cut cold-start cost. |
| **StikDebug / LocalDevVPN / pairing-file dependency** breaks or changes protocol | Medium | High | Pin a tested StikDebug version in docs; wizard detects versions; contribute upstream; credit them visibly (good relations matter). |
| **Free Apple ID limits** (7-day expiry, 3 active sideloaded apps, app ID limits) | Certain | Medium | Explain SideStore auto-refresh; recommend a paid developer account for heavy users; keep data in the app group so reinstall keeps `/root` and `/home` (already designed: never change the bundle ID). |
| **Performance expectations** (Firefox heavy pages ~30 s in the simulator; memory 1.2 to 2.3 GB) | High | High (bad first impression, HN backlash) | Measure on device; show real speed in the video, no speed-ramping; "Honest limits" in README; lead with VS Code/terminal/dev work where it shines; keep improving Firefox (README roadmap). |
| **Memory/jetsam kills** with VS Code + Firefox | Medium | Medium | Document 8 GB iPads as the floor for VS Code + Firefox together; show a memory meter in quick settings; request `increased-memory-limit` where the user's account allows. |
| **Support load** (sideloading questions, StikDebug setup) | High | Medium | Wizard + FAQ + issue templates with diagnostics export; GitHub Discussions for Q&A; label `install-help`; a short troubleshooting video. Consider a Discord only once Discussions overflow. |
| **Apple legal/takedown of the repo** | Low | High | No Apple marks in the logo, no App Store circumvention claims, no enterprise cert, no jailbreak; frame it as an open-source developer tool sideloaded by the user. |
| **Trademark complaints** (Omarchy, Kylin, Ubuntu, Microsoft, Linux) | Low to medium | Medium | Descriptive use only, attribution, no logos; "LinPad" as the name. |
| **Being lumped into the Omarchy controversy** | Medium | Low to medium | Talk about themes compatibility, not about DHH; stay out of political threads. |
| **Security criticism** (curl | sh, running as root in the guest, theme install from git) | Medium | Medium | Theme installer already rejects exotic transports and executables (PORT-SPEC 4.8); verify SHA-256 for system updates (already in README); publish a short SECURITY.md specific to LinPad; fix reported issues fast and credit the reporter (the Omarchy docker-group lesson). |

---

## Sources (primary)

- Omarchy repo and releases: `gh api repos/omacom/omarchy`, https://github.com/omacom/omarchy
- DHH posts: https://world.hey.com/dhh/omarchy-is-out-4666dd31, https://world.hey.com/dhh/all-in-on-omarchy-at-37signals-68162450, https://world.hey.com/dhh/omarchy-2-0-16fefc15, https://world.hey.com/dhh/a-petabyte-worth-of-omarchy-in-a-month-a1fc538e
- X: https://x.com/dhh/status/1938369883617861849, https://x.com/dhh/status/1959990860923449619, https://x.com/dhh/status/1940098954596950428, https://x.com/dhh/status/2090827442365612075
- HN threads (points/comments from the Algolia API, 2026-10-02): https://hn.algolia.com/api/v1/search?query=omarchy&tags=story
- Cloudflare: https://blog.cloudflare.com/supporting-the-future-of-the-open-web/
- The Register (funding, criticism, Omarchy M): https://www.theregister.com/software/2026/09/17/omarchy-gains-185m-in-backing-fresh-converts-and-fierce-critics/5296780
- Wikipedia: https://en.wikipedia.org/wiki/Omarchy
- omarchy.org (claims: 1.22M ISO downloads, $21.7M pledged): https://omarchy.org/
- Omarchy M: https://omarchy.us/news/2026/09/introducing-omarchy-m/
- Security: https://0xcc.io/posts/omarchy-root-creds/
- Critique: https://tedium.co/2025/10/13/omarchy-linux-distro-commentary/
- Star data: Wayback Machine snapshots of github.com/basecamp/omarchy; https://api.ossinsight.io/v1/repos/omacom/omarchy/stargazers/history/?per=month (flagged by the API as lower bounds); https://www.star-history.com/omacom/omarchy/
- Themes: https://omarchy.org/themes/, https://github.com/Wheel-Smith/awesome-omarchy
- Reddit: subreddit rules and month-top posts for r/unixporn, r/ipad, r/linux, r/iPadOS, r/omarchy, read via the Reddit API on 2026-10-02
- iSH: https://ish.app/blog/app-store-removal; UTM SE: https://www.iphoneincanada.ca/2024/07/15/apple-approves-utm-se-the-first-pc-emulator-app-for-ios-following-initial-rejection/
- StikDebug: https://github.com/StikDebug/StikDebug
- LinPad internals: `wl-bridge/DESIGN.md`, `gpu/DESIGN.md`, `jit/DESIGN.md`, `themes/omarchy/PORT-SPEC.md`, `release/RELEASING.md`
