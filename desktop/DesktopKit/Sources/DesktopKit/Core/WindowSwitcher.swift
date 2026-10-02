import SwiftUI
import Observation

@Observable @MainActor
final class WindowSwitcherModel {
    private(set) var windowIDs: [UUID] = []
    private(set) var selection = 0
    private(set) var isPresented = false
    /// False when modifier releases cannot be observed; Return or a click commits instead.
    private(set) var commitsOnModifierRelease = true

    var selectedWindowID: UUID? {
        windowIDs.indices.contains(selection) ? windowIDs[selection] : nil
    }

    func present(_ ids: [UUID], startingAt index: Int, commitsOnModifierRelease: Bool) {
        windowIDs = ids
        selection = min(max(index, 0), max(ids.count - 1, 0))
        self.commitsOnModifierRelease = commitsOnModifierRelease
        isPresented = true
    }

    func move(by step: Int) {
        guard !windowIDs.isEmpty else { return }
        selection = ((selection + step) % windowIDs.count + windowIDs.count) % windowIDs.count
    }

    func select(_ id: UUID) {
        if let index = windowIDs.firstIndex(of: id) { selection = index }
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        windowIDs = []
    }
}

/// Option-Tab: the current workspace's windows, most recent first, as thumbnails.
struct WindowSwitcherView: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopStyle) private var style

    private static let cardWidth: CGFloat = 200
    private static let thumbnailHeight: CGFloat = 128

    private var manager: WindowManager { controller.windowManager }
    private var switcher: WindowSwitcherModel { controller.switcher }

    var body: some View {
        let windows = switcher.windowIDs.compactMap(manager.window(withID:))
        VStack(spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(windows) { window in
                            card(for: window, isSelected: window.id == switcher.selectedWindowID)
                                .id(window.id)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: switcher.selection) { _, _ in
                    if let id = switcher.selectedWindowID { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .frame(maxWidth: min(CGFloat(windows.count) * (Self.cardWidth + 10) + 18, 1000))
            if !switcher.commitsOnModifierRelease {
                Text("Return to switch · Esc to cancel")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.bottom, 10)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background {
            RoundedRectangle(cornerRadius: theme.cornerRadius + 6, style: .continuous)
                .fill(theme.panelBackground.opacity(1))
        }
        .overlay {
            RoundedRectangle(cornerRadius: theme.cornerRadius + 6, style: .continuous)
                .strokeBorder(theme.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop.switcher")
        .accessibilityLabel("Window switcher")
    }

    private func card(for window: DesktopWindow, isSelected: Bool) -> some View {
        Button {
            controller.commitSwitcher(to: window.id)
        } label: {
            VStack(spacing: 8) {
                WindowThumbnail(window: window, controller: controller)
                    .frame(width: Self.cardWidth - 16, height: Self.thumbnailHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.separator, lineWidth: 1)
                    }
                    .opacity(window.isMinimized ? 0.55 : 1)
                HStack(spacing: 6) {
                    AppGlyph(iconName: controller.iconName(forAppID: window.appID), url: controller.iconURL(forAppID: window.appID), symbol: window.symbol,
                             size: 12, tint: isSelected ? theme.accent : theme.secondaryText)
                    Text(window.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(8)
            .frame(width: Self.cardWidth)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? theme.accent.opacity(0.22) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    // UKUI outlines the selection in the primary text color instead of the accent.
                    .strokeBorder(isSelected ? (style == .kylin ? theme.primaryText : theme.accent) : Color.clear,
                                  lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .onHover { if $0 { switcher.select(window.id) } }
        .accessibilityIdentifier("desktop.switcher.item")
        .accessibilityLabel(window.title)
        .accessibilityValue(window.isMinimized ? "Minimized" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The best picture available of a window: a Linux app's latest frame, the last snapshot
/// taken while the window was on top, or its icon.
struct WindowThumbnail: View {
    let window: DesktopWindow
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        ZStack {
            theme.windowBackground
            if let image = controller.thumbnailImage(for: window) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: window.symbol)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }
}

extension DesktopController {
    func thumbnailImage(for window: DesktopWindow) -> UIImage? {
        if let surfaceID = linuxWindows.first(where: { $0.value == window.id })?.key,
           let frame = linux?.surface(withID: surfaceID)?.image {
            return UIImage(cgImage: frame)
        }
        return window.snapshot
    }
}
