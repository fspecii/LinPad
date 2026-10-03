import Foundation

/// What `linpad-apps` reports while it works, parsed from its streamed output:
///   "==> @phase ID NAME", "==> @progress ID DONE TOTAL UNIT", "==> text",
///   and apk's own "(3/45) Installing name (version)" lines.
enum StoreEvent: Equatable {
    case phase(id: String, name: String)
    case progress(id: String, done: Int64, total: Int64, unit: String)
    case step(index: Int, count: Int, verb: String, package: String)
    case message(String)
    case log(String)
}

/// Splits streamed chunks into lines (a chunk can end mid-line) and parses them.
struct StoreOutputParser {
    private var pending = ""

    mutating func consume(_ chunk: String) -> [StoreEvent] {
        pending += chunk
        var events: [StoreEvent] = []
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline]).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            pending.removeSubrange(...newline)
            if let event = Self.parse(line) { events.append(event) }
        }
        return events
    }

    mutating func finish() -> [StoreEvent] {
        defer { pending = "" }
        return pending.isEmpty ? [] : Self.parse(pending).map { [$0] } ?? []
    }

    static func parse(_ line: String) -> StoreEvent? {
        guard !line.isEmpty else { return nil }
        if line.hasPrefix("==> @") {
            let fields = line.dropFirst(5).split(separator: " ").map(String.init)
            switch fields.first {
            case "phase" where fields.count >= 3:
                return .phase(id: fields[1], name: fields[2])
            case "progress" where fields.count >= 5:
                return .progress(id: fields[1], done: Int64(fields[2]) ?? 0, total: Int64(fields[3]) ?? 0, unit: fields[4])
            default:
                return .log(line)
            }
        }
        if line.hasPrefix("==> ") { return .message(String(line.dropFirst(4))) }
        if line.hasPrefix("("), let close = line.firstIndex(of: ")") {
            let counts = line[line.index(after: line.startIndex)..<close].split(separator: "/")
            let rest = line[line.index(after: close)...].split(separator: " ")
            if counts.count == 2, let index = Int(counts[0]), let count = Int(counts[1]), rest.count >= 2 {
                return .step(index: index, count: count, verb: String(rest[0]), package: String(rest[1]))
            }
        }
        return .log(line)
    }
}

enum StoreJobKind: Equatable {
    case install, remove, update

    var verb: String {
        switch self {
        case .install: "install"
        case .remove: "remove"
        case .update: "upgrade"
        }
    }
}

enum StorePhase: Equatable {
    case queued
    case resolving
    case downloading(done: Int64, total: Int64)
    case installing(step: Int, of: Int)
    case configuring
    case removing
    case finished
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .finished, .failed, .cancelled: false
        default: true
        }
    }

    /// Downloads can be stopped; once apk is changing the system it has to finish.
    var isCancellable: Bool {
        switch self {
        case .queued, .resolving, .downloading: true
        default: false
        }
    }
}

/// One install, removal or update in the Store's queue: a small state machine fed by
/// `StoreEvent`s.
struct StoreJob: Identifiable, Equatable {
    let id: String
    let appIDs: [String]
    let kind: StoreJobKind
    let title: String
    var phase: StorePhase = .queued
    var message = ""
    var cancelRequested = false

    init(appIDs: [String], kind: StoreJobKind, title: String) {
        self.id = kind.verb + ":" + (appIDs.isEmpty ? "all" : appIDs.joined(separator: ","))
        self.appIDs = appIDs
        self.kind = kind
        self.title = title
        self.phase = .queued
    }

    mutating func apply(_ event: StoreEvent) {
        switch event {
        case .phase(_, let name):
            switch name {
            case "resolving": phase = .resolving
            case "downloading": phase = .downloading(done: 0, total: 0)
            case "installing": phase = .installing(step: 0, of: 0)
            case "configuring": phase = .configuring
            case "removing": phase = .removing
            case "cancelled": phase = .cancelled
            case "failed": phase = .failed(message.isEmpty ? "The install failed" : message)
            default: break
            }
        case .progress(_, let done, let total, let unit) where unit == "bytes":
            if case .resolving = phase { phase = .downloading(done: done, total: total) }
            if case .downloading = phase { phase = .downloading(done: done, total: total) }
        case .step(let index, let count, let verb, let package):
            if case .configuring = phase { break }
            phase = .installing(step: index, of: count)
            message = "\(verb) \(package)"
        case .message(let text):
            message = text
        default:
            break
        }
    }

    /// The job ended with `exitCode`; anything not already final becomes finished or failed.
    mutating func finish(exitCode: Int32) {
        switch phase {
        case .cancelled:
            return
        case .failed:
            return
        default:
            if cancelRequested && exitCode != 0 { phase = .cancelled }
            else { phase = exitCode == 0 ? .finished : .failed(message.isEmpty ? "linpad-apps exited with status \(exitCode)" : message) }
        }
    }

    /// 0...1 when the job's progress is known; downloads weigh 70 %, apk's install steps 25 %.
    var fraction: Double? {
        switch phase {
        case .queued: return nil
        case .resolving: return 0.02
        case .downloading(let done, let total):
            return total > 0 ? 0.02 + 0.68 * min(1, Double(done) / Double(total)) : 0.02
        case .installing(let step, let count):
            return count > 0 ? 0.70 + 0.25 * Double(step) / Double(count) : (kind == .install ? 0.70 : nil)
        case .configuring: return 0.96
        case .removing: return nil
        case .finished: return 1
        case .failed, .cancelled: return nil
        }
    }

    var statusText: String {
        switch phase {
        case .queued: return "Waiting…"
        case .resolving: return "Checking what is needed…"
        case .downloading(let done, let total):
            guard total > 0 else { return "Downloading…" }
            return "Downloading \(StoreFormat.bytes(done)) of \(StoreFormat.bytes(total))"
        case .installing(let step, let count):
            if count > 0 { return kind == .update ? "Updating \(step) of \(count)" : "Installing \(step) of \(count)" }
            return kind == .update ? "Updating…" : "Installing…"
        case .configuring: return "Finishing…"
        case .removing: return "Removing…"
        case .finished: return kind == .remove ? "Removed" : (kind == .update ? "Updated" : "Installed")
        case .failed(let reason): return reason
        case .cancelled: return "Cancelled"
        }
    }
}

/// Packages with a newer version in the repositories, as `linpad-apps updates` prints them.
struct StorePackageUpdate: Decodable, Equatable, Hashable {
    let name: String
    let installed: String
    let available: String
}

/// What the guest has installed (`linpad-apps state`).
struct StoreInstallState: Decodable, Equatable {
    var world: [String]
    var installed: [String: String]
    var packs: [String: Bool]

    static let empty = StoreInstallState(world: [], installed: [:], packs: [:])

    func isInstalled(_ app: StoreApp) -> Bool {
        if app.isPack { return packs[app.id] ?? false }
        guard let main = app.mainPackage else { return false }
        return world.contains(main)
    }

    func installedVersion(_ app: StoreApp) -> String? {
        app.mainPackage.flatMap { installed[$0] }
    }
}

/// Which installed Store apps have updates. An app is outdated when its own package (or,
/// for a pack, any of its packages) is in the upgradable list.
enum StoreUpdates {
    static func outdatedApps(_ apps: [StoreApp], state: StoreInstallState, updates: [StorePackageUpdate]) -> [(app: StoreApp, update: StorePackageUpdate)] {
        let byName = Dictionary(updates.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return apps.compactMap { app in
            guard state.isInstalled(app) else { return nil }
            let names = app.isPack ? (app.packages ?? []) : [app.mainPackage].compactMap { $0 }
            guard let update = names.lazy.compactMap({ byName[$0] }).first else { return nil }
            return (app, update)
        }
    }

    /// Upgradable packages that belong to no installed Store app (libraries, the system).
    static func otherPackages(_ apps: [StoreApp], state: StoreInstallState, updates: [StorePackageUpdate]) -> [StorePackageUpdate] {
        let owned = Set(outdatedApps(apps, state: state, updates: updates).map(\.update.name))
        return updates.filter { !owned.contains($0.name) }
    }
}

/// What installing an app adds, measured in the guest (`linpad-apps plan`).
struct StorePlan: Decodable, Equatable {
    struct Package: Decodable, Equatable {
        let name: String
        let version: String
        let upgrade: Bool?
        let downloadBytes: Int64
        let installedBytes: Int64
    }

    let id: String
    var packages: [Package]?
    var downloadBytes: Int64?
    var installedBytes: Int64?
    var estimateMB: Int?
    var error: String?

    var packageCount: Int { packages?.count ?? 0 }
}

enum StoreFormat {
    static func bytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = bytes >= 1_000_000_000 ? [.useGB] : (bytes >= 1_000_000 ? [.useMB] : [.useKB])
        return formatter.string(fromByteCount: bytes)
    }

    static func megabytes(_ mb: Int) -> String {
        mb >= 1000 ? String(format: "%.1f GB", Double(mb) / 1000) : "\(mb) MB"
    }

    static func version(_ version: String?) -> String? {
        guard let version, !version.isEmpty else { return nil }
        if let range = version.range(of: #"-r\d+$"#, options: .regularExpression) { return String(version[..<range.lowerBound]) }
        return version
    }
}
