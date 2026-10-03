import Observation
import UIKit
import UniformTypeIdentifiers

/// One copied text or image.
struct ClipboardEntry: Codable, Identifiable, Equatable {
    enum Source: String, Codable {
        case linux, linpad

        var title: String { self == .linux ? "Linux" : "LinPad" }
    }

    var id = UUID()
    var text: String?
    /// PNG file name in the history folder.
    var imageFile: String?
    var imageSize: CGSize?
    var source: Source
    var date: Date
    var isPinned = false

    var title: String {
        if let text {
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return line.trimmingCharacters(in: .whitespaces).isEmpty ? "(whitespace)" : String(line.prefix(120))
        }
        if let imageSize { return "Image \(Int(imageSize.width))×\(Int(imageSize.height))" }
        return "Image"
    }
}

/// The last copies made in LinPad and in Linux apps, newest first. Copies from other iPad
/// apps are not recorded: reading them would show iPadOS's paste prompt each time. Text
/// copied out of a password field (a Linux text input of the password purpose, or a
/// pasteboard item marked concealed) is never kept, and nothing is while history is paused.
/// Stored on this iPad only, in Application Support.
@Observable @MainActor
final class ClipboardHistory {
    static let shared = ClipboardHistory(directory: ClipboardHistory.defaultDirectory)

    static let pausedKey = "desktop.clipboard.historyPaused"
    static let limit = 50
    static let imageLimit = 10
    static let maxTextLength = 200_000
    /// Pasteboard types password managers set on secrets (nspasteboard.org).
    static let concealedTypes = ["org.nspasteboard.ConcealedType", "com.agilebits.onepassword", "org.nspasteboard.TransientType"]

    private(set) var entries: [ClipboardEntry] = []
    var isPaused: Bool {
        didSet { UserDefaults.standard.set(isPaused, forKey: Self.pausedKey) }
    }

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// The pasteboard change this history made itself (restoring an entry).
    @ObservationIgnored private var ownChangeCount = -1
    /// Set while a Linux copy is put on the pasteboard, which reports it synchronously.
    @ObservationIgnored private var isApplyingLinuxCopy = false

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LinPad/Clipboard", isDirectory: true)
    }

    init(directory: URL) {
        self.directory = directory
        isPaused = UserDefaults.standard.bool(forKey: Self.pausedKey)
        #if DEBUG || DESKTOP_AUTOMATION
        // UI tests: `-desktop.clipboard.reset YES` starts with no history.
        if UserDefaults.standard.bool(forKey: "desktop.clipboard.reset") {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        #endif
        load()
    }

    /// Records copies made inside the app. UIKit posts this only for this app's own changes.
    func startObservingPasteboard() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIPasteboard.changedNotification, object: UIPasteboard.general,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pasteboardChanged() }
        }
    }

    private func pasteboardChanged() {
        let pasteboard = UIPasteboard.general
        guard !isApplyingLinuxCopy, UIApplication.shared.applicationState == .active,
              pasteboard.changeCount != ownChangeCount,
              !pasteboard.contains(pasteboardTypes: Self.concealedTypes) else { return }
        if pasteboard.hasStrings, let text = pasteboard.string {
            record(text: text, source: .linpad)
        } else if pasteboard.hasImages, let image = pasteboard.image {
            record(image: image, source: .linpad)
        }
    }

    // MARK: Recording

    /// A copy in a Linux app: recorded unless it came out of a password field, then put on
    /// the iPad pasteboard by `apply` without being recorded a second time.
    func recordLinuxCopy(_ text: String, isSecret: Bool, apply: () -> Void) {
        record(text: text, source: .linux, isSecret: isSecret)
        isApplyingLinuxCopy = true
        apply()
        isApplyingLinuxCopy = false
    }

    func record(text: String, source: ClipboardEntry.Source, isSecret: Bool = false) {
        guard !isPaused, !isSecret, !text.isEmpty, text.count <= Self.maxTextLength else { return }
        if let index = entries.firstIndex(where: { $0.text == text }) {
            var existing = entries.remove(at: index)
            existing.date = Date()
            entries.insert(existing, at: 0)
        } else {
            entries.insert(ClipboardEntry(text: text, source: source, date: Date()), at: 0)
        }
        prune()
        save()
    }

    func record(image: UIImage, source: ClipboardEntry.Source) {
        guard !isPaused, let data = image.pngData() else { return }
        let name = UUID().uuidString + ".png"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name))
        } catch {
            return
        }
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        entries.insert(ClipboardEntry(imageFile: name, imageSize: size, source: source, date: Date()), at: 0)
        prune()
        save()
    }

    /// Keeps every pinned entry, the newest `limit` others, and at most `imageLimit` images.
    private func prune() {
        var unpinned = 0
        var images = 0
        var kept: [ClipboardEntry] = []
        for entry in entries {
            if entry.isPinned {
                kept.append(entry)
                continue
            }
            let isImage = entry.imageFile != nil
            if unpinned < Self.limit && (!isImage || images < Self.imageLimit) {
                kept.append(entry)
                unpinned += 1
                if isImage { images += 1 }
            } else {
                deleteImage(of: entry)
            }
        }
        entries = kept
    }

    // MARK: Editing

    func togglePin(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isPinned.toggle()
        save()
    }

    func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        deleteImage(of: entries.remove(at: index))
        save()
    }

    /// Clears everything except pinned entries.
    func clear() {
        for entry in entries where !entry.isPinned { deleteImage(of: entry) }
        entries.removeAll { !$0.isPinned }
        save()
    }

    func image(of entry: ClipboardEntry) -> UIImage? {
        entry.imageFile.flatMap { UIImage(contentsOfFile: directory.appendingPathComponent($0).path) }
    }

    /// Puts the entry back on the clipboard (Linux apps get it at their next paste) and
    /// moves it to the top.
    func restore(_ entry: ClipboardEntry) {
        let pasteboard = UIPasteboard.general
        if let text = entry.text {
            pasteboard.string = text
        } else if let image = image(of: entry) {
            pasteboard.image = image
        }
        ownChangeCount = pasteboard.changeCount
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            var moved = entries.remove(at: index)
            moved.date = Date()
            entries.insert(moved, at: 0)
            save()
        }
    }

    // MARK: Storage

    private var indexURL: URL { directory.appendingPathComponent("history.json") }

    private func deleteImage(of entry: ClipboardEntry) {
        if let file = entry.imageFile { try? FileManager.default.removeItem(at: directory.appendingPathComponent(file)) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([ClipboardEntry].self, from: data) else { return }
        entries = saved
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            try JSONEncoder().encode(entries).write(to: indexURL, options: [.atomic, .completeFileProtection])
        } catch {
            ClipboardHistory.logSaveFailure(error)
        }
    }

    private static func logSaveFailure(_ error: Error) {
        NSLog("Clipboard history: could not save: %@", error.localizedDescription)
    }
}
