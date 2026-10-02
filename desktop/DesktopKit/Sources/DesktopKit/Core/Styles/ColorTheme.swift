import Foundation
import SwiftUI
import UIKit

/// An sRGB colour from a `#rrggbb` string, with Omarchy's `mix`.
struct RGB: Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    /// `amount` of `other` blended in, as `{{ mix a b N% }}` does.
    func mix(_ other: RGB, _ amount: Double) -> RGB {
        RGB(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount)
    }

    var hex: String {
        String(format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
}

/// One colour theme, as `ish-colors list --json` reports it (themes/omarchy/CONTRACT-COLORS.md;
/// the palette is Omarchy's colors.toml with every fallback resolved).
struct ColorTheme: Codable, Identifiable, Equatable, Sendable {
    struct VSCode: Codable, Equatable, Sendable {
        var name: String?
        var `extension`: String?
    }

    struct WallhavenQuery: Codable, Equatable, Sendable {
        var q: String?
        var colors: [String]?
    }

    var id: String
    var name: String
    var source: String?
    var appearance: String?
    var accent: String
    var background: String
    var foreground: String
    var selection: String?
    var selectionForeground: String?
    var cursor: String?
    var muted: String?
    var darkBackground: String?
    var darkerBackground: String?
    var lighterBackground: String?
    var brightForeground: String?
    var red: String?
    var ansi: [String]?
    var iconTheme: String?
    var vscode: VSCode?
    var wallhaven: WallhavenQuery?

    /// Themes the port leaves out for licensing reasons (PORT-SPEC.md section 5).
    static let excluded: Set<String> = ["ristretto", "lumon"]

    var isDark: Bool {
        if let appearance { return appearance != "light" }
        let bg = rgb(background)
        return bg.red + bg.green + bg.blue <= 1.5
    }

    var isUserTheme: Bool { source == "user" }

    private func rgb(_ hex: String?, _ fallback: RGB = RGB(red: 0.5, green: 0.5, blue: 0.5)) -> RGB {
        hex.flatMap(RGB.init(hex:)) ?? fallback
    }

    var accentRGB: RGB { rgb(accent) }
    var backgroundRGB: RGB { rgb(background) }
    var foregroundRGB: RGB { rgb(foreground) }
    var selectionRGB: RGB { rgb(selection, backgroundRGB.mix(foregroundRGB, 0.2)) }
    var redRGB: RGB { rgb(red, RGB(red: 0.94, green: 0.33, blue: 0.31)) }
    var terminalColors: [RGB] { (ansi ?? []).compactMap(RGB.init(hex:)) }

    /// The desktop's colours from five tokens (PORT-SPEC.md 4.2); shapes, panel translucency
    /// and fonts stay the style's.
    func applied(to base: DesktopTheme, panelOpacity: Double) -> DesktopTheme {
        let bg = backgroundRGB, fg = foregroundRGB
        var theme = base
        theme.accent = accentRGB.color
        theme.panelBackground = bg.color.opacity(panelOpacity)
        theme.windowBackground = bg.color
        theme.titleBarActive = bg.mix(fg, 0.08).color
        theme.titleBarInactive = bg.color
        theme.primaryText = fg.color
        theme.secondaryText = fg.mix(bg, 0.34).color
        theme.separator = bg.mix(fg, 0.15).color
        theme.selection = selectionRGB.color
        theme.urgent = redRGB.color
        theme.borderActive = accentRGB.color
        theme.borderInactive = Color(red: 0x59 / 255, green: 0x59 / 255, blue: 0x59 / 255).opacity(0.67)
        theme.borderWidth = 2
        theme.hoverFill = fg.color.opacity(0.08)
        theme.scrim = bg.color.opacity(0.5)
        theme.terminalPalette = terminalColors.map(\.color)
        theme.colorThemeID = id
        return theme
    }

    /// The built-in palettes bundled with the app, for guests without `ish-colors` and for
    /// instant previews.
    static let builtIn: [ColorTheme] = {
        guard let url = Bundle.module.url(forResource: "themes", withExtension: "json", subdirectory: "ColorThemes"),
              let data = try? Data(contentsOf: url) else { return [] }
        return decodeList(data)
    }()

    static func decodeList(_ data: Data) -> [ColorTheme] {
        ((try? JSONDecoder().decode([ColorTheme].self, from: data)) ?? [])
            .filter { !excluded.contains($0.id) && RGB(hex: $0.background) != nil && RGB(hex: $0.foreground) != nil }
    }
}

extension Color {
    /// The colour's alpha, for keeping a style's translucency when the hue changes.
    var opacityComponent: Double {
        var alpha: CGFloat = 1
        UIColor(self).getWhite(nil, alpha: &alpha)
        return Double(alpha)
    }
}
