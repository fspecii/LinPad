import Foundation

/// The freedesktop.org Trash (Trash spec 1.0) in the guest's home: trashed items live in
/// `$XDG_DATA_HOME/Trash/files` and each has `info/<name>.trashinfo` saying where it came
/// from, so Thunar, Nautilus and `gio trash` see the same trash as the native Files app.
@MainActor
struct FileTrash {
    struct Item: Identifiable, Equatable {
        /// The name inside Trash/files.
        let name: String
        let originalPath: String
        let deletionDate: Date?
        let isDirectory: Bool
        var id: String { name }
    }

    let host: any LinuxHost
    let homeDirectory: String

    var trashDirectory: String { AppPath.join(homeDirectory, ".local/share/Trash") }
    var filesDirectory: String { AppPath.join(trashDirectory, "files") }
    var infoDirectory: String { AppPath.join(trashDirectory, "info") }

    func isInTrash(_ path: String) -> Bool {
        let normalized = AppPath.normalize(path)
        return normalized == filesDirectory || normalized.hasPrefix(filesDirectory + "/")
    }

    /// Moves items to the trash; returns the trash names they got, in order.
    @discardableResult
    func trash(_ paths: [String], now: Date = Date()) async throws -> [String] {
        let listing = await host.run("""
            mkdir -p -- \(filesDirectory.shellQuoted) \(infoDirectory.shellQuoted) || exit 1
            ls -A -- \(filesDirectory.shellQuoted); ls -A -- \(infoDirectory.shellQuoted)
            """, cwd: nil, stdin: nil)
        guard listing.succeeded else { throw LinuxHostError.commandFailed(listing) }
        // A name is taken if either the file or its info exists (a half-finished trash).
        var taken = Set(listing.stdout.split(separator: "\n").map { line -> String in
            line.hasSuffix(".trashinfo") ? String(line.dropLast(".trashinfo".count)) : String(line)
        })
        var names: [String] = []
        var script = "set -e\n"
        for path in paths {
            let original = AppPath.normalize(path)
            let name = FileNaming.unique(AppPath.lastComponent(original), existing: taken)
            taken.insert(name)
            names.append(name)
            let info = TrashInfo.trashInfo(originalPath: original, deletionDate: now)
            let infoPath = AppPath.join(infoDirectory, name + ".trashinfo")
            // The info file goes first, as the spec asks, so a crash never leaves an
            // orphan in files/ with no way back.
            script += "printf '%s' \(info.shellQuoted) > \(infoPath.shellQuoted)\n"
            script += "mv -- \(original.shellQuoted) \(AppPath.join(filesDirectory, name).shellQuoted) || { rm -f -- \(infoPath.shellQuoted); exit 1; }\n"
        }
        let result = await host.run(script, cwd: nil, stdin: nil)
        guard result.succeeded else { throw LinuxHostError.commandFailed(result) }
        return names
    }

    func list() async throws -> [Item] {
        let result = await host.run("""
            cd -- \(infoDirectory.shellQuoted) 2>/dev/null || exit 0
            for f in *.trashinfo; do [ -f "$f" ] || continue; n="${f%.trashinfo}"
              if [ -d "../files/$n" ]; then k=d; elif [ -e "../files/$n" ] || [ -L "../files/$n" ]; then k=f; else continue; fi
              printf '\\001%s\\001%s\\n' "$k" "$n"; cat -- "$f"; printf '\\n'
            done
            """, cwd: nil, stdin: nil)
        guard result.succeeded else { throw LinuxHostError.commandFailed(result) }
        return TrashInfo.parseListing(result.stdout)
    }

    /// Puts items back where they came from, renaming if something new took the name.
    /// Returns the restored paths.
    @discardableResult
    func restore(_ names: [String]) async throws -> [String] {
        let items = try await list().filter { names.contains($0.name) }
        var script = "set -e\n"
        var restored: [String] = []
        for item in items {
            let parent = AppPath.parent(of: item.originalPath)
            let siblings = (try? await TransferNames(host: host).names(in: parent)) ?? []
            let target = AppPath.join(parent, FileNaming.unique(AppPath.lastComponent(item.originalPath), existing: siblings))
            restored.append(target)
            script += "mkdir -p -- \(parent.shellQuoted)\n"
            script += "mv -- \(AppPath.join(filesDirectory, item.name).shellQuoted) \(target.shellQuoted)\n"
            script += "rm -f -- \(AppPath.join(infoDirectory, item.name + ".trashinfo").shellQuoted)\n"
        }
        let result = await host.run(script, cwd: nil, stdin: nil)
        guard result.succeeded else { throw LinuxHostError.commandFailed(result) }
        return restored
    }

    func delete(_ names: [String]) async throws {
        let targets = names.flatMap {
            [AppPath.join(filesDirectory, $0), AppPath.join(infoDirectory, $0 + ".trashinfo")]
        }
        guard !targets.isEmpty else { return }
        let result = await host.run("rm -rf -- " + targets.map(\.shellQuoted).joined(separator: " "),
                                    cwd: nil, stdin: nil)
        guard result.succeeded else { throw LinuxHostError.commandFailed(result) }
    }

    func empty() async throws {
        let result = await host.run("""
            rm -rf -- \(filesDirectory.shellQuoted) \(infoDirectory.shellQuoted) \(AppPath.join(trashDirectory, "directorysizes").shellQuoted)
            mkdir -p -- \(filesDirectory.shellQuoted) \(infoDirectory.shellQuoted)
            """, cwd: nil, stdin: nil)
        guard result.succeeded else { throw LinuxHostError.commandFailed(result) }
    }

}

/// The .trashinfo format and the listing `FileTrash.list` prints.
enum TrashInfo {
    /// `Path` is percent-encoded as a URI path (RFC 2396); `DeletionDate` is local time
    /// without a zone, both as the spec requires.
    static func trashInfo(originalPath: String, deletionDate: Date) -> String {
        "[Trash Info]\nPath=\(encodePath(originalPath))\nDeletionDate=\(dateFormatter.string(from: deletionDate))\n"
    }

    static func parseTrashInfo(_ text: String) -> (path: String, date: Date?)? {
        var inGroup = false
        var path: String?
        var date: Date?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inGroup = line == "[Trash Info]"
                continue
            }
            guard inGroup, let equals = line.firstIndex(of: "=") else { continue }
            let value = String(line[line.index(after: equals)...])
            switch line[..<equals] {
            case "Path": path = value.removingPercentEncoding ?? value
            case "DeletionDate": date = dateFormatter.date(from: value)
            default: break
            }
        }
        return path.map { ($0, date) }
    }

    static func encodePath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%;?#")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    static func parseListing(_ output: String) -> [FileTrash.Item] {
        output.components(separatedBy: "\u{1}").dropFirst().chunked(by: 2).compactMap { pair -> FileTrash.Item? in
            guard pair.count == 2 else { return nil }
            let kind = pair[0]
            guard let newline = pair[1].firstIndex(of: "\n") else { return nil }
            let name = String(pair[1][..<newline])
            let body = String(pair[1][pair[1].index(after: newline)...])
            guard let info = parseTrashInfo(body) else { return nil }
            return FileTrash.Item(name: name, originalPath: info.path, deletionDate: info.date, isDirectory: kind == "d")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()
}

/// `ls -A` of a guest directory, for picking free names.
@MainActor
struct TransferNames {
    let host: any LinuxHost

    func names(in directory: String) async throws -> Set<String> {
        let result = await host.run("ls -A -- \(directory.shellQuoted)", cwd: nil, stdin: nil)
        guard result.succeeded else { throw LinuxHostError.commandFailed(result) }
        return Set(result.stdout.split(separator: "\n").map(String.init))
    }
}

private extension Sequence {
    func chunked(by size: Int) -> [[Element]] {
        var chunks: [[Element]] = []
        var current: [Element] = []
        for element in self {
            current.append(element)
            if current.count == size {
                chunks.append(current)
                current = []
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
