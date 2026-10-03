import SwiftUI

// Era tokens for the shared app chrome (AppChrome.swift, PrimaryButtonStyle, SettingsSection,
// sidebars): toolbars, status bars, buttons, fields, column headers, group boxes and
// selection follow the desktop theme's era. Apps keep their own code; the shared components
// ask `EraSkin` (from the environment's style) how to draw, and draw as before without one.

extension EraSkin {
    /// Classic 98 and Platinum draw everything with grey bevels.
    var isBevelled: Bool { self == .classic || self == .platinum }

    var bevelPalette: ClassicBevel.Palette { self == .platinum ? .platinum : .classic }

    var face: Color { self == .platinum ? EraSkin.platinumFace : EraSkin.classicFace }

    /// Solid selection with light text in sidebars: 98's navy, Luna's and Aqua's blue, Berry's
    /// blue, Dot Matrix's inverted capsule. Aero keeps a pale glassy highlight.
    func selectionFill(theme: DesktopTheme) -> Color? {
        switch self {
        case .classic: Color(rgb: 0x000080)
        case .platinum: Color(rgb: 0x6666CC)
        case .luna: Color(rgb: 0x316AC5)
        case .aqua: Color(rgb: 0x3875D7)
        case .berry: Color(rgb: 0x1E8BFF)
        case .dotMatrix: theme.primaryText
        case .aero, .aeroNight: nil
        }
    }

    func selectionText(theme: DesktopTheme) -> Color {
        self == .dotMatrix ? theme.windowBackground : .white
    }
}

private extension EnvironmentValues {
    var eraSkin: EraSkin? { desktopStyle.spec.skin }
}

// MARK: - Toolbar and status bar surfaces

/// The strip behind toolbars and status bars.
struct EraBarBackground: View {
    let skin: EraSkin
    var isStatusBar = false
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        switch skin {
        case .classic, .platinum:
            Rectangle().fill(skin.face)
                .overlay(ClassicBevel(raised: !isStatusBar, thick: false, palette: skin.bevelPalette))
        case .luna:
            LinearGradient(colors: [Color(rgb: 0xFBFBF8), Color(rgb: 0xECE9D8)], startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .bottom) { Color(rgb: 0xD8D2BD).frame(height: 1) }
        case .aero, .aeroNight:
            LinearGradient(colors: [Color(rgb: 0xF5F9FD), Color(rgb: 0xDCE7F3)], startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .bottom) { Color(rgb: 0xA0AFC3).frame(height: 1) }
        case .aqua:
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(rgb: 0xE6E6E6)))
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.white.opacity(0.85)))
                    y += 2
                }
            }
            .overlay(alignment: .bottom) { Color(rgb: 0xA6A6A6).frame(height: 1) }
        case .berry:
            LinearGradient(colors: [Color(rgb: 0x353A42), Color(rgb: 0x1A1D22)], startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .top) { Color.white.opacity(0.2).frame(height: 1) }
        case .dotMatrix:
            theme.windowBackground
                .overlay(alignment: .bottom) { theme.primaryText.opacity(0.12).frame(height: 1) }
        }
    }
}

// MARK: - Buttons

/// The face of a toolbar or dialog button in the era's material.
struct EraButtonFace: View {
    let skin: EraSkin
    var isActive = false
    var isHovered = false
    var isProminent = false
    var isPressed = false
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        switch skin {
        case .classic, .platinum:
            Rectangle().fill(isActive ? skin.face.opacity(0.7) : skin.face)
                .overlay(ClassicBevel(raised: !(isActive || isPressed), thick: true, palette: skin.bevelPalette))
                .overlay { if isProminent { Rectangle().strokeBorder(Color.black, lineWidth: 1) } }
        case .luna:
            let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
            shape.fill(LinearGradient(colors: isPressed || isActive ? [Color(rgb: 0xE5E4DE), Color(rgb: 0xF3F3EF)]
                                                                    : [Color.white, Color(rgb: 0xECEBE6)],
                                      startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(Color(rgb: isHovered ? 0xF8B330 : 0x003C74), lineWidth: isHovered ? 1.5 : 1))
        case .aero, .aeroNight:
            let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
            shape.fill(LinearGradient(stops: [.init(color: Color(rgb: isHovered ? 0xEAF6FD : 0xF2F2F2), location: 0),
                                              .init(color: Color(rgb: isHovered ? 0xD9F0FC : 0xEBEBEB), location: 0.5),
                                              .init(color: Color(rgb: isHovered ? 0xBEE6FD : 0xDDDDDD), location: 0.51),
                                              .init(color: Color(rgb: isHovered ? 0xA7D9F5 : 0xCFCFCF), location: 1)],
                                      startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(Color(rgb: isHovered ? 0x3C7FB1 : 0x707070), lineWidth: 1))
        case .aqua:
            let blue = isProminent || isActive
            Capsule().fill(LinearGradient(colors: blue ? [Color(rgb: 0xA9D5FF), Color(rgb: 0x2F7FE0), Color(rgb: 0x6FB4FF)]
                                                       : [Color.white, Color(rgb: 0xE2E2E2), Color(rgb: 0xF7F7F7)],
                                          startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.8))
                .overlay(alignment: .top) {
                    Capsule().fill(Color.white.opacity(blue ? 0.55 : 0.8)).frame(height: 5).padding(.horizontal, 6).padding(.top, 2)
                }
        case .berry:
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            shape.fill(isActive || isProminent ? AnyShapeStyle(LinearGradient(colors: [Color(rgb: 0x5FB0FF), Color(rgb: 0x0B5FD0)], startPoint: .top, endPoint: .bottom))
                                               : AnyShapeStyle(LinearGradient(colors: [Color(rgb: 0x454B54), Color(rgb: 0x1E2126)], startPoint: .top, endPoint: .bottom)))
                .overlay(shape.strokeBorder(LinearGradient(colors: [Color(rgb: 0xD9DEE4), Color(rgb: 0x5E646D)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        case .dotMatrix:
            Capsule().fill(isActive || isProminent ? theme.primaryText : Color.clear)
                .overlay(Capsule().strokeBorder(theme.primaryText.opacity(0.7), lineWidth: 1.2))
        }
    }

    /// Text and glyph colour on this face.
    static func label(_ skin: EraSkin, isActive: Bool, isProminent: Bool, theme: DesktopTheme) -> Color {
        switch skin {
        case .classic, .platinum, .luna, .aero, .aeroNight: .black
        case .aqua: isActive || isProminent ? .white : .black
        case .berry: .white
        case .dotMatrix: isActive || isProminent ? theme.windowBackground : theme.primaryText
        }
    }
}

/// `.primary` buttons in the era's material (PrimaryButtonStyle defers here).
struct EraPrimaryButton: View {
    let skin: EraSkin
    let configuration: ButtonStyleConfiguration
    @Environment(\.desktopTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(skin == .dotMatrix ? .system(size: 13, weight: .semibold, design: .monospaced) : .system(size: 13, weight: .semibold))
            .foregroundStyle(EraButtonFace.label(skin, isActive: false, isProminent: true, theme: theme))
            .padding(.horizontal, skin.isBevelled ? 14 : 12)
            .padding(.vertical, 6)
            .background(EraButtonFace(skin: skin, isProminent: true, isPressed: configuration.isPressed))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
    }
}

// MARK: - Fields, headers, group boxes

/// The frame of a text or search field.
struct EraFieldBackground: View {
    let skin: EraSkin
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        switch skin {
        case .classic, .platinum:
            Rectangle().fill(Color.white).overlay(ClassicBevel(raised: false, thick: true, palette: skin.bevelPalette))
        case .luna:
            Rectangle().fill(Color.white).overlay(Rectangle().strokeBorder(Color(rgb: 0x7F9DB9), lineWidth: 1))
        case .aero, .aeroNight:
            RoundedRectangle(cornerRadius: 2).fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color(rgb: 0xABADB3), lineWidth: 1))
        case .aqua:
            Capsule().fill(Color.white)
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
        case .berry:
            RoundedRectangle(cornerRadius: 6).fill(Color(rgb: 0x0B0D10))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(rgb: 0x5E646D), lineWidth: 1))
        case .dotMatrix:
            Capsule().fill(theme.windowBackground)
                .overlay(Capsule().strokeBorder(theme.primaryText.opacity(0.5), lineWidth: 1))
        }
    }
}

/// A list column header cell.
struct EraHeaderBackground: View {
    let skin: EraSkin

    var body: some View {
        switch skin {
        case .classic, .platinum:
            Rectangle().fill(skin.face).overlay(ClassicBevel(raised: true, thick: false, palette: skin.bevelPalette))
        case .luna:
            LinearGradient(colors: [Color.white, Color(rgb: 0xEBEAE5)], startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .bottom) { Color(rgb: 0xD6D2C2).frame(height: 2) }
                .overlay(alignment: .trailing) { Color(rgb: 0xC7C5B2).frame(width: 1).padding(.vertical, 4) }
        case .aqua:
            LinearGradient(colors: [Color.white, Color(rgb: 0xDCDCDC)], startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .trailing) { Color(rgb: 0xB0B0B0).frame(width: 1) }
        default:
            Color.clear
        }
    }
}

/// Settings' grouped sections: 98's etched group box, Luna's rounded frame, Aqua's inset
/// well, Berry's dark panel, Dot Matrix's hairline card.
struct EraGroupBox: View {
    let skin: EraSkin
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        switch skin {
        case .classic, .platinum:
            Rectangle().fill(skin.face)
                .overlay(ClassicBevel(raised: false, thick: false, palette: skin.bevelPalette))
                .overlay(ClassicBevel(raised: true, thick: false, palette: skin.bevelPalette).padding(1.5))
        case .luna:
            RoundedRectangle(cornerRadius: 4).fill(Color(rgb: 0xF7F6F1))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(rgb: 0xD0D0BF), lineWidth: 1))
        case .aero, .aeroNight:
            RoundedRectangle(cornerRadius: 3).fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(rgb: 0xD5DFE5), lineWidth: 1))
        case .aqua:
            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.18), lineWidth: 1))
        case .berry:
            RoundedRectangle(cornerRadius: 10).fill(Color(rgb: 0x1B2026))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(rgb: 0x3A4048), lineWidth: 1))
        case .dotMatrix:
            RoundedRectangle(cornerRadius: 18).fill(theme.windowBackground)
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.primaryText.opacity(0.15), lineWidth: 1))
        }
    }
}

// MARK: - Selection

/// The background of a sidebar row or list item: the era's own highlight when selected,
/// otherwise what the app passes for the modern look (`modernFill` in a rounded rectangle).
struct EraSelectionBackground: View {
    let isSelected: Bool
    var cornerRadius: CGFloat = 6
    let modernFill: Color
    /// List rows keep dark text, so they get a tint instead of the solid sidebar colour.
    var isListRow = false
    @Environment(\.desktopStyle) private var style
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        if let skin = style.spec.skin, isSelected {
            let fill = isListRow ? (skin.selectionFill(theme: theme) ?? theme.accent).opacity(0.28)
                                 : skin.selectionFill(theme: theme)
            switch skin {
            case .aqua, .dotMatrix:
                Capsule().fill(fill ?? theme.accent)
            case .aero, .aeroNight:
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LinearGradient(colors: [Color(rgb: 0xEBF4FD), Color(rgb: 0xC1DCFC)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color(rgb: 0x7DA2CE), lineWidth: 1))
            case .berry:
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill ?? theme.accent)
            default:
                Rectangle().fill(fill ?? theme.accent)
            }
        } else {
            RoundedRectangle(cornerRadius: style.spec.skin?.isBevelled == true ? 0 : cornerRadius, style: .continuous)
                .fill(modernFill)
        }
    }

    /// The text colour on a selected sidebar row, nil to keep the app's own.
    static func textColor(isSelected: Bool, style: DesktopStyle, theme: DesktopTheme) -> Color? {
        guard isSelected, let skin = style.spec.skin, skin.selectionFill(theme: theme) != nil else { return nil }
        return skin.selectionText(theme: theme)
    }
}

// MARK: - Era app tiles (no modern plates)

/// A toolbar icon button's face: flat at rest as in the eras' toolbars, raised (98, Platinum)
/// or hot-tracked (Luna, Aero) under the pointer, pressed in while active.
struct EraToolbarButtonFace: View {
    let skin: EraSkin
    let isActive: Bool
    let isHovered: Bool
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        switch skin {
        case .classic, .platinum:
            if isActive {
                Rectangle().fill(skin.face.opacity(0.6)).overlay(ClassicBevel(raised: false, thick: false, palette: skin.bevelPalette))
            } else if isHovered {
                ClassicBevel(raised: true, thick: false, palette: skin.bevelPalette)
            }
        case .luna:
            if isActive || isHovered {
                RoundedRectangle(cornerRadius: 3).fill(Color(rgb: isActive ? 0x98B5E2 : 0xC1D2EE))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(rgb: 0x316AC5), lineWidth: 1))
            }
        case .aero, .aeroNight:
            if isActive || isHovered {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [Color(rgb: 0xEAF6FD), Color(rgb: isActive ? 0xA7D9F5 : 0xBEE6FD)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(rgb: 0x3C7FB1), lineWidth: 1))
            }
        case .aqua, .berry, .dotMatrix:
            if isActive || isHovered { EraButtonFace(skin: skin, isActive: isActive, isHovered: isHovered) }
        }
    }
}
