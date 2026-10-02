import SwiftUI

/// ⌘/ : every desktop shortcut, grouped, generated from the live binding table, so it
/// always matches what the keys do (including the ⌃⌥ / ⌘ choice in Settings).
struct ShortcutSheetView: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    /// Keys that only work while something is open; they are not in the command table.
    static let contextual: [(String, String)] = [
        ("Close the open overlay", "Esc"),
        ("Move in the launcher, switcher, menus", "↑ ↓ ← →"),
        ("Run the highlighted item", "↩\u{FE0E}"),
        ("Rename a desktop icon", "F2"),
        ("Move desktop icons to the Trash", "⌘⌫"),
        ("Select all desktop icons", "⌘A"),
    ]

    var body: some View {
        let commands = DesktopCommand.all.filter { !Self.isFolded($0.id) }
        ZStack {
            theme.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { controller.isShortcutSheetPresented = false }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Keyboard Shortcuts").font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Text(DesktopShortcutModifier.current == .command ? "General commands on ⌘" : "Desktop commands on ⌃⌥ · ⌘ stays with apps")
                        .font(.caption).foregroundStyle(theme.secondaryText)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 22, alignment: .top),
                                        GridItem(.flexible(), spacing: 22, alignment: .top),
                                        GridItem(.flexible(), alignment: .top)],
                              alignment: .leading, spacing: 18) {
                        ForEach(DesktopCommand.Group.allCases, id: \.self) { group in
                            section(group.rawValue, commands.filter { $0.group == group }.map { (title(for: $0), label(for: $0)) })
                        }
                        section("In overlays and on the desktop", Self.contextual)
                    }
                }
                Text("⌘/ or Esc closes · the ⌘K Command Menu lists every command too")
                    .font(.caption).foregroundStyle(theme.secondaryText)
            }
            .padding(24)
            .frame(maxWidth: 1040, maxHeight: 640)
            .background(RoundedRectangle(cornerRadius: theme.cornerRadius + 4, style: .continuous).fill(theme.windowBackground))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 4, style: .continuous)
                .strokeBorder((theme.borderActive ?? theme.accent).opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            .padding(30)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("shortcutSheet")
        }
    }

    /// Workspace digits collapse into one row each ("Workspace 1–9"): 2…9 are folded into 1.
    static func isFolded(_ id: String) -> Bool {
        guard let last = id.split(separator: ".").last, let digit = Int(last) else { return false }
        return id.hasPrefix("workspace.") && digit > 1
    }

    private func title(for command: DesktopCommand) -> String {
        switch command.id {
        case "workspace.1": "Go to workspace 1–9"
        case "workspace.move.1": "Move window to workspace 1–9"
        default: command.title
        }
    }

    private func label(for command: DesktopCommand) -> String {
        command.id == "workspace.1" || command.id == "workspace.move.1"
            ? command.shortcutLabel.replacingOccurrences(of: "1", with: "1–9") : command.shortcutLabel
    }

    private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.accent)
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Text(rows[index].0).font(.system(size: 13)).foregroundStyle(theme.primaryText).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(rows[index].1)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.primaryText.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(theme.separator, lineWidth: 1))
                }
            }
        }
    }
}
