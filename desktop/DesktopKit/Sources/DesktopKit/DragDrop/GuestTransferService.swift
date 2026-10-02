import Foundation
import Observation

/// Moves files between iPadOS and the guest, always through the guest's own shell.
///
/// The fakefs keeps metadata (owner, mode, inode) in meta.db next to the data directory, so a
/// file the host writes straight into the data directory is invisible to Linux. Imports are
/// therefore streamed into `cat` in chunks and exports are read back with `dd | base64`, which
/// keeps memory bounded and gives progress for large files.
@MainActor
final class GuestTransferService {
    typealias ProgressHandler = @MainActor (_ completed: Int64, _ total: Int64) -> Void

    enum TransferError: LocalizedError {
        case guest(String)
        case unreadable(URL)
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .guest(let message): return message
            case .unreadable(let url): return "Couldn't read \(url.lastPathComponent)."
            case .corrupt(let path): return "The data read from \(path) was damaged."
            }
        }
    }

    /// Raw bytes per guest round trip. Larger chunks amortise the cost of starting a shell
    /// in the emulator; 4 MiB keeps the base64 text of an export chunk under 6 MB.
    static let importChunkSize = 4 << 20
    static let exportChunkSize = 3 << 20

    let host: any LinuxHost

    init(host: any LinuxHost) {
        self.host = host
    }

    // MARK: - Import (iPadOS → guest)

    /// Copies a host file or folder into `directory`, renaming on a name clash.
    /// Returns the new guest path.
    @discardableResult
    func importItem(at url: URL, into directory: String, name: String? = nil,
                    progress: ProgressHandler? = nil) async throws -> String {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw TransferError.unreadable(url)
        }
        let existing = try await names(in: directory)
        let target = AppPath.join(directory, FileNaming.unique(name ?? url.lastPathComponent, existing: existing))
        if isDirectory.boolValue {
            try await importDirectory(at: url, to: target, progress: progress)
        } else {
            let total = Self.size(of: url)
            try await importFile(at: url, to: target, offset: 0, total: total, progress: progress)
        }
        return target
    }

    /// Writes in-memory data (an image from Photos, dropped text) as a new guest file.
    @discardableResult
    func importData(_ data: Data, named name: String, into directory: String) async throws -> String {
        let existing = try await names(in: directory)
        let target = AppPath.join(directory, FileNaming.unique(name, existing: existing))
        try await stream(chunks: [data], to: target)
        return target
    }

    private func importDirectory(at url: URL, to target: String, progress: ProgressHandler?) async throws {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: keys) else {
            throw TransferError.unreadable(url)
        }
        var directories = [target]
        var files: [(URL, String, Int64)] = []
        let base = url.standardizedFileURL.path
        for case let item as URL in enumerator {
            let relative = String(item.standardizedFileURL.path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let guestPath = AppPath.join(target, relative)
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                directories.append(guestPath)
            } else {
                files.append((item, guestPath, Int64(values?.fileSize ?? 0)))
            }
        }
        let mkdir = "mkdir -p -- " + directories.map(\.shellQuoted).joined(separator: " ")
        try check(await host.run(mkdir, cwd: nil, stdin: nil))
        let total = files.reduce(0) { $0 + $1.2 }
        var done: Int64 = 0
        for (source, guestPath, size) in files {
            try await importFile(at: source, to: guestPath, offset: done, total: total, progress: progress)
            done += size
        }
    }

    private func importFile(at url: URL, to target: String, offset: Int64, total: Int64,
                            progress: ProgressHandler?) async throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw TransferError.unreadable(url) }
        defer { try? handle.close() }
        let partial = target + ".part"
        try check(await host.run(": > \(partial.shellQuoted)", cwd: nil, stdin: nil))
        var written = offset
        do {
            while let chunk = try handle.read(upToCount: Self.importChunkSize), !chunk.isEmpty {
                try Task.checkCancellation()
                try check(await host.run("cat >> \(partial.shellQuoted)", cwd: nil, stdin: chunk))
                written += Int64(chunk.count)
                progress?(written, max(total, written))
            }
            try check(await host.run("mv -f -- \(partial.shellQuoted) \(target.shellQuoted)", cwd: nil, stdin: nil))
        } catch {
            _ = await host.run("rm -f -- \(partial.shellQuoted)", cwd: nil, stdin: nil)
            throw error
        }
        if total == 0 { progress?(1, 1) }
    }

    private func stream(chunks: [Data], to target: String) async throws {
        let partial = target + ".part"
        try check(await host.run(": > \(partial.shellQuoted)", cwd: nil, stdin: nil))
        for data in chunks {
            var start = 0
            while start < data.count {
                let end = min(start + Self.importChunkSize, data.count)
                try check(await host.run("cat >> \(partial.shellQuoted)", cwd: nil, stdin: data.subdata(in: start..<end)))
                start = end
            }
        }
        try check(await host.run("mv -f -- \(partial.shellQuoted) \(target.shellQuoted)", cwd: nil, stdin: nil))
    }

    // MARK: - Export (guest → iPadOS)

    /// Copies a guest file or folder into a fresh host staging directory (or `directory`)
    /// and returns its URL, ready to hand to another app, Quick Look or the share sheet.
    func exportItem(_ path: String, isDirectory: Bool, to directory: URL? = nil,
                    progress: ProgressHandler? = nil) async throws -> URL {
        let destination = try directory ?? HostStaging.makeDirectory(prefix: "Export")
        let target = destination.appendingPathComponent(AppPath.lastComponent(path), isDirectory: isDirectory)
        if isDirectory {
            try await exportDirectory(path, to: target, progress: progress)
        } else {
            let total = try await size(ofGuestFile: path)
            try await exportFile(path, size: total, to: target, offset: 0, total: total, progress: progress)
        }
        return target
    }

    private func exportDirectory(_ path: String, to target: URL, progress: ProgressHandler?) async throws {
        // One round trip for the whole tree: directories, then "SIZE<TAB>PATH" per file,
        // NUL-terminated so spaces and tabs in names survive.
        let listing = try check(await host.run("""
            cd -- \(path.shellQuoted) || exit 1
            find . -type d -print0
            printf '\\001'
            find . -type f | while IFS= read -r f; do printf '%s\\t%s\\0' "$(wc -c < "$f" | tr -d ' ')" "$f"; done
            """, cwd: nil, stdin: nil))
        let sections = listing.stdout.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false)
        let directories = sections.first.map(Self.splitNUL) ?? []
        let files: [(path: String, size: Int64)] = (sections.count > 1 ? Self.splitNUL(sections[1]) : []).compactMap { line in
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            return (String(line[line.index(after: tab)...]), Int64(line[..<tab]) ?? 0)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        for relative in directories where relative != "." {
            try manager.createDirectory(at: target.appendingPathComponent(Self.strip(relative)),
                                        withIntermediateDirectories: true)
        }
        let total = files.reduce(0) { $0 + $1.size }
        var done: Int64 = 0
        for (relative, size) in files {
            try await exportFile(AppPath.join(path, Self.strip(relative)), size: size,
                                 to: target.appendingPathComponent(Self.strip(relative)),
                                 offset: done, total: total, progress: progress)
            done += size
        }
    }

    private func exportFile(_ path: String, size: Int64, to target: URL, offset: Int64, total: Int64,
                            progress: ProgressHandler?) async throws {
        let manager = FileManager.default
        manager.createFile(atPath: target.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: target) else { throw TransferError.unreadable(target) }
        defer { try? handle.close() }
        let chunk = Int64(Self.exportChunkSize)
        var block: Int64 = 0
        while block * chunk < size {
            try Task.checkCancellation()
            let result = try check(await host.run(
                "dd if=\(path.shellQuoted) bs=\(chunk) skip=\(block) count=1 2>/dev/null | base64",
                cwd: nil, stdin: nil))
            guard let data = Data(base64Encoded: result.stdout, options: .ignoreUnknownCharacters) else {
                throw TransferError.corrupt(path)
            }
            try handle.write(contentsOf: data)
            block += 1
            progress?(offset + min(block * chunk, size), total)
        }
    }

    // MARK: - Helpers

    func size(ofGuestFile path: String) async throws -> Int64 {
        let result = try check(await host.run("wc -c < \(path.shellQuoted)", cwd: nil, stdin: nil))
        guard let size = Int64(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TransferError.guest("Couldn't read the size of \(path).")
        }
        return size
    }

    /// Names in a guest directory, hidden ones included.
    func names(in directory: String) async throws -> Set<String> {
        let result = try check(await host.run("ls -A -- \(directory.shellQuoted)", cwd: nil, stdin: nil))
        return Set(result.stdout.split(separator: "\n").map(String.init))
    }

    @discardableResult
    private func check(_ result: CommandResult) throws -> CommandResult {
        guard result.succeeded else { throw TransferError.guest(result.failureDescription) }
        return result
    }

    private static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func splitNUL(_ text: Substring) -> [String] {
        text.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
    }

    private static func strip(_ relative: String) -> String {
        relative.hasPrefix("./") ? String(relative.dropFirst(2)) : relative
    }
}

/// Name clash handling shared by imports, copies, the trash and new items.
enum FileNaming {
    /// "report.txt" → "report (2).txt" → "report (3).txt"; the extension stays last, and
    /// a dotfile ("".bashrc") or a name without one simply gets the counter appended.
    static func unique(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let (base, ext) = split(name)
        var counter = 2
        while existing.contains(compose(base: "\(base) (\(counter))", ext: ext)) {
            counter += 1
        }
        return compose(base: "\(base) (\(counter))", ext: ext)
    }

    /// "notes.txt" → "notes (copy).txt", then "notes (copy 2).txt", like Nautilus.
    static func duplicate(_ name: String, existing: Set<String>) -> String {
        let (base, ext) = split(name)
        var candidate = compose(base: "\(base) (copy)", ext: ext)
        var counter = 2
        while existing.contains(candidate) {
            candidate = compose(base: "\(base) (copy \(counter))", ext: ext)
            counter += 1
        }
        return candidate
    }

    /// Archive suffixes count as one extension ("a.tar.gz" splits as "a" + "tar.gz").
    static func split(_ name: String) -> (base: String, ext: String) {
        for compound in ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"] where name.lowercased().hasSuffix("." + compound) && name.count > compound.count + 1 {
            return (String(name.dropLast(compound.count + 1)), String(name.suffix(compound.count)))
        }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    private static func compose(base: String, ext: String) -> String {
        ext.isEmpty ? base : base + "." + ext
    }
}

/// Progress of a long file operation, shown in the Files status bar.
@Observable @MainActor
final class TransferActivity {
    var title: String
    var completed: Int64 = 0
    var total: Int64 = 0

    init(title: String) {
        self.title = title
    }

    var fraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }

    func update(_ completed: Int64, _ total: Int64) {
        self.completed = completed
        self.total = total
    }
}
