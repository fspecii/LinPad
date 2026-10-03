import UIKit
import XCTest
@testable import DesktopKit

final class CommandMenuSearchTests: XCTestCase {
    private func item(_ title: String, keywords: String = "") -> CommandMenuItem {
        CommandMenuItem(id: title, title: title, section: .apps, symbol: "app", keywords: keywords) {}
    }

    func testFuzzyMatchingPrefersWordStartsAndPrefixes() {
        let items = ["Theme: Tokyo Night", "Terminal", "Text Editor", "Task Manager", "Theme: Nord"].map { item($0) }
        XCTAssertEqual(CommandMenuSearch.rank(items, query: "term").first?.title, "Terminal")
        XCTAssertEqual(CommandMenuSearch.rank(items, query: "tokyo").first?.title, "Theme: Tokyo Night")
        XCTAssertEqual(CommandMenuSearch.rank(items, query: "tm").first?.title, "Task Manager", "initials match")
        XCTAssertEqual(CommandMenuSearch.rank(items, query: "te").first?.title, "Terminal")
        XCTAssertTrue(CommandMenuSearch.rank(items, query: "zzz").isEmpty)
        XCTAssertNil(CommandMenuSearch.score("abc", in: "cab"), "letters must come in order")
    }

    func testKeywordsAndEmptyQuery() {
        let items = [item("Files", keywords: "finder nautilus thunar"), item("Settings")]
        XCTAssertEqual(CommandMenuSearch.rank(items, query: "thunar").first?.title, "Files")
        XCTAssertEqual(CommandMenuSearch.rank(items, query: "").map(\.title), ["Files", "Settings"])
    }

    @MainActor
    func testMenuListsAppsWindowsCommandsTogglesThemesAndLinks() {
        let controller = DesktopController(host: MockLinuxHost(), apps: BuiltinApps.all())
        controller.open(appID: AppID.files, arguments: [:])
        controller.commandMenu = CommandMenuState(query: "")
        let sections = Set(controller.commandMenuItems().map(\.section))
        XCTAssertTrue(sections.isSuperset(of: [.windows, .apps, .commands, .toggles, .style, .setup, .capture, .system, .update]))
        controller.commandMenu = CommandMenuState(query: "linpad://open")
        XCTAssertEqual(controller.commandMenuItems().first?.section, .links)
        controller.commandMenu = CommandMenuState(query: "nord")
        XCTAssertEqual(CommandMenuSearch.rank(controller.commandMenuItems(), query: "nord").first?.id, "theme:nord")
    }

    func testCheatsheetFoldsWorkspaceDigits() {
        XCTAssertTrue(ShortcutSheetView.isFolded("workspace.4"))
        XCTAssertTrue(ShortcutSheetView.isFolded("workspace.move.9"))
        XCTAssertFalse(ShortcutSheetView.isFolded("workspace.1"))
        XCTAssertFalse(ShortcutSheetView.isFolded("workspace.next"))
        XCTAssertFalse(ShortcutSheetView.isFolded("snap.left"))
    }
}

final class CaptureTests: XCTestCase {
    func testFileNamesSortByDate() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let name = DesktopCapture.fileName("Screenshot", date: date, extension: "png")
        XCTAssertTrue(name.hasPrefix("Screenshot 2026-"))
        XCTAssertTrue(name.hasSuffix(".png"))
        XCTAssertFalse(name.contains(":"), "no colons in file names")
    }

    func testRiceModeFramesTheShotWithAMargin() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let shot = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }
        let riced = DesktopCapture.riced(shot, backdrop: nil, fallback: .blue)
        XCTAssertEqual(riced.size.width, 224, accuracy: 0.5, "6 % margin on each side")
        XCTAssertEqual(riced.size.height, 124, accuracy: 0.5)
    }

    func testOSDLabels() {
        XCTAssertEqual(OSDState.volume(0).label, "Muted")
        XCTAssertEqual(OSDState.volume(0.5).label, "Volume 50 %")
        XCTAssertEqual(OSDState.brightness(1).symbol, "sun.max.fill")
        XCTAssertFalse(OSDState.layout("ro-RO").label.isEmpty)
    }
}
