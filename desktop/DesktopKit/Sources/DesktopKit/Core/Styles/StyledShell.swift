import SwiftUI

// The panels each style puts around the desktop area. They share the window manager and the
// panel components (workspaces, meters, clock); only arrangement and look differ.

// MARK: - macOS menu bar

struct MenuBar: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    private var manager: WindowManager { controller.windowManager }

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                Button("About This Desktop", systemImage: "info.circle") {
                    controller.open(appID: AppID.settings, arguments: [:])
                }
                Divider()
                Button("Run Command…", systemImage: "terminal") { controller.presentRunDialog() }
                Button("Overview", systemImage: "rectangle.3.group") { controller.toggleOverview() }
                Button("Settings…", systemImage: "gearshape") {
                    controller.open(appID: AppID.settings, arguments: [:])
                }
                Divider()
                PowerMenuItems(controller: controller)
            } label: {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("System menu")

            Text(focusedAppName)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
            if let window = manager.focusedWindow {
                Menu("Window") {
                    WindowMenu(window: window, controller: controller).swiftUIItems
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .hoverEffect(.highlight)
            }
            Menu("Go") {
                ForEach(0..<manager.workspaceCount, id: \.self) { index in
                    Button(manager.title(ofWorkspace: index)) {
                        withAnimation(DesktopMotion.standard) { manager.switchToWorkspace(index) }
                    }
                }
                Divider()
                Button("New Workspace", systemImage: "plus") { addAndSwitch(manager) }
                    .disabled(manager.workspaceCount >= WindowManager.maximumWorkspaces)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .hoverEffect(.highlight)

            Spacer(minLength: 12)
            OverviewButton(isActive: controller.isOverviewPresented) { controller.toggleOverview() }
            TilingButton(manager: manager)
            WorkspaceSwitcher(manager: manager)
            SystemMeters(monitor: controller.systemMonitor)
            SystemTrayButtons(controller: controller)
            PanelClock()
        }
        .foregroundStyle(theme.primaryText)
        .padding(.horizontal, 12)
        .frame(height: DesktopStyleSpec.macos.topBarHeight)
        .background {
            ZStack {
                Rectangle().fill(theme.panelBlur ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.clear))
                theme.panelBackground
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    private var focusedAppName: String {
        guard let window = manager.focusedWindow else { return "Desktop" }
        return controller.launcherApps.first { $0.id == window.appID }?.name ?? window.title
    }
}

// MARK: - Ubuntu top bar

struct TopBar: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                Button {
                    controller.toggleOverview()
                } label: {
                    Text("Activities")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(Capsule().fill(controller.isOverviewPresented
                                                   ? theme.primaryText.opacity(0.2) : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityIdentifier("desktop.panel.overview")
                Spacer()
                TilingButton(manager: controller.windowManager)
                WorkspaceSwitcher(manager: controller.windowManager)
                SystemMeters(monitor: controller.systemMonitor)
                SystemTrayButtons(controller: controller)
                PowerButton(controller: controller, size: 26)
            }
            PanelClock()
        }
        .foregroundStyle(theme.primaryText)
        .padding(.horizontal, 8)
        .frame(height: DesktopStyleSpec.ubuntu.topBarHeight)
        .background(theme.panelBackground.ignoresSafeArea(edges: .top))
    }
}

// MARK: - Windows taskbar

struct WindowsTaskbar: View {
    let controller: DesktopController
    @AppStorage(DesktopSettings.taskbarCenteredKey) private var isCentered = true
    @Environment(\.desktopTheme) private var theme

    private var manager: WindowManager { controller.windowManager }

    var body: some View {
        ZStack {
            HStack(spacing: 4) {
                if !isCentered { launchers }
                Spacer(minLength: 0)
                TilingButton(manager: manager)
                WorkspaceSwitcher(manager: manager)
                SystemMeters(monitor: controller.systemMonitor)
                SystemTrayButtons(controller: controller)
                PanelClock()
            }
            if isCentered { launchers }
        }
        .padding(.horizontal, 10)
        .frame(height: DesktopStyleSpec.windows.bottomBarHeight)
        .background {
            ZStack {
                Rectangle().fill(theme.panelBlur ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.clear))
                theme.panelBackground
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) { theme.separator.frame(height: 1) }
    }

    private var launchers: some View {
        HStack(spacing: 4) {
            TaskbarIconButton(isActive: controller.isLauncherPresented, label: "Start",
                              identifier: "desktop.panel.applications") {
                ThemeGlyph(ThemeIconNames.launcher, symbol: "square.grid.2x2.fill", size: 19)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(theme.accent)
            } action: {
                controller.toggleLauncher()
            }
            TaskbarIconButton(isActive: controller.isOverviewPresented, label: "Task View",
                              identifier: "desktop.panel.overview") {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
            } action: {
                controller.toggleOverview()
            }
            ForEach(manager.windowsInCurrentWorkspace()) { window in
                WindowsTaskbarButton(window: window, controller: controller)
            }
        }
    }
}

private struct TaskbarIconButton<Icon: View>: View {
    let isActive: Bool
    let label: String
    let identifier: String
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        Button(action: action) {
            icon()
                .frame(width: 44, height: 40)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? theme.primaryText.opacity(0.12) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

private struct WindowsTaskbarButton: View {
    let window: DesktopWindow
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    private var manager: WindowManager { controller.windowManager }
    private var isFocused: Bool { manager.focusedWindowID == window.id && !window.isMinimized }

    var body: some View {
        Button {
            manager.activateFromTaskbar(window.id)
        } label: {
            AppIcon(iconName: controller.iconName(forAppID: window.appID), url: controller.iconURL(forAppID: window.appID), symbol: window.symbol, size: 26)
                .frame(width: 44, height: 40)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isFocused ? theme.primaryText.opacity(0.12) : Color.clear))
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(isFocused ? theme.accent : theme.secondaryText)
                        .frame(width: isFocused ? 16 : 6, height: 3)
                        .padding(.bottom, 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .contextMenu {
            WindowMenu(window: window, controller: controller).swiftUIItems
            Divider()
            AppContextMenu(appID: window.appID, controller: controller)
        }
        .windowPreview(for: { [window] }, controller: controller, arrowEdge: .bottom)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            manager.taskbarTargets[window.id] = frame
        }
        .accessibilityLabel(window.title)
        .accessibilityValue(window.isMinimized ? "Minimized" : isFocused ? "Active" : "")
        .accessibilityIdentifier("desktop.taskbar.item")
    }
}

// MARK: - Dock

/// macOS's bottom Dock (magnifies under the pointer) and Ubuntu's left Dock. Pinned apps
/// first, then running apps that are not pinned; a dot marks running apps.
struct Dock: View {
    enum Axis {
        case horizontal
        case vertical
    }

    let controller: DesktopController
    let axis: Axis
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(DesktopSettings.dockMagnificationKey) private var magnifies = true
    @State private var pointer: CGFloat?

    private static let iconSize: CGFloat = 46
    private static let spacing: CGFloat = 8
    private static let magnification: CGFloat = 0.55
    private static let magnificationReach: CGFloat = 110

    private var manager: WindowManager { controller.windowManager }

    private var items: [DesktopAppDescriptor] {
        let pinned = controller.pinnedApps
        let pinnedIDs = Set(pinned.map(\.id))
        var running: [DesktopAppDescriptor] = []
        for window in manager.windows where !pinnedIDs.contains(window.appID)
            && !running.contains(where: { $0.id == window.appID }) {
            running.append(controller.launcherApps.first { $0.id == window.appID }
                ?? DesktopAppDescriptor(id: window.appID, name: window.title, symbol: window.symbol,
                                        category: .linux) { _ in AnyView(EmptyView()) })
        }
        return pinned + running
    }

    var body: some View {
        let stack = Group {
            if style == .macos { applicationsButton }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, app in
                DockItem(app: app, controller: controller, size: Self.iconSize,
                         scale: scale(for: index + (style == .macos ? 1 : 0)), axis: axis)
            }
            if style == .ubuntu {
                Spacer(minLength: 8)
                applicationsButton
            }
        }
        Group {
            if axis == .horizontal {
                HStack(alignment: .bottom, spacing: Self.spacing) { stack }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.panelBlur ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.clear))
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.panelBackground.opacity(0.5))
                        RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        guard !reduceMotion, magnifies else { return }
                        switch phase {
                        case .active(let location): pointer = location.x
                        case .ended: pointer = nil
                        }
                    }
                    .animation(.easeOut(duration: 0.12), value: pointer)
                    .frame(maxWidth: .infinity)
                    .frame(height: DesktopStyleSpec.macos.dockThickness, alignment: .bottom)
                    .padding(.bottom, 4)
            } else {
                VStack(spacing: Self.spacing) { stack }
                    .padding(.vertical, 10)
                    .frame(width: DesktopStyleSpec.ubuntu.dockThickness)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color.black.opacity(0.78))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dock")
        .accessibilityIdentifier("desktop.dock")
    }

    /// Icons near the pointer grow with a cosine falloff, like the macOS Dock.
    private func scale(for index: Int) -> CGFloat {
        guard axis == .horizontal, let pointer else { return 1 }
        let center = 10 + CGFloat(index) * (Self.iconSize + Self.spacing) + Self.iconSize / 2
        let distance = abs(pointer - center)
        guard distance < Self.magnificationReach else { return 1 }
        return 1 + Self.magnification * cos(distance / Self.magnificationReach * .pi / 2)
    }

    private var applicationsButton: some View {
        Button {
            controller.toggleLauncher()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Self.iconSize * 0.24, style: .continuous)
                    .fill(style == .ubuntu ? Color.white.opacity(0.08) : Color(white: 0.25))
                ThemeGlyph(ThemeIconNames.launcher, symbol: style == .ubuntu ? "circle.grid.3x3.fill" : "square.grid.3x3.fill",
                           size: Self.iconSize * 0.42)
                    .font(.system(size: Self.iconSize * 0.42, weight: .semibold))
                    .foregroundStyle(style == .ubuntu ? Color.white : theme.accent)
            }
            .frame(width: Self.iconSize, height: Self.iconSize)
            .scaleEffect(scale(for: 0), anchor: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityLabel(style == .ubuntu ? "Show Applications" : "Launchpad")
        .accessibilityIdentifier("desktop.panel.applications")
    }
}

private struct DockItem: View {
    let app: DesktopAppDescriptor
    let controller: DesktopController
    let size: CGFloat
    let scale: CGFloat
    let axis: Dock.Axis
    @Environment(\.desktopTheme) private var theme

    private var manager: WindowManager { controller.windowManager }
    private var windows: [DesktopWindow] { manager.windows.filter { $0.appID == app.id } }

    var body: some View {
        let isRunning = !windows.isEmpty
        Button(action: activate) {
            AppIcon(iconName: controller.iconName(forAppID: app.id), url: controller.iconURL(forAppID: app.id), symbol: app.symbol, size: size)
                .scaleEffect(scale, anchor: axis == .horizontal ? .bottom : .center)
                .frame(width: size, height: size)
                .overlay(alignment: axis == .horizontal ? .bottom : .leading) {
                    if isRunning {
                        Circle().fill(axis == .horizontal ? theme.primaryText : theme.accent)
                            .frame(width: 5, height: 5)
                            .offset(x: axis == .vertical ? -7 : 0, y: axis == .horizontal ? 7 : 0)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .zIndex(scale)
        // A long press shows the windows' thumbnails above the menu, the touch counterpart of hover.
        .contextMenu { menu } preview: { touchPreview }
        .windowPreview(for: { windows }, controller: controller, arrowEdge: axis == .horizontal ? .bottom : .leading)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            for window in windows { manager.taskbarTargets[window.id] = frame }
        }
        .help(app.name)
        .accessibilityLabel(app.name)
        .accessibilityValue(isRunning ? "Running" : "")
        .accessibilityIdentifier(isRunning ? "desktop.taskbar.item" : "desktop.dock.item")
    }

    /// Opens the app, or brings its most recent window forward; clicking the app that is
    /// already in front cycles through its windows.
    private func activate() {
        let recent = manager.recentWindowsInCurrentWorkspace().filter { $0.appID == app.id }
        let candidates = recent.isEmpty ? windows : recent
        guard let first = candidates.first else {
            controller.open(appID: app.id, arguments: [:])
            return
        }
        if first.id == manager.focusedWindowID, !first.isMinimized, candidates.count > 1 {
            manager.focus(candidates[candidates.count - 1].id)
        } else {
            manager.focus(first.id)
        }
    }

    private var menu: some View {
        AppContextMenu(appID: app.id, controller: controller)
    }

    @ViewBuilder
    private var touchPreview: some View {
        if windows.isEmpty {
            AppIcon(iconName: controller.iconName(forAppID: app.id), url: controller.iconURL(forAppID: app.id), symbol: app.symbol, size: 96).padding(20)
        } else {
            WindowPreviewStrip(windows: windows, controller: controller)
        }
    }
}
