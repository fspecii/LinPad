# ishwl: Linux GUI apps as native DesktopKit windows

## Decision

A small Wayland compositor, `ishwl`, runs as a guest process. It never draws a desktop.
Each `xdg_toplevel` and `xdg_popup` is composited, together with its subsurfaces, into a
separate buffer file. The iOS app maps that same file and shows it in a DesktopKit
window. Input goes back over a FIFO. The design uses no VNC, no X11 and no whole-screen
framebuffer. The only emulator-side code is a guest library (`scm-compat`). No emulator
source is touched.

## What iSH gives us (findings)

| Mechanism | iSH behaviour | Consequence |
|---|---|---|
| `mmap(MAP_SHARED)` of a fakefs file | `realfs_mmap` does a host `mmap(MAP_SHARED)` of `<root>/data/<path>` (fs/real.c) | A guest file is shared memory with the iOS app, which is the same process: zero copy and coherent |
| `memfd_create` | silent stub, returns ENOSYS (kernel/arch/arm64/calls.c:277) | GTK falls back to `shm_open`, so `/dev/shm` must exist (ishwl creates it) |
| AF_UNIX sockets | real host sockets at `sock_tmp_prefix<pid>.<id>`. The guest path is a fakefs node | libwayland works unchanged |
| SCM_RIGHTS | emulated in-kernel (struct fd queue). **Broken for ARM64 guests:** `struct cmsghdr_` uses the 12-byte i386 layout, while aarch64 uses 16 bytes, so every fd is silently dropped | Fixed in the guest by `src/scm-compat.c` (see below) |
| `wl_shm_pool.resize` | `mremap` that grows a file mapping returns EFAULT (`FIXME` in kernel/mmap.c) | ishwl implements `wl_shm` itself (munmap and mmap), not libwayland's |
| timerfd with `TFD_TIMER_ABSTIME` in epoll | stalls the libwayland event loop | ishwl's tick comes from the `wl_event_loop_dispatch` timeout instead (16 ms only while frame callbacks are pending, otherwise 1 s) |
| `signalfd` | stub | children are reaped with `waitpid(WNOHANG)` on the tick |
| FIFOs | `mknod S_IFIFO` becomes a host `mkfifo` in the data dir | the control channel is two host-visible FIFOs |
| wait4 | returns EINTR when the child takes more than 1 s (`wait_for` timeout treated as a signal, kernel/exit.c:575) | `gcc -O2` fails inside the guest, so the build uses a cc1+as wrapper |
| `readlink /proc/<pid>/exe` | segfaults the whole app for a task without an exe file (`proc_pid_exe_readlink` → `generic_getpath`, NULL deref); busybox `pidof` triggers it | liveness is never checked with `pidof`/`/proc`; see Session below |
| `flock` | a host `flock` on the backing file | ishwl holds `/tmp/ishwl/alive` locked; the host tests it with `LOCK_NB` |

All workarounds keep working once the emulator is fixed: scm-compat probes and turns
itself off, the shm and loop changes are plain POSIX, and `ccwrap` is only a build aid.

**Re-verified (2026-10-01) on the emulator with the syscall and CPU fixes.** The probe
reports `scm-compat: off (native fd passing works)`, and Thunar renders through ishwl.

Socket issues found with Firefox. The emulator now fixes the first two (emulator-fixes.md
#19, #20); scm-compat, which is preloaded into the whole session, still guards against
them on older builds:

| Issue | Effect | Workaround |
|---|---|---|
| A stream `sendmsg` carrying two or more fds returned EINVAL | Firefox's wl_shm pools and its IPC hit it; the IPC "pipe error" killed Firefox | On EINVAL the message is re-sent with one fd per chunk (each fd but the last rides on one payload byte), which is legal on a stream socket |
| `sendmsg` with an fd that is not open dereferenced NULL in `fs/sock.c` | The whole app crashed | The shim checks every fd first and returns EBADF |
| Host unix sockets are Darwin's: 8 KiB buffers, against Linux's ~200 KiB | When a send with SCM_RIGHTS hits EAGAIN on the host, iSH can hang or crash | The shim raises SO_SNDBUF/SO_RCVBUF to 1 MiB on `connect` and `socketpair`; ishwl does the same on accepted clients and raises libwayland's per-client buffer to 1 MiB |

## Data path

```
GTK app ──wl_shm buffer (shm_open file)──▶ ishwl ──damage-rect copy──▶ /tmp/ishwl/v<id>-<gen>.buf (MAP_SHARED)
                                             │                                   ▲ same host file
                                             └──"frame …" on notify FIFO──▶ LinuxGUIBridge (iOS) mmaps it,
                                                                             copies into a CGImage, sets
                                                                             CALayer.contents, writes "ack"
```

- **Compositing.** On commit, ishwl copies only the damaged rectangle of the view's
  surface tree into the view's buffer. The root surface is a `memcpy` per row, and
  subsurfaces are alpha-blended. The window geometry is cropped, so CSD shadows never
  reach the host.
- **Frame pacing.** One frame per view is in flight at a time. The host acks on the next
  display refresh (CADisplayLink), and frame callbacks fire on the ack, so a client draws
  at most one frame per refresh, and a hidden or stalled window throttles its client.
  A commit that arrives while a frame is in flight keeps its composite request
  pending until the ack. Dropping it once froze Firefox: a commit with frame callbacks
  but no damage left those callbacks unanswered, and Firefox never drew again.
  A lost ack would freeze the view the same way, so ishwl treats 1.5 s without one as
  lost, logs
  `view N: no ack for frame S, resending` and sends the view again. The host acks
  every frame line it parses, even one it cannot show.
- **Resizes.** A resize creates a new buffer file (`<gen>`) instead of truncating the old
  one, so a host mapping can never SIGBUS.
- **Host copy.** The host makes one native copy per frame (memcpy of at most a few MB),
  so the guest can reuse the buffer straight after the ack.
- **Frame log.** `ISHWL_FRAMELOG=FILE` appends `MS VIEW SEQ DAMAGE_W DAMAGE_H` per
  composited frame (devtools/bench uses it for frame rates and input latency).
- **HiDPI.** `wl_output` advertises scale 2 (`ishwl --scale N`, or `/etc/ishwl/options`).
  `/etc/ishwl/app-scale` overrides it per program: lines `PROGRAM SCALE`, matched on the
  basename of the client's executable (e.g. `firefox-esr 1`). That client renders a
  quarter of the pixels and the host scales the frame up.
  An optional third column is the scale while the client has a fullscreen toplevel
  (`firefox-esr 2 1`: sharp text, fullscreen video at scale 1). On `set_fullscreen` ishwl
  re-sends `wl_output` mode/scale/done to that client and a configure with the
  fullscreen state, which Firefox needs to resolve `requestFullscreen()`.
  Every displayed surface gets `wl_surface.enter(output)`, so GTK renders at 2x. A view is
  composited at its root surface's buffer scale; subsurfaces at another scale are
  nearest-neighbour scaled. Frames carry the scale and the host sets `contentsScale`,
  so one Linux logical pixel is one iOS point and text is pixel-exact on Retina.

## Protocol (one line per message, strings percent-encoded, `-` for empty)

ishwl → host (`/tmp/ishwl/notify`):
`hello 1 SOCKET`, `toplevel ID PARENT MINW MINH MAXW MAXH`, `popup ID PARENT X Y GRAB`,
`title ID TITLE APPID`, `frame ID SEQ W H STRIDE FILE OPAQUE DX DY DW DH SCALE` (sizes in
pixels), `move ID X Y`, `state ID maximize|unmaximize|minimize`, `clipboard BYTES`,
`unmap ID`, `bye`, `textinput ID 0|1 PURPOSE HINT` (zwp_text_input_v3 content type;
`textinput 0 0 0 0` when no field is active), `surrounding ID TEXT CURSOR` (UTF-8, cursor
in bytes, at most 96 bytes each side; never sent for apps that report none), `caret ID X Y W H`
(view coordinates). Guest programs may also write `open URL` (ish-open: an http(s) URL
for Quick Preview, or Firefox when `desktop.linux.urlHandler` is `firefox`); the host
ignores other schemes.

host → ishwl (`/tmp/ishwl/events`):
`ack ID SEQ`, `ime DELETE_BEFORE DELETE_AFTER COMMIT PREEDIT BEGIN END` (one
text-input update: bytes to delete around the caret, text to insert, then the preedit
and its cursor in bytes; an empty preedit ends the composition), `configure ID W H MAXIMIZED`, `focus ID|0`, `close ID`, `motion ID X Y`,
`button ID X Y EVDEV_BUTTON 0|1`, `axis ID DX DY [SOURCE]` (wl_pointer.axis_source: 0 wheel,
1 finger, 2 continuous), `axis_stop ID`, `leave`, `key EVDEV_CODE 0|1`,
`text UTF8`, `keymap LAYOUT VARIANT OPTIONS` (XKB names, `-` for empty; see Keyboard layouts), `selection`, `dismiss`, `spawn CMD`, `hello` (re-announce everything), `quit`.

Coordinates are view-local logical pixels: one Linux logical pixel is one iOS point.

Other files in `/tmp/ishwl`: `alive` (lock), `clipboard-out` (ishwl writes),
`clipboard-in` (created by ishwl, the host only rewrites its contents, since files the
host creates have no fakefs metadata and are invisible to the guest).

## Compositor scope

The compositor implements these globals: `wl_compositor` v5, `wl_subcompositor`
(sync/desync), `wl_shm` (ARGB/XRGB), `wl_seat` v8 (pointer and keyboard; the XKB keymap follows the iPad's layout,
see Keyboard layouts; `text` is replayed as key presses), `wl_output` v4,
`xdg_wm_base` v3 (positioner placement, popup grab and dismissal, reposition),
`zxdg_decoration_manager_v1`, `org_kde_kwin_server_decoration_manager`,
`wp_viewporter` (source crop and destination size, nearest-neighbour),
`xdg_activation_v1` (tokens are always granted; `activate` raises the window), and
`wl_data_device_manager` (text selection, and drag and drop in `src/dnd.c`: see
[DND-SPEC.md](DND-SPEC.md)).
`zwp_linux_dmabuf_v1` (`src/dmabuf.c`, from the GPU work) only advertises formats;
every client here falls back to wl_shm.

**Decorations.** GTK3 and GTK4 only switch to server-side decorations when the KDE
protocol is present. With it, Thunar and Mousepad have no in-app title bar and DesktopKit
draws it. GtkHeaderBar apps (gtk3-demo) still draw their own header. Qt 6 (Falkon) and
Firefox use `zxdg_decoration_manager_v1`, which always answers server-side;
`QT_WAYLAND_DISABLE_WINDOWDECORATION=1` also keeps Qt from drawing its fallback frame.
X11 apps run inside a rootful Xwayland, which never decorates.

**X11 apps.** `ishwl-x11 [-g WxH] CMD` gives one app its own rootful Xwayland, which
ishwl sees as an ordinary toplevel (`Xwayland … -geometry 1024x700`).
`ishwl-x11-wm` is that server's window manager. It makes the app's main windows fill
the screen and centres transient ones. Rootless Xwayland would need an X window
manager inside ishwl, while one server per app keeps ishwl a plain Wayland compositor.
Xwayland names its window "Xwayland on :N", so ishwl-x11 records the app's name in
`/tmp/ishwl-x11/<Xwayland pid>`. ishwl then reports that name as the app_id and leaves
the title empty, and the host shows the app's .desktop name and icon. The X root does
not follow host resizes; Xwayland 24 resizes a rootful window only with libdecor.

**Launch rules.** ishwl starts every command through `ishwl-launch`. It looks the
program up in `/etc/ishwl/apps` (`NAME FLAGS…`): `x11` runs it under ishwl-x11, and
`compat` preloads `libishwl-compat.so`. The defaults are `vlc x11 compat` and
`dillo x11`. `libishwl-compat.so` (`preload/appcompat.c`) does two things:
- It answers the program's own `geteuid()` calls with 1000, because VLC refuses to run
  as root. Libraries still see root: libdbus authenticates with the real socket
  credentials, and Qt aborts when the effective and real ids differ.
- It makes `pthread_mutexattr_setprotocol(PRIO_INHERIT)` return ENOTSUP. musl probes
  FUTEX_LOCK_PI, which iSH lacks (ENOSYS), and libpulse aborts on anything other than
  0 or ENOTSUP.

**Popups.** Every popup is its own view in `LinuxPopupLayer`, a transparent layer
above all DesktopKit windows, positioned from its parent's on-screen position, so menus
can extend past their window. The host slides a popup back on screen (and above the
on-screen keyboard) when it would overflow; that is safe because input is popup-local.
The layer passes through every touch that misses a popup, and such a touch also sends
`dismiss` (once per event), so a tap anywhere outside closes the menu chain. ishwl
additionally swallows a press on the parent window while a grabbing popup is open.

**Clipboard.** ishwl owns the selection as text. When an app copies, ishwl reads the text
from the app's data source at once, keeps it, writes `clipboard-out`, and notifies the
host, which puts it on UIPasteboard. Host text goes the other way through `clipboard-in`
and `selection`. The selection is offered (UTF-8 text types) to whichever client has
keyboard focus, and again on every focus change. iOS shows an "Allow Paste" prompt when
an app reads another app's pasteboard, so the host only reads UIPasteboard when the user
pastes into Linux (Ctrl/Cmd-V or Shift-Insert) or when a copy happens inside this app.
Pasting another app's copy from a Linux *menu* (no key press) therefore needs one key
paste first; that is the price of not prompting on focus.

**Drag and drop.** `src/dnd.c` implements `wl_data_device.start_drag` and the offers between
clients, hands drags that end on native UI to the host, and lets the host drive drags into
Linux clients. The host side is `DesktopKit/.../DragDrop/LinuxDragBridge.swift`; messages go
over the `events` FIFO and a separate `/tmp/ishwl/dnd` FIFO. Details, message formats and
hooks: [DND-SPEC.md](DND-SPEC.md).

**Session.** The desktop starts `ishwl-session` when it opens: a D-Bus session bus,
then ishwl, which runs the commands in `/etc/ishwl/prewarm` (default `thunar --daemon`).
Everything in the session gets scm-compat preloaded. That includes the bus daemon and
bus-activated services. A mix of translated and untranslated peers drops D-Bus
connections, which is what broke GApplication activation before.

Every 2 s the host checks the `alive` lock. If ishwl died, the host closes all Linux
windows, shows a notice, and the next launch starts a new session. When an app dies on
its own, its wl_client is destroyed, which unmaps its views, and the host closes those
windows.

## Text input (zwp_text_input_v3)

The iPad is the input method. `src/textinput.c` implements `zwp_text_input_manager_v3`;
GTK 3 (im-wayland), GTK 4, Qt 6, Firefox and foot all bind it. A text input gets
`enter` with the keyboard focus. When the app enables it and commits, ishwl reports the
field to the host (`textinput`, `surrounding`, `caret`).

On the host, `LinuxSurfaceView` implements UITextInput (`Linux/LinuxTextInput.swift`)
over the app's surrounding text plus the iPad's marked text:
- `insertText` becomes `commit_string`. Emoji, dictation and long-press accents arrive
  this way.
- `setMarkedText` becomes `preedit_string` with its cursor, and `unmarkText` commits it.
  This covers CJK, Option dead keys and dictation in progress.
- Replacing the text before the caret becomes `delete_surrounding_text` plus a commit.
- `deleteBackward` deletes through the text input when the app reports its text. At the
  start of the field, or in a terminal, it is a Backspace key.
- The caret rectangle positions the candidate bar and the emoji and dictation popovers.
- The content purpose picks the iPad keyboard (URL, email, number, phone) and turns
  secure entry on for passwords.

Apps that report no surrounding text (foot) get Backspace presses for deletions, and the
host remembers what it typed. Apps without a text input, and widgets that are not text
fields, keep the old path: text is replayed as key presses.

**Hardware keys.** While a field is active, these keys go to UIKit's text system:
- printable keys
- Option combinations, so dead keys compose
- Return, Tab and Backspace

Command and Control chords, arrows, Escape and function keys stay raw evdev keys, so
shortcuts work as before. While text is being composed, every key goes to the
composition. Return and Tab come back as `insertText`: in a multi-line field (hint
MULTILINE) they are committed text, elsewhere they are key presses (submit, focus).

**Option key.** In a Linux text field, Option either types characters, so dead keys
compose, or stays Alt for the app's shortcuts. The setting is `desktop.linux.optionKey`,
shown in Settings → Keyboard Shortcuts by `LinuxOptionKeySettingsView` in
`Linux/LinuxOptionKey.swift`:
- `automatic` (the default) gives Alt to the app ids in `desktop.linux.optionKeyAltApps`
  (default `foot,code,code-url-handler,codium,kitty,xterm,emacs`) and characters
  everywhere else.
- `alt` is always Alt; `characters` always types characters.

Option with an arrow, Delete, Return, Tab, Home, End or Page keys is always Alt.

**Chromium/Electron (VS Code).** These apps bind text-input-v3 only with
`--enable-wayland-ime --wayland-text-input-version=3`; `devtools/vscode-launch` passes
both. Their surrounding text does not match the document, and they ignore
`delete_surrounding_text`. The host therefore ignores their surrounding text and edits
by Backspace, as it does for terminals (`LinuxTextInputState.unreliableSurroundingApps`).

**Ordering.** Toolkits apply `commit_string` at once but queue key events, so a fast
"abc⏎d" could come out "abcd⏎". While a text input is active, ishwl delivers keys and
text-input updates one at a time. Each one waits for the app's next commit (which
follows `done` and any edit a key makes), or 250 ms for keys that change nothing.
Modifiers and releases do not wait.

## Input

**Host side (`LinuxSurfaceView`).**

| Device | Gesture | What Linux gets |
|---|---|---|
| Trackpad / mouse (indirect pointer, which needs `UIApplicationSupportsIndirectInputEvents` in Info.plist) | Hover | Motion |
| | Press | Button press; a secondary click (two-finger click or right button) is BTN_RIGHT |
| | Press and drag | Drag, which selects text |
| | Two-finger scroll | Smooth pixel `axis`, source `finger`, ended with `axis_stop` (clients do kinetic scrolling) |
| | Mouse wheel | Source `wheel` with discrete steps |
| Touch | Tap | Click |
| | One-finger drag | Scroll, source `finger`. Set `desktop.linux.touchDragScrolls=false` to make it press and drag instead |
| | Hold for 450 ms, then release | Right click |
| | Hold for 450 ms, then drag | Press and drag, which selects text |
| | Two fingers | Scroll |

**Keyboard.** Keys are UIPress HID usages mapped to evdev codes:

- Shift, Ctrl, Alt and Caps Lock map to their Linux keys.
- Left Cmd is Ctrl, so Cmd-C/V/X/A/Z/T/L work as an iPad user expects.
- Right Cmd is Super.
- Desktop-level Cmd shortcuts (Cmd-W, Cmd-M, Cmd-R, Cmd-Return) are UIKeyCommands and win
  over the Linux app.
- Key repeat is client-side, from `wl_keyboard.repeat_info` (30/s after 500 ms). The host
  sends one press and one release per key, as UIKit does.

**Keyboard layouts.** Keys travel by position (HID usage → evdev), and the keymap turns
them into characters, as on a Linux PC. The host picks the XKB layout
(`Linux/LinuxKeyboardLayout.swift`, `LinuxKeyboardLayoutMonitor.swift`) and sends
`keymap LAYOUT VARIANT OPTIONS` after `hello` and on every change; ishwl compiles it
(rules evdev, model pc105), sends `wl_keyboard.keymap` to every client and keeps the old
keymap when the names are refused (only `[A-Za-z0-9_+,:()-]`) or do not compile.
Xwayland applies a new `wl_keyboard.keymap` to its X server, so X11 apps follow without
`setxkbmap`.
- Automatic (the default, `desktop.linux.keyboardLayout`) maps the iPad's input language
  (`UITextInputMode.primaryLanguage`, which changes with the Globe key) to Apple's layout
  for it: `de` → `de(mac)`, `de-CH` → `ch(de_mac)`, `uk` → `ua(macOS)`, `ja` → `jp`.
  iPadOS has no public API for the hardware layout, so every unmodified key press is
  checked against the layout: `UIKey.charactersIgnoringModifiers` is what the iPad made of
  that HID usage. A contradiction (QWERTZ, AZERTY, Dvorak or JIS keys under an English input
  mode) switches to the catalog layout that agrees with everything typed since the last
  language change. The per-layout table is generated from xkeyboard-config by
  `tools/xkb-base-chars.c`.
- Non-Latin layouts are sent with US as a second group (`ru,us`), so shortcuts find Latin
  letters; on-screen keyboard `text` that is only in another group is typed with that
  group locked for the key.
- Apple ISO keyboards report the key left of 1 and the key right of left Shift swapped;
  when the typed characters show that, the host swaps the two evdev codes, as hid-apple does.
- `desktop.linux.optionKeyRole`: right Option is AltGr and left Option Alt (default), both
  AltGr (`lv3:alt_switch`), or both Alt (`lv3:ralt_alt`). This is the Linux keymap; text the
  iPad types itself into a Linux text field (see Option key) is unaffected.
- `text` replay looks each character up in the current keymap with no modifier, Shift,
  AltGr and Shift+AltGr, so on-screen keyboard text keeps working on every layout.
- Dead keys in the keymap compose in the client (xkbcommon's Compose tables come from
  libx11's `/usr/share/X11/locale`, which the repair kit keeps installed).
- `tools/keymap-test.sh` checks all of this in the guest with a headless ishwl, the
  `tools/keymap-test.c` client and a rootful Xwayland.

**Seat.** `wl_seat` v8: a wheel sends `axis_value120` (v8 clients) or `axis_discrete`
(v5–7), at 15 surface pixels per notch, as weston and wlroots do.

**Keyboard focus stays on the toplevel while its popups grab.** Qt and GTK route keys
to their own open popup. Moving `wl_keyboard` focus to the popup made Qt's URL-bar
completer swallow typed characters; GTK menus still navigate with the arrow keys.

**Input regions.** `wl_surface.set_input_region` is honoured (rectangles replayed in
add/subtract order). Firefox draws its content into a subsurface with an empty input
region, and GTK ignores pointer events on surfaces it did not create. Without input
regions, every click and hover in Firefox went to that subsurface and was dropped, while
keys (which go to the toplevel) still worked.

**Popups after dismissal.** A press outside an open menu chain only dismisses the menu.
A popup that has been sent `popup_done` stops counting as grabbing, even before its
client destroys it. Firefox can take seconds to do that under emulation, and in that
time the next click must reach the window.

**Known limits.**
- Characters typed in the first moments after a click that focuses a text field can land
  in the previous focus. Firefox moves focus asynchronously and needs about a second
  under emulation.
- Falkon's location bar loads its first completion (e.g. "search for e") when Enter
  arrives before the emulated completion model has caught up with a burst of typed
  characters (all keys reach Qt in order; see `ishwl -vv`). Human-speed typing is fine.

## scm-compat (emulator workarounds for fd passing)

`src/scm-compat.c` interposes `sendmsg` and `recvmsg`. It is linked into ishwl and
LD_PRELOADed into every app ishwl spawns (`/usr/local/lib/libishwl-scm.so`). What it does:
- **Layout.** On first use it probes a socketpair. Older emulators parse a 12-byte
  `cmsghdr`; on those it converts from the 16-byte aarch64 layout, using raw syscalls.
  On a fixed emulator (current builds: `scm-compat: off` in the log) every call goes to
  libc's own sendmsg/recvmsg. That matters: musl zeroes the padding of the 32-bit
  `msg_controllen`, and passing the caller's msghdr straight to the syscall let iSH read
  a garbage 64-bit length and crash the app in `sys_sendmsg`'s memmove.
- **Bad fds.** It returns EBADF for unopened fds, which old emulators crashed on.
- **Split sends.** If a multi-fd send fails with EINVAL, it resends one fd per chunk.
  This is harmless on fixed emulators.
- **Socket buffers.** `connect` and `socketpair` raise SO_SNDBUF and SO_RCVBUF to 1 MiB.
  iSH sockets are host sockets with Darwin's 8 KiB default, and GDK treats EAGAIN from a
  full socket as fatal.

## Host side (DesktopKit/Sources/DesktopKit/Linux)

| File | Role |
|---|---|
| `LinuxGUIBridge.swift` | Starts and supervises the session, owns the FIFOs (with a reader thread), maps buffers, keeps surface state, syncs the clipboard and writes stats to `<app tmp>/linux-gui-stats.txt` (per-burst FPS, input-to-frame latency, launch-to-window time) |
| `LinuxPopupLayer.swift` | The desktop-wide popup layer and outside-tap dismissal |
| `LinuxSurfaceView.swift` | CALayer rendering and input: touch (tap = click, hold = right click, drag = drag), trackpad and mouse buttons, hover, wheel and two-finger scroll, hardware keys (`UIPress` HID → evdev, Cmd → Ctrl), and the on-screen keyboard through `UIKeyInput`. It debounces resizes into `configure` |
| `LinuxKeyCodes.swift` | HID usage → evdev table |
| `LinuxDesktopEntry.swift` | Parses `/usr/share/applications`, maps app_id to an entry, and picks an SF Symbol per category |
| `LinuxIconCache.swift` | Resolves an entry's `Icon=` in the guest's per-style PNG cache (`/usr/share/ish/icon-cache/<style>/<name>[@2x].png`, style from `/usr/share/ish/current-style`; see themes/CONTRACT.md). The result is `DesktopAppDescriptor.iconURL`, with the SF Symbol as the fallback |
| `LinuxDeviceInfo.swift` | Publishes the iPad model, chip and GPU names as defaults for the guest's fastfetch |
| `DesktopController+Linux.swift` | Launcher entries (`linux:<id>`, featured Firefox, Falkon and foot), the terminal preference (`linux:@terminal`), URL requests, one window per toplevel, close and focus wiring |

Hooks in Core:

- `LinuxGraphicsHost` (in API.swift, opt-in, gives `guestRootURL`)
- `AppCategory.linux`
- `DesktopWindow.onCloseRequest` and `WindowManager.requestClose`
- `DesktopController.launcherApps`
- a focus `onChange` and the popup layer in DesktopRootView
- `DesktopController.open` passes launch arguments to `openLinuxApp`
- Files' "Open Terminal Here" opens `LinuxAppID.preferredTerminal`
- `DesktopAppDescriptor.iconURL` (optional, for the icon cache)

Autostart works with `-desktop.autostart linux:thunar`.

**Launching is generic.** `open(appID: "linux:<desktop-id>")` runs that entry's `Exec`,
and any other `linux:<command line>` runs as given. ishwl exports `WAYLAND_DISPLAY`,
`GDK_BACKEND=wayland`, `MOZ_ENABLE_WAYLAND=1`, `QT_QPA_PLATFORM=wayland`, the bus
address and the scm-compat preload. A browser needs nothing beyond a .desktop file, or a
`linux:` id. Per-app needs (X11, compat preload) live in the guest's `/etc/ishwl/apps`,
not in the host.

## Terminal and system info

**foot is the Linux terminal.** The launcher lists it as "Terminal (foot)" (`linux:foot`);
foot's own .desktop entries are hidden. `ish-terminal` runs it with
`/etc/ish/foot/<style>.ini`, where the style comes from `/usr/share/ish/current-style`
(ish, macos, windows, ubuntu; the default is ish). Each style file sets the colours and
includes `foot.ini`:
- JetBrains Mono 11, which is crisp at scale 2
- 10,000 lines of scrollback
- Cmd+Shift+C/V to copy and paste (the left Cmd key arrives as Ctrl), through the
  bridge's clipboard
- Cmd+Shift+O for URL mode, which opens the chosen URL with `ish-open`

foot cannot open a URL on a plain click; URL mode is its way to do that.

**Open Terminal Here** (Files) opens `linux:@terminal`. That is foot in the folder when
`desktop.terminal` is `foot` (the default) and foot is installed; otherwise it is the
built-in Terminal.

**kitty** (`LIBGL_ALWAYS_SOFTWARE=1`) was tried and is not included. Its first window
took 29.5 s, the frame was black, at scale 1, and kitty exited about 9 s later.

**fastfetch** has a system-wide config in `/etc/xdg/fastfetch`, with the logo in
`/usr/share/ish/logo.txt`; `neofetch` runs fastfetch. `/etc/os-release` says
`Linux for iPad (Alpine 3.21 base)`, ID `linuxforipad`, ID_LIKE `alpine`;
`/etc/alpine-release` is unchanged. The Host, CPU and GPU lines come from
`ish-device-info`, which reads `/proc/ish/.defaults/linux.{hostModel,chipName,gpuName}`.
`LinuxDeviceInfo` publishes those defaults: the iPad model from its identifier (the
simulated model in the simulator) and the Metal device name. The GPU line adds
"Venus, Vulkan" when `/dev/dri/renderD128` exists.

## Browsers

- **Firefox ESR 128 (primary, `linux:firefox`, in both rootfs tarballs).** `ishwl-session` sets
  `MOZ_ENABLE_WAYLAND=1` and `MOZ_CRASHREPORTER_DISABLE=1`. `firefox-prefs.js` is
  installed as `defaults/pref/ishwl.js`; it turns on software WebRender, keeps tabs out
  of the title bar (DesktopKit draws it), and turns off the dmabuf, telemetry and
  first-run noise. Firefox needs no dmabuf: it renders into wl_shm buffers.
- **Falkon / QtWebEngine (`linux:falkon`).** Qt runs on Wayland without EGL
  (`QT_WAYLAND_CLIENT_BUFFER_INTEGRATION=none`): Mesa's EGL fails, or crashes in
  llvmpipe. Qt Quick runs on its software backend, which QWebEngineView needs.
  QtWebEngine flags: `--single-process --no-sandbox --disable-gpu`. It is in the full
  rootfs only; on the lean one, `apk add falkon qt6-qtwayland`.
- **Dillo** is FLTK 1.3, which is X11 only, so it runs under ishwl-x11 (the emulator's
  Xwayland EINVAL is fixed). links and elinks run in the Terminal.
- **VLC 3** has a Qt 5 interface that needs X11, so it also runs under ishwl-x11, with
  the compat preload. Without a reachable PulseAudio server it hangs at startup
  (`pa_write() … Bad file descriptor`); with `-A dummy` it starts in about 3 s. Audio
  comes from the ishaudio work.

## Measured (iPad Air 11-inch M3 simulator on an M4 Mac mini)

| | scale 1 | scale 2 |
|---|---|---|
| Two-finger scroll in Thunar `/usr/lib` | 48 fps | 32 fps |
| App process RSS, two Thunar windows open | ~355–378 MB | ~383–388 MB |
| Text | blurry (upscaled) | pixel-exact |

Thunar launch to first frame:
- cold (session starting at the same time): 2.0 s
- cold, daemon still starting: 1.6 s
- with the prewarmed daemon: 1.3 s (host) / 0.5–0.6 s for further windows (guest log, CLI)
- Mousepad (no prewarm): 2.8–3.0 s

The device will be slower than the M4 host.

Browsers, measured in the same simulator (iOS app process RSS includes the guest
kernel, the session and the prewarmed Thunar daemon):

| | Firefox ESR 128 | Falkon (QtWebEngine 6.8) |
|---|---|---|
| launch to first window | 8–12 s warm, 22 s on first boot | 7.6 s |
| example.com, Enter to page | under 20 s | renders |
| en.wikipedia.org/wiki/Linux, Enter to page | about 30 s (desktop layout, images) | rendered within 12 s of pressing Enter |
| input to next frame (median of 20) | 227 ms | |
| scroll bursts | 5–21 fps | |
| app memory | phys_footprint 1.42 GB; RSS 1.6–2.07 GB | 821 MB while starting; 430–570 MB afterwards |
| stability | 7.5 min session without errors | stable |

The Firefox session covered: click "Start New Session", type a URL, Wikipedia, touch
scrolling, a new tab, example.com, tab switching, the app menu, and a click straight
after dismissing it. The emulator fixes it needed were LD1 lanes (decoder-fixes.md #7)
and sendmsg/connect (emulator-fixes.md #19, #20). Firefox replaces Falkon as the default
browser: the lean rootfs (Firefox only) is now `simrun.sh`'s default.

Emulator issues still visible with Firefox:
- **Rust timed waits spin.** `FUTEX_WAIT_BITSET` always treats its absolute timeout as
  CLOCK_REALTIME (kernel/futex.c). Without `FUTEX_CLOCK_REALTIME` the clock is
  CLOCK_MONOTONIC, so Rust's waits (Glean's thread, among others) time out at once and
  spin one host core at 100%.
- **`FUTEX_LOCK_PI` is unimplemented.** It returns ENOSYS; libishwl-compat covers
  libpulse.

## Building

Build inside the guest:

```sh
apk add build-base wayland-dev wayland-protocols pkgconf zlib-dev libxkbcommon-dev libx11-dev
make CC=tools/ccwrap && make install
```

Without libx11-dev, `ishwl-x11-wm` is skipped and X11 apps keep their own window size.

`ccwrap` runs cc1 and as directly, to avoid the wait4 EINTR described above. A headless
test can be run with `ishwl --png-dir /tmp/png -- gtk3-demo`, which writes each view's
latest frame as a PNG.
