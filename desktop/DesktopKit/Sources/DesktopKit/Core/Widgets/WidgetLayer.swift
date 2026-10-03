import SwiftUI
import UIKit

/// Widgets on the desktop, under the windows and over the icons. Outside edit mode only the
/// widgets themselves take touches; in edit mode they move and resize on the grid, by
/// finger, pointer or keyboard.
struct WidgetLayer: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var drag: Adjustment?
    @State private var resize: Adjustment?

    /// A widget being dragged or resized: the translation so far.
    private struct Adjustment: Equatable {
        var id: UUID
        var translation: CGSize
    }

    private static let gap: CGFloat = 4

    private var store: DesktopWidgetStore { controller.widgets }
    private var workspace: Int { controller.windowManager.currentWorkspace }

    var body: some View {
        GeometryReader { proxy in
            let grid = WidgetGrid(size: proxy.size)
            ZStack(alignment: .topLeading) {
                if store.isEditing {
                    editBackdrop(grid, size: proxy.size)
                }
                ForEach(store.widgets(workspace: workspace)) { widget in
                    widgetView(widget, grid: grid)
                }
                if store.isEditing {
                    editBar
                        .frame(width: proxy.size.width)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onChange(of: grid, initial: true) { _, grid in store.grid = grid }
        }
        .environment(\.widgetsAreLive, scenePhase == .active && !controller.isLocked)
        .background {
            WidgetKeyHost(isActive: store.isEditing, onKey: handle)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
        .animation(DesktopMotion.quick, value: store.isEditing)
    }

    // MARK: Widgets

    private func widgetView(_ widget: DesktopWidget, grid: WidgetGrid) -> some View {
        let base = grid.rect(for: widget.frame)
        var rect = base
        if let drag, drag.id == widget.id {
            rect.origin.x += drag.translation.width
            rect.origin.y += drag.translation.height
        }
        if let resize, resize.id == widget.id {
            rect.size.width = max(base.width + resize.translation.width, CGFloat(widget.kind.minimumSize.width) * WidgetGrid.cell)
            rect.size.height = max(base.height + resize.translation.height, CGFloat(widget.kind.minimumSize.height) * WidgetGrid.cell)
        }
        let isSelected = store.isEditing && store.selectedID == widget.id
        return ZStack(alignment: .topLeading) {
            if drag?.id == widget.id || resize?.id == widget.id {
                snapGhost(for: widget, grid: grid, base: base)
            }
            WidgetChrome(isEditing: store.isEditing, isSelected: isSelected) {
                DesktopWidgetContent(widget: widget, controller: controller) { key, value in
                    store.setOption(key, value, for: widget.id, workspace: workspace)
                }
                .allowsHitTesting(!store.isEditing)
            }
            .frame(width: rect.width - Self.gap * 2, height: rect.height - Self.gap * 2)
            .overlay(alignment: .topLeading) {
                if store.isEditing { removeButton(widget) }
            }
            .overlay(alignment: .bottomTrailing) {
                if store.isEditing { resizeHandle(widget, grid: grid, base: base) }
            }
            .contentShape(Rectangle())
            .gesture(moveGesture(widget, grid: grid, base: base), including: store.isEditing ? .all : .subviews)
            .simultaneousGesture(TapGesture().onEnded { if store.isEditing { store.selectedID = widget.id } })
            .contextMenu { if !store.isEditing { menu(for: widget) } }
            .offset(x: rect.minX + Self.gap, y: rect.minY + Self.gap)
            .zIndex(drag?.id == widget.id ? 1 : 0)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(widget.kind.title)
            .accessibilityIdentifier("desktop.widget.\(widget.kind.rawValue)")
        }
    }

    /// Where the widget lands when the finger lifts.
    private func snapGhost(for widget: DesktopWidget, grid: WidgetGrid, base: CGRect) -> some View {
        let target = targetFrame(for: widget, grid: grid, base: base)
        let rect = grid.rect(for: target)
        return RoundedRectangle(cornerRadius: theme.cornerRadius + 4, style: .continuous)
            .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(RoundedRectangle(cornerRadius: theme.cornerRadius + 4, style: .continuous).fill(theme.accent.opacity(0.12)))
            .frame(width: rect.width - Self.gap * 2, height: rect.height - Self.gap * 2)
            .offset(x: rect.minX + Self.gap, y: rect.minY + Self.gap)
            .allowsHitTesting(false)
    }

    private func targetFrame(for widget: DesktopWidget, grid: WidgetGrid, base: CGRect) -> WidgetFrame {
        var frame = grid.clamp(widget.frame)
        if let drag, drag.id == widget.id {
            let cell = grid.cell(at: CGPoint(x: base.minX + drag.translation.width, y: base.minY + drag.translation.height))
            frame.x = cell.x
            frame.y = cell.y
        }
        if let resize, resize.id == widget.id {
            let kind = widget.kind
            frame.width = min(max(Int(((base.width + resize.translation.width) / WidgetGrid.cell).rounded()), kind.minimumSize.width), kind.maximumSize.width)
            frame.height = min(max(Int(((base.height + resize.translation.height) / WidgetGrid.cell).rounded()), kind.minimumSize.height), kind.maximumSize.height)
        }
        return grid.clamp(frame)
    }

    private func moveGesture(_ widget: DesktopWidget, grid: WidgetGrid, base: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                store.selectedID = widget.id
                drag = Adjustment(id: widget.id, translation: value.translation)
            }
            .onEnded { _ in
                let target = targetFrame(for: widget, grid: grid, base: base)
                withAnimation(DesktopMotion.quick) {
                    store.move(widget.id, toX: target.x, y: target.y, workspace: workspace)
                    drag = nil
                }
            }
    }

    private func resizeHandle(_ widget: DesktopWidget, grid: WidgetGrid, base: CGRect) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(theme.accent.readableLabel)
            .frame(width: 24, height: 24)
            .background(Circle().fill(theme.accent))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .offset(x: 12, y: 12)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    store.selectedID = widget.id
                    resize = Adjustment(id: widget.id, translation: value.translation)
                }
                .onEnded { _ in
                    let target = targetFrame(for: widget, grid: grid, base: base)
                    withAnimation(DesktopMotion.quick) {
                        store.resize(widget.id, to: target.size, workspace: workspace)
                        resize = nil
                    }
                })
            .hoverEffect(.lift)
            .accessibilityLabel("Resize \(widget.kind.title)")
            .accessibilityIdentifier("widgets.resize.\(widget.kind.rawValue)")
    }

    private func removeButton(_ widget: DesktopWidget) -> some View {
        Button {
            withAnimation(DesktopMotion.quick) { store.remove(widget.id, workspace: workspace) }
        } label: {
            Image(systemName: "minus")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color(white: 0.35)))
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: -14, y: -14)
        .hoverEffect(.lift)
        .accessibilityLabel("Remove \(widget.kind.title)")
        .accessibilityIdentifier("widgets.remove.\(widget.kind.rawValue)")
    }

    @ViewBuilder
    private func menu(for widget: DesktopWidget) -> some View {
        if widget.kind == .clock {
            let isAnalog = widget.options["style"] != "digital"
            Button(isAnalog ? "Digital Clock" : "Analog Clock", systemImage: isAnalog ? "textformat.123" : "clock") {
                store.setOption("style", isAnalog ? "digital" : "analog", for: widget.id, workspace: workspace)
            }
        }
        Button("Edit Widgets", systemImage: "square.grid.3x3") { store.isEditing = true }
        Button("Remove Widget", systemImage: "minus.circle", role: .destructive) {
            withAnimation(DesktopMotion.quick) { store.remove(widget.id, workspace: workspace) }
        }
    }

    // MARK: Edit mode

    private func editBackdrop(_ grid: WidgetGrid, size: CGSize) -> some View {
        Canvas { context, _ in
            for column in 0...grid.columns {
                for row in 0...grid.rows {
                    let point = CGPoint(x: WidgetGrid.margin + CGFloat(column) * WidgetGrid.cell,
                                        y: WidgetGrid.margin + CGFloat(row) * WidgetGrid.cell)
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)),
                                 with: .color(.white.opacity(0.35)))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.black.opacity(0.18))
        .contentShape(Rectangle())
        .onTapGesture { store.isEditing = false }
        .overlay {
            if store.widgets(workspace: workspace).isEmpty {
                Text("Add widgets with the button above.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                    .allowsHitTesting(false)
            }
        }
        .transition(.opacity)
        .accessibilityIdentifier("widgets.backdrop")
    }

    private var editBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(DesktopWidgetKind.allCases) { kind in
                    Button {
                        withAnimation(DesktopMotion.quick) { _ = store.add(kind, workspace: workspace) }
                    } label: { ThemedLabel(kind.title, systemImage: kind.symbol) }
                    .accessibilityIdentifier("widgets.gallery.\(kind.rawValue)")
                }
            } label: {
                Label("Add Widget", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(theme.primaryText.opacity(0.1)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityIdentifier("widgets.add")
            Toggle(isOn: Binding(get: { store.scope == .perWorkspace }, set: { perWorkspace in
                store.setScope(perWorkspace ? .perWorkspace : .global, currentWorkspace: workspace)
            })) {
                Label("Per Workspace", systemImage: "square.stack.3d.up")
                    .font(.system(size: 13, weight: .medium))
            }
            .toggleStyle(.button)
            .tint(theme.accent)
            .accessibilityIdentifier("widgets.perWorkspace")
            Button { store.isEditing = false } label: {
                Text("Done")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent.readableLabel)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(Capsule().fill(theme.accent))
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityIdentifier("widgets.done")
        }
        .foregroundStyle(theme.primaryText)
        .padding(6)
        .background {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(theme.panelBackground)
        }
        .overlay(Capsule().strokeBorder(theme.separator))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("widgets.editBar")
    }

    private func handle(_ key: WidgetKey) {
        let widgets = store.widgets(workspace: workspace)
        if key == .done {
            store.isEditing = false
            return
        }
        if key == .next {
            let index = widgets.firstIndex { $0.id == store.selectedID } ?? -1
            store.selectedID = widgets.isEmpty ? nil : widgets[(index + 1) % widgets.count].id
            return
        }
        guard let id = store.selectedID ?? widgets.last?.id,
              let widget = widgets.first(where: { $0.id == id }) else { return }
        store.selectedID = id
        let size = widget.frame.size
        withAnimation(DesktopMotion.quick) {
            switch key {
            case .left: store.nudge(id, dx: -1, dy: 0, workspace: workspace)
            case .right: store.nudge(id, dx: 1, dy: 0, workspace: workspace)
            case .up: store.nudge(id, dx: 0, dy: -1, workspace: workspace)
            case .down: store.nudge(id, dx: 0, dy: 1, workspace: workspace)
            case .narrower: store.resize(id, to: WidgetSize(width: size.width - 1, height: size.height), workspace: workspace)
            case .wider: store.resize(id, to: WidgetSize(width: size.width + 1, height: size.height), workspace: workspace)
            case .shorter: store.resize(id, to: WidgetSize(width: size.width, height: size.height - 1), workspace: workspace)
            case .taller: store.resize(id, to: WidgetSize(width: size.width, height: size.height + 1), workspace: workspace)
            case .remove: store.remove(id, workspace: workspace)
            case .done, .next: break
            }
        }
    }
}

/// The frame every widget shares: the theme's panel colour over a blur, the theme's radius.
struct WidgetChrome<Content: View>: View {
    let isEditing: Bool
    let isSelected: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.cornerRadius + 4, style: .continuous)
        content()
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(theme.primaryText)
            .background {
                shape.fill(theme.panelBlur ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.clear))
                shape.fill(theme.panelBackground)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(isSelected ? theme.accent : theme.separator, lineWidth: isSelected ? 2 : 1))
            .shadow(color: .black.opacity(isEditing ? 0.35 : 0.2), radius: isEditing ? 14 : 8, y: 4)
            .scaleEffect(isEditing ? 0.98 : 1)
    }
}

// MARK: - Keyboard

/// Edit-mode keys: arrows move, ⇧arrows resize, Tab picks the next widget, Delete removes,
/// Return or Escape finishes.
enum WidgetKey: String, CaseIterable {
    case left, right, up, down, narrower, wider, shorter, taller, next, remove, done

    var commands: [UIKeyCommand] {
        let inputs: [(String, UIKeyModifierFlags)] = {
            switch self {
            case .left: [(UIKeyCommand.inputLeftArrow, [])]
            case .right: [(UIKeyCommand.inputRightArrow, [])]
            case .up: [(UIKeyCommand.inputUpArrow, [])]
            case .down: [(UIKeyCommand.inputDownArrow, [])]
            case .narrower: [(UIKeyCommand.inputLeftArrow, .shift)]
            case .wider: [(UIKeyCommand.inputRightArrow, .shift)]
            case .shorter: [(UIKeyCommand.inputUpArrow, .shift)]
            case .taller: [(UIKeyCommand.inputDownArrow, .shift)]
            case .next: [("\t", [])]
            case .remove: [("\u{8}", []), (UIKeyCommand.inputDelete, [])]
            case .done: [(UIKeyCommand.inputEscape, []), ("\r", [])]
            }
        }()
        return inputs.map { input, flags in
            let command = UIKeyCommand(title: "", action: #selector(WidgetKeyView.performWidgetKey(_:)), input: input,
                                       modifierFlags: flags, propertyList: rawValue)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    static let allCommands = allCases.flatMap(\.commands)
}

final class WidgetKeyView: UIView {
    var onKey: ((WidgetKey) -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? { WidgetKey.allCommands }

    @objc func performWidgetKey(_ sender: UIKeyCommand) {
        guard let raw = sender.propertyList as? String, let key = WidgetKey(rawValue: raw) else { return }
        onKey?(key)
    }
}

private struct WidgetKeyHost: UIViewRepresentable {
    let isActive: Bool
    let onKey: (WidgetKey) -> Void

    func makeUIView(context: Context) -> WidgetKeyView {
        let view = WidgetKeyView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: WidgetKeyView, context: Context) {
        view.onKey = onKey
        if isActive, !view.isFirstResponder {
            DispatchQueue.main.async { if view.window != nil { view.becomeFirstResponder() } }
        } else if !isActive, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}
