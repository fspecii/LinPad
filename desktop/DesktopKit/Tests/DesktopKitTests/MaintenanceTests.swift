import CryptoKit
import UIKit
import XCTest
@testable import DesktopKit

final class RepairKitVersionTests: XCTestCase {
    func testNumbers() {
        XCTAssertEqual(RepairKitVersion.number("2026100201"), 2026100201)
        XCTAssertEqual(RepairKitVersion.number(" 2026100201\n"), 2026100201)
        for bad in [nil, "", " ", "v1", "2026-10-02", "1.0", "-5", "12a", "０１"] as [String?] {
            XCTAssertNil(RepairKitVersion.number(bad), String(describing: bad))
        }
    }

    func testNewerIsNumericNotLexical() {
        XCTAssertTrue(RepairKitVersion.isNewer("2026100202", than: "2026100201"))
        XCTAssertFalse(RepairKitVersion.isNewer("2026100201", than: "2026100201"))
        XCTAssertFalse(RepairKitVersion.isNewer("2026100201", than: "2026100202"))
        XCTAssertTrue(RepairKitVersion.isNewer("10", than: "9"), "9 < 10 numerically")
        XCTAssertFalse(RepairKitVersion.isNewer("9", than: "10"))
        XCTAssertFalse(RepairKitVersion.isNewer("2026100201", than: "2026100201\n"), "a trailing newline is the same stamp")
    }

    func testMissingOrUnreadableInstalledStampGetsTheKit() {
        // Systems built before the repair kit (the YouTube fix) have no stamp at all.
        XCTAssertTrue(RepairKitVersion.isNewer("2026100201", than: nil))
        XCTAssertTrue(RepairKitVersion.isNewer("2026100201", than: ""))
        XCTAssertTrue(RepairKitVersion.isNewer("2026100201", than: "garbage"))
    }

    func testBadBundledVersionNeverRepairs() {
        XCTAssertFalse(RepairKitVersion.isNewer("", than: nil))
        XCTAssertFalse(RepairKitVersion.isNewer("next", than: "1"))
    }
}

final class RepairKitManifestTests: XCTestCase {
    private func json(version: String = "2026100201", entry: String = "guest/linpad-repair",
                      files: [String] = ["guest/linpad-repair", "guest/gecko-tune.sh", "themes/styles/ish.conf"],
                      sha: String = String(repeating: "a", count: 64), format: Int = 1) -> Data {
        let object: [String: Any] = ["format": format, "version": version, "entry": entry, "archiveSHA256": sha,
                                     "archiveSize": 1234, "files": files]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testDecodesWhatBuildRepairKitWrites() throws {
        let manifest = try RepairKitManifest.decode(json())
        XCTAssertEqual(manifest.version, "2026100201")
        XCTAssertEqual(manifest.entry, "guest/linpad-repair")
        XCTAssertEqual(manifest.archiveSize, 1234)
        XCTAssertEqual(manifest.files.count, 3)
    }

    func testRejectsBadManifests() {
        XCTAssertThrowsError(try RepairKitManifest.decode(json(format: 2))) {
            XCTAssertEqual($0 as? RepairKitManifest.Problem, .unsupportedFormat(2))
        }
        XCTAssertThrowsError(try RepairKitManifest.decode(json(version: "1.2"))) {
            XCTAssertEqual($0 as? RepairKitManifest.Problem, .badVersion("1.2"))
        }
        XCTAssertThrowsError(try RepairKitManifest.decode(json(sha: "xyz"))) {
            XCTAssertEqual($0 as? RepairKitManifest.Problem, .badChecksum)
        }
        XCTAssertThrowsError(try RepairKitManifest.decode(json(entry: "guest/missing"))) {
            XCTAssertEqual($0 as? RepairKitManifest.Problem, .missingEntry("guest/missing"))
        }
        XCTAssertThrowsError(try RepairKitManifest.decode(json(entry: "guest/x; rm -rf /", files: ["guest/x; rm -rf /"]))) {
            XCTAssertEqual($0 as? RepairKitManifest.Problem, .unsafePath("guest/x; rm -rf /"))
        }
        XCTAssertThrowsError(try RepairKitManifest.decode(Data("{}".utf8)))
    }

    func testSafePaths() {
        for good in ["guest/linpad-repair", "themes/styles/ish.conf", "wl-bridge/foot/foot.ini", "omarchy/colors/tokyo-night/colors.toml"] {
            XCTAssertTrue(RepairKitManifest.isSafeRelativePath(good), good)
        }
        for bad in ["", "/etc/passwd", "../x", "guest/../../x", "guest//x", "guest/", "a b", "a$(id)", "a`id`", "a\nb", "a'b"] {
            XCTAssertFalse(RepairKitManifest.isSafeRelativePath(bad), bad)
        }
    }

    func testLoadsAndVerifiesTheArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = Data("pretend this is a tar".utf8)
        let sha = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        try archive.write(to: directory.appendingPathComponent(RepairKit.archiveName))
        let manifest: [String: Any] = ["format": 1, "version": "2026100201", "entry": "guest/linpad-repair",
                                       "archiveSHA256": sha, "archiveSize": archive.count, "files": ["guest/linpad-repair"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent(RepairKit.manifestName))

        let kit = try RepairKit.load(directory: directory)
        XCTAssertEqual(try kit.verifiedArchive(), archive)

        try Data("pretend this is a tar, tampered".utf8).write(to: directory.appendingPathComponent(RepairKit.archiveName))
        XCTAssertThrowsError(try kit.verifiedArchive())
    }

    func testNoKitWithoutResources() {
        XCTAssertThrowsError(try RepairKit.load(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }
}

final class RepairReportTests: XCTestCase {
    func testParsesLinpadRepairOutput() {
        // Output of release/guest/linpad-repair, offline, on a system with the old ish-tune.js.
        let output = """
            linpad-repair: repair kit 2026100201
            @@step Permissions
            @@step Firefox
              updated /usr/lib/firefox-esr/defaults/pref/ish-tune.js
            @@step System files
            @@note Firefox is not installed
            @@step Packages
            @@skipped-packages-offline playerctl ffmpeg-libavcodec
            @@step Caches
            @@result ok changed=12
            """
        var report = RepairReport()
        var plain: [String] = []
        for line in output.split(separator: "\n").map(String.init) where !report.consume(line) {
            plain.append(line)
        }
        XCTAssertEqual(report.steps, ["Permissions", "Firefox", "System files", "Packages", "Caches"])
        XCTAssertEqual(report.notes, ["Firefox is not installed"])
        XCTAssertEqual(report.skippedOffline, ["playerctl", "ffmpeg-libavcodec"])
        XCTAssertEqual(report.changes, 12)
        XCTAssertEqual(report.succeeded, true)
        XCTAssertEqual(plain, ["linpad-repair: repair kit 2026100201", "  updated /usr/lib/firefox-esr/defaults/pref/ish-tune.js"])
        XCTAssertTrue(report.summary.contains("Repaired 12 items."))
        XCTAssertTrue(report.summary.contains("Skipped packages (offline): playerctl, ffmpeg-libavcodec."))
    }

    func testNoOpAndFailure() {
        var noop = RepairReport()
        noop.consume("@@result ok changed=0")
        XCTAssertEqual(noop.changes, 0)
        XCTAssertTrue(noop.summary.hasPrefix("Everything was already in order"))

        var failed = RepairReport()
        failed.consume("@@fail could not write /etc/asound.conf")
        failed.consume("@@installed-packages playerctl")
        failed.consume("@@result failed changed=3")
        XCTAssertEqual(failed.succeeded, false)
        XCTAssertEqual(failed.failures, ["could not write /etc/asound.conf"])
        XCTAssertEqual(failed.installedPackages, ["playerctl"])
        XCTAssertTrue(failed.summary.contains("1 problem"))
        XCTAssertFalse(failed.consume("@@unknown thing"))
        XCTAssertFalse(failed.consume("plain"))
    }

    func testLineSplitterJoinsChunks() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.feed("@@st"), [])
        XCTAssertEqual(splitter.feed("ep Fire"), [])
        XCTAssertEqual(splitter.feed("fox\nline two\nhalf"), ["@@step Firefox", "line two"])
        XCTAssertEqual(splitter.finish(), ["half"])
        XCTAssertEqual(splitter.finish(), [])
    }

    func testResetConfirmation() {
        XCTAssertTrue(FactoryResetSheet.isConfirmed("RESET"))
        XCTAssertTrue(FactoryResetSheet.isConfirmed(" reset \n"))
        for wrong in ["", "RESE", "RESET!", "yes", "R E S E T"] {
            XCTAssertFalse(FactoryResetSheet.isConfirmed(wrong), wrong)
        }
    }
}

/// Answers the service's two guest commands: the unpack (run, with the kit on stdin) and
/// linpad-repair (stream, delivered in awkward chunks).
@MainActor
private final class ScriptedRepairHost: LinuxHost, LinuxSystemResetting {
    let hostName = "test"
    let homeDirectory = "/root"
    var installedVersion: String?
    var repairOutput = ""
    var repairStatus: Int32 = 0
    private(set) var runs: [(command: String, stdin: Data?)] = []
    private(set) var streams: [String] = []
    private(set) var scheduledFactoryReset: FactoryResetMode?
    private(set) var quitCount = 0

    func run(_ command: String, cwd: String?, stdin: Data?) async -> CommandResult {
        runs.append((command, stdin))
        if command.hasPrefix("cat \(RepairKit.installedVersionPath)") {
            return CommandResult(stdout: installedVersion.map { $0 + "\n" } ?? "", exitCode: installedVersion == nil ? 1 : 0)
        }
        return CommandResult(stdout: "")
    }

    func stream(_ command: String, cwd: String?, onOutput: @escaping @MainActor (String) -> Void) async -> Int32 {
        streams.append(command)
        var rest = Substring(repairOutput)
        while !rest.isEmpty {
            let chunk = rest.prefix(7)
            onOutput(String(chunk))
            rest = rest.dropFirst(chunk.count)
        }
        if repairStatus == 0, let version = repairOutput.contains("@@result ok") ? "2026100201" : nil {
            installedVersion = version
        }
        return repairStatus
    }

    func makeTerminalViewController(command: String?, cwd: String?) -> UIViewController { UIViewController() }

    func scheduleFactoryReset(_ mode: FactoryResetMode) { scheduledFactoryReset = mode }
    func cancelFactoryReset() { scheduledFactoryReset = nil }
    func quitToApplyFactoryReset() { quitCount += 1 }
}

@MainActor
final class SystemMaintenanceServiceTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeKit(version: String = "2026100201") throws -> RepairKit {
        let archive = Data("kit".utf8)
        try archive.write(to: directory.appendingPathComponent(RepairKit.archiveName))
        let sha = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        let manifest: [String: Any] = ["format": 1, "version": version, "entry": "guest/linpad-repair",
                                       "archiveSHA256": sha, "archiveSize": archive.count, "files": ["guest/linpad-repair"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent(RepairKit.manifestName))
        return try RepairKit.load(directory: directory)
    }

    private func defaults() -> UserDefaults {
        let suite = "maintenance-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func testManualRepairUnpacksRunsAndRestartsWhenSomethingChanged() async throws {
        let host = ScriptedRepairHost()
        host.repairOutput = "@@step Firefox\n  updated ish-tune.js\n@@result ok changed=1\n"
        let service = SystemMaintenanceService(host: host, kit: try makeKit(), defaults: defaults())
        var restarts = 0
        service.restartSession = { restarts += 1 }

        await service.repair(automatic: false)

        let unpack = try XCTUnwrap(host.runs.first { $0.command.contains("tar -xf -") })
        XCTAssertEqual(unpack.stdin, Data("kit".utf8))
        XCTAssertEqual(host.streams.count, 1)
        XCTAssertTrue(host.streams[0].contains("sh /tmp/linpad-repair-kit/guest/linpad-repair 2>&1"))
        XCTAssertFalse(host.streams[0].contains("--quick"))
        XCTAssertEqual(service.state, .finished(automatic: false))
        XCTAssertEqual(service.report.succeeded, true)
        XCTAssertEqual(service.report.changes, 1)
        XCTAssertTrue(service.log.contains("  updated ish-tune.js"))
        XCTAssertEqual(restarts, 1)
        XCTAssertEqual(service.installedKitVersion, "2026100201")
    }

    func testNoOpRepairDoesNotRestartTheSession() async throws {
        let host = ScriptedRepairHost()
        host.repairOutput = "@@step Firefox\n@@result ok changed=0\n"
        let service = SystemMaintenanceService(host: host, kit: try makeKit(), defaults: defaults())
        var restarts = 0
        service.restartSession = { restarts += 1 }
        await service.repair(automatic: false)
        XCTAssertEqual(restarts, 0)
    }

    func testScriptDyingWithoutResultIsAFailure() async throws {
        let host = ScriptedRepairHost()
        host.repairOutput = "@@step Firefox\nKilled\n"
        host.repairStatus = 137
        let service = SystemMaintenanceService(host: host, kit: try makeKit(), defaults: defaults())
        await service.repair(automatic: false)
        XCTAssertEqual(service.report.succeeded, false)
        XCTAssertEqual(service.report.failures, ["linpad-repair exited with status 137"])
    }

    func testAutomaticRepairRunsOnceForANewerKitQuietly() async throws {
        let host = ScriptedRepairHost()
        host.installedVersion = nil
        host.repairOutput = "@@result ok changed=2\n"
        let service = SystemMaintenanceService(host: host, kit: try makeKit(), defaults: defaults())
        var toasts: [String] = []
        var restarts = 0
        service.notify = { message, _ in toasts.append(message) }
        service.restartSession = { restarts += 1 }

        await service.runAutomaticRepairIfNeeded()
        XCTAssertEqual(host.streams.count, 1)
        XCTAssertTrue(host.streams[0].contains("--quick"))
        XCTAssertEqual(restarts, 0, "the silent repair never closes the user's apps")
        XCTAssertEqual(toasts.count, 1)

        await service.runAutomaticRepairIfNeeded()
        XCTAssertEqual(host.streams.count, 1, "once per launch")
    }

    func testAutomaticRepairSkipsWhenTheGuestIsCurrent() async throws {
        let host = ScriptedRepairHost()
        host.installedVersion = "2026100201"
        let service = SystemMaintenanceService(host: host, kit: try makeKit(version: "2026100201"), defaults: defaults())
        await service.runAutomaticRepairIfNeeded()
        XCTAssertEqual(host.streams.count, 0)
        XCTAssertEqual(service.state, .idle)
    }

    func testSettingsAppRequestRepairsVisiblyAndClearsTheRequest() async throws {
        let host = ScriptedRepairHost()
        host.installedVersion = "2026100201"
        host.repairOutput = "@@result ok changed=0\n"
        let store = defaults()
        store.set(true, forKey: SystemMaintenanceService.Keys.repairAtLaunch)
        let service = SystemMaintenanceService(host: host, kit: try makeKit(), defaults: store)
        var shown = 0
        service.showSettings = { shown += 1 }
        await service.runAutomaticRepairIfNeeded()
        XCTAssertEqual(host.streams.count, 1)
        XCTAssertFalse(host.streams[0].contains("--quick"))
        XCTAssertTrue(service.isRepairSheetRequested)
        XCTAssertEqual(shown, 1)
        XCTAssertFalse(store.bool(forKey: SystemMaintenanceService.Keys.repairAtLaunch))
    }

    func testDamagedKitIsNotSentToTheGuest() async throws {
        let host = ScriptedRepairHost()
        let kit = try makeKit()
        try Data("tampered".utf8).write(to: kit.archive)
        let service = SystemMaintenanceService(host: host, kit: kit, defaults: defaults())
        await service.repair(automatic: false)
        guard case .failed = service.state else { return XCTFail("expected failure, got \(service.state)") }
        XCTAssertTrue(host.runs.isEmpty)
        XCTAssertTrue(host.streams.isEmpty)
    }

    func testFactoryResetSchedulesThenQuits() throws {
        let host = ScriptedRepairHost()
        let service = SystemMaintenanceService(host: host, kit: nil, defaults: defaults())
        service.resetToFactory(.keepFiles)
        XCTAssertEqual(host.scheduledFactoryReset, .keepFiles)
        XCTAssertEqual(host.quitCount, 1)
        XCTAssertEqual(FactoryResetMode.keepFiles.rawValue, "keep-files", "app/Roots.m RootsFactoryResetKeepFiles")
        XCTAssertEqual(FactoryResetMode.eraseEverything.rawValue, "erase", "app/Roots.m RootsFactoryResetErase")
    }
}
