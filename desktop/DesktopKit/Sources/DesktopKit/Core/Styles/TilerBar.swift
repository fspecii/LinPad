import SwiftUI

/// The Tiler style's bar: workspaces and the focused window on the left, the clock in the
/// middle, status on the right. Thin, flat, monospaced.
struct TilerBar: View {
    static let height: CGFloat = 28

    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    private var manager: WindowManager { controller.windowManager }

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Button { controller.toggleLauncher() } label: {
                    ThemeGlyph(ThemeIconNames.launcher, symbol: "square.grid.2x2", size: 12)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(controller.isLauncherPresented ? theme.accent : theme.primaryText)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Applications")
                .accessibilityIdentifier("desktop.panel.applications")
                WorkspaceSwitcher(manager: manager)
                if let window = manager.focusedWindow {
                    Text(window.title)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .frame(maxWidth: 280, alignment: .leading)
                        .accessibilityIdentifier("desktop.tiler.title")
                }
                Spacer(minLength: 8)
                TilingButton(manager: manager)
                SystemMeters(monitor: controller.systemMonitor)
                SystemTrayButtons(controller: controller)
                PowerButton(controller: controller, size: 24)
            }
            PanelClock()
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 6)
        .frame(height: Self.height)
        .background {
            theme.panelBackground.opacity(1).ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .bottom) {
            (theme.borderActive ?? theme.accent).opacity(0.5).frame(height: 1)
        }
        .fontDesign(.monospaced)
    }
}

extension DesktopController {
    /// Choosing Tiler turns auto-tiling on and brings Tokyo Night when no colour theme is set.
    func applyStyleDefaults(_ style: DesktopStyle) {
        let spec = style.spec
        if spec.tilesByDefault {
            for index in 0..<windowManager.workspaceCount where !windowManager.isTiling(workspace: index) {
                windowManager.setTiling(true, workspace: index)
            }
        }
        if let theme = spec.defaultColorTheme, colorThemes.currentID.isEmpty {
            applyColorTheme(theme)
        }
    }
}
