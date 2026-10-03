import SwiftUI
import UniformTypeIdentifiers

/// Shared pieces of the workspace pills and the overview strip: the context menu (rename,
/// delete), the "+" control, and drag-to-reorder.
enum WorkspaceDrag {
    private static let prefix = "ish-workspace:"

    static func provider(for index: Int) -> NSItemProvider {
        NSItemProvider(object: "\(prefix)\(index)" as NSString)
    }

    static func index(from string: String) -> Int? {
        guard string.hasPrefix(prefix) else { return nil }
        return Int(string.dropFirst(prefix.count))
    }
}

/// Drop target for a workspace pill or card: a workspace dropped here moves to this spot.
struct WorkspaceReorderDropDelegate: DropDelegate {
    let manager: WindowManager
    let index: Int
    @Binding var hovered: Int?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        hovered = index
    }

    func dropExited(info: DropInfo) {
        if hovered == index { hovered = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        hovered = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let target = index
        let manager = manager
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, let source = WorkspaceDrag.index(from: string) else { return }
            Task { @MainActor in
                withAnimation(DesktopMotion.standard) { manager.moveWorkspace(from: source, to: target) }
            }
        }
        return true
    }
}

/// Context menu, rename prompt and delete confirmation for one workspace.
struct WorkspaceMenu: ViewModifier {
    let manager: WindowManager
    let index: Int
    @State private var isRenaming = false
    @State private var name = ""
    @State private var confirmsDelete = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    name = manager.workspaceNames.indices.contains(index) ? manager.workspaceNames[index] : ""
                    isRenaming = true
                } label: { ThemedLabel("Rename…", systemImage: "pencil") }
                Button { addAndSwitch(manager) } label: { ThemedLabel("New Workspace", systemImage: "plus") }
                    .disabled(manager.workspaceCount >= WindowManager.maximumWorkspaces)
                Divider()
                Button(role: .destructive) {
                    if manager.hasWindows(inWorkspace: index) {
                        confirmsDelete = true
                    } else {
                        withAnimation(DesktopMotion.standard) { manager.removeWorkspace(index) }
                    }
                } label: { ThemedLabel("Delete Workspace", systemImage: "trash") }
                .disabled(manager.workspaceCount <= 1)
            }
            .alert("Rename \(manager.title(ofWorkspace: index))", isPresented: $isRenaming) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { manager.renameWorkspace(index, to: name) }
            } message: {
                Text("Leave empty to show the number.")
            }
            .confirmationDialog("Delete \(manager.title(ofWorkspace: index))?", isPresented: $confirmsDelete,
                                titleVisibility: .visible) {
                Button("Delete Workspace", role: .destructive) {
                    withAnimation(DesktopMotion.standard) { manager.removeWorkspace(index) }
                }
            } message: {
                Text("Its \(manager.windows(inWorkspace: index).count) windows move to \(index > 0 ? manager.title(ofWorkspace: index - 1) : manager.title(ofWorkspace: 1)).")
            }
    }
}

@MainActor
func addAndSwitch(_ manager: WindowManager) {
    withAnimation(DesktopMotion.standard) {
        if let index = manager.addWorkspace() { manager.switchToWorkspace(index) }
    }
}

extension View {
    func workspaceMenu(manager: WindowManager, index: Int) -> some View {
        modifier(WorkspaceMenu(manager: manager, index: index))
    }
}
