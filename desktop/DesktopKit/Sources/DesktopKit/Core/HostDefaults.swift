import Foundation

public extension String {
    /// The string as a single POSIX shell word, safe to splice into `run` commands.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Default file operations built only on `run`, so a host only has to provide a shell.
/// Every command is restricted to what Alpine's busybox applets accept.
public extension LinuxHost {
    func listDirectory(_ path: String) async throws -> [FileEntry] {
        try HostPathRules.validate(path)
        let result = await run(BusyboxDirectoryListing.command(for: path), cwd: nil, stdin: nil)
        guard result.succeeded else { throw LinuxHostError.commandFailed(result) }
        return BusyboxDirectoryListing.parse(result.stdout, directory: path)
    }

    func readFile(_ path: String) async throws -> Data {
        try HostPathRules.validate(path)
        let result = await run("base64 \(path.shellQuoted)", cwd: nil, stdin: nil)
        guard result.succeeded else { throw LinuxHostError.commandFailed(result) }
        guard let data = Data(base64Encoded: result.stdout, options: .ignoreUnknownCharacters) else {
            throw LinuxHostError.commandFailed(CommandResult(
                stdout: "", stderr: "Could not decode \(path)", exitCode: 1))
        }
        return data
    }

    func writeFile(_ path: String, data: Data) async throws {
        try HostPathRules.validate(path)
        let result = await run("cat > \(path.shellQuoted)", cwd: nil, stdin: data)
        guard result.succeeded else { throw LinuxHostError.commandFailed(result) }
    }

    func stream(_ command: String, cwd: String?,
                onOutput: @escaping @MainActor (String) -> Void) async -> Int32 {
        let result = await run(command, cwd: cwd, stdin: nil)
        let output = result.stdout + result.stderr
        if !output.isEmpty {
            onOutput(output)
        }
        return result.exitCode
    }
}

enum HostPathRules {
    static func validate(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw LinuxHostError.invalidPath(path)
        }
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}

/// Lists a directory with two `stat` passes in one shell round trip: the first describes the
/// entries themselves (so symlinks are reported as links), the second follows links so a
/// link to a directory is still browsable. Names come last on each line, so any character
/// except a newline survives the split.
enum BusyboxDirectoryListing {
    static let followedLinksMarker = "--desktopkit-followed--"

    static func command(for path: String) -> String {
        let globs = ".[!.]* ..?* *"
        return """
        cd -- \(path.shellQuoted) || exit 2
        stat -c '%A|%s|%Y|%n' -- \(globs) 2>/dev/null
        echo '\(followedLinksMarker)'
        stat -L -c '%F|%n' -- \(globs) 2>/dev/null
        exit 0
        """
    }

    static func parse(_ output: String, directory: String) -> [FileEntry] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        let markerIndex = lines.firstIndex { $0 == followedLinksMarker } ?? lines.endIndex
        let followedDirectories = Set(lines[markerIndex...].dropFirst().compactMap { line -> Substring? in
            let fields = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0] == "directory" else { return nil }
            return fields[1]
        })

        return lines[..<markerIndex].compactMap { line in
            let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, let kind = fields[0].first else { return nil }
            let name = String(fields[3])
            guard name != "." && name != ".." else { return nil }
            let isSymlink = kind == "l"
            return FileEntry(
                path: HostPathRules.join(directory, name),
                name: name,
                isDirectory: kind == "d" || (isSymlink && followedDirectories.contains(fields[3])),
                isSymlink: isSymlink,
                size: Int64(fields[1]) ?? 0,
                modified: TimeInterval(fields[2]).map { Date(timeIntervalSince1970: $0) },
                permissions: String(fields[0]))
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
