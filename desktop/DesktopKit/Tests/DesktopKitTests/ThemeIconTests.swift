import UIKit
import XCTest
@testable import DesktopKit

final class FileTypeIconTests: XCTestCase {
    private func names(_ name: String, directory: Bool = false, permissions: String = "-rw-r--r--",
                       path: String? = nil, home: String? = nil) -> [String] {
        let entry = FileEntry(path: path ?? "/root/\(name)", name: name, isDirectory: directory, permissions: permissions)
        return FileTypeIcons.iconNames(for: entry, home: home)
    }

    func testMimeTypesFromNames() {
        XCTAssertEqual(FileTypeIcons.mimeType(forFileName: "hello.py", isDirectory: false, isExecutable: false), "text/x-python")
        XCTAssertEqual(FileTypeIcons.mimeType(forFileName: "PHOTO.JPG", isDirectory: false, isExecutable: false), "image/jpeg")
        XCTAssertEqual(FileTypeIcons.mimeType(forFileName: "Makefile", isDirectory: false, isExecutable: false), "text/x-makefile")
        XCTAssertEqual(FileTypeIcons.mimeType(forFileName: ".bashrc", isDirectory: false, isExecutable: false),
                       "application/x-shellscript")
        XCTAssertEqual(FileTypeIcons.mimeType(forFileName: "busybox", isDirectory: false, isExecutable: true),
                       "application/x-executable")
        XCTAssertEqual(FileTypeIcons.mimeType(forFileName: "README", isDirectory: false, isExecutable: false), "text/plain")
        XCTAssertEqual(FileTypeIcons.mimeType(forFileName: "blob.qqq", isDirectory: false, isExecutable: false),
                       "application/octet-stream")
        XCTAssertEqual(FileTypeIcons.mimeType(forFileName: "src", isDirectory: true, isExecutable: true), "inode/directory")
    }

    func testFallbackChainFollowsTheSpec() {
        XCTAssertEqual(names("hello.py"), ["text-x-python", "text-x-script", "text-x-generic"])
        XCTAssertEqual(names("notes.txt"), ["text-plain", "text-x-generic"])
        XCTAssertEqual(names("a.png"), ["image-png", "image-x-generic", "text-x-generic"])
        XCTAssertEqual(names("song.flac"), ["audio-flac", "audio-x-generic", "text-x-generic"])
        XCTAssertEqual(names("clip.mkv"), ["video-x-matroska", "video-x-generic", "text-x-generic"])
        XCTAssertEqual(names("backup.tar.gz"), ["application-gzip", "package-x-generic", "text-x-generic"])
        XCTAssertEqual(names("paper.pdf"), ["application-pdf", "x-office-document", "text-x-generic"])
        XCTAssertEqual(names("README.md"), ["text-markdown", "text-x-markdown", "text-x-generic"])
        XCTAssertEqual(names("run", permissions: "-rwxr-xr-x"), ["application-x-executable", "text-x-generic"])
        XCTAssertEqual(names("libfoo.so"), ["application-x-sharedlib", "application-x-executable", "text-x-generic"])
        XCTAssertEqual(names("font.ttf"), ["font-ttf", "font-x-generic", "text-x-generic"])
        XCTAssertEqual(names("blob.qqq"), ["application-octet-stream", "application-x-generic", "text-x-generic"])
        XCTAssertEqual(names("projects", directory: true), ["folder", "inode-directory"])
    }

    func testHomeFoldersHaveTheirOwnIcons() {
        XCTAssertEqual(names("Documents", directory: true, path: "/root/Documents", home: "/root"),
                       ["folder-documents", "folder", "inode-directory"])
        XCTAssertEqual(names("Desktop", directory: true, path: "/root/Desktop", home: "/root/"),
                       ["user-desktop", "folder", "inode-directory"])
        XCTAssertEqual(names("Documents", directory: true, path: "/tmp/Documents", home: "/root"), ["folder", "inode-directory"],
                       "only directly in the home directory")
    }

    /// Every name the shell asks for must be rendered by the guest for every pack.
    func testGuestRendersEveryNameTheShellAsksFor() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("themes/guest/ish-apply-style")
        let source = try String(contentsOf: script, encoding: .utf8)
        func list(_ variable: String) throws -> Set<String> {
            let start = try XCTUnwrap(source.range(of: "\(variable)=\""))
            let end = try XCTUnwrap(source.range(of: "\"", range: start.upperBound..<source.endIndex))
            return Set(source[start.upperBound..<end.lowerBound].split(whereSeparator: \.isWhitespace).map(String.init))
        }
        let rendered = try list("EXACT_ICONS").union(list("NATIVE_ICONS"))
        var asked = Set(FileTypeIcons.typesByExtension.values.flatMap(FileTypeIcons.iconNames(forMIMEType:)))
        asked.formUnion(FileTypeIcons.typesByName.values.flatMap(FileTypeIcons.iconNames(forMIMEType:)))
        asked.formUnion([FileTypeIcons.executableType, FileTypeIcons.unknownType, FileTypeIcons.directoryType]
            .flatMap(FileTypeIcons.iconNames(forMIMEType:)))
        asked.formUnion(FileTypeIcons.homeFolders.values)
        let controls: [[String]] = [
            ThemeIconNames.launcher, ThemeIconNames.goBack, ThemeIconNames.goForward, ThemeIconNames.goUp,
            ThemeIconNames.newFolder, ThemeIconNames.newFile, ThemeIconNames.refresh, ThemeIconNames.gridView,
            ThemeIconNames.listView, ThemeIconNames.menu, ThemeIconNames.sidebar, ThemeIconNames.editPath,
            ThemeIconNames.emptyTrash, ThemeIconNames.eject, ThemeIconNames.add, ThemeIconNames.rootDrive,
            ThemeIconNames.home, ThemeIconNames.desktop, ThemeIconNames.fileSystem, ThemeIconNames.temporary,
            ThemeIconNames.trash, ThemeIconNames.pictures, ThemeIconNames.iPadFolder,
        ] + [WindowButtonKind.minimize, .maximize, .close].flatMap {
            [ThemeIconNames.windowButton($0, isMaximized: false), ThemeIconNames.windowButton($0, isMaximized: true)]
        }
        asked.formUnion(controls.joined())
        XCTAssertEqual(asked.subtracting(rendered).sorted(), [])
    }
}

@MainActor
final class ThemeIconStoreTests: XCTestCase {
    private var root: URL!
    private var cache: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        cache = root.appendingPathComponent("usr/share/ish/icon-cache/ish", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        for name in ["folder", "text-x-script", "text-x-generic", "image-x-generic", "go-previous-symbolic", "app"] {
            try png.write(to: cache.appendingPathComponent("\(name).png"))
        }
        // "never-indexed" exists on disk but not in index.json: the index is authoritative.
        try png.write(to: cache.appendingPathComponent("never-indexed.png"))
        let index = """
        {"version": 1, "style": "ish", "icons": {
          "folder": {"1x": "folder.png", "2x": "folder.png"},
          "text-x-script": {"1x": "text-x-script.png", "2x": "text-x-script.png"},
          "text-x-generic": {"1x": "text-x-generic.png", "2x": "text-x-generic.png"},
          "image-x-generic": {"1x": "image-x-generic.png", "2x": "image-x-generic.png"},
          "go-previous-symbolic": {"1x": "go-previous-symbolic.png", "2x": "go-previous-symbolic.png", "symbolic": true},
          "/opt/app/app.png": {"1x": "app.png", "2x": "app.png"}
        }, "desktopEntries": {}, "missing": []}
        """
        try Data(index.utf8).write(to: cache.appendingPathComponent("index.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFirstNameThePackHasWinsAndSymbolicIsReported() throws {
        let store = DesktopIconStore(guestRoot: root, style: .ish)
        XCTAssertNotNil(store.icon(["text-x-python", "text-x-script", "text-x-generic"]))
        XCTAssertEqual(store.fileReads, 1, "only the resolved file is read; missing names come from index.json")
        let back = try XCTUnwrap(store.icon(ThemeIconNames.goBack))
        XCTAssertTrue(back.isSymbolic)
        XCTAssertFalse(try XCTUnwrap(store.icon(["folder"])).isSymbolic)
        XCTAssertNil(store.icon(["never-indexed"]))
        XCTAssertNil(store.icon([]))
        XCTAssertNotNil(store.image(named: "/opt/app/app.png"), "Icon= paths resolve through their file stem")
    }

    func testUnknownStyleUsesTheCacheTheGuestLastApplied() throws {
        try Data("ish\n".utf8).write(to: root.appendingPathComponent("usr/share/ish/current-style"))
        XCTAssertNotNil(DesktopIconStore(guestRoot: root, style: .luna).icon(["folder"]))
    }

    /// Scrolling a 1,000-file folder: every row asks for its icon on every render.
    func testLargeFolderReadsEachIconFileOnce() {
        let store = DesktopIconStore(guestRoot: root, style: .ish)
        let extensions = ["py", "txt", "png", "md", "json", "c", "", "sh", "jpg", "tar.gz"]
        let entries = (0..<1000).map { index in
            FileEntry(path: "/root/big/f\(index)", name: "file\(index).\(extensions[index % extensions.count])",
                      isDirectory: index % 17 == 0)
        }
        let start = Date()
        for _ in 0..<5 {
            for entry in entries { XCTAssertNotNil(store.icon(FileTypeIcons.iconNames(for: entry, home: "/root"))) }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThanOrEqual(store.fileReads, 4, "one read per distinct icon file, none while scrolling")
        XCTAssertLessThan(elapsed, 0.5, "5,000 row lookups took \(elapsed) s")
        print("theme icon lookups: 5000 rows in \(String(format: "%.1f", elapsed * 1000)) ms, \(store.fileReads) file reads")
    }
}
