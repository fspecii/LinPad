import SwiftUI

enum DesktopCoordinateSpace {
    static let name = "DesktopKit.desktop"
}

/// All windows plus the snap preview and, in overview, the workspace strip. Every window
/// stays in the hierarchy whatever its workspace or minimized state, so hosted UIKit views
/// (the terminal) are never torn down.
struct WindowLayer: View {
    let controller: DesktopController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var manager: WindowManager { controller.windowManager }

    var body: some View {
        let overview = controller.isOverviewPresented ? OverviewLayout(controller: controller) : nil
        ZStack(alignment: .topLeading) {
            if let overview {
                OverviewBackdrop(controller: controller, layout: overview)
                    .zIndex(-1)
                    .transition(.opacity)
            }
            if let preview = manager.snapPreview, let window = manager.window(withID: preview.windowID) {
                SnapPreviewView(frame: preview.frame)
                    .zIndex(Double(manager.stackingOrder(of: window)) - 0.5)
            }
            ForEach(manager.windows) { window in
                WindowView(window: window, controller: controller, overviewFrame: overview?.frames[window.id])
                    .zIndex(Double(manager.stackingOrder(of: window)))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.94, anchor: .center).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transaction { transaction in
            if reduceMotion, transaction.animation != nil {
                transaction.animation = .easeInOut(duration: 0.12)
            }
        }
    }
}

private struct SnapPreviewView: View {
    let frame: CGRect
    @Environment(\.desktopTheme) private var theme

    // Deliberately no material: a live blur under a 120 Hz drag costs a full-screen offscreen pass.
    var body: some View {
        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
            .fill(theme.accent.opacity(0.2))
            .overlay {
                RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                    .strokeBorder(theme.accent.opacity(0.75), lineWidth: 2)
            }
            .padding(6)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityIdentifier("desktop.snapPreview")
    }
}

struct WindowView: View {
    let window: DesktopWindow
    let controller: DesktopController
    /// Where the window sits while the overview is open, nil otherwise.
    let overviewFrame: CGRect?

    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moveOrigin: CGRect?
    @State private var overviewDrag: CGSize = .zero

    private var manager: WindowManager { controller.windowManager }
    private var isFocused: Bool { manager.focusedWindowID == window.id }
    private var isVisible: Bool { manager.isVisible(window) }
    private var isInOverview: Bool { overviewFrame != nil }

    var body: some View {
        let frame = manager.displayFrame(for: window)
        let isMaximized = window.isMaximized && !isInOverview
        let radius = isMaximized ? 0 : theme.cornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let placement = placement(for: frame)

        VStack(spacing: 0) {
            titleBar
            WindowContentHost(window: window)
                .environment(\.desktopWindowIsVisible, isVisible)
                .environment(\.desktopWindowIsFocused, isFocused && !controller.isOverlayPresented)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.windowBackground)
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(isFocused ? theme.accent.opacity(0.45) : theme.separator, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(window.title)
        .accessibilityIdentifier("window:\(window.appID)")
        .accessibilityValue(accessibilityState)
        .background {
            WindowShadow(cornerRadius: radius, isFocused: isFocused, isHidden: isMaximized)
        }
        .overlay { if !window.isMaximized && !isInOverview { resizeHandles } }
        .overlay { if isInOverview { overviewInteraction } }
        .frame(width: frame.width, height: frame.height)
        .scaleEffect(placement.scale, anchor: .topLeading)
        .opacity(placement.opacity)
        .offset(x: placement.origin.x + overviewDrag.width, y: placement.origin.y + overviewDrag.height)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
    }

    private struct Placement {
        var origin: CGPoint
        var scale: CGFloat
        var opacity: Double
    }

    /// Floating, minimized into its taskbar button, or shrunk into the overview grid. Only
    /// transforms change, so the app's content is never laid out again for these.
    private func placement(for frame: CGRect) -> Placement {
        if let overviewFrame, frame.width > 0 {
            return Placement(origin: overviewFrame.origin, scale: overviewFrame.width / frame.width, opacity: 1)
        }
        guard isVisible else {
            if window.isMinimized, !reduceMotion, let global = manager.taskbarTargets[window.id], frame.width > 0 {
                let target = global.offsetBy(dx: -manager.desktopGlobalOrigin.x, dy: -manager.desktopGlobalOrigin.y)
                let scale = max(target.width / frame.width, 0.05)
                return Placement(origin: CGPoint(x: target.midX - frame.width * scale / 2,
                                                 y: target.midY - frame.height * scale / 2),
                                 scale: scale, opacity: 0)
            }
            return Placement(origin: frame.origin, scale: window.isMinimized && !reduceMotion ? 0.9 : 1, opacity: 0)
        }
        return Placement(origin: frame.origin, scale: 1, opacity: 1)
    }

    private var accessibilityState: String {
        var parts: [String] = []
        if isFocused { parts.append("focused") }
        if window.isMinimized { parts.append("minimized") }
        if window.isMaximized { parts.append("maximized") }
        if let snap = window.snap { parts.append(snap.rawValue) }
        if window.isAlwaysOnTop { parts.append("always on top") }
        parts.append("workspace \(window.workspace + 1)")
        return parts.joined(separator: ", ")
    }

    // MARK: Title bar

    private var titleBar: some View {
        let spec = style.spec
        let menu = WindowMenu(window: window, controller: controller)
        return HStack(spacing: 0) {
            if spec.buttonPlacement == .leading {
                WindowButtons(window: window, manager: manager, shape: spec.buttonShape, isFocused: isFocused)
                    .padding(.leading, 6)
            }
            ZStack {
                TitleBarInteraction(
                    onBegan: { pointer in moveOrigin = manager.beginMove(window.id, pointer: pointer) },
                    onChanged: { translation, pointer in
                        guard let origin = moveOrigin else { return }
                        manager.updateMove(window.id, from: origin, translation: translation, pointer: pointer)
                    },
                    onEnded: { pointer in
                        if let origin = moveOrigin { manager.endMove(window.id, from: origin, pointer: pointer) }
                        moveOrigin = nil
                    },
                    onCancelled: {
                        manager.cancelMove(window.id)
                        moveOrigin = nil
                    },
                    onDoubleTap: { manager.toggleMaximize(window.id) },
                    menu: { menu.uiMenu() },
                    coordinator: controller.input)
                .accessibilityIdentifier("desktop.window.titlebar")
                .accessibilityLabel(window.title)
                .accessibilityAddTraits(.isHeader)
                .accessibilityAction(named: "Toggle Maximize") { manager.toggleMaximize(window.id) }

                HStack(spacing: 2) {
                    if spec.centersTitle { Spacer(minLength: 0) }
                    Menu {
                        menu.swiftUIItems
                    } label: {
                        AppGlyph(iconName: controller.iconName(forAppID: window.appID), url: controller.iconURL(forAppID: window.appID), symbol: window.symbol,
                                 size: 13, tint: isFocused ? theme.accent : theme.secondaryText)
                            .frame(width: 40, height: manager.titleBarHeight)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityLabel("Window menu")
                    .accessibilityIdentifier("desktop.window.menu")
                    Text(window.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isFocused ? theme.primaryText : theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .allowsHitTesting(false)
                    Spacer(minLength: 0)
                    if spec.centersTitle { Color.clear.frame(width: 40, height: 1).allowsHitTesting(false) }
                }
            }
            if spec.buttonPlacement == .trailing {
                WindowButtons(window: window, manager: manager, shape: spec.buttonShape, isFocused: isFocused)
            }
        }
        .frame(height: manager.titleBarHeight)
        .background(isFocused ? theme.titleBarActive : theme.titleBarInactive)
        .overlay(alignment: .bottom) {
            theme.separator.frame(height: 1)
        }
    }

    // MARK: Resize

    private var resizeHandles: some View {
        let edge: CGFloat = 20
        let corner: CGFloat = 30
        return ZStack {
            handle(.left).frame(width: edge).padding(.vertical, corner / 2)
                .frame(maxWidth: .infinity, alignment: .leading).offset(x: -edge * 0.6)
            handle(.right).frame(width: edge).padding(.vertical, corner / 2)
                .frame(maxWidth: .infinity, alignment: .trailing).offset(x: edge * 0.6)
            handle(.top).frame(height: edge * 0.7).padding(.horizontal, corner / 2)
                .frame(maxHeight: .infinity, alignment: .top).offset(y: -edge * 0.5)
            handle(.bottom).frame(height: edge).padding(.horizontal, corner / 2)
                .frame(maxHeight: .infinity, alignment: .bottom).offset(y: edge * 0.6)
            handle(.topLeft).frame(width: corner, height: corner)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).offset(x: -corner / 2, y: -corner / 2)
            handle(.topRight).frame(width: corner, height: corner)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).offset(x: corner / 2, y: -corner / 2)
            handle(.bottomLeft).frame(width: corner, height: corner)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).offset(x: -corner / 2, y: corner / 2)
            ZStack(alignment: .bottomTrailing) {
                handle(.bottomRight)
                ResizeGrip(isEmphasized: isFocused)
                    .padding(.trailing, corner / 2 + 3)
                    .padding(.bottom, corner / 2 + 3)
                    .allowsHitTesting(false)
            }
            .frame(width: corner * 1.4, height: corner * 1.4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .offset(x: corner / 2, y: corner / 2)
        }
    }

    /// Only the corner grip is exposed to accessibility; eight resize strips per window
    /// would drown VoiceOver, and the window menu offers the same layouts.
    private func handle(_ edge: ResizeEdge) -> some View {
        ResizeHandle(edge: edge, windowID: window.id, manager: manager)
            .accessibilityElement()
            .accessibilityLabel("Resize")
            .accessibilityIdentifier("desktop.window.resize.\(edge)")
            .accessibilityHidden(edge != .bottomRight)
    }

    // MARK: Overview

    private var overviewInteraction: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                controller.setOverviewPresented(false)
                manager.focus(window.id)
            }
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named(DesktopCoordinateSpace.name))
                    .onChanged { value in
                        overviewDrag = value.translation
                        controller.overviewDropHover = controller.overviewWorkspace(at: value.location)
                    }
                    .onEnded { value in
                        if let target = controller.overviewWorkspace(at: value.location) {
                            manager.move(window.id, toWorkspace: target)
                        }
                        controller.overviewDropHover = nil
                        withAnimation(DesktopMotion.standard) { overviewDrag = .zero }
                    }
            )
            .hoverEffect(.highlight)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(window.title)
            .accessibilityIdentifier("desktop.overview.window")
    }
}

/// Isolates the app's view from chrome updates: dragging re-renders `WindowView`, but this
/// view only reads `content`, which never changes, so the app's body is not re-evaluated.
private struct WindowContentHost: View {
    let window: DesktopWindow

    var body: some View {
        window.content
    }
}

private struct ResizeGrip: View {
    let isEmphasized: Bool
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        Path { path in
            for inset in [0.0, 4.0, 8.0] {
                path.move(to: CGPoint(x: 10, y: inset))
                path.addLine(to: CGPoint(x: inset, y: 10))
            }
        }
        .stroke(theme.secondaryText.opacity(isEmphasized ? 0.7 : 0.35),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }
}

private struct ResizeHandle: View {
    let edge: ResizeEdge
    let windowID: UUID
    let manager: WindowManager

    @State private var origin: CGRect?

    var body: some View {
        ResizeInteraction(
            edge: edge,
            onBegan: { origin = manager.beginResize(windowID) },
            onChanged: { translation in
                guard let origin else { return }
                manager.updateResize(windowID, from: origin, edge: edge, translation: translation)
            },
            onEnded: {
                origin = nil
                manager.endResize(windowID)
            })
    }
}
