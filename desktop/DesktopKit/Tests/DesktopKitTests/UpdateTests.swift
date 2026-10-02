import XCTest
@testable import DesktopKit

final class SemanticVersionTests: XCTestCase {
    private func v(_ text: String) throws -> SemanticVersion {
        try XCTUnwrap(SemanticVersion(text), text)
    }

    func testParsing() throws {
        XCTAssertEqual(try v("v1.4.0"), SemanticVersion(major: 1, minor: 4, patch: 0))
        XCTAssertEqual(try v("1.4"), SemanticVersion(major: 1, minor: 4, patch: 0))
        XCTAssertEqual(try v("2"), SemanticVersion(major: 2, minor: 0, patch: 0))
        XCTAssertEqual(try v("1.5.0-beta.2+sha.abc").prerelease, ["beta", "2"])
        XCTAssertEqual(try v("1.5.0-rc.1").description, "1.5.0-rc.1")
        for bad in ["", "v", "1..2", "1.2.3.4", "1.x", "1.2.3-", "1.2.3-a..b", "-1.0"] {
            XCTAssertNil(SemanticVersion(bad), bad)
        }
    }

    func testOrdering() throws {
        // SemVer 2.0, section 11.
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                       "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.3.3", "1.4.0", "1.10.0", "2.0.0"]
        let versions = try ordered.map(v)
        for (a, b) in zip(versions, versions.dropFirst()) {
            XCTAssertLessThan(a, b, "\(a) < \(b)")
            XCTAssertFalse(b < a, "\(b) !< \(a)")
        }
        XCTAssertEqual(versions.shuffled().sorted(), versions)
        XCTAssertFalse(try v("1.4.0") < v("v1.4"))
        XCTAssertEqual(try v("1.4.0+build.7"), try v("1.4.0"))
    }

    func testLinuxSystemStamps() {
        XCTAssertTrue(LinuxSystemVersion.isNewer("202610021000", than: nil), "unstamped systems are always older")
        XCTAssertTrue(LinuxSystemVersion.isNewer("202610021000", than: "202609301200"))
        XCTAssertFalse(LinuxSystemVersion.isNewer("202610021000", than: "202610021000"))
        XCTAssertFalse(LinuxSystemVersion.isNewer("202601010000", than: "202610021000"))
        XCTAssertFalse(LinuxSystemVersion.isNewer("garbage", than: nil))
        XCTAssertTrue(LinuxSystemVersion.displayName("202610021230").contains("2026"))
        XCTAssertEqual(LinuxSystemVersion.displayName("dev"), "dev")
    }
}

final class ReleaseFeedTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    private func release() throws -> GitHubRelease {
        try XCTUnwrap(GitHubRelease.pick(from: fixture("github-release.json"), includePrereleases: false))
    }

    private func manifest() throws -> RootfsManifest {
        try JSONDecoder().decode(RootfsManifest.self, from: fixture("rootfs-manifest.json"))
    }

    func testParsesTheLatestReleaseObject() throws {
        let release = try release()
        XCTAssertEqual(release.tagName, "v1.5.0")
        XCTAssertEqual(release.version, SemanticVersion(major: 1, minor: 5, patch: 0))
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/fspecii/LinPad/releases/tag/v1.5.0")
        XCTAssertFalse(release.isPrerelease)
        XCTAssertNotNil(release.publishedAt)
        XCTAssertEqual(release.appAsset?.name, "LinPad-1.5.0.ipa")
        XCTAssertEqual(release.rootfsAsset?.name, "linpad-rootfs-1.5.0.tar.gz", "not the .sha256 next to it")
        XCTAssertEqual(release.rootfsAsset?.size, 723_456_789)
        XCTAssertEqual(release.manifestAsset?.downloadURL.lastPathComponent, "rootfs-manifest.json")
        XCTAssertTrue(release.body?.contains("Settings › Updates") == true)
    }

    func testParsesTheManifest() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.version, "202610021000")
        XCTAssertEqual(manifest.minAppVersion, "1.4.0")
        XCTAssertEqual(manifest.sha256.count, 64)
    }

    func testPicksTheNewestReleaseOfTheChannelFromAList() throws {
        func entry(_ tag: String, prerelease: Bool = false, draft: Bool = false) -> String {
            """
            {"tag_name": "\(tag)", "html_url": "https://github.com/fspecii/LinPad/releases/tag/\(tag)",
             "prerelease": \(prerelease), "draft": \(draft), "assets": []}
            """
        }
        let list = Data("[\(entry("v1.6.0-beta.1", prerelease: true)), \(entry("v1.7.0", draft: true)), \(entry("v1.5.0")), \(entry("nightly"))]".utf8)
        XCTAssertEqual(try GitHubRelease.pick(from: list, includePrereleases: false)?.tagName, "v1.5.0")
        XCTAssertEqual(try GitHubRelease.pick(from: list, includePrereleases: true)?.tagName, "v1.6.0-beta.1")
        XCTAssertNil(try GitHubRelease.pick(from: Data("[]".utf8), includePrereleases: true))
        XCTAssertNil(try GitHubRelease.pick(from: Data(entry("v2.0.0-rc.1", prerelease: true).utf8), includePrereleases: false))
        XCTAssertThrowsError(try GitHubRelease.pick(from: Data("{\"message\": \"Not Found\"}".utf8), includePrereleases: false))
    }

    func testOffers() throws {
        let release = try release(), manifest = try manifest()
        func offer(app: String, installed: String?, available: String? = nil) -> UpdateOffer {
            UpdateOffer.evaluate(release: release, manifest: manifest, appVersion: SemanticVersion(app),
                                 installedSystem: installed, availableSystem: available)
        }
        let old = offer(app: "1.4.0", installed: "202609010000")
        XCTAssertEqual(old.app?.version.description, "1.5.0")
        XCTAssertEqual(old.system?.manifest.version, "202610021000")
        XCTAssertEqual(old.system?.download.lastPathComponent, "linpad-rootfs-1.5.0.tar.gz")

        let current = offer(app: "1.5.0", installed: "202610021000")
        XCTAssertNil(current.app)
        XCTAssertNil(current.system)

        XCTAssertNotNil(offer(app: "1.5.0", installed: nil).system, "an unstamped system is offered the update")
        XCTAssertNil(offer(app: "1.5.0", installed: "202609010000", available: "202610021000").system,
                     "the bundled or already downloaded system is as new: nothing to download")

        let tooOld = offer(app: "1.3.3", installed: "202609010000")
        XCTAssertNil(tooOld.system)
        XCTAssertEqual(tooOld.systemNeedsApp?.description, "1.4.0")
        XCTAssertNotNil(tooOld.app)

        XCTAssertEqual(UpdateOffer.evaluate(release: nil, manifest: nil, appVersion: nil, installedSystem: nil, availableSystem: nil), .none)
    }
}

final class UpdateScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testReleaseChecksEverySixHours() {
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: nil, now: now, interval: UpdateSchedule.releaseInterval))
        XCTAssertFalse(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-5 * 3600), now: now, interval: UpdateSchedule.releaseInterval))
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-6 * 3600), now: now, interval: UpdateSchedule.releaseInterval))
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(3600), now: now, interval: UpdateSchedule.releaseInterval),
                      "a last check in the future means the clock moved back")
    }

    func testAutomaticChecksRespectTheSettingAndTheNetwork() {
        let stale = now.addingTimeInterval(-7 * 3600)
        XCTAssertTrue(UpdateSchedule.shouldCheckAutomatically(enabled: true, lastCheck: stale, now: now, network: .available))
        XCTAssertFalse(UpdateSchedule.shouldCheckAutomatically(enabled: false, lastCheck: stale, now: now, network: .available))
        XCTAssertFalse(UpdateSchedule.shouldCheckAutomatically(enabled: true, lastCheck: stale, now: now, network: .offline))
        XCTAssertFalse(UpdateSchedule.shouldCheckAutomatically(enabled: true, lastCheck: stale, now: now, network: .constrained),
                       "Low Data Mode")
        XCTAssertTrue(UpdateSchedule.canCheckManually(network: .constrained))
        XCTAssertFalse(UpdateSchedule.canCheckManually(network: .offline))
    }

    func testPackagesWeekly() {
        let sixDays = now.addingTimeInterval(-6 * 24 * 3600), eightDays = now.addingTimeInterval(-8 * 24 * 3600)
        XCTAssertFalse(UpdateSchedule.shouldCheckAutomatically(enabled: true, lastCheck: sixDays, now: now, network: .available,
                                                               interval: UpdateSchedule.packageInterval))
        XCTAssertTrue(UpdateSchedule.shouldCheckAutomatically(enabled: true, lastCheck: eightDays, now: now, network: .available,
                                                              interval: UpdateSchedule.packageInterval))
    }
}

final class FileDigestTests: XCTestCase {
    func testSHA256OfAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("digest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("test".utf8).write(to: url)
        let expected = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        XCTAssertEqual(try FileDigest.sha256(of: url), expected)
        XCTAssertTrue(try FileDigest.matches(url, sha256: expected.uppercased() + "\n"))
        XCTAssertFalse(try FileDigest.matches(url, sha256: String(repeating: "0", count: 64)))
    }

    func testSHA256SpansChunks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("digest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        // 9 MiB of "a": more than two 4 MB reads. Reference value from `shasum -a 256`.
        try Data(repeating: 0x61, count: 9 << 20).write(to: url)
        XCTAssertEqual(try FileDigest.sha256(of: url), "23ff721b5953999b01acf7b12c7e80f3ee453299b2f0b34b13b116977daef908")
        XCTAssertThrowsError(try FileDigest.sha256(of: url.appendingPathExtension("missing")))
    }
}

final class ApkUpgradeParsingTests: XCTestCase {
    func testParsesApkVersionOutput() {
        let output = """
            Installed:                                Available:
            busybox-1.37.0-r12                      < 1.37.0-r13
            py3-pip-24.3.1-r0                       < 24.3.1-r1
            gtk+3.0-3.24.43-r0                      < 3.24.49-r0
            font-noto-cjk-0_git20220127-r1          < 0_git20240101-r0
            mesa-26.2.3-r0                          > 24.2.8-r0
            WARNING: opening /var/cache/apk: No such file or directory
            """
        let updates = ApkCommands.parseUpgradable(output)
        XCTAssertEqual(updates, [
            PackageUpdate(name: "busybox", installed: "1.37.0-r12", available: "1.37.0-r13"),
            PackageUpdate(name: "py3-pip", installed: "24.3.1-r0", available: "24.3.1-r1"),
            PackageUpdate(name: "gtk+3.0", installed: "3.24.43-r0", available: "3.24.49-r0"),
            PackageUpdate(name: "font-noto-cjk", installed: "0_git20220127-r1", available: "0_git20240101-r0"),
        ])
        XCTAssertTrue(ApkCommands.parseUpgradable("Installed:   Available:\n").isEmpty)
    }
}

/// ETag caching against a stubbed server: the second request is conditional and a 304
/// answer is served from the cache.
final class ReleaseClientTests: XCTestCase {
    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var requests: [URLRequest] = []
        nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, [String: String], Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests.append(request)
            let (status, headers, body) = Self.responder?(request) ?? (500, [:], Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private var cache: URL!
    private var client: ReleaseClient!

    override func setUp() {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("release-cache-\(UUID().uuidString)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        client = ReleaseClient(session: URLSession(configuration: configuration), cacheDirectory: cache)
        StubProtocol.requests = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cache)
        StubProtocol.responder = nil
    }

    func testConditionalRequestsUseTheCache() async throws {
        let body = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/github-release.json"))
        StubProtocol.responder = { request in
            request.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"" ? (304, [:], Data()) : (200, ["ETag": "\"abc\""], body)
        }
        let first = try await client.latestRelease(includePrereleases: false, allowsConstrainedNetwork: false)
        let second = try await client.latestRelease(includePrereleases: false, allowsConstrainedNetwork: false)
        XCTAssertEqual(first?.tagName, "v1.5.0")
        XCTAssertEqual(second, first)
        XCTAssertEqual(StubProtocol.requests.count, 2)
        XCTAssertNil(StubProtocol.requests[0].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(StubProtocol.requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"abc\"")
        XCTAssertEqual(StubProtocol.requests[0].url, LinPadProject.latestReleaseAPI)
        XCTAssertFalse(StubProtocol.requests[0].allowsConstrainedNetworkAccess)
    }

    func testNoReleaseYetAndRateLimit() async throws {
        StubProtocol.responder = { _ in (404, [:], Data("{\"message\":\"Not Found\"}".utf8)) }
        let none = try await client.latestRelease(includePrereleases: false, allowsConstrainedNetwork: true)
        XCTAssertNil(none)

        StubProtocol.responder = { _ in (403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1790000000"], Data()) }
        do {
            _ = try await client.latestRelease(includePrereleases: true, allowsConstrainedNetwork: true)
            XCTFail("expected the rate limit error")
        } catch let error as ReleaseClient.ClientError {
            XCTAssertEqual(error, .rateLimited(resetsAt: Date(timeIntervalSince1970: 1_790_000_000)))
        }
        XCTAssertEqual(StubProtocol.requests.last?.url, LinPadProject.releasesAPI)
    }
}
