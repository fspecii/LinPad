import SwiftUI
import XCTest
@testable import DesktopKit

/// Applies every desktop theme (both members of paired ones), every colour theme and every
/// style from several starting states, and checks what the desktop ends up with and what
/// reached the (mock) guest.
final class DesktopThemeApplyTests: XCTestCase {
    private let keys = [DesktopStyle.storageKey, ColorThemeStore.storageKey, DesktopAppearance.storageKey,
                        DesktopStyling.storageKey, ThemeAppearance.storageKey, WallpaperStore.settingsKey,
                        DesktopThemePreset.storageKey, DesktopThemePreset.snapshotKey, DesktopThemePreset.widgetsKey,
                        EraSettings.brushedMetalKey, LinuxDeviceInfo.colorThemeNameKey, WidgetBoard.storageKey]
    /// Runs `body` on clean settings and puts the previous ones back afterwards.
    @MainActor
    private func withCleanDefaults(_ body: () throws -> Void) rethrows {
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        try body()
    }

    private enum Start: String, CaseIterable {
        case fresh, retro, darkColours, tiler
    }

    /// What DesktopRootView does when the stored style or the colours change.
    @MainActor
    private func settle(_ controller: DesktopController) {
        let style = DesktopStyle.stored(UserDefaults.standard.string(forKey: DesktopStyle.storageKey) ?? "")
        controller.applyStyle(style, dark: isDark(controller, style: style))
        // applyStyle hands the guest side to a Task on the main actor; let it run.
        for _ in 0..<20 where controller.icons.style != style || controller.icons.isDark != isDark(controller, style: style) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    @MainActor
    private func isDark(_ controller: DesktopController, style: DesktopStyle) -> Bool {
        if let colors = controller.colorThemes.active { return colors.isDark }
        let appearance = DesktopAppearance(rawValue: UserDefaults.standard.string(forKey: DesktopAppearance.storageKey) ?? "") ?? .styleDefault
        return appearance.isDark(style: style, system: .light)
    }

    @MainActor
    private func makeController(_ start: Start) -> (DesktopController, MockLinuxHost) {
        let host = MockLinuxHost(latency: .zero)
                let controller = DesktopController(host: host, apps: BuiltinApps.all())
        switch start {
        case .fresh:
            break
        case .retro:
            controller.applyDesktopThemePreset(DesktopThemePreset.preset("classic-98")!)
        case .darkColours:
            UserDefaults.standard.set(DesktopStyle.windows.rawValue, forKey: DesktopStyle.storageKey)
            controller.applyColorTheme("tokyo-night")
        case .tiler:
            UserDefaults.standard.set(DesktopStyle.tiler.rawValue, forKey: DesktopStyle.storageKey)
        }
        settle(controller)
        return (controller, host)
    }

    @MainActor
    private func waitForCommand(_ host: MockLinuxHost, containing needle: String, file: StaticString = #filePath,
                                line: UInt = #line) {
        // The guest calls run in Tasks on the main actor; spinning the run loop lets them go.
        for _ in 0..<100 where !host.commandLog.contains(where: { $0.contains(needle) }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(host.commandLog.contains { $0.contains(needle) }, "guest never got: \(needle)", file: file, line: line)
    }

    @MainActor
    func testEveryDesktopThemeAppliesFromEveryStart() throws {
        try withCleanDefaults {
            var failures: [String] = []
            for start in Start.allCases {
                for preset in DesktopThemePreset.all {
                    for dark in preset.darkColorTheme != nil ? [false, true] : [false] {
                        let (controller, host) = makeController(start)
                        controller.applyDesktopThemePreset(preset, dark: preset.darkColorTheme != nil ? dark : nil)
                        settle(controller)
                        let label = "\(preset.id)\(dark ? " dark" : "") from \(start)"
                        let colors = dark ? preset.darkColorTheme! : (preset.startsDark ? (preset.darkColorTheme ?? preset.lightColorTheme)
                                                                                           : preset.lightColorTheme)
                        let defaults = UserDefaults.standard
                        if defaults.string(forKey: DesktopStyle.storageKey) != preset.style.rawValue { failures.append("\(label): stored style") }
                        if controller.style != preset.style { failures.append("\(label): shell style \(controller.style)") }
                        if controller.colorThemes.currentID != colors { failures.append("\(label): colours \(controller.colorThemes.currentID) != \(colors)") }
                        if controller.themeAppearance.isEnabled { failures.append("\(label): light/dark switching left on") }
                        if controller.styling != preset.styling { failures.append("\(label): styling") }
                        let wallpaper = (dark ? (preset.darkWallpaper ?? preset.wallpaper) : preset.wallpaper).source
                        let shown = controller.wallpapers.settings.source(workspace: 0, isDark: isDark(controller, style: preset.style))
                        if shown != wallpaper { failures.append("\(label): wallpaper \(shown)") }
                        if !colors.isEmpty {
                            let theme = controller.colorThemes.theme(colors)
                            if theme == nil { failures.append("\(label): colour theme \(colors) not bundled") }
                            if let theme, dark && !theme.isDark { failures.append("\(label): dark member is light") }
                            waitForCommand(host, containing: "ish-apply-colors \(ShellQuote.quote(colors))")
                        }
                        if controller.icons.style != preset.style { failures.append("\(label): guest style \(controller.icons.style)") }
                        if controller.icons.isDark != isDark(controller, style: preset.style) { failures.append("\(label): guest variant") }
                        let active = defaults.string(forKey: DesktopThemePreset.storageKey) ?? ""
                        if !active.hasPrefix(preset.id) { failures.append("\(label): active id \(active)") }
                        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
                    }
                }
            }
            XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
        }
    }

    @MainActor
    func testDarkMemberSurvivesLaterAppearanceEvaluation() throws {
        try withCleanDefaults {
            let (controller, _) = makeController(.fresh)
            controller.applyDesktopThemePreset(DesktopThemePreset.preset("dot-matrix")!, dark: true)
            controller.evaluateThemeAppearance()
            controller.systemIsDark = false
            controller.evaluateThemeAppearance()
            XCTAssertEqual(controller.colorThemes.currentID, "dot-matrix-dark")
            // Picking the light member in the gallery afterwards works too.
            controller.applyColorTheme("dot-matrix")
            controller.evaluateThemeAppearance()
            XCTAssertEqual(controller.colorThemes.currentID, "dot-matrix")
        }
    }

    @MainActor
    func testEveryColourThemeAppliesFromEveryStart() throws {
        try withCleanDefaults {
            XCTAssertEqual(ColorTheme.builtIn.count, 29)
            for start in Start.allCases {
                let (controller, host) = makeController(start)
                for theme in ColorTheme.builtIn {
                    controller.applyColorTheme(theme.id)
                    settle(controller)
                    XCTAssertEqual(controller.colorThemes.currentID, theme.id, "\(theme.id) from \(start)")
                    XCTAssertEqual(controller.icons.isDark, theme.isDark, "\(theme.id) guest variant from \(start)")
                    waitForCommand(host, containing: "ish-apply-colors \(ShellQuote.quote(theme.id))")
                }
            }
        }
    }

    @MainActor
    func testEveryStyleAppliesAndRevertRestores() throws {
        try withCleanDefaults {
            let (controller, _) = makeController(.darkColours)
            for style in DesktopStyle.allCases {
                UserDefaults.standard.set(style.rawValue, forKey: DesktopStyle.storageKey)
                settle(controller)
                XCTAssertEqual(controller.style, style)
                XCTAssertEqual(controller.icons.style, style)
            }
            let before = (UserDefaults.standard.string(forKey: DesktopStyle.storageKey), controller.colorThemes.currentID)
            controller.applyDesktopThemePreset(DesktopThemePreset.preset("luna")!)
            controller.applyDesktopThemePreset(DesktopThemePreset.preset("aero")!, dark: true)
            controller.revertDesktopThemePreset()
            settle(controller)
            XCTAssertEqual(UserDefaults.standard.string(forKey: DesktopStyle.storageKey), before.0)
            XCTAssertEqual(controller.colorThemes.currentID, before.1)
            XCTAssertNil(UserDefaults.standard.string(forKey: DesktopThemePreset.storageKey))
        }
    }
}

/// Looks: every built-in look (the desktop themes included, both members of paired ones) and
/// a look per style, applied from several starting states; saved looks from earlier builds
/// still decode.
final class DesktopLookApplyTests: XCTestCase {
    private let keys = [DesktopStyle.storageKey, ColorThemeStore.storageKey, DesktopAppearance.storageKey,
                        DesktopStyling.storageKey, ThemeAppearance.storageKey, WallpaperStore.settingsKey,
                        DesktopThemePreset.storageKey, DesktopThemePreset.snapshotKey, DesktopThemePreset.widgetsKey,
                        EraSettings.brushedMetalKey, LinuxDeviceInfo.colorThemeNameKey, WidgetBoard.storageKey,
                        DesktopLook.storageKey]

    @MainActor
    private func withCleanDefaults(_ body: () throws -> Void) rethrows {
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        try body()
    }

    @MainActor
    private func settle(_ controller: DesktopController) {
        let style = DesktopStyle.stored(UserDefaults.standard.string(forKey: DesktopStyle.storageKey) ?? "")
        let dark = controller.colorThemes.active?.isDark
            ?? (DesktopAppearance(rawValue: UserDefaults.standard.string(forKey: DesktopAppearance.storageKey) ?? "") ?? .styleDefault)
                .isDark(style: style, system: .light)
        controller.applyStyle(style, dark: dark)
    }

    private var allLooks: [DesktopLook] {
        DesktopLook.builtIn + DesktopStyle.allCases.map { style in
            DesktopLook(id: "test-\(style.rawValue)", name: style.displayName, styleID: style.rawValue,
                        colorThemeID: "", styling: DesktopStyling(), wallpaperQuery: nil, appearanceID: "light")
        } + [DesktopLook(id: "test-dot-dark", name: "Saved Dot Dark", styleID: "dotmatrix", colorThemeID: "dot-matrix-dark",
                         styling: DesktopStyling(), wallpaperQuery: nil)]
    }

    @MainActor
    func testEveryLookAppliesFromEveryStart() throws {
        try withCleanDefaults {
            var failures: [String] = []
            let starts: [(String, (DesktopController) -> Void)] = [
                ("fresh", { _ in }),
                ("retro", { $0.applyDesktopThemePreset(DesktopThemePreset.preset("dot-matrix")!, dark: true) }),
                ("darkColours", { $0.applyColorTheme("tokyo-night") }),
                ("tiler", { _ in UserDefaults.standard.set("tiler", forKey: DesktopStyle.storageKey) }),
            ]
            for (startName, start) in starts {
                for look in allLooks {
                    let controller = DesktopController(host: MockLinuxHost(latency: .zero), apps: BuiltinApps.all())
                    start(controller)
                    settle(controller)
                    controller.applyLook(look)
                    settle(controller)
                    let label = "\(look.id) from \(startName)"
                    if controller.style != look.style { failures.append("\(label): style \(controller.style)") }
                    if UserDefaults.standard.string(forKey: DesktopStyle.storageKey) != look.style.rawValue {
                        failures.append("\(label): stored style")
                    }
                    if controller.colorThemes.currentID != look.colorThemeID {
                        failures.append("\(label): colours \(controller.colorThemes.currentID) != \(look.colorThemeID)")
                    }
                    if controller.styling != look.styling { failures.append("\(label): styling") }
                    if controller.themeAppearance.isEnabled { failures.append("\(label): light/dark switching on") }
                    let active = UserDefaults.standard.string(forKey: DesktopThemePreset.storageKey) ?? ""
                    if let preset = look.presetID {
                        if !active.hasPrefix(preset) { failures.append("\(label): preset not marked applied") }
                    } else if !active.isEmpty {
                        failures.append("\(label): stale preset \(active)")
                    }
                    for key in keys { UserDefaults.standard.removeObject(forKey: key) }
                }
            }
            XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
        }
    }

    @MainActor
    func testLooksRoundTripAndOldSavedLooksDecode() throws {
        for look in allLooks {
            let data = try JSONEncoder().encode(look)
            XCTAssertEqual(try JSONDecoder().decode(DesktopLook.self, from: data), look, look.id)
        }
        // As saved by the build before desktop themes (no presetID, wallpaper, brushedMetal),
        // and a styling blob missing keys a newer build added.
        let old = """
        [{"id":"user-1a2b3c4d","name":"My Dot","styleID":"dotmatrix","colorThemeID":"dot-matrix-dark",
          "styling":{"cornerRadius":18,"windowShadows":false,"panelBlur":false,"uiFont":"monospaced",
                     "fontScale":1,"animation":"normal","focusRing":"accent"},
          "wallpaperQuery":"black minimalist dots","isBuiltIn":false},
         {"id":"user-2","name":"Bare","styleID":"luna","colorThemeID":"luna","styling":{}}]
        """
        let looks = try JSONDecoder().decode([DesktopLook].self, from: Data(old.utf8))
        XCTAssertEqual(looks.count, 2)
        XCTAssertEqual(looks[0].style, .dotmatrix)
        XCTAssertEqual(looks[0].styling.cornerRadius, 18)
        XCTAssertEqual(looks[0].styling.uiFont, .monospaced)
        XCTAssertNil(looks[0].presetID)
        XCTAssertEqual(looks[1].styling, DesktopStyling())
        XCTAssertEqual(looks[1].style, .luna)
    }

    @MainActor
    func testEveryDesktopThemeHasALook() {
        for preset in DesktopThemePreset.all {
            let looks = DesktopLook.builtIn.filter { $0.presetID == preset.id }
            XCTAssertEqual(looks.count, preset.darkColorTheme != nil ? 2 : 1, preset.id)
        }
        XCTAssertNotNil(DesktopLook.builtIn.first { $0.id == "desktop-theme-dot-matrix-dark" })
    }
}
