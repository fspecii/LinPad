# ishwl drag and drop (wl_data_device DnD)

Owner: DnD agent. Code: `src/dnd.c` (ishwl) and
`desktop/DesktopKit/Sources/DesktopKit/DragDrop/LinuxDragBridge.swift` (host).
Everything here sits next to the clipboard (`src/clipboard.c`), which still owns the
selection and the `wl_data_device_manager` global.

## What works

| Drag | Path |
|---|---|
| Linux app → Linux app (Thunar → Mousepad, text between apps) | entirely inside ishwl: a `wl_data_source` from one client, `wl_data_offer`s to the next |
| Linux app → native window (Files, Terminal, Text Editor, desktop) | ishwl reads the source's data and hands it to the host (`dnd_data`) |
| native window or iPadOS app → Linux app | the host drives a drag inside ishwl (`dnd_enter` … `dnd_drop`); files are copied into the guest first |
| Linux app → another iPadOS app | not possible directly: iOS can only start a system drag from a fresh lift gesture, and the touch is already owned by the Linux window. Drop on a native Files window or the desktop first, then drag on from there |

## Channel

The host writes to the existing `events` FIFO (one more writer; every line stays far
below Darwin's 512-byte `PIPE_BUF`, so lines never interleave with LinuxGUIBridge's).
ishwl writes DnD notifications to a separate FIFO, **`/tmp/ishwl/dnd`**, created by
`dnd_init` with the same O_RDWR trick as `notify`. A separate FIFO keeps LinuxGUIBridge,
which owns `notify`, untouched. The host only enables Linux DnD when `dnd` exists, so an
older ishwl simply has no DnD.

Strings are percent-encoded like the rest of the bridge (`bridge_escape`), `-` for empty.
Coordinates are view-local logical pixels, as in `motion`.

## Drags started by a Linux app

```
client: wl_data_device.start_drag(source, origin, icon, serial)
ishwl → dnd:     dnd_start MIMES ACTIONS          MIMES: comma list (escaped as one field)
                                                  ACTIONS: wl_data_device_manager.dnd_action mask
host → events:   dnd_over VIEW X Y                pointer over Linux view VIEW
                 dnd_over 0 ACCEPT                pointer over native UI; ACCEPT 1 = a native
                                                  target will take the data, 0 = nothing there
                 dnd_cancel                       the touch was cancelled
(drop)           button VIEW X Y BTN 0            the release LinuxSurfaceView already sends
ishwl → dnd:     dnd_data MIME FILE               native drop: the source's data is in
                                                  /tmp/ishwl/FILE (written by ishwl)
                 dnd_end dropped|host|cancelled
```

While the drag is active ishwl ignores `motion` and `button` presses from the host
(the source window's view keeps sending them, with coordinates outside its bounds); the
release of the dragging button ends the drag. When it starts, the source surface gets
`wl_pointer.leave` and the button is cleared from the seat after the drop, as weston does.

On `dnd_over VIEW X Y` ishwl picks the surface under the point (`surface_at`, input
regions honoured) and sends `wl_data_device.enter/motion/leave` with a fresh
`wl_data_offer` (all of the source's MIME types and, for v3, `source_actions`). The
offer's `accept`, `set_actions`, `receive` and `finish` are forwarded to the source
(`target`, `action`, `send`, `dnd_finished`); the action is negotiated as weston does
(the target's preferred action when both sides allow it, else the first common one).

On release:
- over a Linux target that accepted a MIME type (and, v3, an action): `drop`, then
  `dnd_drop_performed`; `dnd_finished` follows the target's `finish`. → `dnd_end dropped`
- over native UI with ACCEPT 1: ishwl asks the source for the best of
  `text/uri-list`, `text/plain;charset=utf-8`, `UTF8_STRING`, `text/plain`, `image/png`,
  writes it to `dnd-out` (tmp + rename), sends `dnd_data`, then tells the source the
  action was **copy** (`action`, `dnd_drop_performed`, `dnd_finished`), so the source never
  deletes anything; the host performs a move itself when the user asked for one.
  → `dnd_end host`
- anywhere else: `cancelled`. → `dnd_end cancelled`

A source destroyed mid-drag ends the drag (`dnd_end cancelled`).
Drags without a source (client-internal) are delivered to the origin client's surfaces
only, as the protocol requires.

## Drags from the host into a Linux app

```
host → events:  dnd_enter VIEW X Y ACTIONS PREFERRED MIMES
                dnd_data_ready MANIFEST          data available (may come any time, also again)
                dnd_motion VIEW X Y
                dnd_leave
                dnd_drop VIEW X Y
ishwl → dnd:    dnd_status ACCEPTED ACTION       the target's accept/action changed
                dnd_done                         the target finished (or dropped its offer)
```

`MANIFEST` is a guest path to a text file with one `MIME<TAB>GUEST-PATH` line per offered
type; ishwl answers `wl_data_offer.receive(MIME, fd)` by streaming that file into `fd`
(non-blocking, from the event loop). Clients ask for data before the drop too (Thunar
reads the URI list in `drag-motion` to decide whether it can take the files), so a
`receive` that arrives before the manifest is parked and answered when
`dnd_data_ready` comes. The host precomputes the guest paths imported files will get
(`/tmp/ishwl-dnd/<uuid>/files/<name>`), so the URI list is the same before and after the
copy, and sends `dnd_drop` only after the files are in place.

`dnd_status` lets the host show a forbidden badge when the client rejects the drop. A
`dnd_drop` that the target never accepted becomes a `leave`.

## Hooks outside dnd.c (kept to single lines)

| File | Hook |
|---|---|
| `ishwl.h` | prototypes of the `dnd_*` entry points |
| `main.c` | `dnd_init(&s)` after `clipboard_init` |
| `bridge.c` | `handle_line`: `dnd_*` messages go to `dnd_handle` |
| `clipboard.c` | `device_start_drag` calls `dnd_start_drag`; `source_offer` and `source_set_actions` record MIME types and actions with `dnd_source_offer`/`dnd_source_actions` |
| `seat.c` | `seat_pointer_motion` returns early while `dnd_grabs_pointer`; `seat_pointer_button` starts with `if (dnd_pointer_button(...)) return;` |

## Testing in the simulator

`desktop/DnDHarness` (UI tests) drives real drags: native drags with XCUITest, and drags that
start in Linux apps through the app's test-only automation hook
(`DragDrop/DebugAutomation.swift`, built only with `AUTOMATION=1 desktop/simrun-dnd.sh`, enabled
with `-desktop.debugAutomation YES`). The hook sends the same `button`/`motion` messages a
trackpad does and calls LinuxDragBridge as its touch observer would; `desktop/dnd-automation.sh`
sends single commands by hand.

## Testing without the iOS app

`tools/dnd-test.c` is a minimal Wayland client: `dnd-test source MIME TEXT` starts a drag
as soon as it gets a button press, `dnd-test target` prints every `enter/motion/drop` and
the received data. Drive ishwl through `/tmp/ishwl/events` and read `/tmp/ishwl/dnd`.
