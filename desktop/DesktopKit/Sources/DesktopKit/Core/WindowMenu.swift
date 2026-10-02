import SwiftUI
import UIKit

/// The window menu, built once and rendered both as a SwiftUI `Menu` (title-bar icon,
/// taskbar) and as a `UIMenu` (long-press or secondary click on the title bar).
@MainActor
struct WindowMenu {
    struct Entry: Identifiable {
        enum Kind {
            case action(() -> Void)
            case submenu([Entry])
            case divider
        }

        let id = UUID()
        var title = ""
        var symbol: String?
        var isChecked = false
        var isDisabled = false
        var isDestructive = false
        var kind: Kind
    }

    let entries: [Entry]

    init(window: DesktopWindow, controller: DesktopController) {
        let manager = controller.windowManager
        let id = window.id
        let isTiling = manager.isTiling(workspace: window.workspace)
        func snap(_ title: String, _ symbol: String, _ zone: SnapZone) -> Entry {
            Entry(title: title, symbol: symbol, isChecked: window.snap == zone,
                  kind: .action { manager.snap(id, to: zone) })
        }
        let workspaces = (0..<manager.workspaceCount).map { index in
            Entry(title: manager.title(ofWorkspace: index), isChecked: window.workspace == index,
                  isDisabled: window.workspace == index,
                  kind: .action { manager.move(id, toWorkspace: index) })
        }
        entries = [
            Entry(title: window.isMinimized ? "Restore" : "Minimize",
                  symbol: window.isMinimized ? "macwindow" : "minus",
                  kind: .action { window.isMinimized ? manager.focus(id) : manager.minimize(id) }),
            Entry(title: window.isMaximized ? "Unmaximize" : "Maximize",
                  symbol: "arrow.up.left.and.arrow.down.right",
                  kind: .action { manager.toggleMaximize(id) }),
            Entry(title: "Tile", symbol: "rectangle.split.2x2", kind: .submenu([
                snap("Left Half", "rectangle.lefthalf.filled", .leftHalf),
                snap("Right Half", "rectangle.righthalf.filled", .rightHalf),
                Entry(kind: .divider),
                snap("Top Left", "rectangle.inset.topleft.filled", .topLeft),
                snap("Top Right", "rectangle.inset.topright.filled", .topRight),
                snap("Bottom Left", "rectangle.inset.bottomleft.filled", .bottomLeft),
                snap("Bottom Right", "rectangle.inset.bottomright.filled", .bottomRight),
                Entry(kind: .divider),
                Entry(title: "Center", symbol: "rectangle.center.inset.filled",
                      kind: .action { manager.center(id) }),
            ])),
            Entry(title: "Move to Workspace", symbol: "rectangle.on.rectangle", kind: .submenu(workspaces)),
            Entry(title: "Always on Top", symbol: "pin", isChecked: window.isAlwaysOnTop,
                  kind: .action { manager.toggleAlwaysOnTop(id) }),
            Entry(title: "Tile Workspace", symbol: "rectangle.split.2x1", isChecked: isTiling,
                  kind: .action { manager.setTiling(!isTiling, workspace: window.workspace) }),
            Entry(title: "Float Window", symbol: "macwindow.on.rectangle", isChecked: window.isFloating,
                  isDisabled: !isTiling, kind: .action { manager.toggleFloating(id) }),
            Entry(kind: .divider),
            Entry(title: "Close", symbol: "xmark", isDestructive: true,
                  kind: .action { manager.requestClose(id) }),
        ]
    }

    // MARK: SwiftUI

    @ViewBuilder
    var swiftUIItems: some View {
        ForEach(entries) { entry in
            Self.view(for: entry)
        }
    }

    private static func view(for entry: Entry) -> AnyView {
        switch entry.kind {
        case .divider:
            return AnyView(Divider())
        case .submenu(let children):
            return AnyView(Menu {
                ForEach(children) { child in view(for: child) }
            } label: {
                label(for: entry)
            })
        case .action(let perform):
            if entry.isChecked {
                return AnyView(Toggle(isOn: Binding(get: { true }, set: { _ in perform() })) { label(for: entry) }
                    .disabled(entry.isDisabled))
            }
            return AnyView(Button(role: entry.isDestructive ? .destructive : nil, action: perform) {
                label(for: entry)
            }
            .disabled(entry.isDisabled))
        }
    }

    @ViewBuilder
    private static func label(for entry: Entry) -> some View {
        if let symbol = entry.symbol {
            Label(entry.title, systemImage: symbol)
        } else {
            Text(entry.title)
        }
    }

    // MARK: UIKit

    func uiMenu() -> UIMenu {
        UIMenu(children: Self.elements(for: entries))
    }

    private static func elements(for entries: [Entry]) -> [UIMenuElement] {
        // UIKit draws dividers between inline groups, so split at each divider.
        var groups: [[UIMenuElement]] = [[]]
        for entry in entries {
            switch entry.kind {
            case .divider:
                groups.append([])
            case .submenu(let children):
                groups[groups.count - 1].append(UIMenu(title: entry.title, image: entry.symbol.flatMap(UIImage.init(systemName:)),
                                                       children: elements(for: children)))
            case .action(let perform):
                let action = UIAction(title: entry.title, image: entry.symbol.flatMap(UIImage.init(systemName:))) { _ in
                    perform()
                }
                action.state = entry.isChecked ? .on : .off
                if entry.isDisabled { action.attributes.insert(.disabled) }
                if entry.isDestructive { action.attributes.insert(.destructive) }
                groups[groups.count - 1].append(action)
            }
        }
        return groups.filter { !$0.isEmpty }.map { UIMenu(options: .displayInline, children: $0) }
    }
}
