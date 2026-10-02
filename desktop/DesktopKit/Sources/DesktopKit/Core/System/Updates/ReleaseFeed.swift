import Foundation

/// Where LinPad's releases and its SideStore/AltStore source live.
public enum LinPadProject {
    public static let repository = "fspecii/LinPad"
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let releasesAPI = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=10")!
    /// The AltStore-format source (release/source.json) that SideStore and AltStore follow.
    public static let sourceURL = URL(string: "https://raw.githubusercontent.com/\(repository)/main/release/source.json")!
}

/// A GitHub release (the fields of the REST API's release object that updates use).
public struct GitHubRelease: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        public let size: Int64
        public let downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, size
            case downloadURL = "browser_download_url"
        }

        public init(name: String, size: Int64, downloadURL: URL) {
            self.name = name
            self.size = size
            self.downloadURL = downloadURL
        }
    }

    public let tagName: String
    public let name: String?
    public let body: String?
    public let pageURL: URL
    public let isPrerelease: Bool
    public let isDraft: Bool
    public let publishedAt: Date?
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, body, assets
        case tagName = "tag_name"
        case pageURL = "html_url"
        case isPrerelease = "prerelease"
        case isDraft = "draft"
        case publishedAt = "published_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decode(String.self, forKey: .tagName)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        pageURL = try c.decode(URL.self, forKey: .pageURL)
        isPrerelease = try c.decodeIfPresent(Bool.self, forKey: .isPrerelease) ?? false
        isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        let published = try c.decodeIfPresent(String.self, forKey: .publishedAt)
        publishedAt = published.flatMap { ISO8601DateFormatter().date(from: $0) }
        assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }

    public var version: SemanticVersion? { SemanticVersion(tagName) }

    /// LinPad-<version>.ipa
    public var appAsset: Asset? { assets.first { $0.name.hasPrefix("LinPad-") && $0.name.hasSuffix(".ipa") } }
    /// linpad-rootfs-<version>.tar.gz
    public var rootfsAsset: Asset? { assets.first { $0.name.hasPrefix("linpad-rootfs-") && $0.name.hasSuffix(".tar.gz") } }
    public var manifestAsset: Asset? { assets.first { $0.name == "rootfs-manifest.json" } }

    /// The release a channel offers from the API's answer: `/releases/latest` returns one
    /// object, `/releases` an array (newest first, drafts only for maintainers).
    public static func pick(from data: Data, includePrereleases: Bool) throws -> GitHubRelease? {
        let decoder = JSONDecoder()
        if let single = try? decoder.decode(GitHubRelease.self, from: data) {
            return single.isDraft || (single.isPrerelease && !includePrereleases) ? nil : single
        }
        let all = try decoder.decode([GitHubRelease].self, from: data)
        return all
            .filter { !$0.isDraft && (includePrereleases || !$0.isPrerelease) }
            .compactMap { release in release.version.map { (release, $0) } }
            .max { $0.1 < $1.1 }?.0
    }
}

/// rootfs-manifest.json, published next to the rootfs tarball by release/publish.sh.
public struct RootfsManifest: Codable, Equatable, Sendable {
    /// The Linux system's version stamp (yyyymmddHHMM), as in /usr/share/ish/rootfs-version.
    public let version: String
    /// The LinPad release it belongs to.
    public let release: String?
    public let file: String?
    public let size: Int64
    public let sha256: String
    /// The oldest app that can install it.
    public let minAppVersion: String?

    public init(version: String, release: String?, file: String?, size: Int64, sha256: String, minAppVersion: String?) {
        self.version = version
        self.release = release
        self.file = file
        self.size = size
        self.sha256 = sha256
        self.minAppVersion = minAppVersion
    }
}

/// What a release offers this install.
public struct UpdateOffer: Equatable, Sendable {
    public struct AppUpdate: Equatable, Sendable {
        public let version: SemanticVersion
        public let release: GitHubRelease
    }

    public struct SystemUpdate: Equatable, Sendable {
        public let manifest: RootfsManifest
        public let download: URL
    }

    public var app: AppUpdate?
    public var system: SystemUpdate?
    /// A newer Linux system exists but needs a newer app first.
    public var systemNeedsApp: SemanticVersion?

    public static let none = UpdateOffer()

    /// - Parameters:
    ///   - installedSystem: the default root's stamp (nil: unstamped, or unknown).
    ///   - availableSystem: a stamp the app can already install without a download
    ///     (bundled in the app or downloaded earlier), if newer than the installed one.
    public static func evaluate(release: GitHubRelease?, manifest: RootfsManifest?, appVersion: SemanticVersion?,
                                installedSystem: String?, availableSystem: String?) -> UpdateOffer {
        var offer = UpdateOffer()
        guard let release, let releaseVersion = release.version else { return offer }
        if let appVersion, appVersion < releaseVersion {
            offer.app = AppUpdate(version: releaseVersion, release: release)
        }
        guard let manifest, let asset = release.rootfsAsset,
              LinuxSystemVersion.isNewer(manifest.version, than: installedSystem) else { return offer }
        if let availableSystem, !LinuxSystemVersion.isNewer(manifest.version, than: availableSystem) {
            return offer
        }
        if let needed = manifest.minAppVersion.flatMap(SemanticVersion.init), let appVersion, appVersion < needed {
            offer.systemNeedsApp = needed
            return offer
        }
        offer.system = SystemUpdate(manifest: manifest, download: asset.downloadURL)
        return offer
    }
}
