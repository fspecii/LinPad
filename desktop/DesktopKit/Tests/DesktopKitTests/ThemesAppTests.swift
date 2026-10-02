import SwiftUI
import XCTest
@testable import DesktopKit

final class ThemePairingTests: XCTestCase {
    private let themes = ColorTheme.builtIn

    func testEveryLightThemeGetsADarkPartner() {
        let table = ThemePairing.table(for: themes)
        let light = themes.filter { !$0.isDark }.map(\.id)
        XCTAssertEqual(Set(table.keys), Set(light))
        XCTAssertEqual(table["catppuccin-latte"], "catppuccin")
        XCTAssertEqual(table["white"], "vantablack")
        XCTAssertTrue(table.values.allSatisfy { id in themes.first { $0.id == id }?.isDark == true })
    }

    func testUserPairsWinAndPartnersWorkBothWays() {
        let table = ThemePairing.table(for: themes, overrides: ["catppuccin-latte": "nord"])
        XCTAssertEqual(table["catppuccin-latte"], "nord")
        XCTAssertEqual(ThemePairing.partner(of: "catppuccin", in: themes), "catppuccin-latte")
        XCTAssertEqual(ThemePairing.partner(of: "catppuccin-latte", in: themes), "catppuccin")
        XCTAssertEqual(ThemePairing.partner(of: "", in: themes), "")
    }

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000))!
    }

    func testScheduleFlipsAtItsTimesAndAcrossMidnight() {
        let schedule = ThemeSchedule(lightStart: 7 * 60, darkStart: 19 * 60)
        XCTAssertTrue(schedule.isDark(at: date(6, 59)))
        XCTAssertFalse(schedule.isDark(at: date(7)))
        XCTAssertFalse(schedule.isDark(at: date(18, 59)))
        XCTAssertTrue(schedule.isDark(at: date(19)))
        XCTAssertEqual(schedule.nextChange(after: date(12)), date(19))
        XCTAssertGreaterThan(schedule.nextChange(after: date(20)), date(20))

        let nightShift = ThemeSchedule(lightStart: 22 * 60, darkStart: 6 * 60)
        XCTAssertTrue(nightShift.isDark(at: date(12)))
        XCTAssertFalse(nightShift.isDark(at: date(23)))
    }

    func testModesPickTheRightMember() {
        var appearance = ThemeAppearance(mode: .light, lightThemeID: "catppuccin-latte", darkThemeID: "catppuccin")
        XCTAssertEqual(appearance.themeID(at: date(12), systemIsDark: true), "catppuccin-latte")
        appearance.mode = .dark
        XCTAssertEqual(appearance.themeID(at: date(12), systemIsDark: false), "catppuccin")
        appearance.mode = .automatic
        XCTAssertEqual(appearance.themeID(at: date(12), systemIsDark: true), "catppuccin")
        XCTAssertEqual(appearance.themeID(at: date(12), systemIsDark: false), "catppuccin-latte")
        appearance.mode = .scheduled
        XCTAssertEqual(appearance.themeID(at: date(22), systemIsDark: false), "catppuccin")
    }
}

final class ThemeFileTests: XCTestCase {
    func testColorsTomlRoundTrip() throws {
        let original = try XCTUnwrap(ColorTheme.builtIn.first { $0.id == "gruvbox" })
        let text = ColorsToml.write(original)
        XCTAssertTrue(text.contains("mode = \"dark\""))
        XCTAssertTrue(text.contains("background = \"#282828\""))
        let read = try XCTUnwrap(ColorsToml.read(text, id: "gruvbox-copy", name: "Gruvbox Copy"))
        XCTAssertEqual(read.background, original.background)
        XCTAssertEqual(read.foreground, original.foreground)
        XCTAssertEqual(read.accent, original.accent)
        XCTAssertEqual(read.selection, original.selection)
        XCTAssertEqual(read.ansi, original.ansi)
        XCTAssertEqual(read.isDark, original.isDark)
        XCTAssertTrue(read.isUserTheme)
    }

    func testReadsOmarchyStyleFilesWithFallbacks() throws {
        let toml = """
        # comment
        accent = "#89b4fa"
        background = "#1e1e2e"  # trailing comment
        foreground = '#cdd6f4'
        red = "#f38ba8"
        """
        let theme = try XCTUnwrap(ColorsToml.read(toml, id: "x", name: "X"))
        XCTAssertEqual(theme.ansi?.count, 16)
        XCTAssertEqual(theme.ansi?[1], "#f38ba8")
        XCTAssertEqual(theme.ansi?[9], RGB(hex: "#f38ba8")!.mix(RGB(red: 1, green: 1, blue: 1), 0.2).hex, "bright red derived")
        XCTAssertTrue(theme.isDark)
        XCTAssertNil(ColorsToml.read("accent = \"#ffffff\"", id: "y", name: "Y"), "no background, no theme")
    }

    func testIDsMatchTheGuestRule() {
        XCTAssertEqual(ColorsToml.id(forName: "My Theme!"), "my-theme-")
        XCTAssertEqual(ColorsToml.id(forName: "  "), "custom")
        XCTAssertTrue(ColorsToml.id(forName: "../etc").allSatisfy { $0.isLetter || $0.isNumber || "._+-".contains($0) })
        XCTAssertFalse(ColorsToml.id(forName: "../etc").hasPrefix("."))
    }

    func testContrastMatchesWCAG() throws {
        let black = RGB(red: 0, green: 0, blue: 0), white = RGB(red: 1, green: 1, blue: 1)
        XCTAssertEqual(ColorContrast.ratio(black, white), 21, accuracy: 0.01)
        XCTAssertEqual(ColorContrast.ratio(white, white), 1, accuracy: 0.001)
        let grey = try XCTUnwrap(RGB(hex: "#767676"))
        XCTAssertEqual(ColorContrast.ratio(grey, white), 4.54, accuracy: 0.01)
        XCTAssertEqual(ColorContrast.grade(4.54), .aa)
        XCTAssertEqual(ColorContrast.grade(7.1), .aaa)
        XCTAssertEqual(ColorContrast.grade(3.2), .aaLarge)
        XCTAssertEqual(ColorContrast.grade(2), .fail)
    }

    func testImportKeepsOnlyThemeDataLikeIshColorsInstall() {
        typealias Entry = ThemeImportSanitizer.Entry
        let png = Data([0x89, 0x50])
        let entries = [
            Entry(path: "omarchy-forest-theme/colors.toml", data: Data("background = \"#000000\"".utf8)),
            Entry(path: "omarchy-forest-theme/icons.theme", data: Data("Yaru-red; rm -rf /\n".utf8)),
            Entry(path: "omarchy-forest-theme/light.mode", data: Data()),
            Entry(path: "omarchy-forest-theme/backgrounds/1-forest.png", data: png),
            Entry(path: "omarchy-forest-theme/backgrounds/evil.sh", data: Data()),
            Entry(path: "omarchy-forest-theme/backgrounds/link.png", data: png, isSymlink: true),
            Entry(path: "omarchy-forest-theme/hyprland.lua", data: Data()),
            Entry(path: "omarchy-forest-theme/alacritty.toml", data: Data()),
            Entry(path: "omarchy-forest-theme/install", data: Data(), isExecutable: true),
            Entry(path: "omarchy-forest-theme/../../etc/passwd", data: Data()),
            Entry(path: "omarchy-forest-theme/backgrounds/huge.jpg", data: Data(count: ThemeImportSanitizer.maximumImageSize + 1)),
        ]
        let kept = ThemeImportSanitizer.sanitize(ThemeImportSanitizer.strippingCommonRoot(entries))
        XCTAssertEqual(kept.map(\.path).sorted(), ["backgrounds/1-forest.png", "colors.toml", "icons.theme", "light.mode"])
        XCTAssertEqual(String(decoding: kept.first { $0.path == "icons.theme" }!.data, as: UTF8.self), "Yaru-redrm-rf")
    }

    func testThemeFilesFollowTheGuestLayout() throws {
        let light = try XCTUnwrap(ColorTheme.builtIn.first { $0.id == "catppuccin-latte" })
        let names = ThemeFiles.files(for: light).map(\.0)
        XCTAssertEqual(names, ["colors.toml", "theme.conf", "light.mode", "icons.theme"], "icons.theme only when the theme names a pack")
        let dark = try XCTUnwrap(ColorTheme.builtIn.first { $0.id == "nord" })
        XCTAssertFalse(ThemeFiles.files(for: dark).map(\.0).contains("light.mode"))
    }

    func testDraftBuildsAValidTheme() {
        var draft = ThemeDraft()
        draft.name = "Night Owl"
        draft.background = "#011627"
        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(draft.theme.id, "night-owl")
        XCTAssertEqual(draft.theme.ansi?[0], "#011627", "black follows the background")
        draft.accent = "nope"
        XCTAssertFalse(draft.isValid)
    }
}

final class DesktopStylingTests: XCTestCase {
    func testDefaultsChangeNothing() {
        let base = DesktopTheme.dark
        let styled = DesktopStyling().applied(to: base)
        XCTAssertEqual(styled.cornerRadius, base.cornerRadius)
        XCTAssertEqual(styled.borderWidth, base.borderWidth)
        XCTAssertTrue(styled.showsFocusRing)
        XCTAssertTrue(styled.showsWindowShadows)
        XCTAssertNil(DesktopStyling().linuxFontArguments, "no guest call without a choice")
    }

    func testKnobsApply() {
        var styling = DesktopStyling()
        styling.cornerRadius = 0
        styling.borderWidth = 3
        styling.focusRing = .gradient
        styling.windowShadows = false
        styling.panelOpacity = 0.5
        let styled = styling.applied(to: .dark)
        XCTAssertEqual(styled.cornerRadius, 0)
        XCTAssertEqual(styled.borderWidth, 3)
        XCTAssertNotNil(styled.borderGradientEnd)
        XCTAssertFalse(styled.showsWindowShadows)
        XCTAssertEqual(styled.panelBackground.opacityComponent, 0.5, accuracy: 0.02)
        styling.focusRing = .none
        XCTAssertFalse(styling.applied(to: .dark).showsFocusRing)
    }

    func testLinuxFontArguments() {
        var styling = DesktopStyling()
        styling.linuxUIFont = "Inter"
        styling.linuxMonoFont = "JetBrains Mono"
        styling.fontScale = 1.2
        styling.cursorSize = 32
        XCTAssertEqual(styling.linuxFontArguments, ["Inter 13", "JetBrains Mono", "13", "32"])
    }

    func testLooksAndStylingPersist() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DesktopStylingTests"))
        defer { defaults.removePersistentDomain(forName: "DesktopStylingTests") }
        var styling = DesktopStyling()
        styling.innerGap = 5
        styling.outerGap = 10
        styling.save(to: defaults)
        XCTAssertEqual(DesktopStyling.load(from: defaults), styling)
        let look = DesktopLook(id: "mine", name: "Mine", styleID: "macos", colorThemeID: "nord", styling: styling)
        DesktopLook.saveUserLooks([look], to: defaults)
        XCTAssertEqual(DesktopLook.loadUserLooks(from: defaults), [look])
        XCTAssertEqual(DesktopLook.builtIn.first?.colorThemeID, "tokyo-night")
        XCTAssertEqual(DesktopLook.builtIn.first?.styling.cornerRadius, 0, "Omarchy Tokyo Night has square corners")
    }
}
