import Foundation
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import DesktopKit

/// A LinuxHost that runs commands in the host's own /bin/sh, rooted in a scratch directory,
/// so the transfer and trash services are tested against a real POSIX shell. The guest is
/// busybox; every command the services issue is plain POSIX that both accept.
@MainActor
final class ShellTestHost: LinuxHost {
    let hostName = "test"
    let homeDirectory: String
    private(set) var commands: [String] = []

    init(home: String) {
        homeDirectory = home
    }

    func run(_ command: String, cwd: String?, stdin: Data?) async -> CommandResult {
        commands.append(command)
        let body = cwd.map { "cd \($0.shellQuoted) && {\n\(command)\n}" } ?? command
        let script = "export PATH=/usr/bin:/bin:/usr/sbin:/sbin\n" + body
        return await Task.detached { Self.spawn(script, stdin: stdin) }.value
    }

    func makeTerminalViewController(command: String?, cwd: String?) -> UIViewController { UIViewController() }

    nonisolated private static func spawn(_ script: String, stdin: Data?) -> CommandResult {
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        pipe(&input); pipe(&output); pipe(&errors)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errors[1], 2)
        for fd in input + output + errors { posix_spawn_file_actions_addclose(&actions, fd) }
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(script), nil]
        let status = posix_spawn(&pid, "/bin/sh", &actions, nil, argv, environ)
        posix_spawn_file_actions_destroy(&actions)
        argv.forEach { free($0) }
        close(input[0]); close(output[1]); close(errors[1])
        guard status == 0 else { return CommandResult(stdout: "", stderr: "spawn failed", exitCode: -1) }
        let writer = Thread {
            if let stdin { stdin.withUnsafeBytes { _ = write(input[1], $0.baseAddress, $0.count) } }
            close(input[1])
        }
        writer.start()
        let errorHandle = FileHandle(fileDescriptor: errors[0], closeOnDealloc: true)
        var errorData = Data()
        let errorReader = Thread { errorData = errorHandle.readDataToEndOfFile() }
        errorReader.start()
        let out = FileHandle(fileDescriptor: output[0], closeOnDealloc: true).readDataToEndOfFile()
        var waitStatus: Int32 = 0
        waitpid(pid, &waitStatus, 0)
        while !errorReader.isFinished { usleep(1000) }
        return CommandResult(stdout: String(decoding: out, as: UTF8.self),
                             stderr: String(decoding: errorData, as: UTF8.self),
                             exitCode: (waitStatus >> 8) & 0xff)
    }
}

@MainActor
final class DragDropTests: XCTestCase {
    private var root: URL!
    private var host: ShellTestHost!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dnd-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        host = ShellTestHost(home: root.appendingPathComponent("home").path)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var home: String { host.homeDirectory }

    // MARK: Naming

    func testUniqueNamesKeepTheExtensionLast() {
        XCTAssertEqual(FileNaming.unique("a.txt", existing: []), "a.txt")
        XCTAssertEqual(FileNaming.unique("a.txt", existing: ["a.txt"]), "a (2).txt")
        XCTAssertEqual(FileNaming.unique("a.txt", existing: ["a.txt", "a (2).txt"]), "a (3).txt")
        XCTAssertEqual(FileNaming.unique("x.tar.gz", existing: ["x.tar.gz"]), "x (2).tar.gz")
        XCTAssertEqual(FileNaming.unique(".bashrc", existing: [".bashrc"]), ".bashrc (2)")
        XCTAssertEqual(FileNaming.duplicate("notes.md", existing: ["notes (copy).md"]), "notes (copy 2).md")
    }

    // MARK: Transfer

    func testImportStreamsLargeFilesInChunksWithProgress() async throws {
        let size = GuestTransferService.importChunkSize * 2 + 12345
        let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let source = root.appendingPathComponent("big.bin")
        try bytes.write(to: source)
        var updates: [(Int64, Int64)] = []
        let service = GuestTransferService(host: host)
        let path = try await service.importItem(at: source, into: home) { done, total in updates.append((done, total)) }

        XCTAssertEqual(path, home + "/big.bin")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        XCTAssertEqual(updates.count, 3, "one progress update per chunk")
        XCTAssertEqual(updates.last?.0, Int64(size))
        XCTAssertEqual(host.commands.filter { $0.hasPrefix("cat >>") }.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".part"))

        let again = try await service.importItem(at: source, into: home)
        XCTAssertEqual(again, home + "/big (2).bin", "a name clash gets a counter")
    }

    func testImportAndExportFolderRoundTrip() async throws {
        let folder = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("README with space.md"))
        try Data(repeating: 7, count: 70_000).write(to: folder.appendingPathComponent("src/deep/blob.bin"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)

        let service = GuestTransferService(host: host)
        let imported = try await service.importItem(at: folder, into: home)
        XCTAssertEqual(try String(contentsOfFile: imported + "/README with space.md", encoding: .utf8), "hello")

        let exportDir = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let exported = try await service.exportItem(imported, isDirectory: true, to: exportDir)
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("src/deep/blob.bin")), Data(repeating: 7, count: 70_000))
        XCTAssertEqual(try String(contentsOf: exported.appendingPathComponent("README with space.md"), encoding: .utf8), "hello")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appendingPathComponent("empty").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testExportReadsInChunks() async throws {
        let size = GuestTransferService.exportChunkSize + 99
        let path = home + "/data.bin"
        let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: URL(fileURLWithPath: path))
        let url = try await GuestTransferService(host: host).exportItem(path, isDirectory: false, to: root)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(host.commands.filter { $0.hasPrefix("dd if=") }.count, 2)
    }

    // MARK: Export to other apps

    private func loadFile(_ provider: NSItemProvider, type: UTType, read: @escaping @Sendable (URL) -> Data?) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                continuation.resume(returning: url.flatMap(read))
            }
        }
    }

    /// What iPadOS Files (or Mail…) gets when a guest file is dropped on it: the provider's
    /// file representation, exported through the guest on demand.
    func testItemProviderExportsGuestFilesForOtherApps() async throws {
        let path = home + "/report.txt"
        try Data("export me".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.createDirectory(atPath: home + "/Folder/sub", withIntermediateDirectories: true)
        try Data("inner".utf8).write(to: URL(fileURLWithPath: home + "/Folder/sub/inner.txt"))
        let transfer = GuestTransferService(host: host)

        let provider = DragItemProviders.provider(for: [.init(path: path, isDirectory: false)], sourceWindow: nil, transfer: transfer)
        XCTAssertEqual(provider.suggestedName, "report.txt")
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier))
        let contents = await loadFile(provider, type: .plainText) { try? Data(contentsOf: $0) }
        XCTAssertEqual(contents, Data("export me".utf8))

        let folder = DragItemProviders.provider(for: [.init(path: home + "/Folder", isDirectory: true)], sourceWindow: nil, transfer: transfer)
        XCTAssertTrue(folder.hasItemConformingToTypeIdentifier(UTType.folder.identifier))
        let inner = await loadFile(folder, type: .folder) { try? Data(contentsOf: $0.appendingPathComponent("sub/inner.txt")) }
        XCTAssertEqual(inner, Data("inner".utf8))

        // In-app drops get the guest paths themselves, nothing exported.
        let (payload, items) = await DragItemProviders.loadItems(from: [provider])
        XCTAssertEqual(payload?.paths, [path])
        XCTAssertEqual(items, [.guestFile(path: path, isDirectory: false)])
    }

    // MARK: iPad places

    func testIPadPlacesPersistAndResolveBookmarks() throws {
        let defaults = UserDefaults(suiteName: "dnd-tests-\(UUID().uuidString)")!
        let folder = root.appendingPathComponent("Picked Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = try folder.bookmarkData()

        let store = IPadPlaceStore(defaults: defaults)
        let point = store.mountPoint(for: "Picked Folder")
        XCTAssertEqual(point, "/mnt/ipad/Picked Folder")
        store.add(IPadPlace(name: "Picked Folder", mountPoint: point, bookmark: bookmark))
        XCTAssertEqual(store.mountPoint(for: "Picked Folder"), "/mnt/ipad/Picked Folder (2)", "names never collide")

        // A new launch sees the same places, and the bookmark still finds the folder.
        let reloaded = IPadPlaceStore(defaults: defaults)
        XCTAssertEqual(reloaded.places.map(\.mountPoint), [point])
        var stale = false
        let resolved = try URL(resolvingBookmarkData: reloaded.places[0].bookmark, bookmarkDataIsStale: &stale)
        XCTAssertEqual(resolved.standardizedFileURL.path, folder.standardizedFileURL.path)

        // Places the host did not mount again at boot are offered for reconnecting.
        XCTAssertEqual(reloaded.unavailable(mounted: []), [point])
        XCTAssertTrue(reloaded.unavailable(mounted: [point]).isEmpty)
        reloaded.remove(point)
        XCTAssertTrue(IPadPlaceStore(defaults: defaults).places.isEmpty)
        XCTAssertTrue(IPadPlaceStore.decode(Data("garbage".utf8)).isEmpty)
    }

    // MARK: Quick Look export

    func testQuickLookExportIsCachedUntilTheFileChanges() async throws {
        let path = home + "/note.md"
        try Data("# one".utf8).write(to: URL(fileURLWithPath: path))
        let transfer = GuestTransferService(host: host)
        let presenter = QuickLookPresenter.shared
        var entry = FileEntry(path: path, name: "note.md", isDirectory: false, size: 5, modified: Date(timeIntervalSince1970: 1))
        let first = try await presenter.exportedURL(for: entry, transfer: transfer)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "# one")
        let exports = host.commands.filter { $0.hasPrefix("dd if=") }.count
        let again = try await presenter.exportedURL(for: entry, transfer: transfer)
        XCTAssertEqual(again, first)
        XCTAssertEqual(host.commands.filter { $0.hasPrefix("dd if=") }.count, exports, "unchanged files are not exported again")

        try Data("# two!".utf8).write(to: URL(fileURLWithPath: path))
        entry.size = 6
        entry.modified = Date(timeIntervalSince1970: 2)
        let changed = try await presenter.exportedURL(for: entry, transfer: transfer)
        XCTAssertEqual(try String(contentsOf: changed, encoding: .utf8), "# two!")
    }

    // MARK: Trash

    func testTrashInfoFollowsTheSpec() {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 2
        components.hour = 3; components.minute = 4; components.second = 5
        let date = Calendar.current.date(from: components)!
        let info = TrashInfo.trashInfo(originalPath: "/root/My File%.txt", deletionDate: date)
        XCTAssertEqual(info, "[Trash Info]\nPath=/root/My%20File%25.txt\nDeletionDate=2026-10-02T03:04:05\n")
        let parsed = TrashInfo.parseTrashInfo(info)
        XCTAssertEqual(parsed?.path, "/root/My File%.txt")
        XCTAssertEqual(parsed?.date, date)
    }

    func testTrashListRestoreAndEmpty() async throws {
        let trash = FileTrash(host: host, homeDirectory: home)
        let manager = FileManager.default
        try Data("one".utf8).write(to: URL(fileURLWithPath: home + "/a.txt"))
        try manager.createDirectory(atPath: home + "/dir/sub", withIntermediateDirectories: true)

        let names = try await trash.trash([home + "/a.txt", home + "/dir"])
        XCTAssertEqual(names, ["a.txt", "dir"])
        XCTAssertFalse(manager.fileExists(atPath: home + "/a.txt"))
        XCTAssertTrue(manager.fileExists(atPath: trash.filesDirectory + "/a.txt"))
        let info = try String(contentsOfFile: trash.infoDirectory + "/a.txt.trashinfo", encoding: .utf8)
        XCTAssertTrue(info.hasPrefix("[Trash Info]\nPath=\(TrashInfo.encodePath(home + "/a.txt"))\nDeletionDate="))

        // A second file with the same name gets its own trash name.
        try Data("two".utf8).write(to: URL(fileURLWithPath: home + "/a.txt"))
        let second = try await trash.trash([home + "/a.txt"])
        XCTAssertEqual(second, ["a (2).txt"])

        let items = try await trash.list().sorted { $0.name < $1.name }
        XCTAssertEqual(items.map(\.name), ["a (2).txt", "a.txt", "dir"])
        XCTAssertEqual(items.map(\.originalPath), [home + "/a.txt", home + "/a.txt", home + "/dir"])
        XCTAssertEqual(items.map(\.isDirectory), [false, false, true])

        // Restoring onto a name that is taken again renames instead of overwriting.
        try Data("three".utf8).write(to: URL(fileURLWithPath: home + "/a.txt"))
        let restored = try await trash.restore(["a.txt"])
        XCTAssertEqual(restored, [home + "/a (2).txt"])
        XCTAssertEqual(try String(contentsOfFile: home + "/a (2).txt", encoding: .utf8), "one")
        XCTAssertFalse(manager.fileExists(atPath: trash.infoDirectory + "/a.txt.trashinfo"))

        try await trash.empty()
        let remaining = try await trash.list()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(manager.fileExists(atPath: trash.filesDirectory))
    }

    // MARK: File operations

    func testMoveCopyAndDuplicate() async throws {
        let ops = FileOperations(host: host)
        let manager = FileManager.default
        try manager.createDirectory(atPath: home + "/dest", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: home + "/f.txt"))
        try Data("old".utf8).write(to: URL(fileURLWithPath: home + "/dest/f.txt"))

        let copied = try await ops.transfer([home + "/f.txt"], into: home + "/dest", operation: .copy)
        XCTAssertEqual(copied, [home + "/dest/f (2).txt"])
        XCTAssertTrue(manager.fileExists(atPath: home + "/f.txt"))

        let moved = try await ops.transfer([home + "/f.txt"], into: home + "/dest", operation: .move)
        XCTAssertEqual(moved, [home + "/dest/f (3).txt"])
        XCTAssertFalse(manager.fileExists(atPath: home + "/f.txt"))

        let intoItself = try await ops.transfer([home + "/dest"], into: home + "/dest", operation: .move)
        XCTAssertTrue(intoItself.isEmpty, "a folder never moves into itself")

        let duplicates = try await ops.duplicate([home + "/dest/f (2).txt"])
        XCTAssertEqual(duplicates, [home + "/dest/f (2) (copy).txt"])
    }

    func testArchiveCommands() {
        XCTAssertEqual(FileOperations.extractCommand(archive: "/a.tgz", into: "/o", name: "a.tgz"), "tar -xzf '/a.tgz' -C '/o'")
        XCTAssertEqual(FileOperations.extractCommand(archive: "/a.zip", into: "/o", name: "a.zip"), "unzip -oq '/a.zip' -d '/o'")
        XCTAssertNil(FileOperations.extractCommand(archive: "/a.txt", into: "/o", name: "a.txt"))
    }

    func testPropertiesParsing() throws {
        let properties = try FileOperations.parseProperties(
            "-rwxr-x---|750|root|wheel|1234|1700000000|1700000100|1700000200|regular file\n", path: "/root/x")
        XCTAssertEqual(properties.mode, 0o750)
        XCTAssertEqual(properties.owner, "root")
        XCTAssertEqual(properties.size, 1234)
        XCTAssertEqual(FilePropertiesSheet.symbolic(0o750, kind: "-"), "-rwxr-x---")
    }

    // MARK: Formats

    func testURIListRoundTrip() {
        let uri = URIList.fileURI(forGuestPath: "/root/a b#c.txt")
        XCTAssertEqual(uri, "file:///root/a%20b%23c.txt")
        XCTAssertEqual(URIList.guestPath(fromFileURI: uri), "/root/a b#c.txt")
        XCTAssertEqual(URIList.guestPath(fromFileURI: "file://localhost/etc/hosts"), "/etc/hosts")
        XCTAssertEqual(URIList.parse("# comment\r\nfile:///a\r\nhttps://x.org/\r\n"), ["file:///a", "https://x.org/"])
        let items = LinuxDragBridge.items(fromData: Data("file:///root/x\r\nhttps://e.com/\r\n".utf8), mime: "text/uri-list")
        XCTAssertEqual(items, [.guestFile(path: "/root/x", isDirectory: false), .url(URL(string: "https://e.com/")!)])
    }

    func testOpenWithCatalog() {
        let listing = """
            [[file org.xfce.mousepad.desktop]]
            Name=Mousepad
            Exec=mousepad %U
            MimeType=text/plain;
            Type=Application
            [[file hidden.desktop]]
            Name=Hidden
            Exec=hidden %f
            MimeType=text/plain;
            NoDisplay=true
            Type=Application
            [[file ristretto.desktop]]
            Name=Ristretto
            Exec=ristretto %f
            MimeType=image/png;image/jpeg;
            Type=Application
            """
        let apps = OpenWithCatalog.parseApplications(listing)
        XCTAssertEqual(apps.map(\.id), ["org.xfce.mousepad", "ristretto"])
        let globs = OpenWithCatalog.parseGlobs("50:text/x-python:*.py\n50:image/png:*.png\n10:application/x-compressed-tar:*.tar.gz\n")
        XCTAssertEqual(globs["*.py"], "text/x-python")
        XCTAssertEqual(OpenWithCatalog.command(exec: "mousepad %U", path: "/root/it's.txt"), "mousepad '/root/it'\\''s.txt'")
        XCTAssertEqual(OpenWithCatalog.command(exec: "app --flag", path: "/x"), "app --flag '/x'")
    }

    // MARK: Desktop icons

    func testDesktopIconLayoutFillsColumnsAndKeepsMovedIcons() {
        let size = CGSize(width: 1000, height: 16 * 2 + 300)  // three rows
        var layout = DesktopIconLayout()
        let keys = ["a", "b", "c", "d"]
        let cells = layout.resolved(keys, in: size)
        XCTAssertEqual(cells["d"], .init(column: 1, row: 0))
        layout.move(["a"], to: .init(column: 5, row: 2), allKeys: keys, in: size)
        let moved = layout.resolved(keys, in: size)
        XCTAssertEqual(moved["a"], .init(column: 5, row: 2))
        XCTAssertEqual(moved["b"], .init(column: 0, row: 1), "the others keep their cells")
        layout.move(["c"], to: .init(column: 5, row: 2), allKeys: keys, in: size)
        XCTAssertEqual(layout.resolved(keys, in: size)["c"], .init(column: 6, row: 0), "an occupied cell pushes to the next free one")
        XCTAssertEqual(layout.cell(at: CGPoint(x: 16 + 96 * 2 + 5, y: 16 + 100 + 1), in: size), .init(column: 2, row: 1))
    }
}
