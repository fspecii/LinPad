import Foundation

// MARK: - Paths

struct AppPathComponent: Identifiable, Hashable {
    let name: String
    let path: String
    var id: String { path }
}

/// Pure string manipulation of guest (Linux) paths; never touches the iOS file system.
enum AppPath {
    static func normalize(_ path: String, relativeTo base: String = "/") -> String {
        let absolute = path.hasPrefix("/") ? path : join(base, path)
        var parts: [Substring] = []
        for part in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                if !parts.isEmpty { parts.removeLast() }
            default:
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static func parent(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/", let slash = normalized.lastIndex(of: "/") else { return "/" }
        let parent = String(normalized[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    static func lastComponent(_ path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/" else { return "/" }
        return normalized.split(separator: "/").last.map(String.init) ?? "/"
    }

    static func pathExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    static func components(_ path: String) -> [AppPathComponent] {
        var result = [AppPathComponent(name: "/", path: "/")]
        var current = ""
        for part in normalize(path).split(separator: "/") {
            current += "/" + part
            result.append(AppPathComponent(name: String(part), path: current))
        }
        return result
    }

    /// A file name the user typed for a new or renamed item.
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}

// MARK: - Formatting

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func string(kilobytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: kilobytes * 1024, countStyle: .memory)
    }
}

extension CommandResult {
    var failureDescription: String {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { return message }
        let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty { return output }
        return "Command failed with exit status \(exitCode)."
    }
}

extension String {
    var trimmedWhitespace: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Splits combined command output on marker lines emitted with `echo MARKER`.
    func outputSections(separatedBy marker: String) -> [String] {
        components(separatedBy: marker + "\n").map { $0.trimmingCharacters(in: .newlines) }
    }
}

// MARK: - ps

struct ProcessRow: Identifiable, Hashable {
    var id: Int { pid }
    let pid: Int
    let ppid: Int?
    let user: String
    let memoryKB: Int64?
    let state: String
    let name: String
    let command: String
}

/// Parses `ps` output by its header, so it copes with busybox's `-o` columns,
/// busybox's default `PID USER TIME COMMAND` layout, and procps alike.
enum ProcessListParser {
    private static let textColumns: Set<String> = ["COMMAND", "COMM", "ARGS", "CMD"]

    static func parse(_ output: String) -> [ProcessRow] {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let headerIndex = lines.firstIndex(where: { line in
            line.split(whereSeparator: \.isWhitespace).contains { $0.uppercased() == "PID" }
        }) else { return [] }

        let header = lines[headerIndex].split(whereSeparator: \.isWhitespace).map { $0.uppercased() }
        let fixedCount = header.firstIndex(where: textColumns.contains) ?? header.count
        let textCount = header.count - fixedCount
        let maxSplits = textCount >= 2 ? fixedCount + 1 : fixedCount

        var rows: [ProcessRow] = []
        for line in lines[(headerIndex + 1)...] {
            let tokens = line
                .trimmingCharacters(in: .whitespaces)
                .split(maxSplits: maxSplits, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard tokens.count >= fixedCount else { continue }

            var fields: [String: String] = [:]
            for (index, column) in header.prefix(fixedCount).enumerated() {
                fields[column] = tokens[index]
            }
            guard let pid = fields["PID"].flatMap({ Int($0) }) else { continue }

            let textTokens = Array(tokens.dropFirst(fixedCount))
            let command: String
            let name: String
            if textCount >= 2, let comm = textTokens.first {
                name = comm
                command = textTokens.count > 1 ? textTokens[1] : comm
            } else {
                command = textTokens.first ?? ""
                let executable = command.split(separator: " ").first.map(String.init) ?? ""
                name = executable.hasPrefix("[") ? executable : AppPath.lastComponent(executable)
            }

            rows.append(ProcessRow(
                pid: pid,
                ppid: fields["PPID"].flatMap { Int($0) },
                user: fields["USER"] ?? fields["UID"] ?? "",
                memoryKB: (fields["VSZ"] ?? fields["RSS"]).flatMap(parseKilobytes),
                state: fields["STAT"] ?? fields["S"] ?? "",
                name: name,
                command: command))
        }
        return rows
    }

    /// busybox prints large VSZ values with a unit suffix ("1023m", "1.2g") instead of KiB.
    static func parseKilobytes(_ token: String) -> Int64? {
        let lower = token.lowercased()
        let multipliers: [Character: Double] = ["k": 1, "m": 1024, "g": 1024 * 1024, "t": 1024 * 1024 * 1024]
        if let last = lower.last, let multiplier = multipliers[last], let value = Double(lower.dropLast()) {
            return Int64(value * multiplier)
        }
        return Int64(lower)
    }
}

// MARK: - /proc

struct SystemLoad: Equatable {
    let one: Double
    let five: Double
    let fifteen: Double
    let tasks: String?
}

struct MemoryInfo: Equatable {
    let totalKB: Int64
    let availableKB: Int64

    var usedKB: Int64 { max(0, totalKB - availableKB) }
    var usedFraction: Double { totalKB > 0 ? Double(usedKB) / Double(totalKB) : 0 }
}

enum ProcFSParser {
    static func loadAverage(_ text: String) -> SystemLoad? {
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 3,
              let one = Double(fields[0]), let five = Double(fields[1]), let fifteen = Double(fields[2])
        else { return nil }
        return SystemLoad(one: one, five: five, fifteen: fifteen,
                          tasks: fields.count > 3 ? String(fields[3]) : nil)
    }

    static func memory(_ text: String) -> MemoryInfo? {
        var values: [String: Int64] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let number = parts[1].split(whereSeparator: \.isWhitespace).first.flatMap { Int64($0) }
            if let number { values[String(parts[0])] = number }
        }
        guard let total = values["MemTotal"], total > 0 else { return nil }
        // Older kernels (and iSH's emulated /proc) may lack MemAvailable.
        let available = values["MemAvailable"]
            ?? (values["MemFree"] ?? 0) + (values["Buffers"] ?? 0) + (values["Cached"] ?? 0)
        return MemoryInfo(totalKB: total, availableKB: min(available, total))
    }
}

// MARK: - apk

struct APKPackage: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let version: String
    let summary: String
}

enum APKParser {
    /// Parses `apk search -v` / `apk info -vv` lines ("name-1.2.3-r0 - description"),
    /// plus bare "name-version" and `apk list` lines as a fallback.
    static func parse(_ output: String) -> [APKPackage] {
        var seen = Set<String>()
        var packages: [APKPackage] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("WARNING"), !line.hasPrefix("ERROR"),
                  !line.hasPrefix("fetch ") else { continue }

            let nameVersion: String
            let summary: String
            if let separator = line.range(of: " - ") {
                nameVersion = String(line[..<separator.lowerBound])
                summary = String(line[separator.upperBound...])
            } else {
                nameVersion = line.split(separator: " ").first.map(String.init) ?? line
                summary = ""
            }
            guard !nameVersion.contains(" "), let split = splitNameVersion(nameVersion),
                  seen.insert(split.name).inserted else { continue }
            packages.append(APKPackage(name: split.name, version: split.version, summary: summary))
        }
        return packages
    }

    /// "py3-pip-24.3.1-r0" -> ("py3-pip", "24.3.1-r0"). Alpine versions are
    /// `<digits...>-r<N>`, and names may themselves contain dashes and digits.
    static func splitNameVersion(_ value: String) -> (name: String, version: String)? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let isRelease = { (part: String) in
            part.count > 1 && part.first == "r" && part.dropFirst().allSatisfy(\.isNumber)
        }
        if parts.count >= 3, isRelease(parts[parts.count - 1]), parts[parts.count - 2].first?.isNumber == true {
            return (parts.dropLast(2).joined(separator: "-"),
                    parts.suffix(2).joined(separator: "-"))
        }
        if let index = parts.indices.dropFirst().last(where: { parts[$0].first?.isNumber == true }) {
            return (parts[..<index].joined(separator: "-"), parts[index...].joined(separator: "-"))
        }
        return (value, "")
    }
}
