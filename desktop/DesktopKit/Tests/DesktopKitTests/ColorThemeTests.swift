import SwiftUI
import UIKit
import XCTest
@testable import DesktopKit

final class ColorThemeTests: XCTestCase {
    private func hex(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    private func theme(_ id: String) throws -> ColorTheme {
        try XCTUnwrap(ColorTheme.builtIn.first { $0.id == id }, "\(id) is bundled")
    }

    func testBundledThemesExcludeTheUnlicensedOnes() {
        let ids = Set(ColorTheme.builtIn.map(\.id))
        XCTAssertEqual(ids.count, 20)
        XCTAssertFalse(ids.contains("ristretto"))
        XCTAssertFalse(ids.contains("lumon"))
        XCTAssertTrue(ColorTheme.builtIn.allSatisfy { $0.terminalColors.count == 16 }, "every theme resolves 16 ANSI colours")
    }

    func testMixMatchesOmarchy() throws {
        let bg = try XCTUnwrap(RGB(hex: "#1a1b26")), fg = try XCTUnwrap(RGB(hex: "#a9b1d6"))
        XCTAssertEqual(bg.mix(fg, 0.08).hex, "#252734")
        XCTAssertEqual(fg.mix(bg, 0.34).hex, "#787e9a")
        XCTAssertNil(RGB(hex: "nope"))
    }

    func testDesktopTokensDeriveFromFiveColors() throws {
        let tokyo = try theme("tokyo-night")
        let derived = tokyo.applied(to: .dark, panelOpacity: 0.7)
        XCTAssertEqual(hex(derived.accent), "#7aa2f7")
        XCTAssertEqual(hex(derived.windowBackground), "#1a1b26")
        XCTAssertEqual(hex(derived.titleBarActive), "#252734")
        XCTAssertEqual(hex(derived.titleBarInactive), hex(derived.windowBackground))
        XCTAssertEqual(hex(derived.primaryText), "#a9b1d6")
        XCTAssertEqual(hex(derived.secondaryText), "#787e9a")
        XCTAssertEqual(hex(derived.urgent), "#f7768e")
        XCTAssertEqual(derived.borderWidth, 2)
        XCTAssertEqual(derived.terminalPalette.count, 16)
        XCTAssertEqual(derived.colorThemeID, "tokyo-night")
        XCTAssertEqual(derived.cornerRadius, DesktopTheme.dark.cornerRadius, "shapes stay the style's")
        XCTAssertEqual(derived.panelBackground.opacityComponent, 0.7, accuracy: 0.01, "translucency stays the style's")
        XCTAssertTrue(tokyo.isDark)
        XCTAssertFalse(try theme("catppuccin-latte").isDark)
    }

    func testDefaultThemeKeepsTodaysLook() {
        XCTAssertEqual(DesktopTheme.dark.borderWidth, 0)
        XCTAssertNil(DesktopTheme.dark.borderActive)
        XCTAssertEqual(DesktopTheme.dark.colorThemeID, "")
    }

    @MainActor
    func testPickerPreviewsCommitsAndReverts() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ColorThemeTests"))
        defer { defaults.removePersistentDomain(forName: "ColorThemeTests") }
        let store = ColorThemeStore(defaults: defaults)
        XCTAssertEqual(store.currentID, "")
        let ids = store.orderedIDs
        XCTAssertEqual(ids.first, "", "Style Colors first")
        XCTAssertTrue(ids.firstIndex(of: "tokyo-night")! < ids.firstIndex(of: "catppuccin-latte")!, "dark themes before light ones")

        var picker = ColorThemePicker(ids: ids, currentID: store.currentID)
        picker.move(by: -1)
        XCTAssertEqual(picker.selectedID, ids.last, "wraps around")
        picker.move(by: 2)
        XCTAssertEqual(picker.selectedID, ids[1])
        picker.select("nord")
        store.previewID = picker.selectedID
        XCTAssertEqual(store.active?.id, "nord", "the desktop draws the preview")
        XCTAssertEqual(store.currentID, "", "nothing is applied yet")
        store.previewID = nil
        XCTAssertNil(store.active, "Esc goes back")

        store.select("nord")
        XCTAssertEqual(ColorThemeStore(defaults: defaults).currentID, "nord", "the choice persists")
    }

    func testGitURLsAreFilteredLikeOmarchy() {
        XCTAssertTrue(ColorThemeStore.isAcceptableGitURL("https://github.com/someone/omarchy-forest-theme"))
        XCTAssertTrue(ColorThemeStore.isAcceptableGitURL("git@github.com:someone/omarchy-forest-theme.git"))
        XCTAssertFalse(ColorThemeStore.isAcceptableGitURL("--upload-pack=touch /tmp/x"))
        XCTAssertFalse(ColorThemeStore.isAcceptableGitURL("ext::sh -c touch% /tmp/pwned"))
        XCTAssertFalse(ColorThemeStore.isAcceptableGitURL("file:///etc"))
    }

    @MainActor
    func testEachThemeRemembersItsWallpaper() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ColorThemeWallpaperTests"))
        defer { defaults.removePersistentDomain(forName: "ColorThemeWallpaperTests") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WallpaperStore(defaults: defaults, cache: WallpaperImageCache(root: root))
        store.set(.gradient("aurora"), target: .both, workspace: 0)
        store.switchTheme(from: "", to: "nord")
        store.set(.gradient("dusk"), target: .both, workspace: 0)
        store.switchTheme(from: "nord", to: "")
        XCTAssertEqual(store.settings.light, .gradient("aurora"), "back to the style colours' wallpaper")
        store.switchTheme(from: "", to: "nord")
        XCTAssertEqual(store.settings.light, .gradient("dusk"), "nord's wallpaper comes back with it")
    }
}
