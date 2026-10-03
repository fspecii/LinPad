import UIKit
import XCTest
@testable import DesktopKit

// MARK: - Manifest

final class BackupManifestTests: XCTestCase {
    static func manifest(packages: [String] = ["firefox-esr", "mesa-gl=26.2.3-r1", "so:libc.musl-aarch64.so.1"],
                         packs: [String] = ["vscode", "apk:gimp"], files: [String] = ["Wallpapers/a b.jpg", "Calendar/events.json"],
                         format: Int = 1, paths: [String] = ["/root", "/home"]) -> BackupManifest {
        var manifest = BackupManifest(
            createdAt: Date(timeIntervalSince1970: 1_791_000_000), appVersion: "1.4.0", appBuild: "77",
            rootfsVersion: "202610021759", repairKitVersion: "2026100201",
            excludedCategories: [.caches, .nodeModules], compression: .zstd, contentBytes: 123_456, fileCount: 42,
            packages: packages, appPacks: packs, iPadFolders: ["/root/iPad"], desktopFiles: files, hasDesktopSettings: true)
        manifest.format = format
        manifest.paths = paths
        return manifest
    }

    func testRoundTrip() throws {
        let manifest = Self.manifest()
        let decoded = try BackupManifest.decode(manifest.encoded())
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.compression.payloadName, "linux.tar.zst")
        XCTAssertEqual(BackupManifest.Compression.gzip.payloadName, "linux.tar.gz")
    }

    func testRejectsNewerFormatAndUnsafeValues() throws {
        XCTAssertThrowsError(try BackupManifest.decode(Self.manifest(format: 2).encoded())) {
            XCTAssertEqual($0 as? BackupManifest.Problem, .newerFormat(2))
        }
        for bad in ["x; rm -rf /", "-f", "a b", "$(id)", "`id`", "", "pkg\nother"] {
            XCTAssertThrowsError(try BackupManifest.decode(Self.manifest(packages: [bad]).encoded()), bad)
            XCTAssertThrowsError(try BackupManifest.decode(Self.manifest(packs: [bad]).encoded()), bad)
        }
        for bad in ["../x", "/etc/passwd", "Wallpapers/../../x", "a//b", "./a", ""] {
            XCTAssertThrowsError(try BackupManifest.decode(Self.manifest(files: [bad]).encoded()), bad)
        }
        XCTAssertThrowsError(try BackupManifest.decode(Self.manifest(paths: ["/etc"]).encoded()))
        XCTAssertThrowsError(try BackupManifest.decode(Data("{}".utf8)))
    }

    func testSafePackages() {
        for good in ["firefox-esr", "mesa-gl=26.2.3-r1", "so:libc.musl-aarch64.so.1", "apk:gimp", "py3-pip", "gtk+3.0-demo", "font-noto>=1"] {
            XCTAssertTrue(BackupManifest.isSafePackage(good), good)
        }
    }
}

// MARK: - Exclusions

final class BackupExclusionTests: XCTestCase {
    func testCategories() {
        let cases: [(String, BackupExclusionCategory?)] = [
            ("root/.cache", .caches),
            ("home/ana/.cache", .caches),
            ("root/.npm/_cacache", .caches),
            ("root/.mozilla/firefox/abc.default-release/cache2", .caches),
            ("home/ana/.mozilla/firefox/x/startupCache", .caches),
            ("root/.config/Code/CachedData", .editorCaches),
            ("root/.config/Code/Code Cache", .editorCaches),
            ("home/ana/.config/Code - OSS/GPUCache", .editorCaches),
            ("root/.config/Code/logs", .editorCaches),
            ("root/projects/app/node_modules", .nodeModules),
            ("home/ana/node_modules", .nodeModules),
            ("root/node_modules", .nodeModules),
            // user data that merely looks like a cache
            ("root/projects/app/.cache", nil),
            ("root/.cache/x", nil),
            ("root/.config/Code/User", nil),
            ("root/.config/Other/Cache", nil),
            ("root/Documents/logs", nil),
            ("home/.cache", nil),
            ("root", nil),
            ("etc/.cache", nil),
            ("usr/lib/node_modules", nil),
            ("root/.mozilla/firefox/x/prefs.js", nil),
        ]
        for (path, expected) in cases {
            XCTAssertEqual(BackupExclusionCategory.category(of: path), expected, path)
        }
    }

    func testScanPrimariesCoverEveryCategory() {
        XCTAssertTrue(BackupExclusionCategory.scanPrimaries.contains("name:.cache"))
        XCTAssertTrue(BackupExclusionCategory.scanPrimaries.contains("name:node_modules"))
        XCTAssertTrue(BackupExclusionCategory.scanPrimaries.contains("path:*/.config/Code/CachedData"))
        XCTAssertTrue(BackupExclusionCategory.scanPrimaries.allSatisfy { $0.hasPrefix("name:") || $0.hasPrefix("path:") })
    }

    func testFnmatchEscaping() {
        XCTAssertEqual(BackupExclusionList.fnmatchEscaped("root/a*b?[c]\\d"), "root/a\\*b\\?\\[c\\]\\\\d")
        XCTAssertEqual(BackupExclusionList.fnmatchEscaped("root/Code Cache"), "root/Code Cache")
    }

    func testRelativeGuestPaths() {
        XCTAssertEqual(BackupExclusionList.relativeGuestPath("/root/iPad"), "root/iPad")
        XCTAssertEqual(BackupExclusionList.relativeGuestPath("/home/ana/Docs/"), "home/ana/Docs")
        XCTAssertNil(BackupExclusionList.relativeGuestPath("/mnt/ipad"))
        XCTAssertNil(BackupExclusionList.relativeGuestPath("/rootfs"))
    }

    func testListHonoursChoicesAndAlwaysSkipsIPadFolders() {
        let scan = BackupScan.parse("""
        @@total 1000
        @@candidate 100\troot/.cache
        @@candidate 300\troot/p/node_modules
        @@candidate 50\troot/p/.cache
        @@candidate 20\troot/.config/Code/logs
        noise
        """)
        XCTAssertEqual(scan.totalKilobytes, 1000)
        XCTAssertEqual(scan.candidates.count, 3, "root/p/.cache is not a cache folder")
        XCTAssertEqual(scan.kilobytes(of: .nodeModules), 300)
        XCTAssertEqual(scan.includedBytes(excluding: [.caches]), 900 * 1024)
        XCTAssertEqual(scan.includedBytes(excluding: Set(BackupExclusionCategory.allCases)), 580 * 1024)
        XCTAssertEqual(scan.includedBytes(excluding: []), 1000 * 1024)

        let lines = BackupExclusionList.lines(candidates: scan.candidates, excluding: [.caches],
                                              mountPoints: ["/root/iPad [work]", "/mnt/elsewhere", "/root"])
        XCTAssertEqual(lines, ["root/.cache", "root/iPad \\[work\\]"])
        let all = BackupExclusionList.lines(candidates: scan.candidates, excluding: Set(BackupExclusionCategory.allCases), mountPoints: [])
        XCTAssertEqual(all, ["root/.cache", "root/.config/Code/logs", "root/p/node_modules"])
    }

    func testIncludedBytesNeverNegative() {
        let scan = BackupScan(totalKilobytes: 10, candidates: [.init(path: "root/.cache", kilobytes: 50, category: .caches)])
        XCTAssertEqual(scan.includedBytes(excluding: [.caches]), 0)
    }
}

// MARK: - Guest output and plans

final class BackupGuestOutputTests: XCTestCase {
    func testFacts() {
        let facts = BackupGuestFacts.parse("""
        @@rootfs 202610021759
        @@kit
        @@zstd yes
        @@world bash
        @@world mesa-gl=26.2.3-r1
        @@world bad;name
        @@state {"world":["bash"],"packs":{"vscode":true,"wine":false,"x;y":true}}
        """)
        XCTAssertEqual(facts.rootfsVersion, "202610021759")
        XCTAssertNil(facts.repairKitVersion)
        XCTAssertTrue(facts.hasZstd)
        XCTAssertEqual(facts.world, ["bash", "mesa-gl=26.2.3-r1"])
        XCTAssertEqual(facts.installedPacks, ["vscode"])
        XCTAssertFalse(BackupGuestFacts.parse("@@zstd no").hasZstd)
    }

    func testReport() {
        var report = GuestReport()
        for line in ["@@files 3", "@@warn tar: can't open 'root/x': Permission denied", "@@aside /var/lib/linpad/before-restore-1", "@@done"] {
            report.consume(line)
        }
        XCTAssertTrue(report.done)
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertEqual(report.aside, "/var/lib/linpad/before-restore-1")
        var failed = GuestReport()
        failed.consume("@@fail Compressing the backup stopped (status 1).")
        XCTAssertFalse(failed.done)
        XCTAssertEqual(failed.failure, "Compressing the backup stopped (status 1).")
        var cancelled = GuestReport()
        cancelled.consume("@@cancelled")
        XCTAssertTrue(cancelled.cancelled)
    }

    func testReinstallPlanComparesNamesNotPins() {
        let missing = BackupReinstallPlan.missingPackages(
            backup: ["bash", "gimp", "mesa-gl=26.2.3-r1", "gimp", "htop>=3"],
            current: ["bash", "mesa-gl=26.2.4-r0"])
        XCTAssertEqual(missing, ["gimp", "htop>=3"])
        XCTAssertEqual(BackupReinstallPlan.missingPacks(backup: ["vscode", "wine"], current: ["wine"]), ["vscode"])
    }

    func testInvocationQuotesArguments() {
        let script = BackupGuestScript.invocation(["list", "/var/tmp/linpad-backup/a b", "it's"])
        XCTAssertTrue(script.hasPrefix("set -- 'list' '/var/tmp/linpad-backup/a b' 'it'\\''s'\n"), script)
        XCTAssertTrue(script.contains("case $command in"))
        XCTAssertFalse(BackupGuestScript.source.contains("\\#("), "no Swift interpolation in the guest script")
    }

    func testNameProgressCountsIncrementally() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let progress = NameProgress(url: url, total: 4)
        XCTAssertEqual(progress.poll(), 0, "no file yet")
        try Data("root/\nroot/a\n".utf8).write(to: url)
        XCTAssertEqual(progress.poll(), 2)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("root/b\nroot/c\nroot/d\n".utf8))
        try handle.close()
        XCTAssertEqual(progress.poll(), 5)
        XCTAssertEqual(progress.fraction, 1, "capped")
    }
}

// MARK: - Schedule and files

final class BackupScheduleTests: XCTestCase {
    func testDue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(BackupSchedule.off.isDue(lastBackup: nil, now: now))
        XCTAssertTrue(BackupSchedule.weekly.isDue(lastBackup: nil, now: now))
        XCTAssertFalse(BackupSchedule.weekly.isDue(lastBackup: now.addingTimeInterval(-6 * 86400), now: now))
        XCTAssertTrue(BackupSchedule.weekly.isDue(lastBackup: now.addingTimeInterval(-7 * 86400 + 1800), now: now), "an hour of slack")
        XCTAssertTrue(BackupSchedule.daily.isDue(lastBackup: now.addingTimeInterval(-86400), now: now))
        XCTAssertFalse(BackupSchedule.daily.isDue(lastBackup: now.addingTimeInterval(-3600 * 20), now: now))
    }

    func testNamesAndRotation() {
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(BackupFiles.fileName(for: date, automatic: false, timeZone: utc), "linpad-backup-2026-10-03-040000.tar")
        let auto = BackupFiles.fileName(for: date, automatic: true, timeZone: utc)
        XCTAssertEqual(auto, "linpad-backup-auto-2026-10-03-040000.tar")
        XCTAssertTrue(BackupFiles.isAutomatic(auto))
        XCTAssertFalse(BackupFiles.isBackup("notes.txt"))
        let names = ["linpad-backup-auto-2026-10-01-000000.tar", "linpad-backup-auto-2026-10-03-000000.tar",
                     "linpad-backup-2026-09-01-000000.tar", "linpad-backup-auto-2026-10-02-000000.tar", "other.tar"]
        XCTAssertEqual(BackupFiles.automaticBackupsToDelete(names, keep: 2), ["linpad-backup-auto-2026-10-01-000000.tar"])
        XCTAssertEqual(BackupFiles.automaticBackupsToDelete(names, keep: 0).count, 2, "keeps at least one")
        XCTAssertEqual(BackupFiles.automaticBackupsToDelete(names, keep: 5), [])
    }
}

// MARK: - Archive

final class BackupArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testHeaderIsValidUstar() throws {
        let header = [UInt8](try BackupArchive.header(name: "manifest.json", size: 1234, mtime: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertEqual(header.count, 512)
        XCTAssertEqual(String(decoding: header[0..<13], as: UTF8.self), "manifest.json")
        XCTAssertEqual(String(decoding: header[124..<135], as: UTF8.self), "00000002322", "1234 in octal")
        XCTAssertEqual(String(decoding: header[257..<262], as: UTF8.self), "ustar")
        let sum = header.enumerated().reduce(0) { $0 + ((148..<156).contains($1.offset) ? 32 : Int($1.element)) }
        XCTAssertEqual(Int(String(decoding: header[148..<154], as: UTF8.self), radix: 8), sum)
        let parsed = try XCTUnwrap(BackupArchive.parseHeader(Data(header)))
        XCTAssertEqual(parsed.name, "manifest.json")
        XCTAssertEqual(parsed.size, 1234)
    }

    func testLongNamesAndHugeSizes() throws {
        let long = "desktop/files/Wallpapers/" + String(repeating: "a", count: 90) + "/" + String(repeating: "b", count: 80) + ".jpg"
        let parsed = try XCTUnwrap(BackupArchive.parseHeader(BackupArchive.header(name: long, size: 9 << 30)))
        XCTAssertEqual(parsed.name, long)
        XCTAssertEqual(parsed.size, 9 << 30, "base-256 size above 8 GiB")
        XCTAssertThrowsError(try BackupArchive.header(name: String(repeating: "x", count: 120), size: 0))
        XCTAssertThrowsError(try BackupArchive.header(name: String(repeating: "x/", count: 140), size: 0))
    }

    /// The service's own sequence: host members, a reserved header, an appended payload, finish.
    func testWriterRoundTrip() throws {
        let url = directory.appendingPathComponent("b.tar")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let manifest = BackupManifestTests.manifest()
        let writer = try BackupArchiveWriter(url: url)
        try writer.add(name: BackupManifest.memberName, data: manifest.encoded())
        try writer.add(name: BackupArchive.settingsMember, data: Data("plist".utf8))
        try writer.reservePayloadHeader()
        let offset = try XCTUnwrap(writer.payloadHeaderOffset)
        try writer.close()
        let payload = Data((0..<5000).map { UInt8($0 % 251) })
        let append = try FileHandle(forWritingTo: url)
        try append.seekToEnd()
        try append.write(contentsOf: payload)
        try append.close()
        let size = try BackupArchiveWriter.finish(url: url, payloadName: "linux.tar.zst", headerOffset: offset)
        XCTAssertEqual(size, 5000)

        let contents = try BackupArchive.contents(of: url)
        XCTAssertEqual(contents.manifest, manifest)
        XCTAssertEqual(contents.members.map(\.name), ["manifest.json", "desktop/settings.plist", "linux.tar.zst"])
        XCTAssertEqual(try BackupArchive.read(contents.payload, from: url), payload)
        XCTAssertEqual(contents.payload.offset % 512, 0)
        XCTAssertEqual(contents.fileSize % 512, 0)
    }

    func testRejectsOtherFiles() throws {
        let random = directory.appendingPathComponent("random.tar")
        try Data((0..<4096).map { _ in UInt8.random(in: 1...255) }).write(to: random)
        XCTAssertThrowsError(try BackupArchive.contents(of: random)) {
            XCTAssertEqual($0 as? BackupArchive.Problem, .notABackup)
        }
        let otherTar = directory.appendingPathComponent("other.tar")
        var data = try BackupArchive.header(name: "hello.txt", size: 2)
        data.append(Data("hi".utf8) + Data(count: 510 + 1024))
        try data.write(to: otherTar)
        XCTAssertThrowsError(try BackupArchive.contents(of: otherTar)) {
            XCTAssertEqual($0 as? BackupArchive.Problem, .notABackup)
        }
    }

    func testTruncatedBackupIsDamaged() throws {
        let url = directory.appendingPathComponent("cut.tar")
        var data = try BackupArchive.header(name: BackupManifest.memberName, size: 4000)
        data.append(Data(count: 100))
        try data.write(to: url)
        XCTAssertThrowsError(try BackupArchive.contents(of: url)) {
            guard case .damaged = $0 as? BackupArchive.Problem else { return XCTFail("\($0)") }
        }
    }
}

// MARK: - Service against a simulated guest

/// Plays the guest's side of the backup script on a temporary directory standing in for
/// the fakefs: "/var/tmp/..." lives under `root`.
@MainActor
private final class FakeBackupGuest: LinuxGraphicsHost {
    let hostName = "test"
    let homeDirectory = "/root"
    let root: URL
    let payload = Data((0..<20_000).map { UInt8($0 % 241) })
    var world = ["bash", "gimp"]
    var state = #"{"packs":{"vscode":true}}"#
    private(set) var restoreArguments: [String] = []
    private(set) var reinstallCommands: [String] = []
    private(set) var reinstallStdin: [String] = []
    var guestRootURL: URL? { root }

    init(root: URL) { self.root = root }

    private func host(_ guestPath: String) -> URL { BackupService.hostURL(root: root, guestPath: guestPath) }

    private func arguments(_ command: String) -> [String] {
        guard command.hasPrefix("set -- ") else { return [] }
        let line = command.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return line.dropFirst("set -- ".count).components(separatedBy: "' '").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
    }

    func run(_ command: String, cwd: String?, stdin: Data?) async -> CommandResult {
        if command.hasPrefix("rm -rf "), command.contains("mkdir -p") {
            let work = String(command.split(separator: "'")[1])
            try? FileManager.default.createDirectory(at: host(work), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: host(work + "/backup.tar").path, contents: Data())
            FileManager.default.createFile(atPath: host(work + "/excludes").path, contents: Data())
            return CommandResult(stdout: "")
        }
        if command.hasPrefix("mkdir -p /etc/ish") {
            reinstallStdin.append(String(decoding: stdin ?? Data(), as: UTF8.self))
            return CommandResult(stdout: "")
        }
        let args = arguments(command)
        switch args.first {
        case "scan":
            return CommandResult(stdout: "@@total 2048\n@@candidate 1024\troot/.cache\n@@candidate 512\troot/p/node_modules\n")
        case "facts":
            return CommandResult(stdout: (["@@rootfs 202610021759", "@@zstd yes"] + world.map { "@@world " + $0 } + ["@@state " + state]).joined(separator: "\n"))
        case "list":
            return CommandResult(stdout: "@@files 3\n")
        default:
            return CommandResult(stdout: "")
        }
    }

    func stream(_ command: String, cwd: String?, onOutput: @escaping @MainActor (String) -> Void) async -> Int32 {
        if command.hasPrefix("linpad-apps install") {
            reinstallCommands.append(command)
            onOutput("==> installing\n")
            return 0
        }
        let args = arguments(command)
        switch args.first {
        case "archive":
            let work = args[1]
            let handle = try! FileHandle(forWritingTo: host(work + "/backup.tar"))
            try! handle.seekToEnd()
            try! handle.write(contentsOf: payload)
            try! handle.close()
            try! Data("root/\nroot/a\nroot/b\n".utf8).write(to: host(work + "/names"))
            onOutput("@@warn tar: can't open 'root/locked': Permission denied\n@@do")
            onOutput("ne\n")
            return 0
        case "restore":
            restoreArguments = args
            try! Data("root/\nroot/a\nroot/b\n".utf8).write(to: host(args[6] + "/names"))
            onOutput("@@done\n")
            return 0
        default:
            return 1
        }
    }

    func makeTerminalViewController(command: String?, cwd: String?) -> UIViewController { UIViewController() }
}

@MainActor
final class BackupServiceTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "backup-tests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeService(_ guest: FakeBackupGuest) -> BackupService {
        BackupService(host: guest, defaults: defaults, backupsDirectory: directory.appendingPathComponent("Backups"),
                      supportDirectory: directory.appendingPathComponent("Support"), guestRoot: { guest.root },
                      now: { Date(timeIntervalSince1970: 1_791_000_000) })
    }

    func testBackUpThenRestore() async throws {
        let guest = FakeBackupGuest(root: directory.appendingPathComponent("fakefs"))
        let support = directory.appendingPathComponent("Support/Wallpapers")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(to: support.appendingPathComponent("my wall.jpg"))
        defaults.set("aurora", forKey: "desktop.style")
        defaults.set("{}", forKey: "desktop.session")
        let service = makeService(guest)
        XCTAssertEqual(service.schedule, .weekly)
        XCTAssertEqual(service.excluded, BackupExclusionCategory.defaultExcluded)

        await service.refreshScan()
        XCTAssertEqual(service.state, .ready)
        XCTAssertEqual(service.scan?.includedBytes(excluding: service.excluded), 512 * 1024)

        let made = await service.backUp()
        let record = try XCTUnwrap(made)
        guard case .finished(_, let warnings) = service.state else { return XCTFail("\(service.state)") }
        XCTAssertEqual(warnings, ["tar: can't open 'root/locked': Permission denied"])
        XCTAssertEqual(record.name, BackupFiles.fileName(for: Date(timeIntervalSince1970: 1_791_000_000), automatic: false))
        XCTAssertNotNil(service.lastBackup)
        XCTAssertEqual(service.backups.count, 1)

        let contents = try BackupArchive.contents(of: record.url)
        XCTAssertEqual(contents.manifest.fileCount, 3)
        XCTAssertEqual(contents.manifest.packages, ["bash", "gimp"])
        XCTAssertEqual(contents.manifest.appPacks, ["vscode"])
        XCTAssertEqual(contents.manifest.desktopFiles, ["Wallpapers/my wall.jpg"])
        XCTAssertTrue(contents.manifest.hasDesktopSettings)
        XCTAssertEqual(try BackupArchive.read(contents.payload, from: record.url), guest.payload)

        // The settings member holds the desktop's look but not the window layout.
        let settingsMember = try XCTUnwrap(contents.members.first { $0.name == BackupArchive.settingsMember })
        let settings = try XCTUnwrap(PropertyListSerialization.propertyList(from: BackupArchive.read(settingsMember, from: record.url), format: nil) as? [String: Any])
        XCTAssertEqual(settings["desktop.style"] as? String, "aurora")
        XCTAssertNil(settings["desktop.session"])

        // Restore on a "new iPad": no wallpaper, other style, gimp and vscode missing.
        try FileManager.default.removeItem(at: support)
        defaults.set("plain", forKey: "desktop.style")
        guest.world = ["bash"]
        guest.state = #"{"packs":{"vscode":false}}"#
        service.inspect(record.url)
        guard case .inspected = service.restoreState else { return XCTFail("\(service.restoreState)") }
        await service.restore(from: record.url, options: .init(mode: .replace, reinstallApps: true, restoreDesktopSettings: true))
        guard case .finished(let summary) = service.restoreState else { return XCTFail("\(service.restoreState)") }
        XCTAssertEqual(guest.restoreArguments[2], String(contents.payload.offset))
        XCTAssertEqual(guest.restoreArguments[3], String(contents.payload.size))
        XCTAssertEqual(guest.restoreArguments[4], "zstd")
        XCTAssertEqual(guest.restoreArguments[5], "replace")
        XCTAssertEqual(summary.restoredFiles, 3)
        XCTAssertTrue(summary.settingsRestored)
        XCTAssertEqual(defaults.string(forKey: "desktop.style"), "aurora")
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("my wall.jpg"), encoding: .utf8), "jpeg")
        XCTAssertEqual(guest.reinstallStdin, ["gimp\n"])
        XCTAssertEqual(guest.reinstallCommands, ["linpad-apps install 'vscode' 'reinstall' 2>&1"])
        XCTAssertEqual(summary.reinstalled, ["vscode", "gimp"])
        XCTAssertEqual(summary.iPadFolders, [])
    }

    func testRotationKeepsManualBackups() async throws {
        let guest = FakeBackupGuest(root: directory.appendingPathComponent("fakefs"))
        let service = makeService(guest)
        service.keep = 1
        let backups = directory.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        for name in ["linpad-backup-auto-2026-01-01-000000.tar", "linpad-backup-2026-01-02-000000.tar"] {
            FileManager.default.createFile(atPath: backups.appendingPathComponent(name).path, contents: Data())
        }
        _ = await service.backUp(automatic: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
        XCTAssertEqual(names, ["linpad-backup-2026-01-02-000000.tar",
                               BackupFiles.fileName(for: Date(timeIntervalSince1970: 1_791_000_000), automatic: true)])
        XCTAssertEqual(defaults.integer(forKey: BackupService.Keys.keep), 1)
    }

    func testFailsCleanlyWithoutLinux() async {
        let guest = FakeBackupGuest(root: directory)
        let service = BackupService(host: guest, defaults: defaults, backupsDirectory: directory, guestRoot: { nil })
        XCTAssertFalse(service.isAvailable)
        let record = await service.backUp()
        XCTAssertNil(record)
        guard case .failed = service.state else { return XCTFail("\(service.state)") }
    }
}

// MARK: - Diagnostics

final class DiagnosticsRedactorTests: XCTestCase {
    private let redactor = DiagnosticsRedactor(userNames: ["ana"], deviceNames: ["Ana's iPad", "anaspad"],
                                               iPadFolders: ["/root/iPad Work"])

    func testHomePaths() {
        XCTAssertEqual(redactor.redact("open /root/projects/secret-plan/main.c failed"), "open /root/<redacted> failed")
        XCTAssertEqual(redactor.redact("/root/.mozilla/firefox/x.default/prefs.js"), "/root/.mozilla/<redacted>")
        XCTAssertEqual(redactor.redact("cwd=/root"), "cwd=/root")
        XCTAssertEqual(redactor.redact("/home/bob/Documents/taxes.pdf"), "/home/<user>/<redacted>")
        XCTAssertEqual(redactor.redact("/home/bob/.config"), "/home/<user>/.config")
        XCTAssertEqual(redactor.redact("'/root/a b.txt'"), "'/root/<redacted> b.txt'", "stops at whitespace, the rest is a word")
    }

    func testSystemPathsStay() {
        for text in ["/usr/share/ish/rootfs-version", "/etc/apk/world", "/proc/meminfo", "1234(firefox-esr) stub syscall 435",
                     "/usr/lib/node_modules/npm", "NETDIAG sock_wait(pid=12 comm=node fd=3)"] {
            XCTAssertEqual(redactor.redact(text), text)
        }
    }

    func testNamesMailAndFolders() {
        XCTAssertEqual(redactor.redact("host Ana's iPad (ANASPAD)"), "host <name> (<name>)")
        XCTAssertEqual(redactor.redact("user ana logged in"), "user <name> logged in")
        XCTAssertEqual(redactor.redact("banana"), "banana", "whole words only")
        XCTAssertEqual(redactor.redact("mail me: ana.p+x@example.co.uk."), "mail me: <email>.")
        XCTAssertEqual(redactor.redact("mounted /root/iPad Work/Notes"), "mounted <ipad-folder>/Notes")
        XCTAssertEqual(redactor.redact("/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/x.txt"), "<icloud-path>")
        XCTAssertEqual(redactor.redact("/Users/valentin/Library/x"), "/Users/<user>/Library/x")
    }

    func testUsersFromPasswd() {
        let passwd = """
        root:x:0:0:root:/root:/bin/ash
        nobody:x:65534:65534:nobody:/:/sbin/nologin
        ana:x:1000:1000:Ana:/home/ana:/bin/bash
        build:x:1001:1001::/home/build:/bin/sh
        """
        XCTAssertEqual(DiagnosticsRedactor.userNames(fromPasswd: passwd), ["ana", "build"])
    }
}

final class WatchdogThresholdTests: XCTestCase {
    func testMainThreadStall() {
        var detector = MainThreadStallDetector()
        XCTAssertNil(detector.tick(now: 0, pendingSince: nil))
        XCTAssertNil(detector.tick(now: 0.25, pendingSince: 0.25))
        XCTAssertNil(detector.tick(now: 1.25, pendingSince: 0.25))
        XCTAssertNil(detector.tick(now: 2.0, pendingSince: 0.25), "1.75 s is under the 2 s threshold")
        XCTAssertEqual(detector.tick(now: 2.5, pendingSince: 0.25), .stalled(duration: 2.25))
        XCTAssertNil(detector.tick(now: 3.5, pendingSince: 0.25), "reported once")
        XCTAssertEqual(detector.tick(now: 4.0, pendingSince: nil), .recovered(duration: 3.75))
        XCTAssertNil(detector.tick(now: 4.25, pendingSince: nil))
    }

    func testShortHiccupsAreNotStalls() {
        var detector = MainThreadStallDetector()
        var time = 0.0
        for _ in 0..<100 {
            XCTAssertNil(detector.tick(now: time, pendingSince: time - 0.2))
            time += 0.25
        }
    }

    func testSuspensionIsNotAStall() {
        var detector = MainThreadStallDetector()
        XCTAssertNil(detector.tick(now: 0, pendingSince: 0))
        XCTAssertNil(detector.tick(now: 60, pendingSince: 0), "the watchdog thread itself was not scheduled")
        XCTAssertNil(detector.tick(now: 60.25, pendingSince: nil))
    }

    func testGuestHeartbeat() {
        var monitor = GuestHeartbeatMonitor()
        XCTAssertNil(monitor.record(answered: true))
        XCTAssertNil(monitor.record(answered: false), "one slow answer is not a wedge")
        XCTAssertNil(monitor.record(answered: true))
        XCTAssertNil(monitor.record(answered: false))
        XCTAssertEqual(monitor.record(answered: false), .wedged)
        XCTAssertNil(monitor.record(answered: false), "reported once")
        XCTAssertEqual(monitor.record(answered: true), .recovered)
        XCTAssertNil(monitor.record(answered: true))
    }

    func testRepairSuggestion() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = DiagnosticsEvent(date: now.addingTimeInterval(-10 * 86400), kind: .uncleanExit, detail: "")
        let recent = DiagnosticsEvent(date: now.addingTimeInterval(-3600), kind: .uncleanExit, detail: "")
        let stall = DiagnosticsEvent(date: now, kind: .mainThreadStall, detail: "")
        XCTAssertFalse(UncleanExitPolicy.suggestsRepair(events: [old, recent, stall], now: now))
        XCTAssertTrue(UncleanExitPolicy.suggestsRepair(events: [old, recent, recent], now: now))
    }
}

@MainActor
final class DiagnosticsCenterTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func center(foreground: Bool = true) -> DiagnosticsCenter {
        DiagnosticsCenter(directory: directory, isInForeground: { foreground }, observesSystem: false)
    }

    func testDetectsAnExitWhileInFront() {
        let first = center()
        first.beginSession()
        XCTAssertFalse(first.previousSessionEndedUncleanly, "first launch")
        // The process dies here without going to the background.
        let second = center()
        second.beginSession()
        XCTAssertTrue(second.previousSessionEndedUncleanly)
        XCTAssertEqual(second.events.map(\.kind), [.uncleanExit])

        var toasts: [String] = []
        second.notify = { message, _ in toasts.append(message) }
        second.desktopStarted(host: MockLinuxHost())
        XCTAssertEqual(toasts, ["LinPad closed unexpectedly last time."])
        XCTAssertFalse(second.previousSessionEndedUncleanly, "shown once")

        second.markCleanExit()
        let third = center()
        third.beginSession()
        XCTAssertFalse(third.previousSessionEndedUncleanly)
        XCTAssertEqual(third.events.count, 1, "events persist across launches")
    }

    func testSuspendedAppKilledByIPadOSIsNormal() {
        center(foreground: false).beginSession()
        let next = center()
        next.beginSession()
        XCTAssertFalse(next.previousSessionEndedUncleanly)
    }

    func testRepeatedCrashesSuggestRepair() {
        center().beginSession()
        center().beginSession()
        let third = center()
        third.beginSession()
        var actions: [String] = []
        third.notify = { _, action in actions.append(action?.title ?? "") }
        third.desktopStarted(host: MockLinuxHost())
        XCTAssertEqual(actions, ["Export Diagnostics", "Repair…"])
    }

    func testZipContainsReviewedItemsOnly() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let items = [
            DiagnosticsItem(id: "info", title: "Info", detail: "d", fileName: "info.txt", text: "App: LinPad"),
            DiagnosticsItem(id: "log", title: "Log", detail: "d", fileName: "log.txt", text: "secret", isIncluded: false),
        ]
        let zip = try DiagnosticsExportModel.writeZip(items: items.filter(\.isIncluded), to: directory, date: Date(timeIntervalSince1970: 0))
        let data = try Data(contentsOf: zip)
        XCTAssertEqual(data.prefix(2), Data("PK".utf8))
        let listing = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(listing.contains("info.txt"))
        XCTAssertTrue(listing.contains("README.txt"))
        XCTAssertFalse(listing.contains("log.txt"))
    }
}
