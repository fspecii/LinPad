import SwiftUI
import UniformTypeIdentifiers

/// Exposé: the current workspace's windows shrink into a grid (live, by transform only),
/// with a strip of all workspaces on top that windows can be dragged onto.
@MainActor
struct OverviewLayout {
    static let stripTop: CGFloat = 16
    /// Room for Ubuntu's Activities search field above the workspace strip.
    static let searchHeight: CGFloat = 54
    static let workspaceSize = CGSize(width: 150, height: 92)
    static let workspaceSpacing: CGFloat = 14

    let frames: [UUID: CGRect]
    let workspaceFrames: [CGRect]
    /// The "+" card after the last workspace; nil at the maximum.
    let addFrame: CGRect?

    init(controller: DesktopController) {
        let manager = controller.windowManager
        let bounds = manager.desktopSize
        let spec = controller.style.spec
        let count = manager.workspaceCount
        let slots = Self.workspaceFrames(in: bounds, count: count + (count < WindowManager.maximumWorkspaces ? 1 : 0),
                                         searches: spec.overviewSearches, atBottom: spec.overviewStripAtBottom)
        workspaceFrames = Array(slots.prefix(count))
        addFrame = slots.count > count ? slots[count] : nil
        let area: CGRect
        if spec.overviewStripAtBottom {
            let stripTop = (workspaceFrames.first?.minY ?? bounds.height) - 28
            area = CGRect(x: 40, y: 32, width: bounds.width - 80, height: max(stripTop - 32, 1))
        } else {
            let stripBottom = (workspaceFrames.first?.maxY ?? 0) + 28
            area = CGRect(x: 40, y: stripBottom, width: bounds.width - 80,
                          height: max(bounds.height - stripBottom - 40, 1))
        }
        let windows = manager.windows
            .filter(manager.isVisible)
            .sorted { $0.zIndex < $1.zIndex }
        let grid = WindowGeometry.overviewLayout(for: windows.map { manager.displayFrame(for: $0) }, in: area)
        frames = Dictionary(uniqueKeysWithValues: zip(windows.map(\.id), grid))
    }

    /// UKUI's task view puts the strip along the bottom.
    /// `count` cards centred in a row, shrunk to fit the width when there are many.
    static func workspaceFrames(in bounds: CGSize, count: Int, searches: Bool = false, atBottom: Bool = false) -> [CGRect] {
        let n = CGFloat(max(count, 1))
        let fitting = (bounds.width - 80 - workspaceSpacing * (n - 1)) / n
        let width = max(min(workspaceSize.width, fitting.rounded(.down)), 60)
        let size = CGSize(width: width, height: (width * workspaceSize.height / workspaceSize.width).rounded())
        let total = size.width * n + workspaceSpacing * (n - 1)
        let startX = ((bounds.width - total) / 2).rounded()
        return (0..<count).map { index in
            CGRect(x: startX + CGFloat(index) * (size.width + workspaceSpacing),
                   y: atBottom ? bounds.height - size.height - 40 : stripTop + (searches ? searchHeight : 0),
                   width: size.width, height: size.height)
        }
    }
}

extension DesktopController {
    /// The workspace whose overview thumbnail is under `point` (desktop coordinates).
    func overviewWorkspace(at point: CGPoint) -> Int? {
        OverviewLayout(controller: self).workspaceFrames
            .firstIndex { $0.insetBy(dx: -8, dy: -8).contains(point) }
    }
}

/// The dimmed desktop behind the overview grid, the workspace strip, and the empty-space
/// tap that closes the overview.
struct OverviewBackdrop: View {
    let controller: DesktopController
    let layout: OverviewLayout
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopStyle) private var style
    @State private var query = ""
    @State private var reorderHover: Int?

    private var manager: WindowManager { controller.windowManager }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if style == .ish || style == .windows || style == .kylin {
                    Color.black.opacity(0.45)
                } else {
                    Rectangle().fill(.ultraThinMaterial).overlay(Color.black.opacity(0.3))
                }
            }
                .contentShape(Rectangle())
                .onTapGesture { controller.setOverviewPresented(false) }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Close overview")
                .accessibilityIdentifier("desktop.overview")
            if style.spec.overviewSearches {
                activitiesSearch
            }
            ForEach(Array(layout.workspaceFrames.enumerated()), id: \.offset) { index, frame in
                WorkspaceThumbnail(controller: controller, index: index,
                                   isDropTarget: controller.overviewDropHover == index || reorderHover == index)
                    .frame(width: frame.width, height: frame.height)
                    .onDrag { WorkspaceDrag.provider(for: index) }
                    .onDrop(of: [.plainText], delegate: WorkspaceReorderDropDelegate(manager: manager, index: index,
                                                                                     hovered: $reorderHover))
                    .workspaceMenu(manager: manager, index: index)
                    .offset(x: frame.minX, y: frame.minY)
            }
            if let frame = layout.addFrame {
                Button { addAndSwitch(manager) } label: {
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .overlay { Image(systemName: "plus").font(.system(size: 22, weight: .medium)) }
                        Text(style == .kylin ? "New Desktop" : "New Workspace")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.white.opacity(0.8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.lift)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .accessibilityLabel(style == .kylin ? "New Desktop" : "New Workspace")
                .accessibilityIdentifier("desktop.overview.addWorkspace")
            }
            if manager.windowsInCurrentWorkspace().allSatisfy(\.isMinimized) {
                VStack(spacing: 6) {
                    Text("No open windows on this workspace")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.9))
                    Text("Open an app from the launcher, or drag a window here from another workspace.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// GNOME's Activities search: typing hands over to the application grid with the query.
    private var activitiesSearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
            TextField("Type to search", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("desktop.overview.search")
        }
        .font(.system(size: 15))
        .foregroundStyle(theme.primaryText)
        .padding(.horizontal, 14)
        .frame(width: 320, height: 38)
        .background(theme.primaryText.opacity(0.12), in: Capsule())
        .frame(maxWidth: .infinity)
        .padding(.top, OverviewLayout.stripTop)
        .onChange(of: query) { _, text in
            guard !text.isEmpty else { return }
            controller.launcherInitialQuery = text
            query = ""
            controller.setOverviewPresented(false)
            controller.toggleLauncher()
        }
    }
}

private struct WorkspaceThumbnail: View {
    let controller: DesktopController
    let index: Int
    let isDropTarget: Bool
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopStyle) private var style

    private var manager: WindowManager { controller.windowManager }

    var body: some View {
        let isCurrent = manager.currentWorkspace == index
        Button {
            withAnimation(DesktopMotion.standard) { manager.switchToWorkspace(index) }
        } label: {
            VStack(spacing: 5) {
                GeometryReader { proxy in
                    miniDesktop(in: proxy.size)
                }
                .background(WallpaperView(store: controller.wallpapers, source: controller.wallpaperSource(workspace: index),
                                          accessibilityID: "desktop.overview.wallpaper").opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isDropTarget || isCurrent ? theme.accent : theme.separator,
                                      lineWidth: isDropTarget ? 3 : (isCurrent ? 2 : 1))
                }
                Text(manager.workspaceNames[index].isEmpty
                     ? (style == .kylin ? "Desktop \(index + 1)" : "Workspace \(index + 1)")
                     : manager.workspaceNames[index])
                    .lineLimit(1)
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .medium))
                    // The overview's backdrop is dark in every appearance.
                    .foregroundStyle(Color.white.opacity(isCurrent ? 1 : 0.7))
            }
            .scaleEffect(isDropTarget ? 1.06 : 1)
            .animation(DesktopMotion.quick, value: isDropTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityLabel(manager.title(ofWorkspace: index))
        .accessibilityValue("\(manager.windows(inWorkspace: index).count) windows")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("desktop.overview.workspace.\(index + 1)")
    }

    /// Each window as a rectangle at its real position, scaled to the thumbnail.
    private func miniDesktop(in size: CGSize) -> some View {
        let desktop = manager.desktopSize
        let scale = desktop.width > 0 ? min(size.width / desktop.width, size.height / desktop.height) : 0
        let windows = manager.windows(inWorkspace: index).filter { !$0.isMinimized }.sorted { $0.zIndex < $1.zIndex }
        return ZStack(alignment: .topLeading) {
            ForEach(windows) { window in
                let frame = manager.displayFrame(for: window)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(theme.titleBarActive)
                    .overlay {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(theme.separator, lineWidth: 0.5)
                    }
                    .overlay {
                        Image(systemName: window.symbol)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .frame(width: max(frame.width * scale, 4), height: max(frame.height * scale, 3))
                    .offset(x: frame.minX * scale, y: frame.minY * scale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
