#if DEBUG || DESKTOP_AUTOMATION
import Foundation
import UIKit

/// Test-only remote control (launch argument `-desktop.debugAutomation YES`), compiled only
/// into Debug builds or builds with the DESKTOP_AUTOMATION condition (desktop/simrun-dnd.sh
/// with AUTOMATION=1). XCUITest cannot aim reliably at content drawn by Linux apps, so this
/// drives Linux windows through the same bridge calls LinuxSurfaceView and LinuxDragBridge
/// make for real touches.
///
/// Commands are files in /tmp/ish-automation/SIMULATOR_UDID/in (processed in name order, then deleted),
/// one command per file, fields separated by "|":
///   sh|COMMAND                       run in the guest, output to the log
///   state                            list windows (app id, title, frame)
///   open|APPID[|key=value…]          open an app
///   click|WINDOW|X|Y[|right]         click in a Linux window (content coordinates)
///   dblclick|WINDOW|X|Y
///   frame|WINDOW|X|Y|W|H / minimize|WINDOW / focus|WINDOW   arrange windows
///   key|WINDOW|EVDEV[,EVDEV…]           press the keys in order, release in reverse
///   drag|WINDOW|X|Y|TARGET|X|Y       drag from a Linux window to TARGET: another window
///                                    (content coordinates) or "desktop" (desktop coordinates)
/// WINDOW/TARGET match a window title substring, or "app:ID" for an app id.
/// Results and every ishwl dnd message are appended to /tmp/ish-automation/SIMULATOR_UDID/log.
@MainActor
final class DebugAutomation {
    static let enabledKey = "desktop.debugAutomation"
    /// Per simulator, since every simulator shares the Mac's /tmp.
    private static let root = URL(fileURLWithPath: "/tmp/ish-automation", isDirectory: true)
        .appendingPathComponent(ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "device", isDirectory: true)

    private weak var controller: DesktopController?
    private var pollTask: Task<Void, Never>?
    private var busy = false

    init(controller: DesktopController) {
        self.controller = controller
    }

    static func startIfEnabled(_ controller: DesktopController) -> DebugAutomation? {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return nil }
        let automation = DebugAutomation(controller: controller)
        automation.start()
        return automation
    }

    private func start() {
        let inbox = Self.root.appendingPathComponent("in", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        log("automation ready")
        DragDropCenter.shared.linuxDrag?.onMessage = { [weak self] line in self?.log("dnd: " + line) }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                await self?.poll(inbox)
            }
        }
    }

    private func poll(_ inbox: URL) async {
        guard !busy else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        guard let next = files.filter({ $0.pathExtension == "cmd" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first,
              let text = try? String(contentsOf: next, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: next)
        busy = true
        await run(text.trimmingCharacters(in: .whitespacesAndNewlines))
        busy = false
    }

    private func log(_ line: String) {
        let url = Self.root.appendingPathComponent("log")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: Commands

    private func run(_ command: String) async {
        guard let controller else { return }
        let fields = command.components(separatedBy: "|")
        log("> " + command)
        switch fields.first ?? "" {
        case "sh":
            let result = await controller.host.run(fields.dropFirst().joined(separator: "|"), cwd: nil, stdin: nil)
            log(result.stdout + (result.stderr.isEmpty ? "" : "stderr: " + result.stderr) + "exit \(result.exitCode)")
        case "state":
            if DragDropCenter.shared.linuxDrag == nil { DragDropCenter.shared.attach(controller) }
            DragDropCenter.shared.windowsChanged()
            for window in controller.windowManager.windows {
                log("window \(window.appID)|\(window.title)|\(controller.windowManager.displayFrame(for: window))")
            }
        case "open" where fields.count > 1:
            var arguments: [String: String] = [:]
            for pair in fields.dropFirst(2) {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { arguments[parts[0]] = parts[1] }
            }
            controller.open(appID: fields[1], arguments: arguments)
        case "click", "dblclick":
            guard fields.count >= 4, let view = linuxView(fields[1]),
                  let x = Double(fields[2]), let y = Double(fields[3]) else { return log("bad click") }
            let button: UInt32 = fields.count > 4 && fields[4] == "right" ? 0x111 : 0x110
            for _ in 0..<(fields[0] == "dblclick" ? 2 : 1) {
                await click(view, CGPoint(x: x, y: y), button: button)
            }
            log("ok")
        case "frame", "minimize", "focus":
            guard fields.count >= 2, let window = controller.windowManager.windows.first(where: { matches($0, fields[1]) }) else {
                return log("no window")
            }
            if fields[0] == "minimize" {
                controller.windowManager.minimize(window.id)
            } else if fields[0] == "focus" {
                controller.windowManager.focus(window.id)
            } else if fields.count >= 6, let x = Double(fields[2]), let y = Double(fields[3]),
                      let w = Double(fields[4]), let h = Double(fields[5]) {
                window.frame = CGRect(x: x, y: y, width: w, height: h)
            }
            log("ok")
        case "key":
            guard fields.count >= 3, let view = linuxView(fields[1]) else { return log("bad key") }
            let codes = fields[2].split(separator: ",").compactMap { UInt32($0) }
            bridge?.focus(view.surfaceID)
            for code in codes { bridge?.key(code, pressed: true, focusedSurface: view.surfaceID) }
            for code in codes.reversed() { bridge?.key(code, pressed: false, focusedSurface: view.surfaceID) }
            log("ok")
        case "drag":
            guard fields.count >= 7, let source = linuxView(fields[1]),
                  let x = Double(fields[2]), let y = Double(fields[3]),
                  let tx = Double(fields[5]), let ty = Double(fields[6]),
                  let target = windowPoint(fields[4], CGPoint(x: tx, y: ty)) else { return log("bad drag") }
            await drag(from: source, CGPoint(x: x, y: y), to: target)
        default:
            log("unknown command")
        }
    }

    private var bridge: LinuxGUIBridge? { controller?.linux }

    private func linuxView(_ match: String) -> LinuxSurfaceView? {
        guard let controller, let bridge else { return nil }
        for (surfaceID, windowID) in controller.linuxWindows {
            guard let window = controller.windowManager.window(withID: windowID), matches(window, match) else { continue }
            if let view = bridge.surface(withID: surfaceID)?.view { return view }
        }
        return nil
    }

    private func matches(_ window: DesktopWindow, _ match: String) -> Bool {
        if match.hasPrefix("app:") { return window.appID == String(match.dropFirst(4)) }
        return window.title.localizedCaseInsensitiveContains(match)
    }

    /// A point in UIWindow coordinates: content coordinates of a Linux window, window-frame
    /// coordinates of a native window, or desktop coordinates for "desktop".
    private func windowPoint(_ match: String, _ point: CGPoint) -> CGPoint? {
        guard let controller, let reference = controller.input.referenceView, let uiWindow = reference.window else { return nil }
        if match == "desktop" { return reference.convert(point, to: uiWindow) }
        if let view = linuxView(match) { return view.convert(point, to: uiWindow) }
        let manager = controller.windowManager
        guard let window = manager.windows.first(where: { matches($0, match) }) else { return nil }
        let frame = manager.displayFrame(for: window)
        return reference.convert(CGPoint(x: frame.minX + point.x, y: frame.minY + point.y), to: uiWindow)
    }

    private func click(_ view: LinuxSurfaceView, _ point: CGPoint, button: UInt32) async {
        bridge?.pointerMotion(view.surfaceID, point)
        bridge?.pointerButton(view.surfaceID, point, button: button, pressed: true)
        try? await Task.sleep(for: .milliseconds(60))
        bridge?.pointerButton(view.surfaceID, point, button: button, pressed: false)
        try? await Task.sleep(for: .milliseconds(120))
    }

    /// A press-and-drag as the trackpad would produce it: press, nudge past the toolkit's
    /// drag threshold until ishwl reports the drag, then travel to the target and release.
    private func drag(from source: LinuxSurfaceView, _ start: CGPoint, to target: CGPoint) async {
        guard let bridge, let dnd = DragDropCenter.shared.linuxDrag, let uiWindow = source.window else {
            return log("drag: no bridge")
        }
        let id = source.surfaceID
        bridge.pointerMotion(id, start)
        try? await Task.sleep(for: .milliseconds(100))
        bridge.pointerButton(id, start, button: 0x110, pressed: true)
        var nudge = 0
        let deadline = Date().addingTimeInterval(6)
        while !dnd.isLinuxDragActive && Date() < deadline {
            nudge += 1
            let offset = CGFloat(min(nudge * 3, 30))
            bridge.pointerMotion(id, CGPoint(x: start.x + offset, y: start.y + offset / 2))
            try? await Task.sleep(for: .milliseconds(80))
        }
        guard dnd.isLinuxDragActive else {
            bridge.pointerButton(id, start, button: 0x110, pressed: false)
            return log("drag: the app did not start a drag")
        }
        let from = source.convert(start, to: uiWindow)
        let steps = 30
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: from.x + (target.x - from.x) * t, y: from.y + (target.y - from.y) * t)
            let local = source.convert(point, from: uiWindow)
            bridge.pointerMotion(id, local)
            dnd.linuxDragMoved(to: local, in: source)
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(400))
        let end = source.convert(target, from: uiWindow)
        dnd.linuxDragEnded(at: end, in: source)
        bridge.pointerButton(id, end, button: 0x110, pressed: false)
        log("drag: released")
    }
}
#endif
