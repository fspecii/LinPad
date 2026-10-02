import Foundation
import Observation

/// The desktop-wide file clipboard (Cut/Copy/Paste between Files windows and the desktop),
/// separate from the text pasteboard, as in Thunar and Nautilus.
@Observable @MainActor
final class FileClipboard {
    static let shared = FileClipboard()

    private(set) var paths: [String] = []
    private(set) var isCut = false

    var isEmpty: Bool { paths.isEmpty }

    func copy(_ paths: [String]) {
        self.paths = paths
        isCut = false
    }

    func cut(_ paths: [String]) {
        self.paths = paths
        isCut = true
    }

    func clear() {
        paths = []
        isCut = false
    }

    func isCut(_ path: String) -> Bool {
        isCut && paths.contains(path)
    }
}

/// File manager operations, each one guest shell round trip.
@MainActor
struct FileOperations {
    let host: any LinuxHost

    struct Properties: Equatable {
        var path: String
        var kind: String
        var permissions: String   // "-rw-r--r--"
        var mode: Int             // 0o644
        var owner: String
        var group: String
        var size: Int64
        var accessed: Date?
        var modified: Date?
        var changed: Date?
        var itemCount: Int?
    }

    enum ArchiveFormat: String, CaseIterable, Identifiable {
        case tarGz = "tar.gz"
        case zip = "zip"
        var id: String { rawValue }
    }

    /// Copies or moves `paths` into `directory`. Names that clash get a counter; moving an
    /// item onto itself or into its own subtree is skipped. Returns the new paths.
    @discardableResult
    func transfer(_ paths: [String], into directory: String, operation: DropOperation) async throws -> [String] {
        let target = AppPath.normalize(directory)
        var taken = try await TransferNames(host: host).names(in: target)
        var script = "set -e\n"
        var results: [String] = []
        for path in paths.map({ AppPath.normalize($0) }) {
            if target == path || target.hasPrefix(path + "/") { continue }
            if operation == .move && AppPath.parent(of: path) == target { continue }
            let name = FileNaming.unique(AppPath.lastComponent(path), existing: taken)
            taken.insert(name)
            let destination = AppPath.join(target, name)
            results.append(destination)
            switch operation {
            case .copy: script += "cp -a -- \(path.shellQuoted) \(destination.shellQuoted)\n"
            case .move: script += "mv -- \(path.shellQuoted) \(destination.shellQuoted)\n"
            }
        }
        guard !results.isEmpty else { return [] }
        try check(await host.run(script, cwd: nil, stdin: nil))
        return results
    }

    @discardableResult
    func duplicate(_ paths: [String]) async throws -> [String] {
        var results: [String] = []
        var script = "set -e\n"
        var namesByParent: [String: Set<String>] = [:]
        for path in paths {
            let parent = AppPath.parent(of: path)
            var taken: Set<String>
            if let cached = namesByParent[parent] { taken = cached } else { taken = try await TransferNames(host: host).names(in: parent) }
            let name = FileNaming.duplicate(AppPath.lastComponent(path), existing: taken)
            taken.insert(name)
            namesByParent[parent] = taken
            let destination = AppPath.join(parent, name)
            results.append(destination)
            script += "cp -a -- \(path.shellQuoted) \(destination.shellQuoted)\n"
        }
        try check(await host.run(script, cwd: nil, stdin: nil))
        return results
    }

    func deletePermanently(_ paths: [String], protecting protected: Set<String>) async throws {
        let targets = paths.map { AppPath.normalize($0) }.filter { $0 != "/" && !protected.contains($0) }
        guard !targets.isEmpty else { return }
        try check(await host.run("rm -rf -- " + targets.map(\.shellQuoted).joined(separator: " "), cwd: nil, stdin: nil))
    }

    /// Whether the guest can write zip archives (busybox only extracts them).
    func canCreateZip() async -> Bool {
        await host.run("command -v zip >/dev/null", cwd: nil, stdin: nil).succeeded
    }

    @discardableResult
    func compress(_ paths: [String], format: ArchiveFormat) async throws -> String {
        guard let first = paths.first else { throw LinuxHostError.invalidPath("") }
        let parent = AppPath.parent(of: first)
        let base = paths.count == 1 ? FileNaming.split(AppPath.lastComponent(first)).base.nonEmpty ?? "Archive" : "Archive"
        let taken = try await TransferNames(host: host).names(in: parent)
        let name = FileNaming.unique(base + "." + format.rawValue, existing: taken)
        let archive = AppPath.join(parent, name)
        let members = paths.map { AppPath.lastComponent($0).shellQuoted }.joined(separator: " ")
        let command: String
        switch format {
        case .tarGz: command = "tar -czf \(archive.shellQuoted) -- \(members)"
        case .zip: command = "zip -qr \(archive.shellQuoted) \(members)"
        }
        try check(await host.run(command, cwd: parent, stdin: nil))
        return archive
    }

    static func isArchive(_ name: String) -> Bool {
        extractCommand(archive: "a", into: "b", name: name) != nil
    }

    /// Extracts next to the archive into a folder named after it (so an archive without a
    /// top-level folder doesn't spill its files), as file-roller's "Extract Here" does.
    @discardableResult
    func extractHere(_ archive: String) async throws -> String {
        let parent = AppPath.parent(of: archive)
        let name = AppPath.lastComponent(archive)
        let taken = try await TransferNames(host: host).names(in: parent)
        let folder = AppPath.join(parent, FileNaming.unique(FileNaming.split(name).base.nonEmpty ?? "Extracted", existing: taken))
        guard let command = Self.extractCommand(archive: archive, into: folder, name: name) else {
            throw LinuxHostError.invalidPath(archive)
        }
        let result = await host.run("mkdir -p -- \(folder.shellQuoted) && \(command)", cwd: nil, stdin: nil)
        guard result.succeeded else {
            _ = await host.run("rm -rf -- \(folder.shellQuoted)", cwd: nil, stdin: nil)
            throw LinuxHostError.commandFailed(result)
        }
        return folder
    }

    static func extractCommand(archive: String, into folder: String, name: String) -> String? {
        let lower = name.lowercased()
        let flag: String
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { flag = "z" }
        else if lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz2") { flag = "j" }
        else if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz") { flag = "J" }
        else if lower.hasSuffix(".tar") { flag = "" }
        else if lower.hasSuffix(".zip") {
            return "unzip -oq \(archive.shellQuoted) -d \(folder.shellQuoted)"
        } else { return nil }
        return "tar -x\(flag)f \(archive.shellQuoted) -C \(folder.shellQuoted)"
    }

    func properties(of path: String) async throws -> Properties {
        let quoted = path.shellQuoted
        let result = try check(await host.run("""
            stat -c '%A|%a|%U|%G|%s|%X|%Y|%Z|%F' -- \(quoted) || exit 1
            if [ -d \(quoted) ] && [ ! -L \(quoted) ]; then
              printf 'items|%s\\n' "$(ls -A -- \(quoted) | wc -l)"
              printf 'du|%s\\n' "$(du -sk -- \(quoted) 2>/dev/null | cut -f1)"
            fi
            """, cwd: nil, stdin: nil))
        return try Self.parseProperties(result.stdout, path: path)
    }

    static func parseProperties(_ output: String, path: String) throws -> Properties {
        let lines = output.split(separator: "\n").map(String.init)
        guard let first = lines.first else { throw LinuxHostError.invalidPath(path) }
        let fields = first.split(separator: "|", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 9 else { throw LinuxHostError.invalidPath(path) }
        func date(_ value: String) -> Date? { TimeInterval(value).map { Date(timeIntervalSince1970: $0) } }
        var properties = Properties(
            path: path, kind: fields[8], permissions: fields[0], mode: Int(fields[1], radix: 8) ?? 0,
            owner: fields[2], group: fields[3], size: Int64(fields[4]) ?? 0,
            accessed: date(fields[5]), modified: date(fields[6]), changed: date(fields[7]))
        for line in lines.dropFirst() {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if parts[0] == "items" { properties.itemCount = Int(value) }
            if parts[0] == "du", let kilobytes = Int64(value) { properties.size = kilobytes * 1024 }
        }
        return properties
    }

    func setMode(_ mode: Int, of path: String) async throws {
        try check(await host.run("chmod \(String(mode, radix: 8)) -- \(path.shellQuoted)", cwd: nil, stdin: nil))
    }

    @discardableResult
    private func check(_ result: CommandResult) throws -> CommandResult {
        guard result.succeeded else { throw LinuxHostError.commandFailed(result) }
        return result
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
