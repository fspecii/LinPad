import Foundation

// MARK: - Manifest

/// What a LinPad backup holds, stored as the first member ("manifest.json") of the backup
/// file so Restore can show it without unpacking anything.
struct BackupManifest: Codable, Equatable {
    static let currentFormat = 1
    static let memberName = "manifest.json"

    enum Compression: String, Codable, CaseIterable {
        case zstd
        case gzip

        var payloadName: String { self == .zstd ? "linux.tar.zst" : "linux.tar.gz" }
    }

    var format = BackupManifest.currentFormat
    var createdAt: Date
    var appVersion: String
    var appBuild: String
    var rootfsVersion: String?
    var repairKitVersion: String?
    /// Guest directories in the archive (always "/root" and "/home" so far).
    var paths: [String] = ["/root", "/home"]
    var excludedCategories: [BackupExclusionCategory]
    var compression: Compression
    /// Size of what was archived (du), before compression.
    var contentBytes: Int64
    var fileCount: Int
    /// The apk world (packages added on purpose), reinstalled on restore when missing.
    var packages: [String]
    /// linpad-apps catalog packs that were installed (they may not be apk packages).
    var appPacks: [String]
    /// Guest mount points of the iPad folders added in Files. Not in the archive (their files
    /// stay on the iPad); listed so the user knows which to add again.
    var iPadFolders: [String]
    /// Desktop files under Application Support in the archive (wallpapers, calendar).
    var desktopFiles: [String]
    var hasDesktopSettings: Bool
    var automatic = false

    enum Problem: Error, Equatable, LocalizedError {
        case newerFormat(Int)
        case unsafeValue(String)

        var errorDescription: String? {
            switch self {
            case .newerFormat:
                return "This backup was made by a newer version of LinPad. Update LinPad to restore it."
            case .unsafeValue(let value):
                return "The backup's description is damaged (\(value))."
            }
        }
    }

    static func decode(_ data: Data) throws -> BackupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Package names and pack ids reach the guest's shell on restore; paths are written
    /// under Application Support.
    func validate() throws {
        guard format <= Self.currentFormat, format >= 1 else { throw Problem.newerFormat(format) }
        for path in paths where !["/root", "/home"].contains(path) { throw Problem.unsafeValue(path) }
        for package in packages where !Self.isSafePackage(package) { throw Problem.unsafeValue(package) }
        for pack in appPacks where !Self.isSafePackage(pack) { throw Problem.unsafeValue(pack) }
        for file in desktopFiles where !Self.isSafeRelativeFile(file) { throw Problem.unsafeValue(file) }
        guard contentBytes >= 0, fileCount >= 0 else { throw Problem.unsafeValue("size") }
    }

    /// apk world entries ("firefox-esr", "mesa-gl=26.2.3-r1", "so:libc.musl-aarch64.so.1")
    /// and linpad-apps ids ("vscode", "apk:gimp").
    static func isSafePackage(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 200, !name.hasPrefix("-") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._+-=<>~:@"))
        return name.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    static func isSafeRelativeFile(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }
}

// MARK: - Exclusions

/// Parts of /root and /home that a backup leaves out by default: they are rebuilt on use.
enum BackupExclusionCategory: String, Codable, CaseIterable, Identifiable {
    /// ~/.cache (Firefox's cache2, thumbnails, pip, fontconfig…), npm's cache.
    case caches
    /// VS Code's caches and logs (~/.config/Code/Cache, CachedData, GPUCache, logs…).
    case editorCaches = "editor-caches"
    /// node_modules folders anywhere; `npm install` brings them back.
    case nodeModules = "node-modules"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .caches: return "Caches"
        case .editorCaches: return "VS Code caches and logs"
        case .nodeModules: return "node_modules folders"
        }
    }

    var detail: String {
        switch self {
        case .caches: return "~/.cache (Firefox's web cache, thumbnails) and npm's download cache. Rebuilt automatically."
        case .editorCaches: return "Code caches, GPU caches and logs in ~/.config/Code. Rebuilt when VS Code starts."
        case .nodeModules: return "Installed JavaScript dependencies. Run npm install in a project to get them back."
        }
    }

    static let defaultExcluded: Set<BackupExclusionCategory> = Set(allCases)

    private static let editorDirectories: Set<String> = ["Code", "Code - OSS", "VSCodium", "code-oss"]
    private static let editorCacheNames: Set<String> = [
        "Cache", "CachedData", "Code Cache", "GPUCache", "CachedExtensionVSIXs", "CachedProfilesData",
        "logs", "DawnGraphiteCache", "DawnWebGPUCache", "Crashpad",
    ]

    /// The category of a path relative to "/" ("root/.cache", "home/ana/p/node_modules"),
    /// or nil when it is user data. Only whole directories match, never their children.
    static func category(of path: String) -> BackupExclusionCategory? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let homeDepth: Int
        switch parts.first {
        case "root": homeDepth = 1
        case "home": homeDepth = 2
        default: return nil
        }
        guard parts.count > homeDepth else { return nil }
        let inHome = Array(parts.dropFirst(homeDepth))
        if inHome.last == "node_modules" { return .nodeModules }
        switch inHome.count {
        case 1:
            return inHome[0] == ".cache" ? .caches : nil
        case 2:
            return inHome == [".npm", "_cacache"] ? .caches : nil
        case 3:
            if inHome[0] == ".config", editorDirectories.contains(inHome[1]), editorCacheNames.contains(inHome[2]) {
                return .editorCaches
            }
            return nil
        case 4:
            if inHome[0] == ".mozilla", inHome[1] == "firefox", ["cache2", "startupCache"].contains(inHome[3]) {
                return .caches
            }
            return nil
        default:
            return nil
        }
    }

    /// find(1) primaries that list every candidate directory for the guest's `scan` (a
    /// superset; `category(of:)` decides).
    static let scanPrimaries: [String] = [
        "name:.cache", "name:node_modules", "path:*/.npm/_cacache",
        "path:*/.mozilla/firefox/*/cache2", "path:*/.mozilla/firefox/*/startupCache",
    ] + editorDirectories.sorted().flatMap { directory in
        editorCacheNames.sorted().map { "path:*/.config/\(directory)/\($0)" }
    }
}

/// The paths a backup leaves out, as patterns for the guest's find -path (one per line in
/// WORK/excludes): literal paths with fnmatch's special characters escaped.
enum BackupExclusionList {
    static func fnmatchEscaped(_ path: String) -> String {
        var escaped = ""
        for character in path {
            if "*?[]\\".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// "/root/iPad" → "root/iPad"; nil for anything outside /root and /home.
    static func relativeGuestPath(_ absolute: String) -> String? {
        let trimmed = absolute.hasPrefix("/") ? String(absolute.dropFirst()) : absolute
        let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard normalized == "root" || normalized == "home" || normalized.hasPrefix("root/") || normalized.hasPrefix("home/") else {
            return nil
        }
        return normalized
    }

    static func lines(candidates: [BackupScan.Candidate], excluding categories: Set<BackupExclusionCategory>,
                      mountPoints: [String]) -> [String] {
        var paths = candidates.filter { categories.contains($0.category) }.map(\.path)
        paths += mountPoints.compactMap(relativeGuestPath).filter { $0 != "root" && $0 != "home" }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }.sorted().map(fnmatchEscaped)
    }
}

/// What the guest's `scan` found: the size of /root and /home and of each excludable folder.
struct BackupScan: Equatable {
    struct Candidate: Equatable {
        let path: String
        let kilobytes: Int64
        let category: BackupExclusionCategory
    }

    var totalKilobytes: Int64 = 0
    var candidates: [Candidate] = []

    static func parse(_ output: String) -> BackupScan {
        var scan = BackupScan()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("@@total ") {
                scan.totalKilobytes = Int64(line.dropFirst("@@total ".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("@@candidate ") {
                let body = line.dropFirst("@@candidate ".count)
                guard let tab = body.firstIndex(of: "\t"), let size = Int64(body[..<tab]) else { continue }
                let path = String(body[body.index(after: tab)...])
                guard let category = BackupExclusionCategory.category(of: path) else { continue }
                scan.candidates.append(Candidate(path: path, kilobytes: size, category: category))
            }
        }
        return scan
    }

    func kilobytes(of category: BackupExclusionCategory) -> Int64 {
        candidates.filter { $0.category == category }.reduce(0) { $0 + $1.kilobytes }
    }

    /// What a backup with these categories left out holds, in bytes (before compression).
    func includedBytes(excluding categories: Set<BackupExclusionCategory>) -> Int64 {
        let excluded = categories.reduce(Int64(0)) { $0 + kilobytes(of: $1) }
        return max(0, totalKilobytes - excluded) * 1024
    }
}

// MARK: - Facts for the manifest

/// The guest's `facts` output.
struct BackupGuestFacts: Equatable {
    var rootfsVersion: String?
    var repairKitVersion: String?
    var hasZstd = false
    var world: [String] = []
    var installedPacks: [String] = []

    static func parse(_ output: String) -> BackupGuestFacts {
        var facts = BackupGuestFacts()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            func value(_ prefix: String) -> String? {
                guard line.hasPrefix(prefix) else { return nil }
                let text = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : text
            }
            if line.hasPrefix("@@rootfs") { facts.rootfsVersion = value("@@rootfs") }
            else if line.hasPrefix("@@kit") { facts.repairKitVersion = value("@@kit") }
            else if line.hasPrefix("@@zstd") { facts.hasZstd = value("@@zstd") == "yes" }
            else if let package = value("@@world "), BackupManifest.isSafePackage(package) { facts.world.append(package) }
            else if let json = value("@@state "), let data = json.data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let packs = object["packs"] as? [String: Bool] {
                facts.installedPacks = packs.filter { $0.value && BackupManifest.isSafePackage($0.key) }.map(\.key).sorted()
            }
        }
        return facts
    }
}

// MARK: - Restore plan

enum BackupRestoreMode: String, CaseIterable, Identifiable {
    /// Unpack over the current files: files in the backup replace the same files, others stay.
    case merge
    /// /root and /home become exactly the backup; the current ones are moved aside, not deleted.
    case replace

    var id: String { rawValue }
}

enum BackupReinstallPlan {
    /// World entries in the backup that the current system lacks. Version pins are compared
    /// by name, so "mesa-gl=26.2.3-r1" is not reinstalled over "mesa-gl=26.2.4-r0".
    static func missingPackages(backup: [String], current: [String]) -> [String] {
        let installed = Set(current.map(packageName))
        var seen = Set<String>()
        return backup.filter { !installed.contains(packageName($0)) && seen.insert(packageName($0)).inserted }
    }

    static func missingPacks(backup: [String], current: [String]) -> [String] {
        let installed = Set(current)
        return backup.filter { !installed.contains($0) }
    }

    static func packageName(_ entry: String) -> String {
        String(entry.prefix { !"=<>~".contains($0) })
    }
}

// MARK: - Files and schedule

enum BackupSchedule: String, CaseIterable, Identifiable {
    case off
    case daily
    case weekly

    var id: String { rawValue }

    var interval: TimeInterval? {
        switch self {
        case .off: return nil
        case .daily: return 24 * 3600
        case .weekly: return 7 * 24 * 3600
        }
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }

    /// Due when the last backup (any, manual or automatic) is older than the interval, with
    /// an hour of slack so a daily backup does not creep later each day.
    func isDue(lastBackup: Date?, now: Date) -> Bool {
        guard let interval else { return false }
        guard let lastBackup else { return true }
        return now.timeIntervalSince(lastBackup) >= interval - 3600
    }
}

/// Names, listing and rotation of the backups in Documents/Backups.
enum BackupFiles {
    static let directoryName = "Backups"
    static let prefix = "linpad-backup-"
    static let automaticMarker = "auto-"
    static let fileExtension = "tar"

    static func fileName(for date: Date, automatic: Bool, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return prefix + (automatic ? automaticMarker : "") + formatter.string(from: date) + "." + fileExtension
    }

    static func isBackup(_ name: String) -> Bool {
        name.hasPrefix(prefix) && name.hasSuffix("." + fileExtension)
    }

    static func isAutomatic(_ name: String) -> Bool {
        name.hasPrefix(prefix + automaticMarker)
    }

    /// The automatic backups beyond the newest `keep`, oldest first. Manual ones are never
    /// rotated away.
    static func automaticBackupsToDelete(_ names: [String], keep: Int) -> [String] {
        let automatic = names.filter { isBackup($0) && isAutomatic($0) }.sorted(by: >)
        return Array(automatic.dropFirst(max(1, keep)).reversed())
    }
}
