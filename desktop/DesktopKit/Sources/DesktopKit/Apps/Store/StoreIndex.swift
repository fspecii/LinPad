import Foundation

/// LinPad Store's app index (release/guest/linpad/store/linpad-store-index.mjs): every
/// desktop app in Alpine's main and community repositories plus LinPad's own packs, with
/// AppStream metadata, and the curated collections and compatibility list on top.
struct StoreIndex: Decodable, Equatable {
    var format: Int
    /// ISO 8601; the newest of the bundled and the guest's copies wins.
    var generated: String
    var branch: String?
    var mediaBase: String
    var warnSizeMB: Int?
    var categories: [String]
    var hero: [StoreHero]
    var collections: [StoreCollection]
    var apps: [StoreApp]

    var generatedDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: generated) ?? ISO8601DateFormatter().date(from: generated)
    }

    var sizeWarningMB: Int { warnSizeMB ?? 400 }

    /// Category pages list apps that have AppStream metadata; the bare desktop-file
    /// packages only appear in search.
    func apps(inCategory category: String) -> [StoreApp] {
        apps.filter { $0.category == category && !$0.isBarePackage }
    }

    func url(for path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("https://") || path.hasPrefix("http://") { return URL(string: path) }
        return URL(string: mediaBase + "/" + path)
    }

    private enum CodingKeys: String, CodingKey {
        case format, generated, branch, mediaBase, warnSizeMB, categories, hero, collections, apps
    }
}

struct StoreHero: Decodable, Equatable, Identifiable {
    var app: String
    var title: String
    var subtitle: String
    var tint: String?
    var id: String { app }
}

struct StoreCollection: Decodable, Equatable, Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    var apps: [String]
}

struct StoreScreenshot: Decodable, Hashable {
    var url: String
    var w: Int?
    var h: Int?
    var full: String?
    var caption: String?

    var aspectRatio: CGFloat {
        guard let w, let h, w > 0, h > 0 else { return 16 / 10 }
        return CGFloat(w) / CGFloat(h)
    }
}

/// How well an app is known to run under LinPad's emulator and Wayland bridge.
enum StoreCompatibility: String, CaseIterable {
    case works, experimental, broken, untested

    var title: String {
        switch self {
        case .works: "Works well"
        case .experimental: "Experimental"
        case .broken: "Does not run yet"
        case .untested: "Not tested"
        }
    }

    var symbol: String {
        switch self {
        case .works: "checkmark.seal.fill"
        case .experimental: "flask.fill"
        case .broken: "xmark.octagon.fill"
        case .untested: "questionmark.circle"
        }
    }
}

struct StoreApp: Decodable, Identifiable, Hashable {
    var id: String
    /// "pack" (catalog.json) or "apk" (one Alpine package).
    var kind: String
    var name: String
    var summary: String?
    var description: String?
    var category: String
    var packages: [String]?
    var version: String?
    var license: String?
    var homepage: String?
    var appstreamID: String?
    var sizeMB: Int?
    var downloadBytes: Int64?
    var installedBytes: Int64?
    var desktopID: String?
    var iconNames: [String]?
    var icon: String?
    var screenshots: [StoreScreenshot]?
    var keywords: [String]?
    var toolkit: String?
    var x11: Bool?
    var cli: Bool?
    var experimental: Bool?
    var compat: String?
    var compatNote: String?
    /// "package" when the app has no AppStream data (name and text come from apk).
    var metadata: String?
    var metadataSource: String?

    var isPack: Bool { kind == "pack" }
    var isBarePackage: Bool { metadata == "package" }
    var isCommandLine: Bool { cli == true }

    /// The package whose presence in apk's world means the app is installed.
    var mainPackage: String? {
        kind == "apk" ? String(id.dropFirst(4)) : packages?.first
    }

    var compatibility: StoreCompatibility {
        if let compat, let value = StoreCompatibility(rawValue: compat) { return value }
        return experimental == true ? .experimental : .untested
    }

    /// Rough size before `linpad-apps plan` has measured it: the pack's estimate, or the
    /// package's own installed size (without dependencies).
    var estimatedMB: Int? {
        if let sizeMB { return sizeMB }
        guard let installedBytes, installedBytes > 0 else { return nil }
        return max(1, Int((Double(installedBytes) / 1_000_000).rounded()))
    }

    var displayServer: String? {
        if isCommandLine { return "Command line" }
        switch toolkit {
        case "gtk2", "x11": return "X11 (its own Xwayland)"
        case "gtk3", "gtk4": return "Wayland (GTK)"
        case "qt5", "qt6": return "Wayland (Qt)"
        case "sdl": return "Wayland (SDL)"
        default: return x11 == true ? "X11 (its own Xwayland)" : nil
        }
    }

    var categorySymbol: String { StoreCategory.symbol(for: category) }
}

enum StoreCategory {
    static func symbol(for category: String) -> String {
        switch category {
        case "Internet": "globe"
        case "Office": "doc.richtext"
        case "Graphics": "paintpalette"
        case "Audio & Video": "play.rectangle.on.rectangle"
        case "Developer tools": "chevron.left.forwardslash.chevron.right"
        case "Games": "gamecontroller"
        case "Education & Science": "graduationcap"
        case "System": "gearshape.2"
        case "Windows apps": "macwindow.on.rectangle"
        default: "wrench.and.screwdriver"
        }
    }
}

/// Where the index comes from: the copy bundled with the app (always there), or the
/// guest's, which `linpad-apps refresh-index` rebuilds.
enum StoreIndexSource {
    static let guestPaths = ["/var/lib/linpad/store-index.json", "/usr/share/linpad/store-index.json"]

    static func bundled() -> StoreIndex? {
        guard let url = Bundle.module.url(forResource: "store-index", withExtension: "json", subdirectory: "Store"),
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> StoreIndex? {
        try? JSONDecoder().decode(StoreIndex.self, from: data)
    }

    /// Prints "<path>\t<generated>" for each guest copy, read from the file's first bytes.
    static let stampCommand = guestPaths.map { path in
        "[ -f \(path) ] && printf '%s\\t%s\\n' \(path) \"$(head -c 120 \(path) | sed -n 's/.*\"generated\":\"\\([^\"]*\\)\".*/\\1/p')\""
    }.joined(separator: "; ") + "; true"

    /// The guest copy newer than `current`, if any.
    static func newerGuestPath(stamps: String, than current: String) -> String? {
        let candidates = stamps.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
        guard let best = candidates.max(by: { $0.1 < $1.1 }), best.1 > current else { return nil }
        return best.0
    }
}
