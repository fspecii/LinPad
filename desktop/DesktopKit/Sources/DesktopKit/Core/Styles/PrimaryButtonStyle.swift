import SwiftUI
import UIKit

extension Color {
    /// Black or white, whichever reads at WCAG 4.5:1 or better on this colour (the higher
    /// ratio wins when neither does).
    var readableLabel: Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return Self.prefersDarkLabel(on: RGB(red: Double(r), green: Double(g), blue: Double(b))) ? .black : .white
    }

    static func prefersDarkLabel(on fill: RGB) -> Bool {
        ColorContrast.ratio(fill, RGB(red: 0, green: 0, blue: 0)) > ColorContrast.ratio(fill, RGB(red: 1, green: 1, blue: 1))
    }
}

/// The one filled, primary action of a view: the accent fill with a label that keeps its
/// contrast on any theme's accent. Disabled drops the fill and fades, so it never looks
/// like a pale enabled button.
struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color?
    @Environment(\.desktopTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.desktopStyle) private var style

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if let skin = style.spec.skin, fill == nil {
            EraPrimaryButton(skin: skin, configuration: configuration)
        } else {
            modernBody(configuration: configuration)
        }
    }

    private func modernBody(configuration: Configuration) -> some View {
        let color = fill ?? theme.accent
        let shape = RoundedRectangle(cornerRadius: min(theme.cornerRadius, 8), style: .continuous)
        return configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isEnabled ? color.readableLabel : theme.secondaryText)
            .background(shape.fill(isEnabled ? color : Color.clear))
            .overlay(shape.strokeBorder(isEnabled ? Color.clear : theme.separator, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(shape)
            .hoverEffect(.highlight)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}
