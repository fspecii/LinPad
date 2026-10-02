import Foundation

/// A release version such as "1.4.0", "v1.4.0" or "1.5.0-beta.2", ordered by SemVer 2.0
/// precedence. Build metadata ("+abc") is ignored; a missing minor or patch counts as 0.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        var prerelease: [String] = []
        if let dash = text.firstIndex(of: "-") {
            prerelease = text[text.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !prerelease.contains(where: \.isEmpty) else { return nil }
            text = String(text[..<dash])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: prerelease)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let left = (lhs.major, lhs.minor, lhs.patch), right = (rhs.major, rhs.minor, rhs.patch)
        if left != right { return left < right }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// The Linux system's version stamp (UTC yyyymmddHHMM, from release/build-rootfs.sh), the
/// number the app compares the same way Roots.availableUpdate does.
public enum LinuxSystemVersion {
    /// True when `candidate` should replace `installed`; an unstamped system (nil) is older
    /// than any stamp.
    public static func isNewer(_ candidate: String, than installed: String?) -> Bool {
        guard let new = Int64(candidate.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        guard let installed, let old = Int64(installed.trimmingCharacters(in: .whitespacesAndNewlines)) else { return true }
        return new > old
    }

    /// "202610021230" as "2 Oct 2026, 12:30 UTC"; anything else unchanged.
    public static func displayName(_ stamp: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmm"
        guard stamp.count == 12, let date = formatter.date(from: stamp) else { return stamp }
        formatter.locale = Locale.current
        formatter.dateFormat = "d MMM yyyy, HH:mm 'UTC'"
        return formatter.string(from: date)
    }
}
