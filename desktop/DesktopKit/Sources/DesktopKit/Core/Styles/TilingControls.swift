import SwiftUI

/// Auto-tiling settings as stored in UserDefaults, shared by the shell and Settings.
enum TilingSettings {
    static func decode(_ json: String) -> [TilingState]? {
        guard !json.isEmpty else { return nil }
        return try? JSONDecoder().decode([TilingState].self, from: Data(json.utf8))
    }

    static func encode(_ states: [TilingState]) -> String {
        (try? JSONEncoder().encode(states)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// The panel's tiling control: on/off for the current workspace and the layout.
struct TilingButton: View {
    let manager: WindowManager
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        let state = manager.tiling[manager.currentWorkspace]
        Menu {
            Toggle(isOn: Binding(get: { state.isEnabled }, set: { manager.setTiling($0) })) {
                Label("Auto-Tile Workspace \(manager.currentWorkspace + 1)", systemImage: "rectangle.split.2x1")
            }
            Divider()
            ForEach(TilingLayout.allCases, id: \.self) { layout in
                Toggle(isOn: Binding(get: { state.isEnabled && state.layout == layout },
                                     set: { _ in manager.setTilingLayout(layout) })) {
                    Label(layout.title, systemImage: layout.symbol)
                }
            }
        } label: {
            Image(systemName: state.isEnabled ? state.layout.symbol : "rectangle.split.2x1")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state.isEnabled ? theme.accent : theme.secondaryText)
                .frame(width: 32, height: 26)
                .background(PanelItemBackground(isActive: state.isEnabled))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .help("Auto-tiling (⌃⌥⇧T)")
        .accessibilityLabel("Auto-tiling")
        .accessibilityValue(state.isEnabled ? "On, \(state.layout.title)" : "Off")
        .accessibilityIdentifier("desktop.panel.tiling")
    }
}
