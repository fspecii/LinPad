import Foundation

/// The public Wallhaven API (https://wallhaven.cc/help/api), SFW only: every request
/// carries purity=100 and no API key is sent or stored.
enum Wallhaven {
    static let baseURL = URL(string: "https://wallhaven.cc/api/v1")!

    struct Wallpaper: Codable, Identifiable, Hashable, Sendable {
        struct Thumbs: Codable, Hashable, Sendable {
            let large: URL
            let original: URL
            let small: URL
        }

        struct Uploader: Codable, Hashable, Sendable {
            let username: String
        }

        struct Tag: Codable, Hashable, Sendable, Identifiable {
            let id: Int
            let name: String
        }

        let id: String
        let url: URL
        let shortURL: URL?
        let views: Int?
        let favorites: Int?
        let source: String?
        let purity: String
        let category: String
        let dimensionX: Int
        let dimensionY: Int
        let resolution: String
        let ratio: String?
        let fileSize: Int
        let fileType: String
        let colors: [String]?
        let path: URL
        let thumbs: Thumbs
        let uploader: Uploader?
        let tags: [Tag]?

        enum CodingKeys: String, CodingKey {
            case id, url, views, favorites, source, purity, category, resolution, ratio, colors, path, thumbs, uploader, tags
            case shortURL = "short_url"
            case dimensionX = "dimension_x"
            case dimensionY = "dimension_y"
            case fileSize = "file_size"
            case fileType = "file_type"
        }

        var fileExtension: String {
            fileType.split(separator: "/").last.map(String.init).map { $0 == "jpeg" ? "jpg" : $0 } ?? "jpg"
        }

        var attribution: String {
            uploader.map { "Wallpaper by \($0.username) on Wallhaven" } ?? "Wallpaper from Wallhaven"
        }
    }

    struct Meta: Codable, Hashable, Sendable {
        let currentPage: Int
        let lastPage: Int
        let seed: String?

        enum CodingKeys: String, CodingKey {
            case currentPage = "current_page"
            case lastPage = "last_page"
            case seed
        }
    }

    struct SearchResponse: Codable, Sendable {
        let data: [Wallpaper]
        let meta: Meta
    }

    struct InfoResponse: Codable, Sendable {
        let data: Wallpaper
    }

    enum Sorting: String, CaseIterable, Identifiable, Sendable {
        case latest = "date_added"
        case toplist
        case random
        case views
        case favorites
        case relevance

        var id: String { rawValue }
    }

    enum TopRange: String, CaseIterable, Identifiable, Sendable {
        case day = "1d", threeDays = "3d", week = "1w", month = "1M", year = "1y"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .day: "Day"
            case .threeDays: "3 Days"
            case .week: "Week"
            case .month: "Month"
            case .year: "Year"
            }
        }
    }

    enum Orientation: String, CaseIterable, Identifiable, Sendable {
        case any, landscape, portrait

        var id: String { rawValue }

        /// Wallhaven ratio filters: the landscape ratios iPads and Macs use, or "portrait".
        var ratios: String? {
            switch self {
            case .any: nil
            case .landscape: "16x10,16x9,4x3,3x2"
            case .portrait: "portrait"
            }
        }
    }

    /// The colors Wallhaven accepts in the `colors` filter.
    static let colors = ["660000", "990000", "cc0000", "cc3333", "ea4c88", "993399", "663399", "333399", "0066cc",
                         "0099cc", "66cccc", "77cc33", "669900", "336600", "666600", "999900", "cccc33", "ffff00",
                         "ffcc33", "ff9900", "ff6600", "cc6633", "996633", "663300", "000000", "999999", "cccccc",
                         "ffffff", "424153"]

    struct Query: Equatable, Sendable {
        var text = ""
        var sorting = Sorting.latest
        var topRange = TopRange.month
        var general = true
        var anime = true
        var people = true
        var orientation = Orientation.landscape
        /// "WIDTHxHEIGHT" in pixels, or nil for any size.
        var atLeast: String?
        var color: String?
        var page = 1
        var seed: String?

        var categories: String {
            [general, anime, people].map { $0 ? "1" : "0" }.joined()
        }

        func queryItems() -> [URLQueryItem] {
            var items = [
                URLQueryItem(name: "categories", value: categories == "000" ? "111" : categories),
                URLQueryItem(name: "purity", value: "100"),
                URLQueryItem(name: "sorting", value: sorting.rawValue),
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "page", value: String(page)),
            ]
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { items.append(URLQueryItem(name: "q", value: trimmed)) }
            if sorting == .toplist { items.append(URLQueryItem(name: "topRange", value: topRange.rawValue)) }
            if let ratios = orientation.ratios { items.append(URLQueryItem(name: "ratios", value: ratios)) }
            if let atLeast { items.append(URLQueryItem(name: "atleast", value: atLeast)) }
            if let color { items.append(URLQueryItem(name: "colors", value: color)) }
            if sorting == .random, let seed { items.append(URLQueryItem(name: "seed", value: seed)) }
            return items
        }
    }

    enum APIError: LocalizedError, Equatable {
        case offline
        case rateLimited
        case http(Int)
        case decoding

        var errorDescription: String? {
            switch self {
            case .offline: "You're offline. Wallhaven will load when the connection is back."
            case .rateLimited: "Wallhaven is busy (too many requests). Try again in a minute."
            case .http(let code): "Wallhaven returned an error (\(code))."
            case .decoding: "Wallhaven sent something unexpected."
            }
        }
    }
}

/// Wallhaven allows 45 API calls a minute. A token bucket spaces requests out before they
/// are sent, so the limit is hit only when other clients share the address.
actor RateLimiter {
    private let capacity: Double
    private let refillPerSecond: Double
    private var tokens: Double
    private var lastRefill: ContinuousClock.Instant
    private let clock = ContinuousClock()

    init(requestsPerMinute: Int = 45, burst: Int = 10) {
        capacity = Double(burst)
        refillPerSecond = Double(requestsPerMinute) / 60
        tokens = Double(burst)
        lastRefill = clock.now
    }

    /// How long to wait before the next request may go out; takes a token.
    func reserve() -> Duration {
        refill()
        tokens -= 1
        if tokens >= 0 { return .zero }
        return .seconds(-tokens / refillPerSecond)
    }

    func acquire() async {
        let wait = reserve()
        if wait > .zero { try? await Task.sleep(for: wait) }
    }

    private func refill() {
        let now = clock.now
        let elapsed = (now - lastRefill) / .seconds(1)
        lastRefill = now
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
    }
}

/// Talks to the API: rate-limited, backs off exponentially on 429, identifies itself.
final class WallhavenClient: Sendable {
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "LinPad/\(version) (+https://github.com/fspecii/LinPad)"
    }()

    let session: URLSession
    let limiter: RateLimiter
    private let maxRetries: Int
    private let baseBackoff: Duration

    init(session: URLSession = WallhavenClient.makeSession(), limiter: RateLimiter = RateLimiter(),
         maxRetries: Int = 3, baseBackoff: Duration = .seconds(2)) {
        self.session = session
        self.limiter = limiter
        self.maxRetries = maxRetries
        self.baseBackoff = baseBackoff
    }

    /// Thumbnails and previews are cached on disk (capped at 200 MB) by this session.
    static func makeSession(protocolClasses: [AnyClass] = []) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        configuration.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 200 << 20,
                                          directory: caches.appendingPathComponent("Wallhaven"))
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.timeoutIntervalForRequest = 20
        if !protocolClasses.isEmpty {
            configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        }
        return URLSession(configuration: configuration)
    }

    func search(_ query: Wallhaven.Query) async throws -> Wallhaven.SearchResponse {
        var components = URLComponents(url: Wallhaven.baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        components.queryItems = query.queryItems()
        return try await decode(Wallhaven.SearchResponse.self, from: components.url!)
    }

    func info(id: String) async throws -> Wallhaven.Wallpaper {
        try await decode(Wallhaven.InfoResponse.self, from: Wallhaven.baseURL.appendingPathComponent("w/\(id)")).data
    }

    /// The full-resolution image. Image hosts are not rate limited like the API.
    func download(_ wallpaper: Wallhaven.Wallpaper) async throws -> Data {
        try await fetch(wallpaper.path, limited: false)
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let data = try await fetch(url, limited: true)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw Wallhaven.APIError.decoding
        }
    }

    private func fetch(_ url: URL, limited: Bool) async throws -> Data {
        var attempt = 0
        while true {
            if limited { await limiter.acquire() }
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(from: url)
            } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost,
                                                 .cannotFindHost, .timedOut, .dataNotAllowed].contains(error.code) {
                throw Wallhaven.APIError.offline
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status == 429 {
                guard attempt < maxRetries else { throw Wallhaven.APIError.rateLimited }
                try await Task.sleep(for: baseBackoff * (1 << attempt))
                attempt += 1
                continue
            }
            guard (200..<300).contains(status) else { throw Wallhaven.APIError.http(status) }
            return data
        }
    }
}
