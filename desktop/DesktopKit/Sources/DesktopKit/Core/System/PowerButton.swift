import SwiftUI

/// A power glyph opening the power menu, for panels and start menus.
struct PowerButton: View {
    let controller: DesktopController
    var size: CGFloat = 30
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        Menu {
            PowerMenuItems(controller: controller)
        } label: {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Power")
        .accessibilityIdentifier("desktop.panel.power")
    }
}
