import UIKit
import XCTest
@testable import DesktopKit

/// Serves canned responses per URL path; records requests.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let (status, data) = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class WallhavenClientTests: XCTestCase {
    private let searchBody = """
    {"data":[{"id":"abc123","url":"https://wallhaven.cc/w/abc123","short_url":"https://whvn.cc/abc123","views":1,
    "favorites":2,"source":"","purity":"sfw","category":"general","dimension_x":2732,"dimension_y":2048,
    "resolution":"2732x2048","ratio":"1.33","file_size":1000,"file_type":"image/jpeg","created_at":"2026-01-01 00:00:00",
    "colors":["000000"],"path":"https://w.wallhaven.cc/full/ab/wallhaven-abc123.jpg",
    "thumbs":{"large":"https://th.wallhaven.cc/lg/ab/abc123.jpg","original":"https://th.wallhaven.cc/orig/ab/abc123.jpg",
    "small":"https://th.wallhaven.cc/small/ab/abc123.jpg"}}],
    "meta":{"current_page":1,"last_page":7,"per_page":24,"total":150,"query":null,"seed":null}}
    """

    private func client(retries: Int = 3) -> WallhavenClient {
        MockURLProtocol.requests = []
        return WallhavenClient(session: WallhavenClient.makeSession(protocolClasses: [MockURLProtocol.self]),
                               limiter: RateLimiter(requestsPerMinute: 6000, burst: 100),
                               maxRetries: retries, baseBackoff: .milliseconds(10))
    }

    func testSearchDecodesAndAlwaysAsksForSFW() async throws {
        MockURLProtocol.handler = { _ in (200, Data(self.searchBody.utf8)) }
        var query = Wallhaven.Query()
        query.text = "mountains"
        query.sorting = .toplist
        query.topRange = .week
        query.anime = false
        query.atLeast = "2732x2048"
        let response = try await client().search(query)
        XCTAssertEqual(response.data.first?.id, "abc123")
        XCTAssertEqual(response.meta.lastPage, 7)
        let items = URLComponents(url: MockURLProtocol.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["purity"], "100")
        XCTAssertEqual(values["categories"], "101")
        XCTAssertEqual(values["topRange"], "1w")
        XCTAssertEqual(values["atleast"], "2732x2048")
        XCTAssertEqual(values["ratios"], "16x10,16x9,4x3,3x2")
        XCTAssertNil(values["apikey"], "no API key is ever sent")
        XCTAssertEqual(MockURLProtocol.requests[0].value(forHTTPHeaderField: "User-Agent"), WallhavenClient.userAgent)
    }

    func testBacksOffOn429ThenSucceeds() async throws {
        var calls = 0
        MockURLProtocol.handler = { _ in
            calls += 1
            return calls < 3 ? (429, Data()) : (200, Data(self.searchBody.utf8))
        }
        let response = try await client().search(Wallhaven.Query())
        XCTAssertEqual(response.data.count, 1)
        XCTAssertEqual(calls, 3)
    }

    func testGivesUpAfterRetriesAndReportsRateLimit() async {
        MockURLProtocol.handler = { _ in (429, Data()) }
        do {
            _ = try await client(retries: 2).search(Wallhaven.Query())
            XCTFail("expected rate limit error")
        } catch {
            XCTAssertEqual(error as? Wallhaven.APIError, .rateLimited)
            XCTAssertEqual(MockURLProtocol.requests.count, 3)
        }
    }

    func testOfflineAndHTTPErrors() async {
        MockURLProtocol.handler = nil
        do {
            _ = try await client().search(Wallhaven.Query())
            XCTFail("expected offline")
        } catch {
            XCTAssertEqual(error as? Wallhaven.APIError, .offline)
        }
        MockURLProtocol.handler = { _ in (500, Data()) }
        do {
            _ = try await client().info(id: "x")
            XCTFail("expected http error")
        } catch {
            XCTAssertEqual(error as? Wallhaven.APIError, .http(500))
        }
    }

    func testRateLimiterAllowsBurstThenSpacesRequests() async {
        let limiter = RateLimiter(requestsPerMinute: 45, burst: 3)
        for _ in 0..<3 {
            let wait = await limiter.reserve()
            XCTAssertEqual(wait, .zero)
        }
        let wait = await limiter.reserve()
        XCTAssertGreaterThan(wait, .milliseconds(1200), "the 4th call waits for a token (60/45 s)")
        XCTAssertLessThan(wait, .milliseconds(1400))
    }
}

@MainActor
final class WallpaperStoreTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: UUID().uuidString)!
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func testDownsamplesOnceAndReusesTheCache() throws {
        let cache = WallpaperImageCache(root: root)
        try cache.storeOriginal(png(width: 4000, height: 3000), fileName: "big.png")
        let image = try XCTUnwrap(cache.downsampled(fileName: "big.png", id: "big", maxPixel: 1000, suffix: "1000"))
        XCTAssertLessThanOrEqual(max(image.size.width * image.scale, image.size.height * image.scale), 1000)
        let cached = cache.cacheDirectory.appendingPathComponent("big-1000.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
        try FileManager.default.removeItem(at: cache.originalsDirectory.appendingPathComponent("big.png"))
        XCTAssertNotNil(cache.downsampled(fileName: "big.png", id: "big", maxPixel: 1000, suffix: "1000"),
                        "the second request is served from Caches without the original")
    }

    func testLibrarySettingsAndTargets() async throws {
        let store = WallpaperStore(defaults: defaults, cache: WallpaperImageCache(root: root))
        XCTAssertEqual(store.library.filter { $0.origin == .builtIn }.count, BuiltInWallpapers.names.count)
        XCTAssertThrowsError(try store.add(imageData: Data("nope".utf8), suggestedName: "x.txt", origin: .files))
        let item = try store.add(imageData: png(width: 64, height: 48), suggestedName: "a.png", origin: .wallhaven,
                                 attribution: "Wallpaper by someone on Wallhaven", id: "wallhaven-abc")
        store.set(.image(item.id), target: .dark, workspace: 0)
        XCTAssertEqual(store.activeSource(workspace: 0, isDark: true), .image("wallhaven-abc"))
        store.remapWorkspaces([0: 0, 1: 1, 2: 5])
        XCTAssertEqual(store.activeSource(workspace: 5, isDark: true), .color(0x112233), "a workspace's wallpaper moves with it")
        XCTAssertEqual(store.activeSource(workspace: 0, isDark: false), .default)
        store.set(.color(0x112233), target: .currentWorkspace, workspace: 2)
        XCTAssertEqual(store.activeSource(workspace: 2, isDark: true), .color(0x112233))
        XCTAssertEqual(store.activeSource(workspace: 1, isDark: true), .image("wallhaven-abc"))

        let reloaded = WallpaperStore(defaults: defaults, cache: WallpaperImageCache(root: root))
        XCTAssertEqual(reloaded.settings, store.settings, "settings persist")

        var undo: (@MainActor () -> Void)?
        store.onApplied = { _, action in undo = action }
        store.set(.gradient("dusk"), target: .both, workspace: 0)
        XCTAssertEqual(store.activeSource(workspace: 2, isDark: true), .gradient("dusk"),
                       "all workspaces replaces a workspace's own wallpaper")
        XCTAssertTrue(store.settings.perWorkspace.isEmpty)
        undo?()
        XCTAssertEqual(store.activeSource(workspace: 2, isDark: true), .color(0x112233), "undo restores it")
        XCTAssertEqual(store.activeSource(workspace: 0, isDark: true), .image("wallhaven-abc"))
        XCTAssertEqual(reloaded.item("wallhaven-abc")?.attribution, "Wallpaper by someone on Wallhaven")

        store.remove("wallhaven-abc")
        XCTAssertNil(store.item("wallhaven-abc"))
        XCTAssertEqual(store.activeSource(workspace: 0, isDark: true), .default, "removing falls back to the default")
    }

    func testDecodedImagesStayLimitedToVisibleOnes() async throws {
        let store = WallpaperStore(defaults: defaults, cache: WallpaperImageCache(root: root))
        store.targetPixelSize = CGSize(width: 400, height: 300)
        let a = try store.add(imageData: png(width: 800, height: 600), suggestedName: "a.png", origin: .files)
        let b = try store.add(imageData: png(width: 800, height: 600), suggestedName: "b.png", origin: .files)
        store.ensureDecoded([a.id])
        for _ in 0..<50 where store.decoded[a.id] == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(store.decoded[a.id])
        XCTAssertNotNil(store.blurred[a.id])
        store.ensureDecoded([b.id])
        XCTAssertNil(store.decoded[a.id], "only visible wallpapers stay decoded")
    }

    func testSlideshowCyclesFavorites() throws {
        let store = WallpaperStore(defaults: defaults, cache: WallpaperImageCache(root: root))
        let a = try store.add(imageData: png(width: 32, height: 32), suggestedName: "a.png", origin: .files)
        let b = try store.add(imageData: png(width: 32, height: 32), suggestedName: "b.png", origin: .files)
        store.toggleFavorite(a.id)
        store.toggleFavorite(b.id)
        store.update { $0.slideshow.isEnabled = true; $0.slideshow.source = .favorites }
        let first = store.activeSource(workspace: 0, isDark: true)
        store.advanceSlideshow()
        let second = store.activeSource(workspace: 0, isDark: true)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue([WallpaperSource.image(a.id), .image(b.id)].contains(second))
    }
}
