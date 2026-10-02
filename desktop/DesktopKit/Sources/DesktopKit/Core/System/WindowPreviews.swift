import SwiftUI

/// Thumbnails of an app's windows, for taskbar and Dock previews.
struct WindowPreviewStrip: View {
    let windows: [DesktopWindow]
    let controller: DesktopController
    var onPick: (() -> Void)?
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ForEach(windows) { window in
                Button {
                    onPick?()
                    controller.windowManager.focus(window.id)
                } label: {
                    VStack(spacing: 6) {
                        WindowThumbnail(window: window, controller: controller)
                            .frame(width: 240, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.separator))
                        Text(window.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                            .frame(width: 240)
                    }
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel(window.title)
                .accessibilityIdentifier("desktop.preview.window")
            }
        }
        .padding(12)
        .background(theme.windowBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop.preview")
    }
}

/// Pointer hover on a taskbar or Dock item shows live thumbnails of its windows after a
/// short delay; on touch, the long-press context menu carries the same preview.
struct WindowPreviewOnHover: ViewModifier {
    let windows: () -> [DesktopWindow]
    let controller: DesktopController
    let arrowEdge: Edge

    @State private var isPresented = false
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()
                guard hovering else {
                    hoverTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        if !Task.isCancelled { isPresented = false }
                    }
                    return
                }
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled, !windows().isEmpty else { return }
                    for window in windows() where window.snapshot == nil && controller.windowManager.visibleStack().first?.id == window.id {
                        controller.input.captureSnapshot(of: window)
                    }
                    isPresented = true
                }
            }
            .popover(isPresented: $isPresented, arrowEdge: arrowEdge) {
                WindowPreviewStrip(windows: windows(), controller: controller) { isPresented = false }
                    .presentationCompactAdaptation(.popover)
            }
    }
}

extension View {
    func windowPreview(for windows: @escaping () -> [DesktopWindow], controller: DesktopController,
                       arrowEdge: Edge = .bottom) -> some View {
        modifier(WindowPreviewOnHover(windows: windows, controller: controller, arrowEdge: arrowEdge))
    }
}
