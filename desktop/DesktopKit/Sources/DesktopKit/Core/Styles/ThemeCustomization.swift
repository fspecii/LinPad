import Foundation
import SwiftUI

// MARK: - Advanced styling

/// The Themes app's styling knobs, applied live over the style and colour theme. A nil
/// value keeps the style's own choice. Persisted as JSON under `desktop.styling`.
struct DesktopStyling: Codable, Equatable, Sendable {
    enum FocusRing: String, Codable, CaseIterable, Identifiable, Sendable {
        case accent, gradient, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .accent: "Accent"
            case .gradient: "Gradient"
            case .none: "None"
            }
        }
    }

    /// Native UI typeface: SF's designs (the iPad's own fonts).
    enum UIFontDesign: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, rounded, serif, monospaced
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var design: Font.Design {
            switch self {
            case .system: .default
            case .rounded: .rounded
            case .serif: .serif
            case .monospaced: .monospaced
            }
        }
    }

    enum AnimationSpeed: String, Codable, CaseIterable, Identifiable, Sendable {
        case off, fast, normal
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    /// Fonts installed in the guest image for Linux apps.
    static let linuxUIFonts = ["Cantarell", "Inter", "Noto Sans", "Ubuntu", "JetBrains Mono"]
    static let linuxMonoFonts = ["JetBrains Mono", "Noto Sans Mono", "DejaVu Sans Mono", "Ubuntu Mono"]
    static let cursorSizes = [24, 32, 48]

    var cornerRadius: Double?
    var borderWidth: Double?
    var focusRing: FocusRing = .accent
    var innerGap: Double?
    var outerGap: Double?
    var windowShadows = true
    /// 0.3 … 1; nil keeps the style's translucency.
    var panelOpacity: Double?
    var panelBlur = true
    var uiFont: UIFontDesign = .system
    /// 0.9 … 1.2: Linux apps' font size and the native monospaced text.
    var fontScale: Double = 1
    var linuxUIFont: String?
    var linuxMonoFont: String?
    var monoFontSize: Double?
    var animation: AnimationSpeed = .normal
    var cursorSize: Int?

    static let storageKey = "desktop.styling"

    static func load(from defaults: UserDefaults = .standard) -> DesktopStyling {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(DesktopStyling.self, from: $0) } ?? DesktopStyling()
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }

    /// The knobs that reach the guest (`ish-apply-colors --fonts`); nil means style defaults.
    var linuxFontArguments: [String]? {
        guard linuxUIFont != nil || linuxMonoFont != nil || cursorSize != nil || fontScale != 1 || monoFontSize != nil else {
            return nil
        }
        let uiSize = Int((11 * fontScale).rounded())
        let monoSize = Int(((monoFontSize ?? 11) * fontScale).rounded())
        return ["\(linuxUIFont ?? "Cantarell") \(uiSize)", linuxMonoFont ?? "JetBrains Mono", "\(monoSize)", "\(cursorSize ?? 24)"]
    }

    /// Applies the overrides to a theme (the gaps and zen live in the window manager).
    func applied(to base: DesktopTheme) -> DesktopTheme {
        var theme = base
        if let cornerRadius { theme.cornerRadius = cornerRadius }
        if let borderWidth { theme.borderWidth = borderWidth }
        switch focusRing {
        case .accent: break
        case .gradient: theme.borderGradientEnd = theme.secondaryText
        case .none: theme.showsFocusRing = false
        }
        if let panelOpacity { theme.panelBackground = theme.panelBackground.opacity(panelOpacity / max(theme.panelBackground.opacityComponent, 0.01)) }
        theme.showsWindowShadows = theme.showsWindowShadows && windowShadows
        theme.panelBlur = theme.panelBlur && panelBlur
        if let monoFontSize { theme.monospacedFontSize = monoFontSize * fontScale }
        return theme
    }
}

// MARK: - Light / dark pairing and schedule

/// When the light or the dark member of a theme pair is active.
enum ThemeAppearanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case light, dark, automatic, scheduled
    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .automatic: "Automatic"
        case .scheduled: "Scheduled"
        }
    }
}

struct ThemeSchedule: Codable, Equatable, Sendable {
    /// Minutes after midnight. Defaults are fixed sunrise/sunset times, no location needed.
    var lightStart = 7 * 60
    var darkStart = 19 * 60

    func isDark(at date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if lightStart == darkStart { return false }
        if lightStart < darkStart { return !(minute >= lightStart && minute < darkStart) }
        return minute >= darkStart && minute < lightStart
    }

    /// The next moment the schedule flips, for a timer.
    func nextChange(after date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        let candidates = [lightStart, darkStart].flatMap { minute in
            [0, 1].compactMap { day in
                calendar.date(byAdding: .minute, value: minute + day * 24 * 60, to: start)
            }
        }
        return candidates.filter { $0 > date }.min() ?? date.addingTimeInterval(3600)
    }
}

/// The theme for light and for dark, and the mode that picks between them.
struct ThemeAppearance: Codable, Equatable, Sendable {
    var mode: ThemeAppearanceMode = .dark
    var lightThemeID = ""
    var darkThemeID = ""
    var schedule = ThemeSchedule()
    /// User edits to the pairing table: light id → dark id.
    var pairs: [String: String] = [:]
    /// Off until the user picks a mode in the Themes app; then the mode drives the theme.
    var isEnabled = false

    static let storageKey = "desktop.themeAppearance"

    static func load(from defaults: UserDefaults = .standard) -> ThemeAppearance {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(ThemeAppearance.self, from: $0) } ?? ThemeAppearance()
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }

    func wantsDark(at date: Date, systemIsDark: Bool) -> Bool {
        switch mode {
        case .light: false
        case .dark: true
        case .automatic: systemIsDark
        case .scheduled: schedule.isDark(at: date)
        }
    }

    func themeID(at date: Date, systemIsDark: Bool) -> String {
        wantsDark(at: date, systemIsDark: systemIsDark) ? darkThemeID : lightThemeID
    }
}

enum ThemePairing {
    /// Pairs that share a family name upstream; the rest are matched by accent hue.
    static let known: [String: String] = [
        "catppuccin-latte": "catppuccin",
        "rose-pine": "kanagawa",
        "flexoki-light": "matte-black",
        "lupine": "tokyo-night",
        "white": "vantablack",
        "aero": "aero-night",
        "dot-matrix": "dot-matrix-dark",
    ]

    /// light id → dark id for every light theme, user overrides first.
    static func table(for themes: [ColorTheme], overrides: [String: String] = [:]) -> [String: String] {
        let dark = themes.filter(\.isDark)
        var table: [String: String] = [:]
        for light in themes where !light.isDark {
            if let chosen = overrides[light.id], dark.contains(where: { $0.id == chosen }) {
                table[light.id] = chosen
            } else if let known = known[light.id], dark.contains(where: { $0.id == known }) {
                table[light.id] = known
            } else if let nearest = dark.min(by: { distance($0.accentRGB, light.accentRGB) < distance($1.accentRGB, light.accentRGB) }) {
                table[light.id] = nearest.id
            }
        }
        return table
    }

    /// The other member of a theme's pair ("" pairs with "").
    static func partner(of id: String, in themes: [ColorTheme], overrides: [String: String] = [:]) -> String {
        guard !id.isEmpty else { return "" }
        let table = table(for: themes, overrides: overrides)
        if let dark = table[id] { return dark }
        return table.first { $0.value == id }?.key ?? id
    }

    private static func distance(_ a: RGB, _ b: RGB) -> Double {
        let dr = a.red - b.red, dg = a.green - b.green, db = a.blue - b.blue
        return dr * dr + dg * dg + db * db
    }
}

// MARK: - Contrast

enum ColorContrast {
    /// WCAG 2 relative luminance.
    static func luminance(_ color: RGB) -> Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }

    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    enum Grade: String {
        case aaa = "AAA", aa = "AA", aaLarge = "AA Large", fail = "Fail"
    }

    static func grade(_ ratio: Double) -> Grade {
        if ratio >= 7 { return .aaa }
        if ratio >= 4.5 { return .aa }
        if ratio >= 3 { return .aaLarge }
        return .fail
    }
}

// MARK: - colors.toml

/// Omarchy's colors.toml: `key = "#rrggbb"` lines, `mode = "dark"|"light"`.
enum ColorsToml {
    static let ansiKeys = ["background", "red", "green", "yellow", "blue", "magenta", "cyan", "foreground",
                           "muted", "bright_red", "bright_green", "bright_yellow", "bright_blue", "bright_magenta",
                           "bright_cyan", "bright_foreground"]

    static func write(_ theme: ColorTheme) -> String {
        var lines = ["# Written by the LinPad Themes app (colors.toml, as used by Omarchy community themes).",
                     "mode = \"\(theme.isDark ? "dark" : "light")\"", ""]
        func line(_ key: String, _ value: String?) {
            guard let value, RGB(hex: value) != nil else { return }
            lines.append("\(key) = \"\(value.lowercased())\"")
        }
        line("accent", theme.accent)
        line("selection", theme.selection)
        line("cursor", theme.cursor)
        lines.append("")
        let ansi = theme.ansi ?? []
        for (index, key) in ansiKeys.enumerated() {
            switch key {
            case "background": line(key, theme.background)
            case "foreground": line(key, theme.foreground)
            default: line(key, ansi.indices.contains(index) ? ansi[index] : nil)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads a colors.toml (ours or Omarchy's) into a theme with the given id and name.
    static func read(_ text: String, id: String, name: String) -> ColorTheme? {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.hasPrefix("["), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            values[key] = value
        }
        let background = values["background"] ?? values["bg"] ?? values["color0"]
        let foreground = values["foreground"] ?? values["fg"] ?? values["color7"]
        guard let background, let foreground, RGB(hex: background) != nil, RGB(hex: foreground) != nil else { return nil }
        let bg = RGB(hex: background)!
        let fallbackAnsi: [String: String] = ["background": background, "foreground": foreground]
        let ansi = ansiKeys.enumerated().map { index, key -> String in
            values[key] ?? values["color\(index)"] ?? fallbackAnsi[key]
                ?? (key.hasPrefix("bright_") ? values[String(key.dropFirst(7))].flatMap(RGB.init(hex:))?.mix(RGB(red: 1, green: 1, blue: 1), 0.2).hex : nil)
                ?? (key == "muted" ? bg.mix(RGB(hex: foreground)!, 0.3).hex : foreground)
        }
        let mode = values["mode"] ?? (bg.red + bg.green + bg.blue > 1.5 ? "light" : "dark")
        return ColorTheme(id: id, name: name, source: "user", appearance: mode,
                          accent: values["accent"] ?? ansi[4], background: background, foreground: foreground,
                          selection: values["selection"] ?? values["selection_background"],
                          selectionForeground: nil, cursor: values["cursor"], muted: ansi[8],
                          darkBackground: nil, darkerBackground: nil, lighterBackground: nil,
                          brightForeground: ansi[15], red: ansi[1], ansi: ansi,
                          iconTheme: nil, vscode: nil, wallhaven: nil)
    }

    /// Theme ids follow ish-colors: lower case, `^[a-z0-9_][a-z0-9._+-]*$`.
    static func id(forName name: String) -> String {
        let lowered = name.lowercased().map { char -> Character in
            char.isLetter || char.isNumber ? char : "-"
        }
        var id = String(lowered).replacingOccurrences(of: "--", with: "-")
        while id.hasPrefix("-") || id.hasPrefix(".") { id.removeFirst() }
        id = String(id.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) })
        return id.isEmpty ? "custom" : id
    }
}

// MARK: - Import

/// Which files of an imported theme folder (or zip) are kept: the same rule as
/// `ish-colors install` (CONTRACT-COLORS.md): colors.toml, icons.theme, light.mode and
/// images under backgrounds/, nothing executable, no links, no other configs.
enum ThemeImportSanitizer {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp"]
    static let maximumImageSize = 20 * 1024 * 1024

    struct Entry: Equatable {
        var path: String
        var data: Data
        var isSymlink = false
        var isExecutable = false
    }

    static func sanitize(_ entries: [Entry]) -> [Entry] {
        entries.compactMap { entry in
            guard !entry.isSymlink, !entry.isExecutable else { return nil }
            let parts = entry.path.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
            guard !parts.contains(".."), let name = parts.last else { return nil }
            switch parts.count {
            case 1 where name == "colors.toml":
                return Entry(path: name, data: entry.data)
            case 1 where name == "icons.theme" || name == "light.mode":
                let safe = String(decoding: entry.data, as: UTF8.self)
                    .filter { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) }
                return Entry(path: name, data: Data(safe.prefix(64).utf8))
            case 2 where parts[0] == "backgrounds":
                guard imageExtensions.contains((name as NSString).pathExtension.lowercased()),
                      entry.data.count <= maximumImageSize else { return nil }
                return Entry(path: "backgrounds/\(name)", data: entry.data)
            default:
                return nil
            }
        }
    }

    /// Zips and theme folders often wrap everything in one top-level directory.
    static func strippingCommonRoot(_ entries: [Entry]) -> [Entry] {
        let roots = Set(entries.map { $0.path.split(separator: "/").first.map(String.init) ?? "" })
        guard roots.count == 1, let root = roots.first, entries.allSatisfy({ $0.path.contains("/") }) else { return entries }
        return entries.map { Entry(path: String($0.path.dropFirst(root.count + 1)), data: $0.data,
                                   isSymlink: $0.isSymlink, isExecutable: $0.isExecutable) }
    }
}

// MARK: - Looks

/// A one-tap combination of layout style, colour theme and styling ("Omarchy Tokyo Night").
struct DesktopLook: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var styleID: String
    var colorThemeID: String
    var styling: DesktopStyling
    var wallpaperQuery: String?
    /// DesktopAppearance raw value for looks without a colour theme ("light", "dark").
    var appearanceID: String?
    var isBuiltIn = false

    var style: DesktopStyle { DesktopStyle.stored(styleID) }

    static let storageKey = "desktop.looks"

    static let builtIn: [DesktopLook] = {
        var omarchy = DesktopStyling()
        omarchy.cornerRadius = 0
        omarchy.borderWidth = 2
        omarchy.innerGap = 5
        omarchy.outerGap = 10
        omarchy.windowShadows = false
        omarchy.panelOpacity = 1
        omarchy.panelBlur = false
        omarchy.linuxMonoFont = "JetBrains Mono"
        omarchy.linuxUIFont = "JetBrains Mono"
        omarchy.uiFont = .monospaced

        var mac = DesktopStyling()
        mac.cornerRadius = 12
        mac.innerGap = 8
        mac.outerGap = 16
        mac.linuxUIFont = "Inter"

        var kylin = DesktopStyling()
        kylin.cornerRadius = 8
        kylin.linuxUIFont = "Noto Sans"

        var ubuntu = DesktopStyling()
        ubuntu.cornerRadius = 10
        ubuntu.linuxUIFont = "Ubuntu"
        ubuntu.linuxMonoFont = "Ubuntu Mono"

        return [
            DesktopLook(id: "tiler-tokyo-night", name: "Tiler Tokyo Night", styleID: "ish", colorThemeID: "tokyo-night",
                        styling: omarchy, wallpaperQuery: "city night", isBuiltIn: true),
            DesktopLook(id: "mac-rose-pine", name: "Mac Rosé Pine", styleID: "macos", colorThemeID: "rose-pine",
                        styling: mac, wallpaperQuery: "minimalist", isBuiltIn: true),
            DesktopLook(id: "kylin-light", name: "Kylin Light", styleID: "kylin", colorThemeID: "",
                        styling: kylin, wallpaperQuery: nil, appearanceID: "light", isBuiltIn: true),
            DesktopLook(id: "ubuntu-yaru-dark", name: "Ubuntu Yaru Dark", styleID: "ubuntu", colorThemeID: "",
                        styling: ubuntu, wallpaperQuery: nil, appearanceID: "dark", isBuiltIn: true),
        ]
    }()

    static func loadUserLooks(from defaults: UserDefaults = .standard) -> [DesktopLook] {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([DesktopLook].self, from: $0) } ?? []
    }

    static func saveUserLooks(_ looks: [DesktopLook], to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(looks) { defaults.set(data, forKey: storageKey) }
    }
}
