import SwiftUI

/// Minimize, maximize and close in the active style's shape. Each control keeps a touch
/// target of at least 32 x 40 pt (44 x 40 where the style's layout allows) whatever its
/// drawn size, and every style exposes the same accessibility identifiers.
struct WindowButtons: View {
    let window: DesktopWindow
    let manager: WindowManager
    let shape: DesktopStyleSpec.ButtonShape
    let isFocused: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            switch shape {
            case .trafficLight:
                light(.close)
                light(.minimize)
                light(.maximize)
            default:
                button(.minimize)
                button(.maximize)
                button(.close)
            }
        }
        .onHover { isHovering = $0 }
    }

    private func perform(_ kind: WindowButtonKind) {
        switch kind {
        case .minimize: manager.minimize(window.id)
        case .maximize: manager.toggleMaximize(window.id)
        case .close: manager.requestClose(window.id)
        }
    }

    private func light(_ kind: WindowButtonKind) -> some View {
        TrafficLight(kind: kind, isActive: isFocused || isHovering, showsGlyph: isHovering || manager.metrics.isTouch,
                     isMaximized: window.isMaximized, metrics: manager.metrics) { perform(kind) }
            .accessibilityLabel(kind.label(isMaximized: window.isMaximized))
            .accessibilityIdentifier("desktop.window.\(kind.rawValue)")
    }

    @ViewBuilder
    private func button(_ kind: WindowButtonKind) -> some View {
        let base = ChromeButton(kind: kind, shape: shape, isMaximized: window.isMaximized,
                                isFocused: isFocused, manager: manager) { perform(kind) }
            .accessibilityLabel(kind.label(isMaximized: window.isMaximized))
            .accessibilityIdentifier("desktop.window.\(kind.rawValue)")
        if kind == .maximize && shape == .caption {
            base.modifier(SnapLayoutsFlyout(windowID: window.id, manager: manager))
        } else {
            base
        }
    }
}

enum WindowButtonKind: String {
    case minimize
    case maximize
    case close

    func label(isMaximized: Bool) -> String {
        switch self {
        case .minimize: "Minimize"
        case .maximize: isMaximized ? "Restore" : "Maximize"
        case .close: "Close"
        }
    }

    func symbol(isMaximized: Bool, shape: DesktopStyleSpec.ButtonShape) -> String {
        switch (self, shape) {
        case (.minimize, _): "minus"
        case (.close, _): "xmark"
        case (.maximize, .caption), (.maximize, .kylin): isMaximized ? "square.on.square" : "square"
        case (.maximize, .round): isMaximized ? "arrow.down.right.and.arrow.up.left" : "chevron.up"
        case (.maximize, _): isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        }
    }
}

private struct ChromeButton: View {
    let kind: WindowButtonKind
    let shape: DesktopStyleSpec.ButtonShape
    let isMaximized: Bool
    let isFocused: Bool
    let manager: WindowManager
    let action: () -> Void

    @Environment(\.desktopTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            glyph
                .frame(width: buttonWidth, height: manager.titleBarHeight)
                .background(captionFill)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var buttonWidth: CGFloat {
        switch shape {
        case .kylin: manager.metrics.isTouch ? 48 : 34
        case .caption: max(46, manager.metrics.buttonSize)
        default: max(44, manager.metrics.buttonSize)
        }
    }

    @ViewBuilder
    private var glyph: some View {
        let image = Image(systemName: kind.symbol(isMaximized: isMaximized, shape: shape))
        switch shape {
        case .kylin:
            // 1 pt line art in a 30 pt box; hover tile radius 6 (DESIGN-SPEC.md §4).
            image.font(.system(size: 11, weight: .light))
                .foregroundStyle(isHovered && kind == .close ? Color.white
                                 : theme.primaryText.opacity(isFocused ? 1 : 0.3))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(kylinFill))
        case .caption:
            image.font(.system(size: 12, weight: .regular))
                .foregroundStyle(isHovered && kind == .close ? Color.white : theme.primaryText)
        case .round:
            let isClose = kind == .close
            image.font(.system(size: 9, weight: .heavy))
                .foregroundStyle(theme.primaryText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(roundFill(isClose: isClose)))
        default:
            image.font(.system(size: 11, weight: .bold))
                .foregroundStyle(isHovered && kind == .close ? Color.white : theme.secondaryText)
                .frame(width: 32, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(glyphFill))
        }
    }

    private var kylinFill: Color {
        guard isHovered else { return .clear }
        return kind == .close ? Color(red: 0xE7 / 255, green: 0x20 / 255, blue: 0x2B / 255) : theme.primaryText.opacity(0.16)
    }

    private func roundFill(isClose: Bool) -> Color {
        if isClose { return isHovered ? theme.accent : theme.primaryText.opacity(0.2) }
        return theme.primaryText.opacity(isHovered ? 0.18 : 0.08)
    }

    private var captionFill: Color {
        guard shape == .caption, isHovered else { return .clear }
        return kind == .close ? Color(red: 0.77, green: 0.17, blue: 0.11) : theme.primaryText.opacity(0.1)
    }

    private var glyphFill: Color {
        guard isHovered else { return .clear }
        return kind == .close ? Color(red: 0.86, green: 0.24, blue: 0.24) : theme.primaryText.opacity(0.12)
    }
}

private struct TrafficLight: View {
    let kind: WindowButtonKind
    let isActive: Bool
    let showsGlyph: Bool
    let isMaximized: Bool
    let metrics: WindowMetrics
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(isActive ? color : Color(white: 0.35))
                .overlay(Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                .overlay {
                    if showsGlyph {
                        Image(systemName: glyph)
                            .font(.system(size: 7, weight: .black))
                            .foregroundStyle(.black.opacity(0.6))
                    }
                }
                .frame(width: metrics.isTouch ? 18 : 13, height: metrics.isTouch ? 18 : 13)
                // Lights sit 8 pt apart as on macOS; touch mode spreads them to 40 pt targets.
                .frame(width: metrics.isTouch ? 40 : 26, height: metrics.titleBarHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var color: Color {
        switch kind {
        case .close: Color(red: 1.0, green: 0.37, blue: 0.34)
        case .minimize: Color(red: 1.0, green: 0.74, blue: 0.18)
        case .maximize: Color(red: 0.16, green: 0.78, blue: 0.25)
        }
    }

    private var glyph: String {
        switch kind {
        case .close: "xmark"
        case .minimize: "minus"
        case .maximize: isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        }
    }
}

/// Windows 11's Snap layouts: hovering the maximize button with a pointer (or long-pressing
/// it) offers the tiling layouts.
private struct SnapLayoutsFlyout: ViewModifier {
    let windowID: UUID
    let manager: WindowManager

    @State private var isPresented = false
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()
                guard hovering else { return }
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(550))
                    if !Task.isCancelled { isPresented = true }
                }
            }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in isPresented = true })
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                SnapLayoutsGrid { zone in
                    isPresented = false
                    manager.snap(windowID, to: zone)
                }
                .presentationCompactAdaptation(.popover)
            }
    }
}

private struct SnapLayoutsGrid: View {
    let choose: (SnapZone) -> Void
    @Environment(\.desktopTheme) private var theme

    private let layouts: [[SnapZone]] = [
        [.leftHalf, .rightHalf],
        [.topLeft, .topRight, .bottomLeft, .bottomRight],
        [.maximize],
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(layouts.indices, id: \.self) { index in
                layout(layouts[index])
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop.snapLayouts")
    }

    private func layout(_ zones: [SnapZone]) -> some View {
        let size = CGSize(width: 96, height: 64)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.primaryText.opacity(0.06))
            ForEach(zones, id: \.self) { zone in
                let frame = WindowGeometry.frame(for: zone, in: size).insetBy(dx: 2, dy: 2)
                Button { choose(zone) } label: {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(theme.primaryText.opacity(0.18))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .accessibilityLabel(zone.rawValue)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
