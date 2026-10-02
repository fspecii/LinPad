import SwiftUI
import UIKit

/// Every desktop keyboard command, in one table that drives the key bindings, the hold-⌘
/// discoverability overlay and Settings > Keyboard Shortcuts.
///
/// Bindings stay clear of iPadOS's own: ⌘Tab, ⌘Space, ⌘H, ⌃Space (input source) and every
/// Globe/fn chord belong to the system. Everything lives on ⌃⌥, which neither iPadOS nor
/// shells use for anything common; ⌘ belongs to the apps (VS Code's ⌘W closes a tab, not
/// the window). The user can move the general commands to ⌘ (`DesktopShortcutModifier`);
/// even then Linux apps and the terminal keep ⌘ while they have focus.
enum DesktopShortcutModifier: String, CaseIterable, Identifiable {
    case controlOption
    case command

    static let storageKey = "desktop.keyboard.modifier"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .controlOption: "⌃⌥ Control-Option"
        case .command: "⌘ Command"
        }
    }

    static var current: DesktopShortcutModifier {
        UserDefaults.standard.string(forKey: storageKey).flatMap(DesktopShortcutModifier.init) ?? .controlOption
    }
}

struct DesktopCommand: Identifiable {
    enum Group: String, CaseIterable {
        case general = "General"
        case windows = "Windows"
        case snapping = "Snapping"
        case tiling = "Tiling"
        case workspaces = "Workspaces"
    }

    let id: String
    let title: String
    let group: Group
    let key: KeyEquivalent
    let modifiers: EventModifiers
    /// What the shortcut panel shows, e.g. "⌃⌥←".
    let keyLabel: String
    let perform: @MainActor (DesktopController) -> Void

    var shortcutLabel: String { Self.symbols(for: modifiers) + keyLabel }

    /// ⌘ chords give way to Linux apps and the terminal while one of them has focus.
    var yieldsToApps: Bool { modifiers.contains(.command) }

    private static func symbols(for modifiers: EventModifiers) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result
    }

    private static let windowKeys: EventModifiers = [.control, .option]

    @MainActor
    private static func onFocused(_ action: @escaping @MainActor (WindowManager, UUID) -> Void)
        -> @MainActor (DesktopController) -> Void {
        { controller in
            let manager = controller.windowManager
            if let id = manager.focusedWindowID { action(manager, id) }
        }
    }

    /// One key, two meanings: tile navigation in a tiling workspace, placement otherwise.
    @MainActor
    private static func tilingAware(tiled: @escaping @MainActor (WindowManager) -> Void,
                                    floating: @escaping @MainActor (WindowManager, UUID) -> Void)
        -> @MainActor (DesktopController) -> Void {
        { controller in
            let manager = controller.windowManager
            if manager.isTiling(workspace: manager.currentWorkspace),
               manager.focusedWindow.map(manager.isTiledByLayout) ?? true {
                tiled(manager)
            } else if let id = manager.focusedWindowID {
                floating(manager, id)
            }
        }
    }

    @MainActor
    static var all: [DesktopCommand] { commands(for: .current) }

    @MainActor
    static func commands(for modifier: DesktopShortcutModifier) -> [DesktopCommand] {
        let onCommand = modifier == .command
        var commands: [DesktopCommand] = [
            // Not ⌃⌥Space: iPadOS takes that for switching input sources while a text field has focus.
            DesktopCommand(id: "launcher", title: "Applications", group: .general, key: onCommand ? .space : "a",
                           modifiers: onCommand ? [.command, .shift] : windowKeys, keyLabel: onCommand ? "Space" : "A") {
                $0.toggleLauncher()
            },
            DesktopCommand(id: "run", title: "Run Command…", group: .general, key: "r",
                           modifiers: onCommand ? .command : windowKeys, keyLabel: "R") { $0.presentRunDialog() },
            // ⌃⌥T is the usual Linux desktop's terminal key; ⌃⌥↩ is Maximize.
            DesktopCommand(id: "terminal", title: "New Terminal", group: .general, key: onCommand ? .return : "t",
                           modifiers: onCommand ? .command : windowKeys, keyLabel: onCommand ? "↩" : "T") {
                $0.open(appID: AppID.terminal, arguments: [:])
            },
            DesktopCommand(id: "theme.picker", title: "Color Themes", group: .general, key: .space,
                           modifiers: [.control, .option, .shift], keyLabel: "Space") { $0.presentThemePicker() },
            DesktopCommand(id: "theme.next", title: "Next Color Theme", group: .general, key: "c",
                           modifiers: [.control, .option, .shift], keyLabel: "C") { $0.cycleColorTheme() },
            DesktopCommand(id: "background.next", title: "Next Wallpaper", group: .general, key: "b",
                           modifiers: [.control, .option, .shift], keyLabel: "B") { $0.cycleWallpaper() },
            DesktopCommand(id: "overview", title: "Overview", group: .general, key: "o",
                           modifiers: windowKeys, keyLabel: "O") { $0.toggleOverview() },

            DesktopCommand(id: "switcher", title: "Switch Windows", group: .windows, key: .tab,
                           modifiers: .option, keyLabel: "Tab") { $0.advanceSwitcher(by: 1) },
            DesktopCommand(id: "switcher.back", title: "Switch Windows Backwards", group: .windows, key: .tab,
                           modifiers: [.option, .shift], keyLabel: "Tab") { $0.advanceSwitcher(by: -1) },
            DesktopCommand(id: "close", title: "Close Window", group: .windows, key: "w",
                           modifiers: onCommand ? .command : windowKeys, keyLabel: "W",
                           perform: onFocused { $0.requestClose($1) }),
            // ⌘M is iPadOS 26's own Minimize for the whole app window.
            DesktopCommand(id: "minimize", title: "Minimize Window", group: .windows, key: "m",
                           modifiers: windowKeys, keyLabel: "M", perform: onFocused { $0.minimize($1) }),
            DesktopCommand(id: "maximize", title: "Toggle Maximize", group: .windows, key: .return,
                           modifiers: windowKeys, keyLabel: "↩", perform: onFocused { $0.toggleMaximize($1) }),
            DesktopCommand(id: "center", title: "Center Window", group: .windows, key: "c",
                           modifiers: windowKeys, keyLabel: "C", perform: onFocused { $0.center($1) }),
            DesktopCommand(id: "pin", title: "Always on Top", group: .windows, key: "p",
                           modifiers: windowKeys, keyLabel: "P", perform: onFocused { $0.toggleAlwaysOnTop($1) }),

            DesktopCommand(id: "tiling", title: "Toggle Auto-Tiling", group: .tiling, key: "t",
                           modifiers: [.control, .option, .shift], keyLabel: "T") { controller in
                let manager = controller.windowManager
                manager.setTiling(!manager.isTiling(workspace: manager.currentWorkspace))
            },
            DesktopCommand(id: "tiling.zen", title: "Gaps, Borders and Rounding Off", group: .tiling, key: .delete,
                           modifiers: [.control, .option, .shift], keyLabel: "⌫") { controller in
                withAnimation(DesktopMotion.tile) { controller.windowManager.isZen.toggle() }
            },
            DesktopCommand(id: "tiling.layout", title: "Next Tiling Layout", group: .tiling, key: "\\",
                           modifiers: windowKeys, keyLabel: "\\") { $0.windowManager.cycleTilingLayout() },
            DesktopCommand(id: "tiling.float", title: "Float Window", group: .tiling, key: "f",
                           modifiers: windowKeys, keyLabel: "F", perform: onFocused { $0.toggleFloating($1) }),
            DesktopCommand(id: "tiling.left", title: "Focus Tile Left", group: .tiling, key: "h",
                           modifiers: windowKeys, keyLabel: "H") { $0.windowManager.focusTile(dx: -1, dy: 0) },
            DesktopCommand(id: "tiling.down", title: "Snap Bottom Left · Tile Below", group: .snapping,
                           key: "j", modifiers: windowKeys, keyLabel: "J",
                           perform: tilingAware(tiled: { $0.focusTile(dx: 0, dy: 1) },
                                                floating: { $0.snap($1, to: .bottomLeft) })),
            DesktopCommand(id: "tiling.up", title: "Snap Bottom Right · Tile Above", group: .snapping,
                           key: "k", modifiers: windowKeys, keyLabel: "K",
                           perform: tilingAware(tiled: { $0.focusTile(dx: 0, dy: -1) },
                                                floating: { $0.snap($1, to: .bottomRight) })),
            DesktopCommand(id: "tiling.right", title: "Focus Tile Right", group: .tiling, key: "l",
                           modifiers: windowKeys, keyLabel: "L") { $0.windowManager.focusTile(dx: 1, dy: 0) },
            DesktopCommand(id: "tiling.move.left", title: "Move Tile Left", group: .tiling, key: "h",
                           modifiers: [.control, .option, .shift], keyLabel: "H") { $0.windowManager.moveTile(dx: -1, dy: 0) },
            DesktopCommand(id: "tiling.move.down", title: "Move Tile Down", group: .tiling, key: "j",
                           modifiers: [.control, .option, .shift], keyLabel: "J") { $0.windowManager.moveTile(dx: 0, dy: 1) },
            DesktopCommand(id: "tiling.move.up", title: "Move Tile Up", group: .tiling, key: "k",
                           modifiers: [.control, .option, .shift], keyLabel: "K") { $0.windowManager.moveTile(dx: 0, dy: -1) },
            DesktopCommand(id: "tiling.move.right", title: "Move Tile Right", group: .tiling, key: "l",
                           modifiers: [.control, .option, .shift], keyLabel: "L") { $0.windowManager.moveTile(dx: 1, dy: 0) },

            // In a tiling workspace the arrows move focus between tiles instead of snapping.
            DesktopCommand(id: "snap.left", title: "Snap Left Half", group: .snapping, key: .leftArrow,
                           modifiers: windowKeys, keyLabel: "←",
                           perform: tilingAware(tiled: { $0.focusTile(dx: -1, dy: 0) },
                                                floating: { $0.snap($1, to: .leftHalf) })),
            DesktopCommand(id: "snap.right", title: "Snap Right Half", group: .snapping, key: .rightArrow,
                           modifiers: windowKeys, keyLabel: "→",
                           perform: tilingAware(tiled: { $0.focusTile(dx: 1, dy: 0) },
                                                floating: { $0.snap($1, to: .rightHalf) })),
            DesktopCommand(id: "snap.up", title: "Maximize", group: .snapping, key: .upArrow,
                           modifiers: windowKeys, keyLabel: "↑",
                           perform: tilingAware(tiled: { $0.focusTile(dx: 0, dy: -1) },
                                                floating: { $0.snap($1, to: .maximize) })),
            DesktopCommand(id: "snap.down", title: "Restore or Minimize", group: .snapping, key: .downArrow,
                           modifiers: windowKeys, keyLabel: "↓",
                           perform: tilingAware(tiled: { $0.focusTile(dx: 0, dy: 1) },
                                                floating: { $0.restoreOrMinimize($1) })),
            DesktopCommand(id: "snap.topLeft", title: "Snap Top Left", group: .snapping, key: "u",
                           modifiers: windowKeys, keyLabel: "U", perform: onFocused { $0.snap($1, to: .topLeft) }),
            DesktopCommand(id: "snap.topRight", title: "Snap Top Right", group: .snapping, key: "i",
                           modifiers: windowKeys, keyLabel: "I", perform: onFocused { $0.snap($1, to: .topRight) }),

            DesktopCommand(id: "workspace.previous", title: "Previous Workspace", group: .workspaces, key: "[",
                           modifiers: windowKeys, keyLabel: "[") { controller in
                withAnimation(DesktopMotion.standard) { controller.windowManager.switchWorkspace(by: -1) }
            },
            DesktopCommand(id: "workspace.new", title: "New Workspace", group: .workspaces, key: "n",
                           modifiers: windowKeys, keyLabel: "N") { addAndSwitch($0.windowManager) },
            DesktopCommand(id: "workspace.next", title: "Next Workspace", group: .workspaces, key: "]",
                           modifiers: windowKeys, keyLabel: "]") { controller in
                withAnimation(DesktopMotion.standard) { controller.windowManager.switchWorkspace(by: 1) }
            },
        ]
        for index in 0..<WindowManager.maximumWorkspaces {
            let digit = KeyEquivalent(Character(String(index + 1)))
            commands.append(DesktopCommand(
                id: "workspace.\(index + 1)", title: "Workspace \(index + 1)", group: .workspaces, key: digit,
                modifiers: windowKeys, keyLabel: "\(index + 1)") { controller in
                    withAnimation(DesktopMotion.standard) { controller.windowManager.switchToWorkspace(index) }
                })
        }
        for index in 0..<WindowManager.maximumWorkspaces {
            let digit = KeyEquivalent(Character(String(index + 1)))
            commands.append(DesktopCommand(
                id: "workspace.move.\(index + 1)", title: "Move Window to Workspace \(index + 1)", group: .workspaces,
                key: digit, modifiers: [.control, .option, .shift], keyLabel: "\(index + 1)",
                perform: onFocused { $0.move($1, toWorkspace: index) }))
        }
        return commands
    }
}

/// Registers the command table as UIKit key commands on the root view controller, which is
/// on every responder chain, so they work while a terminal, a Linux window or a text field
/// holds first responder. Titles are what the hold-⌘ overlay lists. UIKit rather than
/// SwiftUI's `.keyboardShortcut`, because SwiftUI drops Return chords and cannot give
/// Escape priority over a focused text field.
@MainActor
final class DesktopKeyCommands {
    private weak var controller: DesktopController?
    private weak var host: UIViewController?
    private var overlayCommands: [UIKeyCommand] = []
    private var tableCommands: [UIKeyCommand] = []

    init(controller: DesktopController) {
        self.controller = controller
    }

    func install(on host: UIViewController) {
        guard host !== self.host else { return }
        self.host = host
        tableCommands = []
        syncOverlayCommands()
    }

    /// The table's bindings, minus ⌘ chords while a Linux app or the terminal has focus.
    /// ⌘W is always caught: left to UIKit it closes the whole iSH window (iPadOS 26), so
    /// when the desktop does not use it, it goes to the focused Linux app by hand.
    private func syncTableCommands() {
        guard let host, let controller else { return }
        let yield = controller.focusedWindowOwnsCommandKeys
        let table = DesktopCommand.all.filter { !(yield && $0.yieldsToApps) }
        var wanted = table.map {
            Self.keyCommand(title: $0.title, key: $0.key, modifiers: $0.modifiers, id: $0.id)
        }
        if !table.contains(where: { $0.key == "w" && $0.modifiers == .command }) {
            let guardCommand = UIKeyCommand(title: "", action: #selector(UIResponder.desktopPerformKeyCommand(_:)),
                                            input: "w", modifierFlags: .command, propertyList: "app.commandW")
            guardCommand.wantsPriorityOverSystemBehavior = true
            wanted.append(guardCommand)
        }
        let signature = { (commands: [UIKeyCommand]) in
            commands.map { "\($0.propertyList ?? "")|\($0.input ?? "")|\($0.modifierFlags.rawValue)" }
        }
        guard signature(wanted) != signature(tableCommands) else { return }
        tableCommands.forEach(host.removeKeyCommand)
        tableCommands = wanted
        tableCommands.forEach(host.addKeyCommand)
    }

    /// Escape and the switcher's arrows are bound only while an overlay is open, so they
    /// still reach apps (vim needs its Escape) the rest of the time.
    func syncOverlayCommands() {
        syncTableCommands()
        guard let host, let controller else { return }
        overlayCommands.forEach(host.removeKeyCommand)
        overlayCommands = []
        if controller.isOverlayPresented {
            overlayCommands.append(Self.keyCommand(title: "Close", key: .escape, modifiers: [], id: "overlay.close"))
        }
        if controller.themePicker != nil {
            overlayCommands += [
                Self.keyCommand(title: "Previous Theme", key: .leftArrow, modifiers: [], id: "picker.previous"),
                Self.keyCommand(title: "Next Theme", key: .rightArrow, modifiers: [], id: "picker.next"),
                Self.keyCommand(title: "Previous Theme", key: .upArrow, modifiers: [], id: "picker.previous"),
                Self.keyCommand(title: "Next Theme", key: .downArrow, modifiers: [], id: "picker.next"),
                Self.keyCommand(title: "Apply Theme", key: .return, modifiers: [], id: "picker.commit"),
            ]
        }
        if controller.switcher.isPresented {
            overlayCommands += [
                Self.keyCommand(title: "Previous Window", key: .leftArrow, modifiers: [], id: "switcher.previous"),
                Self.keyCommand(title: "Next Window", key: .rightArrow, modifiers: [], id: "switcher.next"),
                Self.keyCommand(title: "Switch to Window", key: .return, modifiers: [], id: "switcher.commit"),
            ]
        }
        if controller.desktopHasKeyboardFocus && !controller.isOverlayPresented {
            overlayCommands += [
                Self.keyCommand(title: "Select Left", key: .leftArrow, modifiers: [], id: "desktop.left"),
                Self.keyCommand(title: "Select Right", key: .rightArrow, modifiers: [], id: "desktop.right"),
                Self.keyCommand(title: "Select Up", key: .upArrow, modifiers: [], id: "desktop.up"),
                Self.keyCommand(title: "Select Down", key: .downArrow, modifiers: [], id: "desktop.down"),
                Self.keyCommand(title: "Open", key: .return, modifiers: [], id: "desktop.open"),
                Self.keyCommand(title: "Move to Trash", key: .delete, modifiers: .command, id: "desktop.trash"),
                Self.keyCommand(title: "Select All Icons", key: "a", modifiers: .command, id: "desktop.selectAll"),
                Self.renameCommand(),
            ]
        }
        overlayCommands.forEach(host.addKeyCommand)
    }

    /// F2 renames, as on Linux and Windows desktops.
    private static func renameCommand() -> UIKeyCommand {
        let command = UIKeyCommand(title: "Rename", action: #selector(UIResponder.desktopPerformKeyCommand(_:)),
                                   input: UIKeyCommand.f2, modifierFlags: [], propertyList: "desktop.rename")
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    func perform(_ id: String) {
        guard let controller else { return }
        switch id {
        case "overlay.close": controller.dismissTopOverlay()
        case "switcher.previous": controller.switcher.move(by: -1)
        case "switcher.next": controller.switcher.move(by: 1)
        case "switcher.commit": controller.commitSwitcher()
        case "picker.previous": controller.moveThemePicker(by: -1)
        case "picker.next": controller.moveThemePicker(by: 1)
        case "picker.commit": controller.commitThemePicker()
        case "desktop.left": _ = controller.desktopKeyHandler?(.move(dx: -1, dy: 0))
        case "desktop.right": _ = controller.desktopKeyHandler?(.move(dx: 1, dy: 0))
        case "desktop.up": _ = controller.desktopKeyHandler?(.move(dx: 0, dy: -1))
        case "desktop.down": _ = controller.desktopKeyHandler?(.move(dx: 0, dy: 1))
        case "desktop.open": _ = controller.desktopKeyHandler?(.open)
        case "desktop.trash": _ = controller.desktopKeyHandler?(.trash)
        case "desktop.rename": _ = controller.desktopKeyHandler?(.rename)
        case "desktop.selectAll": _ = controller.desktopKeyHandler?(.selectAll)
        case "app.commandW": controller.forwardCommandChord(UIKeyboardHIDUsage.keyboardW)
        default: DesktopCommand.all.first { $0.id == id }?.perform(controller)
        }
    }

    private static func keyCommand(title: String, key: KeyEquivalent, modifiers: EventModifiers,
                                   id: String) -> UIKeyCommand {
        let command = UIKeyCommand(title: title, action: #selector(UIResponder.desktopPerformKeyCommand(_:)),
                                   input: input(for: key), modifierFlags: flags(for: modifiers),
                                   propertyList: id)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    private static func input(for key: KeyEquivalent) -> String {
        switch key {
        case .leftArrow: UIKeyCommand.inputLeftArrow
        case .rightArrow: UIKeyCommand.inputRightArrow
        case .upArrow: UIKeyCommand.inputUpArrow
        case .downArrow: UIKeyCommand.inputDownArrow
        case .escape: UIKeyCommand.inputEscape
        case .return: "\r"
        // Backspace: the key labelled Delete on Apple keyboards.
        case .delete: "\u{8}"
        case .tab: "\t"
        case .space: " "
        default: String(key.character)
        }
    }

    private static func flags(for modifiers: EventModifiers) -> UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.alternate) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }

    /// The key command's action travels up the responder chain from whatever holds first
    /// responder; every responder answers it and hands it here.
    static weak var active: DesktopKeyCommands?
}

extension UIResponder {
    @objc func desktopPerformKeyCommand(_ sender: UIKeyCommand) {
        guard let id = sender.propertyList as? String else { return }
        MainActor.assumeIsolated { DesktopKeyCommands.active?.perform(id) }
    }
}
