import CryptoKit
import Foundation

/// The guest repair kit the app bundles (release/build-repair-kit.sh): `repair-kit.tar`
/// holds the system files that ship with LinPad and `guest/linpad-repair`, which puts them
/// back; `repair-kit.json` describes it.
struct RepairKitManifest: Decodable, Equatable {
    static let supportedFormat = 1

    let format: Int
    /// yyyymmddNN, release/guest/repair-kit-version.
    let version: String
    /// The script to run, relative to the unpacked kit.
    let entry: String
    let archiveSHA256: String
    let archiveSize: Int64
    let files: [String]

    enum Problem: Error, Equatable, LocalizedError {
        case unsupportedFormat(Int)
        case badVersion(String)
        case badChecksum
        case unsafePath(String)
        case missingEntry(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let format): return "The repair kit has an unknown format (\(format))."
            case .badVersion(let version): return "The repair kit's version is not a number: \(version)."
            case .badChecksum: return "The repair kit's checksum is malformed."
            case .unsafePath(let path): return "The repair kit lists an unsafe path: \(path)."
            case .missingEntry(let entry): return "The repair kit does not contain \(entry)."
            }
        }
    }

    static func decode(_ data: Data) throws -> RepairKitManifest {
        let manifest = try JSONDecoder().decode(RepairKitManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    func validate() throws {
        guard format == Self.supportedFormat else { throw Problem.unsupportedFormat(format) }
        guard RepairKitVersion.number(version) != nil else { throw Problem.badVersion(version) }
        guard archiveSHA256.count == 64, archiveSHA256.allSatisfy(\.isHexDigit) else { throw Problem.badChecksum }
        for path in files + [entry] where !Self.isSafeRelativePath(path) {
            throw Problem.unsafePath(path)
        }
        guard files.contains(entry) else { throw Problem.missingEntry(entry) }
    }

    /// The entry is passed to the guest's shell, and every file is unpacked under one
    /// directory: no absolute paths, no "..", nothing a shell would expand.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-+/"))
        guard path.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
    }
}

/// Repair kit versions are yyyymmddNN numbers, compared numerically.
enum RepairKitVersion {
    static func number(_ text: String?) -> UInt64? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.allSatisfy(\.isASCIIDigit) else { return nil }
        return UInt64(text)
    }

    /// Whether the bundled kit should be applied over what the guest has. A guest without a
    /// stamp (systems built before the kit existed) or with an unreadable one gets it.
    static func isNewer(_ bundled: String, than installed: String?) -> Bool {
        guard let bundled = number(bundled) else { return false }
        guard let installed = number(installed) else { return true }
        return bundled > installed
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

struct RepairKit {
    static let archiveName = "repair-kit.tar"
    static let manifestName = "repair-kit.json"
    /// Where the guest learns which kit it last applied (linpad-repair writes it).
    static let installedVersionPath = "/usr/share/ish/repair-kit-version"

    let manifest: RepairKitManifest
    let archive: URL

    enum LoadError: Error, LocalizedError {
        case damaged

        var errorDescription: String? {
            "The repair kit inside the app is damaged (size or SHA-256 does not match). Reinstall LinPad."
        }
    }

    /// The kit in the app bundle, or nil for builds without one (the desktop harness).
    static func bundled(in bundle: Bundle = .main) -> RepairKit? {
        guard let directory = bundle.resourceURL else { return nil }
        return try? load(directory: directory)
    }

    static func load(directory: URL) throws -> RepairKit {
        let manifest = try RepairKitManifest.decode(Data(contentsOf: directory.appendingPathComponent(manifestName)))
        return RepairKit(manifest: manifest, archive: directory.appendingPathComponent(archiveName))
    }

    /// The archive's bytes, checked against the manifest.
    func verifiedArchive() throws -> Data {
        let data = try Data(contentsOf: archive)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard Int64(data.count) == manifest.archiveSize, digest == manifest.archiveSHA256.lowercased() else {
            throw LoadError.damaged
        }
        return data
    }
}

/// What linpad-repair reported, parsed from its "@@" lines (release/guest/linpad-repair).
struct RepairReport: Equatable {
    var steps: [String] = []
    var notes: [String] = []
    var failures: [String] = []
    var skippedOffline: [String] = []
    var installedPackages: [String] = []
    var changes = 0
    /// nil until the script's last line arrived.
    var succeeded: Bool?

    var currentStep: String? { steps.last }

    /// Returns true when the line was a report line (and not plain log output).
    @discardableResult
    mutating func consume(_ line: String) -> Bool {
        guard line.hasPrefix("@@") else { return false }
        let body = line.dropFirst(2)
        let keyword = body.prefix { $0 != " " }
        let value = body.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
        switch keyword {
        case "step": steps.append(value)
        case "note": notes.append(value)
        case "fail": failures.append(value)
        case "skipped-packages-offline": skippedOffline += value.split(separator: " ").map(String.init)
        case "installed-packages": installedPackages += value.split(separator: " ").map(String.init)
        case "result":
            let fields = value.split(separator: " ")
            succeeded = fields.first == "ok"
            if let changed = fields.first(where: { $0.hasPrefix("changed=") }) {
                changes = Int(changed.dropFirst("changed=".count)) ?? changes
            }
        default: return false
        }
        return true
    }

    /// One or two sentences for the end of a repair.
    var summary: String {
        var parts: [String] = []
        if succeeded == true {
            parts.append(changes == 0 ? "Everything was already in order; nothing needed fixing."
                                      : "Repaired \(changes) item\(changes == 1 ? "" : "s").")
        } else {
            parts.append(failures.isEmpty ? "The repair did not finish." : "The repair hit \(failures.count) problem\(failures.count == 1 ? "" : "s").")
        }
        if !installedPackages.isEmpty {
            parts.append("Reinstalled \(installedPackages.joined(separator: ", ")).")
        }
        if !skippedOffline.isEmpty {
            parts.append("Skipped packages (offline): \(skippedOffline.joined(separator: ", ")). Repair again when online to install them.")
        }
        return parts.joined(separator: " ")
    }
}

/// Splits streamed output into whole lines; the last partial line waits for its newline.
struct LineSplitter {
    private var pending = ""

    mutating func feed(_ chunk: String) -> [String] {
        pending += chunk
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()
        return lines
    }

    mutating func finish() -> [String] {
        defer { pending = "" }
        return pending.isEmpty ? [] : [pending]
    }
}
