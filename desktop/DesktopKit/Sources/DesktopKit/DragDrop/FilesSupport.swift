import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Keyboard

/// File manager keys. SwiftUI can't bind F2, Space or bare Delete reliably next to the
/// desktop's UIKit key commands, so a small UIKit responder takes them while its window
/// is focused; the desktop's own shortcuts stay reachable further up the responder chain.
enum FileKey: String, CaseIterable {
    case copy, cut, paste, selectAll, trash, trashCommand, deletePermanently, rename
    case open, quickLook, up, down, left, right, extendUp, extendDown, extendLeft, extendRight
    case goUp, back, forward, newFolder, escape, showHidden, duplicate, properties

    var command: UIKeyCommand {
        let (input, flags): (String, UIKeyModifierFlags) = {
            switch self {
            case .copy: return ("c", .command)
            case .cut: return ("x", .command)
            case .paste: return ("v", .command)
            case .selectAll: return ("a", .command)
            case .trash: return ("\u{8}", [])
            case .trashCommand: return ("\u{8}", .command)
            case .deletePermanently: return ("\u{8}", .shift)
            case .rename: return (UIKeyCommand.f2, [])
            case .open: return ("\r", [])
            case .quickLook: return (" ", [])
            case .up: return (UIKeyCommand.inputUpArrow, [])
            case .down: return (UIKeyCommand.inputDownArrow, [])
            case .left: return (UIKeyCommand.inputLeftArrow, [])
            case .right: return (UIKeyCommand.inputRightArrow, [])
            case .extendUp: return (UIKeyCommand.inputUpArrow, .shift)
            case .extendDown: return (UIKeyCommand.inputDownArrow, .shift)
            case .extendLeft: return (UIKeyCommand.inputLeftArrow, .shift)
            case .extendRight: return (UIKeyCommand.inputRightArrow, .shift)
            case .goUp: return (UIKeyCommand.inputUpArrow, .command)
            case .back: return ("[", .command)
            case .forward: return ("]", .command)
            case .newFolder: return ("n", [.command, .shift])
            case .escape: return (UIKeyCommand.inputEscape, [])
            case .showHidden: return ("h", .control)
            case .duplicate: return ("d", .command)
            case .properties: return ("i", .command)
            }
        }()
        let command = UIKeyCommand(title: "", action: #selector(KeyCommandView.performKeyCommand(_:)),
                                   input: input, modifierFlags: flags, propertyList: rawValue)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    static let commands = allCases.map(\.command)
}

final class KeyCommandView: UIView {
    var onKey: ((FileKey) -> Void)?
    var onType: ((String) -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? { FileKey.commands }

    @objc func performKeyCommand(_ sender: UIKeyCommand) {
        guard let raw = sender.propertyList as? String, let key = FileKey(rawValue: raw) else { return }
        onKey?(key)
    }

    /// Plain printable keys select by name (type-to-select).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, key.modifierFlags.isDisjoint(with: [.command, .control, .alternate]),
                  key.characters.count == 1, let scalar = key.characters.unicodeScalars.first,
                  scalar.value >= 0x21, scalar.value != 0x7f else {
                unhandled.insert(press)
                continue
            }
            onType?(key.characters)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }
}

/// Takes the keyboard while `isActive`, and again whenever `focusToken` changes (after a
/// click in the list, or when a prompt that held the keyboard closes).
struct KeyCommandHost: UIViewRepresentable {
    let isActive: Bool
    let focusToken: Int
    let onKey: (FileKey) -> Void
    let onType: (String) -> Void

    func makeUIView(context: Context) -> KeyCommandView {
        let view = KeyCommandView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: KeyCommandView, context: Context) {
        view.onKey = onKey
        view.onType = onType
        if isActive {
            if !view.isFirstResponder || context.coordinator.lastToken != focusToken {
                context.coordinator.lastToken = focusToken
                DispatchQueue.main.async { if view.window != nil { view.becomeFirstResponder() } }
            }
        } else if view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastToken = -1
    }
}

// MARK: - Dropping into a folder

/// A folder that takes drops: guest files are moved (copied with Option, shown with the
/// system's + badge), everything else is copied in.
struct FolderDropDelegate: DropDelegate {
    let directory: String
    let onTarget: (String?, DropOperation?) -> Void
    let onDrop: (_ providers: [NSItemProvider], _ operation: DropOperation) -> Void

    @MainActor
    private func operation(_ info: DropInfo) -> DropOperation {
        info.hasItemsConforming(to: [.guestItems]) ? DropOperation.forGuestDrag() : .copy
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: DragItemProviders.acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated { onTarget(directory, operation(info)) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            let operation = operation(info)
            onTarget(directory, operation)
            return DropProposal(operation: operation == .copy ? .copy : .move)
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { onTarget(nil, nil) }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            let operation = operation(info)
            onTarget(nil, nil)
            onDrop(info.itemProviders(for: DragItemProviders.acceptedTypes), operation)
        }
        return true
    }
}

/// "Move to Documents" / "Copy to Documents", shown while something hovers a folder.
struct DropBadge: View {
    let directory: String
    let operation: DropOperation
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        Label("\(operation == .copy ? "Copy" : "Move") to \(AppPath.lastComponent(directory))",
              systemImage: operation == .copy ? "plus.circle.fill" : "arrow.right.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(operation == .copy ? Color.green.opacity(0.9) : theme.accent))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .accessibilityIdentifier("files.drop-badge")
    }
}

// MARK: - Properties

struct FilePropertiesSheet: View {
    let path: String
    let operations: FileOperations
    let onDone: () -> Void

    @Environment(\.desktopTheme) private var theme
    @State private var properties: FileOperations.Properties?
    @State private var mode = 0
    @State private var error: String?

    private static let classes = [("Owner", 6), ("Group", 3), ("Others", 0)]
    private static let bits = [("Read", 4), ("Write", 2), ("Execute", 1)]

    var body: some View {
        NavigationStack {
            Form {
                if let properties {
                    Section {
                        row("Name", AppPath.lastComponent(path))
                        row("Kind", properties.kind.capitalized)
                        row("Location", AppPath.parent(of: path))
                        row("Size", ByteFormat.string(properties.size)
                            + (properties.itemCount.map { ", \($0) item\($0 == 1 ? "" : "s")" } ?? ""))
                    }
                    Section("Owner") {
                        row("User", properties.owner)
                        row("Group", properties.group)
                    }
                    Section("Permissions") {
                        ForEach(Self.classes, id: \.0) { name, shift in
                            HStack {
                                Text(name).frame(width: 70, alignment: .leading)
                                ForEach(Self.bits, id: \.0) { bitName, bit in
                                    Toggle(bitName, isOn: binding(bit << shift))
                                        .toggleStyle(.button)
                                        .accessibilityIdentifier("properties.\(name.lowercased()).\(bitName.lowercased())")
                                }
                            }
                        }
                        row("Mode", String(format: "%04o", mode) + "  " + Self.symbolic(mode, kind: properties.permissions.first ?? "-"))
                    }
                    Section("Dates") {
                        dateRow("Modified", properties.modified)
                        dateRow("Accessed", properties.accessed)
                        dateRow("Changed", properties.changed)
                    }
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("\(AppPath.lastComponent(path)) Properties")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                        .disabled(properties == nil || properties?.mode == mode)
                }
            }
        }
        .task {
            do {
                let loaded = try await operations.properties(of: path)
                properties = loaded
                mode = loaded.mode
            } catch {
                self.error = error.localizedDescription
            }
        }
        .frame(minWidth: 420, minHeight: 520)
    }

    private func binding(_ bit: Int) -> Binding<Bool> {
        Binding(get: { mode & bit != 0 }, set: { mode = $0 ? mode | bit : mode & ~bit })
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }

    private func dateRow(_ label: String, _ date: Date?) -> some View {
        row(label, date.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "—")
    }

    private func apply() {
        Task {
            do {
                try await operations.setMode(mode, of: path)
                onDone()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    static func symbolic(_ mode: Int, kind: Character) -> String {
        var result = String(kind)
        for shift in [6, 3, 0] {
            result += mode & (4 << shift) != 0 ? "r" : "-"
            result += mode & (2 << shift) != 0 ? "w" : "-"
            result += mode & (1 << shift) != 0 ? "x" : "-"
        }
        return result
    }
}
