import Foundation

/// Reads LinPad's releases from the unauthenticated GitHub API (60 requests an hour per IP).
/// Answers are cached with their ETag, and a conditional request that comes back
/// 304 Not Modified does not count against the rate limit.
public struct ReleaseClient: Sendable {
    public enum ClientError: LocalizedError, Equatable {
        case http(Int)
        case rateLimited(resetsAt: Date?)
        case lowDataMode

        public var errorDescription: String? {
            switch self {
            case .http(let status): return "GitHub answered with HTTP \(status)."
            case .rateLimited(let date):
                let when = date.map { " until " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
                return "GitHub's rate limit for this network is used up\(when)."
            case .lowDataMode: return "Low Data Mode is on."
            }
        }
    }

    private let session: URLSession
    private let cacheDirectory: URL
    /// Replaces the GitHub API (UserDefaults `linpad.updates.feedURL`): a file or URL with a
    /// release object or array, for tests and for checking the UI against a mock release.
    private let feedOverride: URL?

    public init(session: URLSession = .shared, cacheDirectory: URL? = nil, feedOverride: URL? = nil) {
        self.session = session
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linpad-updates", isDirectory: true)
        self.feedOverride = feedOverride
    }

    public func latestRelease(includePrereleases: Bool, allowsConstrainedNetwork: Bool) async throws -> GitHubRelease? {
        let url = feedOverride ?? (includePrereleases ? LinPadProject.releasesAPI : LinPadProject.latestReleaseAPI)
        guard let data = try await fetch(url, allowsConstrainedNetwork: allowsConstrainedNetwork) else {
            return nil // no release published yet
        }
        return try GitHubRelease.pick(from: data, includePrereleases: includePrereleases)
    }

    public func manifest(for release: GitHubRelease, allowsConstrainedNetwork: Bool) async throws -> RootfsManifest? {
        guard let asset = release.manifestAsset,
              let data = try await fetch(asset.downloadURL, allowsConstrainedNetwork: allowsConstrainedNetwork) else { return nil }
        return try JSONDecoder().decode(RootfsManifest.self, from: data)
    }

    /// The body for `url`, from the cache when the server says it has not changed; nil for 404.
    func fetch(_ url: URL, allowsConstrainedNetwork: Bool) async throws -> Data? {
        if url.isFileURL {
            return try Data(contentsOf: url)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.allowsConstrainedNetworkAccess = allowsConstrainedNetwork
        let cached = cacheEntry(for: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let etag = try? String(contentsOf: cached.etag, encoding: .utf8), FileManager.default.fileExists(atPath: cached.body.path) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.networkUnavailableReason == .constrained {
            throw ClientError.lowDataMode
        }
        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200:
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: cached.body, options: .atomic)
            if let etag = http.value(forHTTPHeaderField: "ETag") {
                try? etag.write(to: cached.etag, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: cached.etag)
            }
            return data
        case 304:
            return try Data(contentsOf: cached.body)
        case 404:
            return nil
        case 403, 429:
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || http.statusCode == 429 {
                let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
                throw ClientError.rateLimited(resetsAt: reset.map { Date(timeIntervalSince1970: $0) })
            }
            throw ClientError.http(http.statusCode)
        default:
            throw ClientError.http(http.statusCode)
        }
    }

    private func cacheEntry(for url: URL) -> (body: URL, etag: URL) {
        let key = url.absoluteString.unicodeScalars.reduce(into: UInt64(14_695_981_039_346_656_037)) { hash, scalar in
            hash = (hash ^ UInt64(scalar.value)) &* 1_099_511_628_211
        }
        let base = cacheDirectory.appendingPathComponent(String(key, radix: 16))
        return (base.appendingPathExtension("json"), base.appendingPathExtension("etag"))
    }
}
