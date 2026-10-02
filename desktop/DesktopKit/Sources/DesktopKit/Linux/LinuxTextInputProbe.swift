#if DEBUG || DESKTOP_AUTOMATION
import Foundation
import UIKit

/// Test-only: drives the focused Linux window's UITextInput the way the iPad keyboard
/// does, since the simulator cannot type through an input method (its `text` tool
/// pastes anything non-ASCII). Enabled with the same `-desktop.debugAutomation YES` as
/// DebugAutomation. Commands are files in /tmp/ish-automation/SIMULATOR_UDID/ime
/// (name order, deleted when done), fields separated by "|":
///   insert|TEXT            insertText (a long-press accent, an emoji, dictation)
///   mark|TEXT|LOC|LEN      setMarkedText with that selection (a composition step)
///   unmark                 unmarkText (commit the composition)
///   replace|N|TEXT         replace the N characters before the caret (a correction)
///   delete                 deleteBackward
/// Each command and the resulting document goes to /tmp/ish-automation/SIMULATOR_UDID/ime.log.
@MainActor
final class LinuxTextInputProbe {
    private static let root = URL(fileURLWithPath: "/tmp/ish-automation", isDirectory: true)
        .appendingPathComponent(ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "device", isDirectory: true)

    private let target: () -> LinuxSurfaceView?
    private var task: Task<Void, Never>?

    init(target: @escaping () -> LinuxSurfaceView?) {
        self.target = target
    }

    static func startIfEnabled(target: @escaping () -> LinuxSurfaceView?) -> LinuxTextInputProbe? {
        guard UserDefaults.standard.bool(forKey: "desktop.debugAutomation") else { return nil }
        let probe = LinuxTextInputProbe(target: target)
        let inbox = root.appendingPathComponent("ime", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        probe.task = Task { [weak probe] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                probe?.poll(inbox)
            }
        }
        return probe
    }

    private func poll(_ inbox: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let command = (try? String(contentsOf: file, encoding: .utf8))?
                .trimmingCharacters(in: .newlines) ?? ""
            try? FileManager.default.removeItem(at: file)
            run(command)
        }
    }

    private func run(_ command: String) {
        let fields = command.components(separatedBy: "|")
        guard let view = target() else {
            log("\(command): no Linux text field")
            return
        }
        switch fields.first {
        case "insert" where fields.count > 1:
            view.insertText(fields[1])
        case "mark" where fields.count > 3:
            view.setMarkedText(fields[1], selectedRange: NSRange(location: Int(fields[2]) ?? 0, length: Int(fields[3]) ?? 0))
        case "unmark":
            view.unmarkText()
        case "replace" where fields.count > 2:
            let caret = view.selectedTextRange?.start ?? view.beginningOfDocument
            if let start = view.position(from: caret, offset: -(Int(fields[1]) ?? 0)),
               let range = view.textRange(from: start, to: caret) {
                view.replace(range, withText: fields[2])
            }
        case "delete":
            view.deleteBackward()
        default:
            log("\(command): unknown")
            return
        }
        let document = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument).flatMap(view.text(in:)) ?? ""
        log("\(command) -> \(document)")
    }

    private func log(_ line: String) {
        let url = Self.root.appendingPathComponent("ime.log")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
