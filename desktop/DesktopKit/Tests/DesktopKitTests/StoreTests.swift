import XCTest
@testable import DesktopKit

@MainActor
final class StoreTests: XCTestCase {
    private static let index = StoreIndexSource.bundled()

    private func index() throws -> StoreIndex {
        try XCTUnwrap(Self.index, "the bundled store-index.json decodes")
    }

    // MARK: Index

    func testBundledIndexHasTheCuratedLayer() throws {
        let index = try index()
        XCTAssertGreaterThan(index.apps.count, 500)
        XCTAssertFalse(index.hero.isEmpty)
        let ids = Set(index.apps.map(\.id))
        for collection in index.collections {
            XCTAssertFalse(collection.apps.isEmpty, collection.id)
            for id in collection.apps { XCTAssertTrue(ids.contains(id), "\(collection.id) lists \(id)") }
        }
        for hero in index.hero { XCTAssertTrue(ids.contains(hero.app), hero.app) }
        let titles = index.collections.map(\.title)
        for title in ["Developer essentials", "Internet", "Office", "Graphics", "Audio & Video", "Creators", "Utilities", "Games that run well", "Windows apps (Wine)"] {
            XCTAssertTrue(titles.contains(title), title)
        }
    }

    func testRequestedAppsAreInTheirCollections() throws {
        let index = try index()
        func collection(_ id: String) throws -> [String] { try XCTUnwrap(index.collections.first { $0.id == id }).apps }
        XCTAssertTrue(try collection("internet").contains("apk:filezilla"))
        XCTAssertTrue(try collection("internet").contains("mail"), "Thunderbird pack")
        XCTAssertTrue(try collection("internet").contains("apk:firefox-esr"))
        XCTAssertTrue(try collection("audio-video").contains("apk:audacity"))
        XCTAssertTrue(try collection("creators").contains("apk:audacity"))
        XCTAssertEqual(try collection("windows"), ["wine", "wine-x86"])
    }

    func testAppsHaveTheMetadataTheDetailPageShows() throws {
        let index = try index()
        let filezilla = try XCTUnwrap(index.apps.first { $0.id == "apk:filezilla" })
        XCTAssertEqual(filezilla.mainPackage, "filezilla")
        XCTAssertNotNil(filezilla.version)
        XCTAssertNotNil(filezilla.license)
        XCTAssertNotNil(filezilla.homepage)
        XCTAssertFalse(filezilla.screenshots?.isEmpty ?? true)
        XCTAssertNotNil(index.url(for: filezilla.icon))
        let gimp = try XCTUnwrap(index.apps.first { $0.id == "image-editor" })
        XCTAssertTrue(gimp.isPack)
        XCTAssertEqual(gimp.mainPackage, "gimp")
        let office = try XCTUnwrap(index.apps.first { $0.id == "office" })
        XCTAssertGreaterThanOrEqual(office.estimatedMB ?? 0, index.sizeWarningMB, "LibreOffice gets the size warning")
    }

    func testBundledIconsCoverAppsTheMediaServerLacks() {
        XCTAssertNotNil(StoreBundledIcons.image(for: "apk:geany"), "Geany has no remote 128 px icon")
        XCTAssertNotNil(StoreBundledIcons.image(for: "image-editor"))
        XCTAssertNil(StoreBundledIcons.image(for: "apk:does-not-exist"))
    }

    func testCompatibilityDefaultsToNotTested() {
        var app = StoreApp(id: "apk:x", kind: "apk", name: "X", category: "Utilities")
        XCTAssertEqual(app.compatibility, .untested)
        app.experimental = true
        XCTAssertEqual(app.compatibility, .experimental)
        app.compat = "works"
        XCTAssertEqual(app.compatibility, .works)
    }

    func testNewerGuestIndexWins() {
        let stamps = "/var/lib/linpad/store-index.json\t2026-10-05T10:00:00.000Z\n/usr/share/linpad/store-index.json\t2026-10-03T00:00:00.000Z\n"
        XCTAssertEqual(StoreIndexSource.newerGuestPath(stamps: stamps, than: "2026-10-03T00:00:00.000Z"), "/var/lib/linpad/store-index.json")
        XCTAssertNil(StoreIndexSource.newerGuestPath(stamps: stamps, than: "2026-10-06T00:00:00.000Z"))
        XCTAssertNil(StoreIndexSource.newerGuestPath(stamps: "", than: ""))
    }

    // MARK: Search

    private func top(_ query: String, _ count: Int = 1) throws -> [String] {
        let index = try index()
        let featured = Set(index.collections.flatMap(\.apps))
        return Array(StoreSearch.results(query, in: index.apps, featured: featured).prefix(count).map(\.id))
    }

    func testSearchFindsAppsByName() throws {
        XCTAssertEqual(try top("filezilla"), ["apk:filezilla"])
        XCTAssertEqual(try top("FileZilla"), ["apk:filezilla"])
        XCTAssertEqual(try top("audacity"), ["apk:audacity"])
        XCTAssertEqual(try top("inkscape"), ["apk:inkscape"])
        XCTAssertEqual(try top("thunderbird"), ["mail"])
        XCTAssertEqual(try top("gimp"), ["image-editor"])
    }

    func testSearchToleratesTyposAndPrefixes() throws {
        XCTAssertEqual(try top("filezila"), ["apk:filezilla"])
        XCTAssertEqual(try top("audacty"), ["apk:audacity"])
        XCTAssertEqual(try top("inksc"), ["apk:inkscape"])
    }

    func testSearchMatchesWhatAnAppDoes() throws {
        XCTAssertTrue(try top("ftp", 3).contains("apk:filezilla"))
        XCTAssertTrue(try top("torrent", 5).contains("apk:transmission-gtk"))
        XCTAssertTrue(try top("office", 5).contains("office"))
        XCTAssertTrue(try top("vector graphics", 5).contains("apk:inkscape"))
    }

    func testSearchByPackageName() throws {
        XCTAssertEqual(try top("transmission-gtk"), ["apk:transmission-gtk"])
    }

    func testEveryWordMustMatch() throws {
        XCTAssertTrue(try top("filezilla zzzzqqq").isEmpty)
        XCTAssertTrue(StoreSearch.results("   ", in: try index().apps).isEmpty)
    }

    func testOneEditTypos() {
        XCTAssertTrue(StoreSearch.isTypo("gimq", of: "gimp"))
        XCTAssertTrue(StoreSearch.isTypo("igmp", of: "gimp"))
        XCTAssertTrue(StoreSearch.isTypo("vlcc", of: "vlc"))
        XCTAssertFalse(StoreSearch.isTypo("abcd", of: "gimp"))
    }

    // MARK: Output parsing and the install state machine

    func testParserJoinsLinesAcrossChunks() {
        var parser = StoreOutputParser()
        XCTAssertEqual(parser.consume("==> @phase apk:x down"), [])
        XCTAssertEqual(parser.consume("loading\n==> @progress apk:x 10 100 bytes\n(3/11) Install"),
                       [.phase(id: "apk:x", name: "downloading"), .progress(id: "apk:x", done: 10, total: 100, unit: "bytes")])
        XCTAssertEqual(parser.consume("ing filezilla (3.68.1-r0)\nExecuting busybox.trigger\n"),
                       [.step(index: 3, count: 11, verb: "Installing", package: "filezilla"), .log("Executing busybox.trigger")])
        XCTAssertEqual(parser.consume("==> FileZilla: installed"), [])
        XCTAssertEqual(parser.finish(), [.message("FileZilla: installed")])
    }

    private func job(after lines: [String], exitCode: Int32? = nil, kind: StoreJobKind = .install) -> StoreJob {
        var job = StoreJob(appIDs: ["apk:filezilla"], kind: kind, title: "FileZilla")
        var parser = StoreOutputParser()
        for event in parser.consume(lines.joined(separator: "\n") + "\n") { job.apply(event) }
        if let exitCode { job.finish(exitCode: exitCode) }
        return job
    }

    func testInstallWalksThePhasesWithRisingProgress() {
        let script = [
            "==> Installing FileZilla", "==> @phase apk:filezilla resolving",
            "==> @phase apk:filezilla downloading", "==> @progress apk:filezilla 0 1000 bytes",
            "==> @progress apk:filezilla 500 1000 bytes", "==> @progress apk:filezilla 1000 1000 bytes",
            "==> @phase apk:filezilla installing", "(1/2) Installing libfilezilla (0.49.0-r0)",
            "(2/2) Installing filezilla (3.68.1-r0)", "==> @phase apk:filezilla configuring",
            "==> @phase apk:filezilla done", "==> FileZilla: installed",
        ]
        var fractions: [Double] = []
        for end in 1...script.count {
            let state = job(after: Array(script.prefix(end)))
            if let fraction = state.fraction { fractions.append(fraction) }
        }
        XCTAssertEqual(fractions, fractions.sorted(), "progress never goes backwards")
        XCTAssertEqual(job(after: Array(script.prefix(5))).phase, .downloading(done: 500, total: 1000))
        XCTAssertEqual(job(after: Array(script.prefix(5))).statusText, "Downloading \(StoreFormat.bytes(500)) of \(StoreFormat.bytes(1000))")
        XCTAssertEqual(job(after: Array(script.prefix(9))).phase, .installing(step: 2, of: 2))
        XCTAssertEqual(job(after: script, exitCode: 0).phase, .finished)
        XCTAssertEqual(job(after: script, exitCode: 0).fraction, 1)
    }

    func testCancelAndFailureAreFinal() {
        let cancelled = job(after: ["==> @phase apk:filezilla downloading", "==> @phase apk:filezilla cancelled"], exitCode: 1)
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertFalse(cancelled.phase.isActive)
        let failed = job(after: ["==> @phase apk:filezilla installing", "ERROR: unable to select packages", "==> FileZilla: FAILED", "==> @phase apk:filezilla failed"], exitCode: 1)
        XCTAssertEqual(failed.phase, .failed("FileZilla: FAILED"))
        let crashed = job(after: ["==> @phase apk:filezilla installing"], exitCode: 137)
        if case .failed = crashed.phase {} else { XCTFail("a non-zero exit without a phase line fails the job") }
    }

    func testOnlyDownloadsCanBeCancelled() {
        XCTAssertTrue(StorePhase.queued.isCancellable)
        XCTAssertTrue(StorePhase.downloading(done: 1, total: 2).isCancellable)
        XCTAssertFalse(StorePhase.installing(step: 1, of: 2).isCancellable)
        XCTAssertFalse(StorePhase.configuring.isCancellable)
    }

    // MARK: Installed state and updates

    private let filezilla = StoreApp(id: "apk:filezilla", kind: "apk", name: "FileZilla", category: "Internet", packages: ["filezilla"])
    private let vlc = StoreApp(id: "multimedia", kind: "pack", name: "VLC", category: "Audio & Video", packages: ["vlc", "vlc-qt", "qt5-qtwayland"])
    private let gimp = StoreApp(id: "image-editor", kind: "pack", name: "GIMP", category: "Graphics", packages: ["gimp", "xwayland"])

    func testInstalledStateUsesWorldForAppsAndPackStates() {
        let state = StoreInstallState(world: ["filezilla", "vlc"], installed: ["filezilla": "3.68.1-r0"], packs: ["multimedia": true, "image-editor": false])
        XCTAssertTrue(state.isInstalled(filezilla))
        XCTAssertTrue(state.isInstalled(vlc))
        XCTAssertFalse(state.isInstalled(gimp))
        XCTAssertEqual(state.installedVersion(filezilla), "3.68.1-r0")
    }

    func testUpdateDetection() {
        let state = StoreInstallState(world: ["filezilla", "vlc"], installed: [:], packs: ["multimedia": true])
        let updates = [
            StorePackageUpdate(name: "filezilla", installed: "3.68.1-r0", available: "3.68.2-r0"),
            StorePackageUpdate(name: "vlc-qt", installed: "3.0.21-r0", available: "3.0.21-r1"),
            StorePackageUpdate(name: "gimp", installed: "2.10.38-r0", available: "2.10.38-r1"),
            StorePackageUpdate(name: "openssl", installed: "3.3.4-r0", available: "3.3.5-r0"),
        ]
        let outdated = StoreUpdates.outdatedApps([filezilla, vlc, gimp], state: state, updates: updates)
        XCTAssertEqual(outdated.map(\.app.id), ["apk:filezilla", "multimedia"], "GIMP is not installed")
        XCTAssertEqual(outdated.first?.update.available, "3.68.2-r0")
        XCTAssertEqual(StoreUpdates.otherPackages([filezilla, vlc, gimp], state: state, updates: updates).map(\.name), ["gimp", "openssl"])
    }

    func testFormatting() {
        XCTAssertEqual(StoreFormat.version("3.68.1-r0"), "3.68.1")
        XCTAssertEqual(StoreFormat.megabytes(1100), "1.1 GB")
        XCTAssertEqual(StoreFormat.megabytes(95), "95 MB")
    }

    // MARK: Model, end to end on the mock guest

    func testModelInstallsThroughTheQueueAndUpdatesState() async throws {
        UserDefaults.standard.set(0.2, forKey: "store.mockInstallSeconds")
        defer { UserDefaults.standard.removeObject(forKey: "store.mockInstallSeconds") }
        let host = MockLinuxHost(latency: .milliseconds(1))
        let model = StoreModel(host: host, index: try index())
        await model.loadState()
        let app = try XCTUnwrap(model.app("apk:filezilla"))
        if model.isInstalled(app) { model.remove(app.id); try await waitUntilIdle(model) }
        XCTAssertFalse(model.isInstalled(app))
        model.install([app.id, "apk:audacity"])
        XCTAssertEqual(model.jobs.map(\.appIDs), [["apk:filezilla"], ["apk:audacity"]], "one job per app, in order")
        try await waitUntilIdle(model)
        XCTAssertTrue(model.isInstalled(app))
        XCTAssertEqual(model.history.first?.phase, .finished)
        XCTAssertTrue(host.commandLog.contains { $0.contains("linpad-apps refresh-icons") }, "icons refresh once after a queue")
        await model.loadPlan("apk:inkscape")
        XCTAssertGreaterThan(model.plans["apk:inkscape"]?.downloadBytes ?? 0, 0)
    }

    private func waitUntilIdle(_ model: StoreModel) async throws {
        for _ in 0..<200 where model.isBusy || model.isRefreshingIcons {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(model.isBusy)
    }
}
