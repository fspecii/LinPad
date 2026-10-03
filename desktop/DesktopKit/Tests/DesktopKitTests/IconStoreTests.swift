import UIKit
import XCTest
@testable import DesktopKit

@MainActor
final class IconStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = root.appendingPathComponent("usr/share/ish/icon-cache/macos", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        try png.write(to: cache.appendingPathComponent("utilities-terminal@2x.png"))
        try png.write(to: cache.appendingPathComponent("com.visualstudio.code.png"))
        try png.write(to: root.appendingPathComponent("thunar.png"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCacheLookupFollowsStyleAndNormalisesNames() {
        let store = DesktopIconStore(guestRoot: root, style: .macos)
        XCTAssertNotNil(store.image(named: "utilities-terminal"))
        XCTAssertNotNil(store.image(named: "/usr/share/icons/WhiteSur/apps/utilities-terminal.svg"),
                        "Icon= paths resolve by file name")
        XCTAssertNil(store.image(named: "missing-icon"))
        XCTAssertNotNil(store.image(named: "code"), "VS Code's icon is found under its reverse-DNS name")
        XCTAssertNotNil(store.image(at: root.appendingPathComponent("thunar.png")), "iconURL renders")

        let other = DesktopIconStore(guestRoot: root, style: .windows)
        XCTAssertGreaterThan(other.image(named: "utilities-terminal")?.size.width ?? 0, 8,
                       "each style has its own cache; without one the bundled pack's icon is drawn")
        XCTAssertNotNil(DesktopIconStore(guestRoot: nil, style: .macos).image(named: "utilities-terminal"),
                        "no guest: the bundled default pack")
    }

    /// Every built-in app, Trash and the featured Linux apps have a real icon even before
    /// Linux has booted: the bundled default pack has one of their names.
    func testBuiltinAppsHaveABundledPackIcon() throws {
        let index = try XCTUnwrap(BundledIcons.index, "Resources/Icons/index.json is bundled")
        var lists = BuiltinApps.all().map { DesktopIconStore.builtinIconCandidates[$0.id] ?? [] }
        lists.append(["user-trash"])
        lists.append(["user-trash-full"])
        for list in lists {
            XCTAssertNotNil(list.first { index.entry(for: $0) != nil }, "bundled icon for \(list)")
        }
        for app in LinuxFeaturedApp.all {
            let names = app.iconNames.flatMap { [$0] + (DesktopIconStore.aliases[$0] ?? []) }
            XCTAssertNotNil(names.first { index.entry(for: $0) != nil }, "bundled icon for \(app.id)")
        }
        let store = DesktopIconStore(guestRoot: nil, style: .ish)
        for app in BuiltinApps.all() {
            XCTAssertNotNil(store.image(named: DesktopIconStore.builtinIconNames[app.id]), "\(app.id) draws a pack icon")
        }
    }

    func testBuiltinAppsMapToFreedesktopNames() {
        XCTAssertEqual(DesktopIconStore.builtinIconNames[AppID.terminal], "utilities-terminal")
        XCTAssertEqual(DesktopIconStore.builtinIconNames[AppID.files], "system-file-manager")
        XCTAssertEqual(DesktopIconStore.builtinIconNames[AppID.settings], "preferences-system")
    }
}

@MainActor
final class NotificationCenterTests: XCTestCase {
    func testHistoryNewestFirstAndClear() {
        let model = NotificationCenterModel()
        model.record("first")
        model.record("second")
        XCTAssertEqual(model.notices.map(\.message), ["second", "first"])
        XCTAssertEqual(model.unreadCount, 2)
        model.markAllRead()
        XCTAssertEqual(model.unreadCount, 0)
        model.remove(model.notices[0].id)
        XCTAssertEqual(model.notices.map(\.message), ["first"])
        model.clear()
        XCTAssertTrue(model.notices.isEmpty)
    }
}

final class AppIconNameTests: XCTestCase {
    @MainActor
    func testEveryBuiltinAndFeaturedAppHasIconNames() {
        for app in BuiltinApps.all() {
            let names = DesktopIconStore.builtinIconCandidates[app.id] ?? []
            XCTAssertFalse(names.isEmpty, "\(app.id) has icon names")
            XCTAssertEqual(DesktopIconStore.builtinIconNames[app.id], names.first, "\(app.id) asks for its first name")
            XCTAssertEqual(DesktopIconStore.aliases[names[0]] ?? [], Array(names.dropFirst()), "\(app.id) falls back in order")
        }
        for app in LinuxFeaturedApp.all {
            XCTAssertFalse(app.iconNames.isEmpty, "\(app.id) has icon names")
            XCTAssertNotNil(DesktopIconStore.aliases[app.iconNames[0]], app.id)
        }
        XCTAssertEqual(DesktopIconStore.aliases["firefox"]?.first, "firefox-esr")
        XCTAssertEqual(DesktopIconStore.builtinIconNames[ThemesApp.id], "preferences-desktop-theme")
    }
}
