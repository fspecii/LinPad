import Foundation
import Observation
import UIKit
import os

/// One Wayland toplevel or popup exported by the in-guest compositor (ishwl).
@MainActor
final class LinuxSurface {
    enum Kind {
        case toplevel
        case popup
    }

    let id: UInt32
    let kind: Kind
    let parentID: UInt32
    var title = ""
    var appID = ""
    /// Popups: offset from the parent surface's content origin, as the client asked.
    var position: CGPoint = .zero
    var minimumSize: CGSize = .zero
    var image: CGImage?
    /// The size of `image` in points: Linux logical pixels.
    var size: CGSize = .zero
    /// Image pixels per point (the client's buffer scale).
    var scale: CGFloat = 1
    var hasFrame: Bool { image != nil }
    /// Set while the app has an enabled text input in this toplevel (LinuxTextInput.swift).
    var textInput: LinuxTextInputState?
    /// The UIKit view showing this surface. Toplevels own a root view; popups are
    /// subviews of their toplevel's root view.
    var view: LinuxSurfaceView?

    fileprivate var bufferName: String?
    fileprivate var mapping: UnsafeRawBufferPointer?

    init(id: UInt32, kind: Kind, parentID: UInt32) {
        self.id = id
        self.kind = kind
        self.parentID = parentID
    }
}

@MainActor
protocol LinuxGUIBridgeDelegate: AnyObject {
    /// A toplevel produced its first frame and needs a window.
    func linuxBridge(_ bridge: LinuxGUIBridge, didMap surface: LinuxSurface)
    func linuxBridge(_ bridge: LinuxGUIBridge, didUnmap surface: LinuxSurface)
    func linuxBridge(_ bridge: LinuxGUIBridge, didRetitle surface: LinuxSurface)
    func linuxBridge(_ bridge: LinuxGUIBridge, didRequest state: String, for surface: LinuxSurface)
    /// xdg_activation: the app asked for its window to be raised.
    func linuxBridge(_ bridge: LinuxGUIBridge, didRequestActivation surface: LinuxSurface)
    /// ishwl died; its surfaces are about to be unmapped.
    func linuxBridgeSessionEnded(_ bridge: LinuxGUIBridge)
    /// A guest program asked for an http(s) URL to be shown (ish-open).
    func linuxBridge(_ bridge: LinuxGUIBridge, didRequestOpen url: URL)
    /// ish-preview: show the URL in Quick Preview regardless of the URL handler setting.
    func linuxBridge(_ bridge: LinuxGUIBridge, didRequestPreview url: URL)
}

/// The host half of the display bridge (wl-bridge/DESIGN.md).
///
/// ishwl runs in the guest and composites every toplevel and popup into its own
/// file under /tmp/ishwl. A MAP_SHARED mapping of a fakefs file is a host mmap of
/// the backing file, so this side maps the same file and sees the pixels without
/// any copy through the emulator. Control traffic is line-based over two FIFOs in
/// the same directory; FIFOs in the fakefs are real host FIFOs.
@Observable @MainActor
final class LinuxGUIBridge {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    static let guestRuntimeDirectory = "/tmp/ishwl"
    private static let logger = Logger(subsystem: "DesktopKit", category: "LinuxGUI")

    private(set) var state = State.stopped
    private(set) var applications: [LinuxDesktopEntry] = []

    @ObservationIgnored weak var delegate: LinuxGUIBridgeDelegate?
    @ObservationIgnored private let host: any LinuxGraphicsHost
    @ObservationIgnored private var surfaces: [UInt32: LinuxSurface] = [:]
    @ObservationIgnored private var textInputSurfaceID: UInt32?
    #if DEBUG || DESKTOP_AUTOMATION
    @ObservationIgnored private var textInputProbe: LinuxTextInputProbe?
    #endif
    @ObservationIgnored private var eventsFD: Int32 = -1
    @ObservationIgnored private var reader: FIFOLineReader?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    @ObservationIgnored private var pendingLaunches: [String] = []
    @ObservationIgnored private var launchTimes: [Date] = []
    @ObservationIgnored private var stats = FrameStats()
    /// Where popups go so they can extend past their window; see LinuxPopupLayer.
    @ObservationIgnored weak var popupLayer: UIView?
    /// UIPasteboard.changeCount last exchanged with Linux; -1 pushes the current
    /// pasteboard on the first paste.
    @ObservationIgnored private var pasteboardChangeCount = -1
    @ObservationIgnored private var controlKeysDown = Set<UInt32>()
    /// Keys Linux was told are down. A key held while LinPad leaves the screen (⌘ of
    /// ⌘-Tab, the shortcut that locks the iPad) never sends its release to this app.
    @ObservationIgnored private var keysDown = Set<UInt32>()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pendingAcks: [String] = []
    @ObservationIgnored private var displayLink: CADisplayLink?
    /// Sends the iPad's keyboard layout to ishwl; LinuxSurfaceView feeds it key presses.
    @ObservationIgnored let keyboardLayout = LinuxKeyboardLayoutMonitor()

    /// "firefox" opens guest URL requests in Firefox; anything else in Quick Preview.
    static let urlHandlerKey = "desktop.linux.urlHandler"
    private static let healthCheckInterval: Duration = .seconds(2)
    private static let controlKeys: Set<UInt32> = [29, 97]  // evdev left/right Ctrl (Cmd maps to Ctrl)
    private static let keyV: UInt32 = 47
    private static let keyInsert: UInt32 = 110
    private static let maxClipboardBytes = 4 << 20

    init(host: any LinuxGraphicsHost) {
        self.host = host
        let center = NotificationCenter.default
        // Copies made inside this app; other apps' copies are picked up on paste.
        observers.append(center.addObserver(forName: UIPasteboard.changedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushPasteboardIfChanged() }
        })
    }

    func surface(withID id: UInt32) -> LinuxSurface? {
        surfaces[id]
    }

    var iconCache: LinuxIconCache? {
        host.guestRootURL.map(LinuxIconCache.init(guestRoot:))
    }

    // MARK: - Session

    private var runtimeURL: URL? {
        host.guestRootURL?.appendingPathComponent(String(Self.guestRuntimeDirectory.dropFirst()), isDirectory: true)
    }

    /// Starts ishwl in the guest (once) and connects to it.
    func start() {
        guard startTask == nil, state != .running else { return }
        state = .starting
        LinuxDeviceInfo.publish()
        #if DEBUG || DESKTOP_AUTOMATION
        textInputProbe = textInputProbe ?? LinuxTextInputProbe.startIfEnabled { [weak self] in
            self?.textInputSurfaceID.flatMap { self?.surfaces[$0]?.view }
        }
        if showFakeToplevelIfRequested() { return }
        #endif
        startTask = Task { [weak self] in
            await self?.connect()
            self?.startTask = nil
        }
    }

    private func connect() async {
        guard let runtimeURL else {
            state = .failed("The Linux filesystem is not reachable from the app")
            return
        }
        if !Self.isSessionAlive(runtimeURL) {
            // Liveness comes from ishwl's flock, not pidof: scanning /proc/*/exe can crash
            // the emulator (proc_pid_exe_readlink on a task without an exe file).
            let dir = Self.guestRuntimeDirectory
            let launch = await host.run("""
                command -v ishwl-session >/dev/null || { echo "ishwl is not installed" >&2; exit 3; }
                rm -rf \(dir); mkdir -p \(dir)
                setsid ishwl-session --runtime-dir \(dir) -v >/tmp/ishwl.log 2>&1 </dev/null &
                echo $! > \(Self.sessionPIDFile)
                """)
            guard launch.succeeded else {
                state = .failed(launch.stderr.isEmpty ? "Could not start ishwl" : launch.stderr)
                return
            }
        }

        let notifyPath = runtimeURL.appendingPathComponent("notify").path
        let eventsPath = runtimeURL.appendingPathComponent("events").path
        for _ in 0..<150 where !(Self.isSessionAlive(runtimeURL) && Self.isFIFO(notifyPath) && Self.isFIFO(eventsPath)) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // O_RDWR on both: opening never blocks waiting for the other side.
        let notifyFD = open(notifyPath, O_RDWR | O_CLOEXEC)
        eventsFD = open(eventsPath, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard notifyFD >= 0, eventsFD >= 0, Self.isSessionAlive(runtimeURL) else {
            state = .failed("ishwl did not start (see /tmp/ishwl.log)")
            if notifyFD >= 0 { close(notifyFD) }
            if eventsFD >= 0 { close(eventsFD) }
            eventsFD = -1
            return
        }
        reader = FIFOLineReader(fd: notifyFD) { [weak self] lines in
            Task { @MainActor in
                for line in lines { self?.handle(line) }
            }
        }
        state = .running
        send("hello")
        keyboardLayout.attach { [weak self] line in self?.send(line) }
        for command in pendingLaunches { spawn(command) }
        pendingLaunches.removeAll()
        monitorSession(runtimeURL)
        await loadApplications()
    }

    /// ishwl holds an exclusive flock on `alive` for its lifetime; a guest flock is a host
    /// flock in iSH, so being able to take it means ishwl is gone.
    private static func isSessionAlive(_ runtimeURL: URL) -> Bool {
        let fd = open(runtimeURL.appendingPathComponent("alive").path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    private func monitorSession(_ runtimeURL: URL) {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.healthCheckInterval)
                guard let self, self.state == .running else { return }
                if !Self.isSessionAlive(runtimeURL) {
                    self.sessionEnded()
                    return
                }
            }
        }
    }

    /// LinPad is in front again. ishwl may have died meanwhile (the guest was low on
    /// memory), and acks queued for a display refresh that never came while the screen
    /// was off are still pending. `hello` makes ishwl announce every window again and
    /// redraw it in full, which also clears any frame it was still holding for an ack.
    func resumeAfterBackground() {
        guard state == .running, let runtimeURL else { return }
        guard Self.isSessionAlive(runtimeURL) else {
            sessionEnded()
            return
        }
        flushAcks()
        send("hello")
    }

    /// ishwl's pid (ishwl-session execs it), written when the session is started.
    private static let sessionPIDFile = "/tmp/ishwl-session.pid"

    /// True while `restartSession()` runs, so the end of the old session is not reported
    /// as a crash.
    private(set) var isRestarting = false

    /// Stops the whole Linux GUI session and starts a fresh one: ishwl (and with it every
    /// Wayland and Xwayland client), the session's D-Bus daemon and PulseAudio. ishwl is
    /// asked to quit over its control FIFO first; whatever is still running after that is
    /// signalled. Processes are found through /proc/<pid>/cmdline only, never through
    /// pidof/pkill, which read /proc/<pid>/exe and can crash the emulator (DESIGN.md).
    func restartSession() async {
        guard !isRestarting else { return }
        isRestarting = true
        defer { isRestarting = false }
        startTask?.cancel()
        startTask = nil
        pendingLaunches.removeAll()
        if state == .running { send("quit") }
        if let runtimeURL {
            let deadline = ContinuousClock.now + .seconds(5)
            while Self.isSessionAlive(runtimeURL), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        _ = await host.run(Self.stopSessionScript)
        if state == .running || !surfaces.isEmpty { sessionEnded() }
        state = .stopped
        start()
    }

    /// Patterns are anchored at the start of the command line, so the shell running this
    /// script (whose own command line contains them) never matches.
    private static let stopSessionScript = #"""
        session_pids() {
            for d in /proc/[0-9]*; do
                cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
                case "$cmd" in
                "ishwl "*|"/usr/local/bin/ishwl "*|"dbus-daemon --session "*|"pulseaudio -n --file=/etc/ishaudio/"*)
                    echo "${d#/proc/}" ;;
                esac
            done
        }
        pid=$(cat \#(sessionPIDFile) 2>/dev/null)
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
        pids=$(session_pids)
        [ -n "$pids" ] && kill $pids 2>/dev/null
        i=0
        while [ $i -lt 20 ] && [ -n "$(session_pids)" ]; do sleep 0.25; i=$((i + 1)); done
        pids=$(session_pids)
        [ -n "$pids" ] && kill -9 $pids 2>/dev/null
        rm -f \#(sessionPIDFile) /tmp/ishaudio/native
        true
        """#

    /// ishwl crashed or was killed: its apps lost their display with it. Close their
    /// windows; the next launch starts a new session.
    private func sessionEnded() {
        Self.logger.error("ishwl exited; closing Linux windows")
        healthTask?.cancel()
        healthTask = nil
        delegate?.linuxBridgeSessionEnded(self)
        for surface in surfaces.values where surface.kind == .popup { unmap(surface) }
        for surface in surfaces.values where surface.kind == .toplevel { unmap(surface) }
        surfaces.removeAll()
        reader?.stop()
        reader = nil
        if eventsFD >= 0 { close(eventsFD) }
        eventsFD = -1
        pendingAcks.removeAll()
        displayLink?.isPaused = true
        launchTimes.removeAll()
        state = .stopped
    }

    func loadApplications() async {
        let listing = await host.run(LinuxDesktopEntry.listingCommand)
        applications = LinuxDesktopEntry.parseListing(listing.stdout)
    }

    func launch(command: String) {
        if state == .running {
            spawn(command)
        } else {
            pendingLaunches.append(command)
            start()
        }
    }

    private func spawn(_ command: String) {
        launchTimes.append(Date())
        send("spawn \(Self.escape(command))")
    }

    // MARK: - Clipboard

    /// Gives Linux the iOS pasteboard's text when it changed since the last exchange.
    /// Reading another app's pasteboard shows iOS's "Allow Paste" prompt, so this runs
    /// only when the user pastes (Ctrl/Cmd-V, Shift-Insert), never just on focus.
    func pushPasteboardIfChanged() {
        guard state == .running, let runtimeURL else { return }
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount != pasteboardChangeCount else { return }
        pasteboardChangeCount = pasteboard.changeCount
        guard pasteboard.hasStrings, let text = pasteboard.string else { return }
        let data = Data(text.utf8.prefix(Self.maxClipboardBytes))
        // ishwl created the file, so it exists in the fakefs; only its contents change here.
        let fd = open(runtimeURL.appendingPathComponent("clipboard-in").path, O_WRONLY | O_TRUNC | O_CLOEXEC)
        guard fd >= 0 else { return }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        if written == data.count { send("selection") }
    }

    private func pullClipboard() {
        guard let runtimeURL,
              let data = try? Data(contentsOf: runtimeURL.appendingPathComponent("clipboard-out")),
              data.count <= Self.maxClipboardBytes else { return }
        // Setting the pasteboard posts changedNotification synchronously; without the
        // count taken first, that would echo the text straight back to Linux.
        pasteboardChangeCount = UIPasteboard.general.changeCount + 1
        let text = String(decoding: data, as: UTF8.self)
        let isSecret = textInputSurfaceID.flatMap { surfaces[$0]?.textInput?.isSecret } ?? false
        ClipboardHistory.shared.recordLinuxCopy(text, isSecret: isSecret) {
            UIPasteboard.general.string = text
        }
        pasteboardChangeCount = UIPasteboard.general.changeCount
    }

    // MARK: - Input and window management (host → ishwl)

    func pointerMotion(_ id: UInt32, _ point: CGPoint) {
        send("motion \(id) \(Self.format(point.x)) \(Self.format(point.y))")
    }

    func pointerButton(_ id: UInt32, _ point: CGPoint, button: UInt32, pressed: Bool) {
        stats.inputSent(to: id)
        send("button \(id) \(Self.format(point.x)) \(Self.format(point.y)) \(button) \(pressed ? 1 : 0)")
    }

    /// wl_pointer.axis_source values.
    enum ScrollSource: Int {
        case wheel = 0
        case finger = 1
        case continuous = 2
    }

    func pointerAxis(_ id: UInt32, dx: CGFloat, dy: CGFloat, source: ScrollSource) {
        stats.inputSent(to: id)
        send("axis \(id) \(Self.format(dx)) \(Self.format(dy)) \(source.rawValue)")
    }

    func pointerAxisStop(_ id: UInt32) {
        send("axis_stop \(id)")
    }

    func pointerLeave() {
        send("leave")
    }

    func key(_ code: UInt32, pressed: Bool, focusedSurface: UInt32?) {
        if let focusedSurface { stats.inputSent(to: focusedSurface) }
        // Another app's copy doesn't notify this one, so the pasteboard is synced on paste.
        if Self.controlKeys.contains(code) {
            if pressed { controlKeysDown.insert(code) } else { controlKeysDown.remove(code) }
        }
        if pressed { keysDown.insert(code) } else { keysDown.remove(code) }
        if pressed && (code == Self.keyV && !controlKeysDown.isEmpty || code == Self.keyInsert) {
            pushPasteboardIfChanged()
        }
        send("key \(code) \(pressed ? 1 : 0)")
    }

    /// LinPad is leaving the screen: release every key Linux thinks is held and take the
    /// pointer out of the windows, so nothing stays pressed when the user comes back.
    func releaseHeldInput() {
        for code in keysDown.sorted() { send("key \(code) 0") }
        keysDown.removeAll()
        controlKeysDown.removeAll()
        if state == .running { send("leave") }
    }

    func type(_ text: String) {
        send("text \(Self.escape(text))")
    }

    /// One text-input update for the app's focused field: delete `deleteBefore` UTF-8
    /// bytes before the caret, insert `commit`, then show `preedit` (empty ends the
    /// composition) with its cursor as a UTF-8 byte range.
    func compose(_ id: UInt32, deleteBefore: Int = 0, commit: String = "", preedit: String = "",
                 cursor: Range<Int> = 0..<0) {
        stats.inputSent(to: id)
        send("ime \(deleteBefore) 0 \(Self.escape(commit)) \(Self.escape(preedit)) \(cursor.lowerBound) \(cursor.upperBound)")
    }

    func focus(_ id: UInt32?) {
        send("focus \(id ?? 0)")
    }

    func configure(_ id: UInt32, size: CGSize, maximized: Bool) {
        send("configure \(id) \(Int(size.width)) \(Int(size.height)) \(maximized ? 1 : 0)")
    }

    func requestClose(_ id: UInt32) {
        send("close \(id)")
    }

    func dismissPopups() {
        send("dismiss")
    }

    private func send(_ line: String) {
        guard eventsFD >= 0 else { return }
        let bytes = Array((line + "\n").utf8)
        // Messages are below PIPE_BUF, so each write is atomic.
        let written = bytes.withUnsafeBytes { write(eventsFD, $0.baseAddress, $0.count) }
        if written != bytes.count {
            Self.logger.error("dropped bridge message '\(line, privacy: .public)': \(String(cString: strerror(errno)), privacy: .public)")
        }
    }

    // MARK: - Messages (ishwl → host)

    private func handle(_ line: String) {
        let fields = line.split(separator: " ").map(String.init)
        guard let command = fields.first else { return }
        func uint(_ i: Int) -> UInt32 { i < fields.count ? UInt32(fields[i]) ?? 0 : 0 }
        func int(_ i: Int) -> Int { i < fields.count ? Int(fields[i]) ?? 0 : 0 }

        switch command {
        case "toplevel":
            let surface = announcedSurface(id: uint(1), kind: .toplevel, parentID: uint(2))
            surface.minimumSize = CGSize(width: int(3), height: int(4))
        case "popup":
            let surface = announcedSurface(id: uint(1), kind: .popup, parentID: uint(2))
            surface.position = CGPoint(x: int(3), y: int(4))
            if surface.hasFrame { layoutPopup(surface) }
        case "move":
            if let surface = surfaces[uint(1)] {
                surface.position = CGPoint(x: int(2), y: int(3))
                layoutPopup(surface)
            }
        case "title":
            guard let surface = surfaces[uint(1)] else { return }
            surface.title = fields.count > 2 ? Self.unescape(fields[2]) : ""
            surface.appID = fields.count > 3 ? Self.unescape(fields[3]) : ""
            if surface.hasFrame { delegate?.linuxBridge(self, didRetitle: surface) }
        case "frame":
            handleFrame(fields)
        case "unmap":
            guard let surface = surfaces.removeValue(forKey: uint(1)) else { return }
            unmap(surface)
        case "state":
            if let surface = surfaces[uint(1)], fields.count > 2 {
                delegate?.linuxBridge(self, didRequest: fields[2], for: surface)
            }
        case "clipboard":
            pullClipboard()
        case "activate":
            if let surface = surfaces[uint(1)], surface.hasFrame {
                delegate?.linuxBridge(self, didRequestActivation: surface)
            }
        case "textinput":
            updateTextInput(id: uint(1), enabled: int(2) != 0, purpose: uint(3), hint: uint(4))
        case "surrounding":
            guard let surface = surfaces[uint(1)], surface.textInput != nil, fields.count > 3,
                  !LinuxTextInputState.unreliableSurroundingApps.contains(surface.appID.lowercased()) else { return }
            let bytes = Self.unescapeBytes(fields[2])
            let cursor = min(max(int(3), 0), bytes.count)
            let before = String(decoding: bytes[..<cursor], as: UTF8.self)
            let after = String(decoding: bytes[cursor...], as: UTF8.self)
            guard before != surface.textInput?.textBeforeCursor || after != surface.textInput?.textAfterCursor
                    || surface.textInput?.appReportsText != true else { return }
            surface.textInput?.textBeforeCursor = before
            surface.textInput?.textAfterCursor = after
            surface.textInput?.appReportsText = true
            surface.view?.textInputDidChange(activationChanged: false)
        case "caret":
            surfaces[uint(1)]?.textInput?.caret = CGRect(x: int(2), y: int(3), width: int(4), height: int(5))
        case "open", "preview":
            // Written by ish-open / ish-preview, not ishwl: any guest program can send
            // them, so only web URLs are honoured. "preview" always opens Quick Preview
            // (WebKit, hardware video decoding), whatever the URL handler setting says.
            if fields.count > 1, let url = URL(string: Self.unescape(fields[1])),
               url.scheme?.lowercased() == LinPadLink.scheme, fields[0] == "open" {
                // linpad:// from `linpad update` and friends: the desktop asks before acting.
                LinPadLinkInbox.shared.receive(url)
            } else if fields.count > 1, let url = URL(string: Self.unescape(fields[1])),
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                if fields[0] == "preview" {
                    delegate?.linuxBridge(self, didRequestPreview: url)
                } else {
                    delegate?.linuxBridge(self, didRequestOpen: url)
                }
            }
        case "hello":
            break
        case "bye":
            sessionEnded()
        default:
            Self.logger.debug("unknown message \(line, privacy: .public)")
        }
    }

    /// ishwl announces every mapped view again on `hello`; a view this side already
    /// knows keeps its surface, so its window is reused rather than duplicated.
    private func announcedSurface(id: UInt32, kind: LinuxSurface.Kind, parentID: UInt32) -> LinuxSurface {
        if let existing = surfaces[id], existing.kind == kind, existing.parentID == parentID {
            return existing
        }
        if let stale = surfaces.removeValue(forKey: id) { unmap(stale) }
        let surface = LinuxSurface(id: id, kind: kind, parentID: parentID)
        surfaces[id] = surface
        return surface
    }

    private func updateTextInput(id: UInt32, enabled: Bool, purpose: UInt32, hint: UInt32) {
        if let previous = textInputSurfaceID, previous != id || !enabled, let surface = surfaces[previous] {
            surface.textInput = nil
            surface.view?.textInputDidChange(activationChanged: true)
        }
        textInputSurfaceID = nil
        guard enabled, let surface = surfaces[id] else { return }
        textInputSurfaceID = id
        let old = surface.textInput
        var state = old ?? LinuxTextInputState()
        state.purpose = purpose
        state.hint = hint
        surface.textInput = state
        if old == nil || old?.purpose != purpose || old?.hint != hint {
            surface.view?.textInputDidChange(activationChanged: true)
        }
    }

    // frame ID SEQ WIDTH HEIGHT STRIDE FILE OPAQUE DX DY DW DH [SCALE]
    private func handleFrame(_ fields: [String]) {
        guard fields.count >= 8, let id = UInt32(fields[1]), let seq = UInt32(fields[2]) else { return }
        // Acked even when the frame is unusable: ishwl holds the view's next frame,
        // and its client's frame callbacks, until this ack arrives.
        defer { scheduleAck("ack \(id) \(seq)") }
        guard let width = Int(fields[3]), let height = Int(fields[4]), let stride = Int(fields[5]),
              let surface = surfaces[id], let runtimeURL else { return }
        let name = fields[6]
        let length = stride * height
        if surface.bufferName != name || (surface.mapping?.count ?? 0) < length {
            releaseMapping(surface)
            let path = runtimeURL.appendingPathComponent(name).path
            guard let mapping = Self.map(path: path, length: length) else {
                Self.logger.error("cannot map \(path, privacy: .public)")
                return
            }
            surface.mapping = mapping
            surface.bufferName = name
        }
        guard let base = surface.mapping?.baseAddress else { return }

        // Copy out of the shared mapping: ishwl may draw the next frame as soon as it
        // gets the ack, while Core Animation could still be reading this one.
        let pixels = Data(bytes: base, count: length)
        let opaque = fields[7] == "1"
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipFirst : .premultipliedFirst
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | alpha.rawValue)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: info, provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else { return }

        let firstFrame = !surface.hasFrame
        let scale = CGFloat(max(1, fields.count > 12 ? Int(fields[12]) ?? 1 : 1))
        surface.image = image
        surface.scale = scale
        surface.size = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        if surface.view == nil {
            surface.view = LinuxSurfaceView(surface: surface, bridge: self)
        }
        surface.view?.showFrame()
        stats.frameShown(for: id)

        if firstFrame {
            switch surface.kind {
            case .toplevel:
                if !launchTimes.isEmpty {
                    stats.launched(after: Date().timeIntervalSince(launchTimes.removeFirst()))
                }
                delegate?.linuxBridge(self, didMap: surface)
            case .popup:
                attachPopup(surface)
            }
        } else if surface.kind == .popup {
            layoutPopup(surface)
        }
    }

    #if DEBUG || DESKTOP_AUTOMATION
    /// UI tests: `-desktop.fakeLinuxWindow APPID[:text]` maps one toplevel with a blank
    /// frame and no guest behind it, so keyboard behaviour over a Linux window can be
    /// checked in the harness. ":text" reports a focused text field.
    private func showFakeToplevelIfRequested() -> Bool {
        guard let spec = UserDefaults.standard.string(forKey: "desktop.fakeLinuxWindow"), !spec.isEmpty else { return false }
        let parts = spec.split(separator: ":").map(String.init)
        let surface = LinuxSurface(id: 1, kind: .toplevel, parentID: 0)
        surface.appID = parts[0]
        surface.title = parts[0]
        if parts.contains("text") { surface.textInput = LinuxTextInputState() }
        let size = CGSize(width: 900, height: 560)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        surface.image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemGray5.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: 44))
        }.cgImage
        surface.size = size
        surfaces[surface.id] = surface
        surface.view = LinuxSurfaceView(surface: surface, bridge: self)
        surface.view?.showFrame()
        state = .running
        delegate?.linuxBridge(self, didMap: surface)
        return true
    }
    #endif

    private func unmap(_ surface: LinuxSurface) {
        releaseMapping(surface)
        if surface.kind == .popup {
            surface.view?.removeFromSuperview()
        } else if surface.hasFrame {
            delegate?.linuxBridge(self, didUnmap: surface)
        }
        surface.view = nil
    }

    private func releaseMapping(_ surface: LinuxSurface) {
        if let mapping = surface.mapping, let base = mapping.baseAddress {
            munmap(UnsafeMutableRawPointer(mutating: base), mapping.count)
        }
        surface.mapping = nil
        surface.bufferName = nil
    }

    /// Acks go out on the next display refresh, so a client draws at most one frame
    /// per refresh: frames between refreshes would never be seen, and drawing them
    /// costs emulated CPU time.
    private func scheduleAck(_ line: String) {
        pendingAcks.append(line)
        if displayLink == nil {
            let link = CADisplayLink(target: DisplayLinkTarget { [weak self] in self?.flushAcks() },
                                     selector: #selector(DisplayLinkTarget.tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    private func flushAcks() {
        for line in pendingAcks { send(line) }
        pendingAcks.removeAll()
        displayLink?.isPaused = true
    }

    // MARK: - Popups

    private func rootSurface(of surface: LinuxSurface) -> LinuxSurface? {
        var current: LinuxSurface? = surface
        while let candidate = current, candidate.kind == .popup {
            current = surfaces[candidate.parentID]
        }
        return current
    }

    /// Popups live in the desktop-wide popup layer, above every window, so a menu can
    /// extend past its window. Without the layer they fall back to the toplevel's view.
    private func attachPopup(_ popup: LinuxSurface) {
        guard let root = rootSurface(of: popup), let rootView = root.view, let view = popup.view else { return }
        (popupLayer ?? rootView).addSubview(view)
        layoutPopup(popup)
    }

    /// Positions are relative to the parent surface. Popups are slid back on screen when
    /// they would overflow it: input coordinates are popup-local, so the client never
    /// notices the move.
    private func layoutPopup(_ popup: LinuxSurface) {
        guard let view = popup.view, let container = view.superview,
              let parent = surfaces[popup.parentID], let parentView = parent.view else { return }
        var origin = parentView.convert(popup.position, to: container)
        var bounds = container.bounds
        // Keep menus above the on-screen keyboard as well.
        let keyboardTop = container.keyboardLayoutGuide.layoutFrame.minY
        if keyboardTop > 0 && keyboardTop < bounds.maxY {
            bounds.size.height = keyboardTop - bounds.minY
        }
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - popup.size.width))
        origin.y = max(bounds.minY, min(origin.y, bounds.maxY - popup.size.height))
        view.frame = CGRect(origin: origin, size: popup.size)
    }

    // MARK: - Helpers

    private static func isFIFO(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFIFO
    }

    private static func map(path: String, length: Int) -> UnsafeRawBufferPointer? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let base = mmap(nil, length, PROT_READ, MAP_SHARED, fd, 0), base != MAP_FAILED else { return nil }
        return UnsafeRawBufferPointer(start: base, count: length)
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    static func escape(_ text: String) -> String {
        guard !text.isEmpty else { return "-" }
        // A lone "-" means the empty string on the wire.
        guard text != "-" else { return "%2D" }
        var out: [UInt8] = []
        for byte in text.utf8 {
            if byte <= 0x20 || byte == 0x25 || byte == 0x7f {
                out.append(contentsOf: Array(String(format: "%%%02X", byte).utf8))
            } else {
                out.append(byte)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func unescape(_ text: String) -> String {
        String(decoding: unescapeBytes(text), as: UTF8.self)
    }

    static func unescapeBytes(_ text: String) -> [UInt8] {
        guard text != "-" else { return [] }
        var bytes: [UInt8] = []
        var iterator = Array(text.utf8).makeIterator()
        while let byte = iterator.next() {
            if byte == 0x25, let high = iterator.next(), let low = iterator.next(),
               let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16) {
                bytes.append(value)
            } else {
                bytes.append(byte)
            }
        }
        return bytes
    }
}

/// CADisplayLink retains its target; this breaks the cycle back to the bridge.
private final class DisplayLinkTarget: NSObject {
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func tick() {
        MainActor.assumeIsolated { action() }
    }
}

/// Line reader for the notify FIFO, on its own thread so the main thread never waits
/// on the guest. It polls with a timeout so `stop()` can end it; the FIFO is opened
/// O_RDWR and so never reports EOF.
private final class FIFOLineReader: @unchecked Sendable {
    private let fd: Int32
    private let deliver: @Sendable ([String]) -> Void
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    init(fd: Int32, deliver: @escaping @Sendable ([String]) -> Void) {
        self.fd = fd
        self.deliver = deliver
        let thread = Thread { [self] in run() }
        thread.name = "LinuxGUIBridge.notify"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        stopped.withLock { $0 = true }
    }

    private func run() {
        defer { close(fd) }
        var pending = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !stopped.withLock({ $0 }) {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 500) > 0 else { continue }
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            pending.append(contentsOf: buffer[0..<count])
            guard let lastNewline = pending.lastIndex(of: 0x0A) else { continue }
            let complete = pending[...lastNewline]
            pending.removeSubrange(...lastNewline)
            let lines = complete.split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) }
            if !stopped.withLock({ $0 }) { deliver(lines) }
        }
    }
}

/// Frame rate, input-to-frame latency and launch-to-window time, written to the app's
/// temporary directory (linux-gui-stats.txt) for measuring from outside the app.
/// Frame rate is measured per burst (frames less than half a second apart, e.g. one
/// scroll gesture), which is what matters for interaction; idle time would dilute it.
@MainActor
private struct FrameStats {
    private static let burstGap: TimeInterval = 0.5

    private var burstStart = Date.distantPast
    private var lastFrame = Date.distantPast
    private var burstFrames = 0
    private var bursts: [Double] = []
    private var inputTimes: [UInt32: Date] = [:]
    private var latencies: [Double] = []
    private var launches: [Double] = []

    mutating func inputSent(to id: UInt32) {
        if inputTimes[id] == nil { inputTimes[id] = Date() }
    }

    mutating func launched(after seconds: TimeInterval) {
        launches.append(seconds * 1000)
        write()
    }

    mutating func frameShown(for id: UInt32) {
        let now = Date()
        if let sent = inputTimes.removeValue(forKey: id) {
            latencies.append(now.timeIntervalSince(sent) * 1000)
            if latencies.count > 100 { latencies.removeFirst(latencies.count - 100) }
        }
        if now.timeIntervalSince(lastFrame) > Self.burstGap {
            finishBurst()
            burstStart = now
            burstFrames = 0
        }
        burstFrames += 1
        lastFrame = now
    }

    private mutating func finishBurst() {
        let duration = lastFrame.timeIntervalSince(burstStart)
        guard burstFrames >= 10, duration > 0 else { return }
        bursts.append(Double(burstFrames - 1) / duration)
        if bursts.count > 20 { bursts.removeFirst() }
        write()
    }

    private func write() {
        let sorted = latencies.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let format = { (values: [Double]) in values.map { String(format: "%.0f", $0) }.joined(separator: ",") }
        let summary = "burst-fps [\(format(bursts))] | input-to-frame median \(String(format: "%.0f", median)) ms (n=\(latencies.count)) | launch-to-window ms [\(format(launches))]\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("linux-gui-stats.txt")
        try? summary.write(to: url, atomically: true, encoding: .utf8)
    }
}
