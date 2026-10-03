import Foundation

// MARK: - Redaction

/// Removes what would identify the user or their files from diagnostics text before it is
/// shown for review and exported: paths inside home folders, user and device names, e-mail
/// addresses and the iPad's own folder paths. System paths (/usr, /etc, /proc) stay, since
/// they are what a bug report needs.
struct DiagnosticsRedactor {
    /// Linux user names with a home under /home (and their login names in /etc/passwd).
    var userNames: [String] = []
    /// The iPad's name (often "Ana's iPad") and the guest's hostname.
    var deviceNames: [String] = []
    /// Guest mount points of the iPad folders added in Files.
    var iPadFolders: [String] = []

    static let redacted = "<redacted>"

    func redact(_ text: String) -> String {
        var result = text
        for folder in iPadFolders.sorted(by: { $0.count > $1.count }) where folder.count > 1 {
            result = result.replacingOccurrences(of: folder, with: "<ipad-folder>")
        }
        result = Self.replace(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, in: result, with: "<email>")
        result = Self.replace(#"/(?:private/)?var/mobile/Library/Mobile Documents/[^\s"'<>]*"#, in: result, with: "<icloud-path>")
        result = Self.replace(#"/(?:private/)?var/mobile/Containers/Shared/AppGroup/[0-9A-Fa-f-]{36}/File Provider Storage/[^\s"'<>]*"#, in: result, with: "<files-app-path>")
        result = Self.replace(#"/Users/[^/\s"'<>]+"#, in: result, with: "/Users/<user>")
        result = Self.redactHomePaths(result)
        for name in (deviceNames + userNames).filter({ $0.count >= 3 }).sorted(by: { $0.count > $1.count }) {
            let pattern = #"(?<![A-Za-z0-9])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![A-Za-z0-9])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length),
                                                    withTemplate: "<name>")
        }
        return result
    }

    /// "/root/projects/app/main.c" → "/root/<redacted>", "/home/ana/.config/x" →
    /// "/home/<user>/.config/<redacted>". A first-level hidden folder (.config, .mozilla,
    /// .cache) is kept: it names a program, not the user's data.
    static func redactHomePaths(_ text: String) -> String {
        let pattern = #"(/root|/home/[^/\s"'<>:]+)((?:/[^\s"'<>:]+)*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var output = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let start = match.range.location
            if start > 0 {
                let previous = source.substring(with: NSRange(location: start - 1, length: 1))
                if previous.rangeOfCharacter(from: .alphanumerics) != nil || previous == "/" || previous == "." { continue }
            }
            output += source.substring(with: NSRange(location: last, length: start - last))
            let home = source.substring(with: match.range(at: 1))
            let rest = match.range(at: 2).length > 0 ? source.substring(with: match.range(at: 2)) : ""
            output += (home == "/root" ? "/root" : "/home/<user>") + redactedRest(rest)
            last = match.range.location + match.range.length
        }
        output += source.substring(from: last)
        return output
    }

    private static func redactedRest(_ rest: String) -> String {
        let components = rest.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = components.first else { return rest }
        if first.hasPrefix("."), first.count > 1 {
            return "/" + first + (components.count > 1 ? "/" + redacted : "")
        }
        return "/" + redacted
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    /// Login names of real users (uid 1000 and up) from /etc/passwd.
    static func userNames(fromPasswd passwd: String) -> [String] {
        passwd.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 3, let uid = Int(fields[2]), uid >= 1000, uid < 65534 else { return nil }
            return String(fields[0])
        }
    }
}

// MARK: - Events

/// Something the diagnostics export should mention: an unclean exit, a stall, a crash
/// report from MetricKit. Kept in Application Support/Diagnostics/events.jsonl.
struct DiagnosticsEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case uncleanExit = "unclean-exit"
        case mainThreadStall = "main-thread-stall"
        case guestUnresponsive = "guest-unresponsive"
        case guestRecovered = "guest-recovered"
        case crashReport = "crash-report"
        case hangReport = "hang-report"
        case emulatorCrashLog = "emulator-crash-log"
    }

    var date: Date
    var kind: Kind
    var detail: String
}

/// The marker that tells the next launch whether this one ended cleanly. iPadOS ending a
/// suspended app is normal; dying while in front (a crash, a jetsam kill, the watchdog
/// killing a hung app) is not.
struct DiagnosticsSessionMarker: Codable, Equatable {
    var launchedAt: Date
    var appVersion: String
    var inForeground: Bool
    /// A main-thread stall that was still going on when this was written.
    var stallInProgressSince: Date?
    /// Set when LinPad exits on purpose (Quit, Reset to Factory). Absent in markers from
    /// before it existed.
    var exitedCleanly: Bool?

    /// Whether the previous session (this marker, read at the next launch) ended badly.
    var endedUncleanly: Bool { inForeground && exitedCleanly != true }
}

enum UncleanExitPolicy {
    static let repeatWindow: TimeInterval = 3 * 24 * 3600
    static let repeatCount = 2

    /// Suggest Repair System when LinPad closed unexpectedly this often recently.
    static func suggestsRepair(events: [DiagnosticsEvent], now: Date) -> Bool {
        events.filter { $0.kind == .uncleanExit && now.timeIntervalSince($0.date) <= repeatWindow }.count >= repeatCount
    }
}

// MARK: - Watchdog thresholds

/// Main-thread stalls, measured from a background thread that pings the main queue.
struct MainThreadStallDetector {
    /// A stall is reported once it has lasted this long.
    var threshold: TimeInterval = 2
    /// The pinging thread itself was not scheduled for this long: the app was suspended,
    /// which is not a stall.
    var suspensionGap: TimeInterval = 1.5

    private(set) var lastTick: TimeInterval?
    private(set) var stallStart: TimeInterval?
    private(set) var reported = false

    enum Event: Equatable {
        /// The main thread has not answered for `duration` seconds and still does not.
        case stalled(duration: TimeInterval)
        /// It answered again after a reported stall of `duration` seconds.
        case recovered(duration: TimeInterval)
    }

    /// `pendingSince` is when the oldest unanswered ping was sent, or nil if all were.
    mutating func tick(now: TimeInterval, pendingSince: TimeInterval?) -> Event? {
        defer { lastTick = now }
        if let lastTick, now - lastTick > suspensionGap {
            stallStart = nil
            reported = false
            return nil
        }
        guard let pendingSince else {
            defer { stallStart = nil; reported = false }
            if reported, let stallStart { return .recovered(duration: now - stallStart) }
            return nil
        }
        stallStart = pendingSince
        if !reported, now - pendingSince >= threshold {
            reported = true
            return .stalled(duration: now - pendingSince)
        }
        return nil
    }
}

/// Whether Linux still answers: `true` run in the guest every so often while the app is in
/// front. Two misses in a row, each a timeout, mean the guest is wedged.
struct GuestHeartbeatMonitor {
    var timeout: TimeInterval = 20
    var missesBeforeWedged = 2

    private(set) var consecutiveMisses = 0
    private(set) var isWedged = false

    enum Event: Equatable {
        case wedged
        case recovered
    }

    mutating func record(answered: Bool) -> Event? {
        if answered {
            consecutiveMisses = 0
            if isWedged {
                isWedged = false
                return .recovered
            }
            return nil
        }
        consecutiveMisses += 1
        if !isWedged, consecutiveMisses >= missesBeforeWedged {
            isWedged = true
            return .wedged
        }
        return nil
    }
}
