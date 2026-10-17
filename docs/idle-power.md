# Idle CPU regressions

## Observed problem

A 15.73-second Time Profiler recording of LinPad 1.5.0 (4428) on an iPad
at rest attributed 15.447 seconds of sampled CPU time to the guest
`pipe-source` thread: approximately one CPU core. The hot stack was
`realfs_poll -> poll_wait -> sys_poll -> sys_ppoll`; the desktop main thread
accounted for only 0.130 seconds of sampled CPU time. These are CPU samples,
not measurements of device watts or temperature.

PulseAudio suspends its microphone source by polling its FIFO without read
interest. The host microphone bridge leaves a small silence probe in that FIFO.
`kernel/poll.c` still requests hangup/error notifications, so `fs/poll.c` watches
the host read filter with `NOTE_LOWAT(INT_MAX)`. Darwin named FIFOs ignore this
low-water setting: buffered bytes repeatedly wake the host filter, but the
guest correctly rejects ordinary read readiness. The wait therefore spins.

Hangup-only host read watches now clear each notification after collection.
The guest readiness scan still reports persistent hangups. Recreating the read
filter when interests change also resets Darwin's sticky `EV_CLEAR` and
`NOTE_LOWAT` settings, so ordinary level-triggered reads resume normally.

A second regression involved nested epoll sets with at least 16 ready host
filters. Repeatedly draining a full batch never finishes for level-triggered
descriptors. Collection now takes one bounded snapshot sized for the set's
registered host filters, including edge bookkeeping beyond the small buffer.

## Regression checks

Run from the repository root:

```sh
tests/unit/poll-test.sh
```

The native test links the production `fs/poll.c` and `fs/real.c`; no guest
filesystem, JIT or simulator is needed. It checks:

- A buffered named FIFO with read interest disabled waits for its timeout with
  low CPU use, and restoring read interest exposes the existing data.
- Empty and buffered anonymous pipes still wake promptly when the writer closes.
- Read-watch mode changes preserve host level-triggered notifications.
- Nested sets with 20 ready sockets return promptly; edge-triggered events rearm
  without duplicate or stale readiness.

Darwin's raw named-FIFO close behavior differs from anonymous pipes, so the
hangup checks use anonymous pipes rather than asserting unsupported host FIFO
semantics. A watchdog catches an unbounded wait.

DesktopKit also combines its CPU/memory samples into one guest command and
releases panel, widget, folder and optional FPS sampling while backgrounded,
locked or covered by the screensaver. Folder scans also stop when desktop
icons are hidden. `PanelMonitorSharingTests` covers shared sampling and late
replies from a cancelled sampling session.

## Device acceptance

Source tests do not update the installed iPad app. After installing a signed
build containing these changes, repeat an idle Time Profiler recording with the
same windows, fast-mode setting and desktop settings. Confirm that the
`pipe-source` thread blocks rather than consuming a core, then check playback,
microphone capture, lock/unlock and background/foreground transitions. Compare
temperature or battery use only after a matched device run and cooling period.

### Device validation, 2026-10-17

A local LinPad 1.5.0 build 4437 carrying this fix was installed over build 4428
on an iPad Pro 11-inch (M5), iPadOS 26.6.2. The existing Linux root was reused
and its rootfs version remained `202610031701`.

Time Profiler used the same device and a 15-second recording limit:

| Recording | Wall time | Total sampled CPU time | Average, one core | `pipe-source` CPU time |
| --- | ---: | ---: | ---: | ---: |
| 4428, before fix | 15.730690 s | 15.652 s | 99.50% | 15.447 s |
| 4437, first idle run | 15.768679 s | 0.109 s | 0.69% | no samples |
| 4437, explicitly activated in foreground | 15.729654 s | 0.109 s | 0.69% | 0.002 s |

The foreground run activated the existing process without restarting it; the
display was on and active. PulseAudio's microphone source was still loaded and
suspended, and `pipe-source` remained present in the guest process list. The
result therefore does not depend on unloading the microphone source. These are
short running-thread CPU samples, not watt, battery-life or temperature
measurements. The trace lifecycle table reported the attached app's state as
unknown; the foreground run instead has a successful device activation record.
The old and new runs were both idle with Fast Mode On, but exact window contents
were not captured as a controlled benchmark. The native regression separately
isolates the FIFO polling defect.

JIT was enabled before Linux boot for the new process. Native readback confirmed
`AppDelegate.jitStatus == 1`, `fastModeState == 2`,
`fastModeNewProgramsOnly == 0`, a 256 MiB RX arena and `txm_arena == 1`.
The debugger was detached before profiling and left detached afterwards.

The tested app's native Swift, Objective-C and C code was compiled as an iOS
arm64 Release build with native JIT and virtgpu enabled. Its root archive was
byte-identical to the original 1.5.0 package. Because the local resource
compilers required an unavailable simulator runtime, unchanged compiled assets
and storyboards were reused from the verified original package. All 34 reused
files matched the original, and their source inputs had no changes from
`v1.5.0`. No resource or project configuration change is part of this fix.

Native poll regressions and UBSan passed. DesktopKit iOS sources and test sources
compiled; XCTest execution was unavailable without a simulator runtime. Actual
microphone capture, playback, lock/unlock and extended temperature/battery runs
remain separate acceptance checks.
