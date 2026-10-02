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
        XCTAssertNil(other.image(named: "utilities-terminal"), "each style has its own cache")
        XCTAssertNil(DesktopIconStore(guestRoot: nil, style: .macos).image(named: "utilities-terminal"))
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
