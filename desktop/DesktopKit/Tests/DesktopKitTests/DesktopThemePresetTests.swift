import SwiftUI
import XCTest
@testable import DesktopKit

final class DesktopThemePresetTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    func testEveryEraStyleHasASkinAndOnlyThoseDo() {
        let era: [DesktopStyle] = [.luna, .aero, .aeronight, .classic, .platinum, .aqua, .berry, .dotmatrix]
        for style in DesktopStyle.allCases {
            XCTAssertEqual(style.spec.skin != nil, era.contains(style), style.rawValue)
            XCTAssertEqual(EraSkin(style: style), style.spec.skin, style.rawValue)
            XCTAssertEqual(DesktopStyle.stored(style.rawValue), style)
        }
        XCTAssertEqual(Set(era.compactMap(EraSkin.init(style:))), Set(EraSkin.allCases))
    }

    func testEraSpecsUseEraChromeAndTouchSizedControls() {
        for skin in EraSkin.allCases {
            let style = DesktopStyle.allCases.first { EraSkin(style: $0) == skin }!
            let spec = style.spec
            XCTAssertEqual(spec.buttonShape, .era, style.rawValue)
            XCTAssertGreaterThanOrEqual(spec.touchMetrics.buttonSize, 44)
            XCTAssertGreaterThanOrEqual(spec.touchMetrics.titleBarHeight, 40)
            if spec.launcher == .eraMenu {
                XCTAssertTrue(spec.shell == .taskbar || spec.shell == .menuBarAndDock, style.rawValue)
            }
        }
        XCTAssertEqual(DesktopStyle.platinum.spec.buttonPlacement, .split)
        XCTAssertEqual(EraSkin.platinum.launcherAlignment, .topLeading)
        XCTAssertEqual(EraSkin.luna.launcherAlignment, .bottomLeading)
    }

    func testDotMatrixFontRegisters() throws {
        _ = EraFonts.dot(size: 12)
        XCTAssertNotNil(UIFont(name: EraFonts.dotFamily, size: 12), "LinPadDot resolves after registration")
    }

    func testButtonOrderPerEraAndSide() {
        XCTAssertEqual(EraWindowButtons.kinds(for: .platinum, side: .leading), [.close])
        XCTAssertEqual(EraWindowButtons.kinds(for: .platinum, side: .trailing), [.maximize, .minimize])
        XCTAssertEqual(EraWindowButtons.kinds(for: .aqua, side: .leading), [.close, .minimize, .maximize])
        XCTAssertEqual(EraWindowButtons.kinds(for: .luna, side: .trailing), [.minimize, .maximize, .close])
    }

    func testPresetsReferenceShippedColourThemesAndWallpapers() {
        let ids = Set(ColorTheme.builtIn.map(\.id))
        XCTAssertEqual(Set(DesktopThemePreset.all.map(\.id)).count, DesktopThemePreset.all.count)
        for preset in DesktopThemePreset.all {
            if !preset.lightColorTheme.isEmpty { XCTAssertTrue(ids.contains(preset.lightColorTheme), preset.id) }
            if let dark = preset.darkColorTheme {
                XCTAssertEqual(ColorTheme.builtIn.first { $0.id == dark }?.isDark, true, preset.id)
                XCTAssertNotEqual(dark, preset.lightColorTheme)
            }
            for wallpaper in [preset.wallpaper, preset.darkWallpaper].compactMap({ $0 }) {
                if case .builtIn(let name) = wallpaper {
                    XCTAssertTrue(BuiltInWallpapers.names.contains(name), name)
                    XCTAssertNotNil(BuiltInWallpapers.url(for: BuiltInWallpapers.prefix + name + ".jpg"), name)
                }
            }
        }
        let names = DesktopThemePreset.all.map(\.name).joined(separator: " ")
        for mark in ["Windows", "Microsoft", "Mac OS", "macOS", "Apple", "BlackBerry", "Nothing"] {
            XCTAssertFalse(names.contains(mark), mark)
        }
    }

    func testEveryStyleHasAGuestConfAndPacksExistInTheCatalogue() throws {
        let styles = repo.appendingPathComponent("themes/guest/styles")
        let packs = try String(contentsOf: repo.appendingPathComponent("themes/guest/ish-style-packs"), encoding: .utf8)
        for style in DesktopStyle.allCases {
            let conf = styles.appendingPathComponent("\(style.rawValue).conf")
            let text = try String(contentsOf: conf, encoding: .utf8)
            for key in ["GTK_THEME_light", "GTK_THEME_dark", "ICON_THEME_light", "FONT", "BUTTON_LAYOUT"] {
                XCTAssertTrue(text.contains("\(key)="), "\(style.rawValue): \(key)")
            }
            if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("STYLE_PACKS=") }) {
                let ids = line.dropFirst("STYLE_PACKS=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                for id in ids.split(separator: " ") { XCTAssertTrue(packs.contains("\n\(id)|"), "\(style.rawValue): \(id)") }
            }
        }
    }

    func testDesktopThemePalettesDecodeAndLeaveStyleWidgetsWhereAsked() throws {
        let colors = repo.appendingPathComponent("themes/desktop-themes/colors")
        for id in try FileManager.default.contentsOfDirectory(atPath: colors.path) {
            let toml = try String(contentsOf: colors.appendingPathComponent("\(id)/colors.toml"), encoding: .utf8)
            let theme = try XCTUnwrap(ColorsToml.read(toml, id: id, name: id), id)
            XCTAssertEqual(theme.ansi?.count, 16, id)
            XCTAssertNotNil(ColorTheme.builtIn.first { $0.id == id }, "\(id) missing from themes.json")
            let conf = try String(contentsOf: colors.appendingPathComponent("\(id)/theme.conf"), encoding: .utf8)
            XCTAssertTrue(conf.contains("name="), id)
        }
    }

    func testPresetApplyAndRevertRoundTrip() throws {
        let snapshot = DesktopThemeSnapshot(styleID: "ish", colorThemeID: "nord", appearanceID: "dark",
                                            styling: DesktopStyling(), wallpaper: WallpaperSettings(),
                                            themeAppearance: ThemeAppearance(), brushedMetal: false)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(DesktopThemeSnapshot.self, from: data), snapshot)
        XCTAssertEqual(DesktopThemePreset.Wallpaper.color(0x008080).source, .color(0x008080))
        XCTAssertEqual(DesktopThemePreset.Wallpaper.builtIn("meadow").source, .image("builtin-meadow"))
        XCTAssertEqual(ThemePairing.partner(of: "dot-matrix", in: ColorTheme.builtIn), "dot-matrix-dark")
        XCTAssertEqual(ThemePairing.partner(of: "aero", in: ColorTheme.builtIn), "aero-night")
    }
}
