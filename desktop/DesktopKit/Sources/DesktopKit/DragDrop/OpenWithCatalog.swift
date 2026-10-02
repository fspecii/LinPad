import Foundation
import Observation

/// "Open With": which Linux applications (by their .desktop `MimeType=`) and which native
/// apps can open a file, with MIME types from the guest's shared-mime-info glob table.
@Observable @MainActor
final class OpenWithCatalog {
    struct Application: Identifiable, Equatable {
        let id: String          // desktop id, or the native app id
        let name: String
        let exec: String        // with field codes, for Linux apps
        let mimeTypes: [String]
        let isNative: Bool
        let symbol: String
    }

    static let shared = OpenWithCatalog()

    private(set) var linuxApplications: [Application] = []
    @ObservationIgnored private var globs: [String: String] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private static let applicationsDirectory = "/usr/share/applications"
    private static let globsFile = "/usr/share/mime/globs2"

    func loadIfNeeded(host: any LinuxHost) {
        guard loadTask == nil else { return }
        loadTask = Task {
            // Off the launch path: the guest is busiest while the session starts.
            try? await Task.sleep(for: .seconds(10))
            let entries = await host.run("""
                for f in \(Self.applicationsDirectory)/*.desktop; do [ -f "$f" ] || continue
                  printf '[[file %s]]\\n' "${f##*/}"
                  sed -n '/^\\[Desktop Entry\\]/,/^\\[/p' "$f" | grep -E '^(Name|Exec|MimeType|NoDisplay|Hidden|Type|Terminal)='
                done
                """, cwd: nil, stdin: nil)
            linuxApplications = Self.parseApplications(entries.stdout)
            let table = await host.run("cat \(Self.globsFile) 2>/dev/null", cwd: nil, stdin: nil)
            globs = Self.parseGlobs(table.stdout)
        }
    }

    func mimeType(for name: String, isDirectory: Bool) -> String {
        if isDirectory { return "inode/directory" }
        let lower = name.lowercased()
        // Longest suffix first, so "x.tar.gz" is a tarball rather than plain gzip.
        var index = lower.firstIndex(of: ".")
        while let dot = index {
            if let mime = globs["*" + lower[dot...]] { return mime }
            index = lower[lower.index(after: dot)...].firstIndex(of: ".")
        }
        return Self.fallbackMimeTypes[AppPath.pathExtension(name)] ?? "application/octet-stream"
    }

    /// Linux apps for the file, exact MIME matches first, then apps for the general kind
    /// ("text/plain" editors for any text/*), never NoDisplay helpers.
    func linuxApplications(for mime: String) -> [Application] {
        let exact = linuxApplications.filter { $0.mimeTypes.contains(mime) }
        let family = mime.split(separator: "/").first.map(String.init) ?? ""
        let generic: [Application]
        if family == "text" || Self.textLike.contains(mime) {
            generic = linuxApplications.filter { $0.mimeTypes.contains("text/plain") }
        } else {
            generic = linuxApplications.filter { app in app.mimeTypes.contains { $0 == family + "/*" } }
        }
        var seen = Set<String>()
        return (exact + generic).filter { seen.insert($0.id).inserted }
    }

    enum DefaultOpen: Equatable {
        case editor
        case linux(Application)
        case quickLook
    }

    /// Text goes to the Text Editor; other kinds to the first Linux app registered for
    /// them, falling back to Quick Look for media, then the editor.
    func defaultOpen(for name: String) -> DefaultOpen {
        let mime = mimeType(for: name, isDirectory: false)
        if Self.isText(mime: mime) { return .editor }
        if let app = linuxApplications(for: mime).first { return .linux(app) }
        if mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime == "application/pdf" {
            return .quickLook
        }
        return .editor
    }

    static func isText(mime: String) -> Bool {
        mime.hasPrefix("text/") || textLike.contains(mime) || mime == "application/octet-stream"
    }

    /// The command that opens `path` with an app, from its Exec line (Desktop Entry spec
    /// field codes; %u gets a plain path, which every GTK and Qt app accepts).
    static func command(exec: String, path: String) -> String {
        var parts: [String] = []
        var substituted = false
        for token in exec.split(separator: " ") {
            switch token {
            case "%f", "%F", "%u", "%U":
                parts.append(path.shellQuoted)
                substituted = true
            case "%i", "%c", "%k", "%d", "%D", "%n", "%N", "%v", "%m":
                continue
            default:
                parts.append(token.replacingOccurrences(of: "%%", with: "%"))
            }
        }
        if !substituted { parts.append(path.shellQuoted) }
        return parts.joined(separator: " ")
    }

    // MARK: - Parsing

    static func parseApplications(_ output: String) -> [Application] {
        var result: [Application] = []
        var file: String?
        var fields: [String: String] = [:]
        func flush() {
            defer { fields = [:] }
            guard let file, fields["Type"] == "Application", fields["NoDisplay"] != "true",
                  fields["Hidden"] != "true", fields["Terminal"] != "true",
                  let name = fields["Name"], let exec = fields["Exec"], !exec.isEmpty else { return }
            let mimes = (fields["MimeType"] ?? "").split(separator: ";").map(String.init)
            guard !mimes.isEmpty else { return }
            let id = file.hasSuffix(".desktop") ? String(file.dropLast(8)) : file
            result.append(Application(id: id, name: name, exec: exec, mimeTypes: mimes, isNative: false, symbol: "app"))
        }
        for line in output.split(separator: "\n") {
            if line.hasPrefix("[[file "), line.hasSuffix("]]") {
                flush()
                file = String(line.dropFirst(7).dropLast(2))
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            if fields[key] == nil { fields[key] = String(line[line.index(after: equals)...]) }
        }
        flush()
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// globs2 lines are "weight:mime:glob[:flags]"; the highest weight wins per glob.
    static func parseGlobs(_ output: String) -> [String: String] {
        var best: [String: (Int, String)] = [:]
        for line in output.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count >= 3, let weight = Int(parts[0]) else { continue }
            let glob = parts[2].lowercased()
            guard glob.hasPrefix("*."), !glob.dropFirst(2).contains(where: { "*?[".contains($0) }) else { continue }
            if (best[glob]?.0 ?? -1) < weight { best[glob] = (weight, String(parts[1])) }
        }
        return best.mapValues(\.1)
    }

    private static let textLike: Set<String> = [
        "application/json", "application/xml", "application/javascript", "application/x-shellscript",
        "application/x-yaml", "application/toml", "application/x-desktop", "application/x-perl",
        "application/x-ruby", "application/sql",
    ]

    /// Used before globs2 has loaded or when shared-mime-info is missing.
    private static let fallbackMimeTypes: [String: String] = [
        "txt": "text/plain", "md": "text/markdown", "log": "text/plain", "c": "text/x-csrc",
        "h": "text/x-chdr", "py": "text/x-python", "sh": "application/x-shellscript",
        "js": "application/javascript", "json": "application/json", "html": "text/html",
        "htm": "text/html", "css": "text/css", "xml": "application/xml", "png": "image/png",
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml",
        "webp": "image/webp", "pdf": "application/pdf", "mp3": "audio/mpeg", "mp4": "video/mp4",
        "mkv": "video/x-matroska", "zip": "application/zip", "gz": "application/gzip",
        "tar": "application/x-tar",
    ]
}
