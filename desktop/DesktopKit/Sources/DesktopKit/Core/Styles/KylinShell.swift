import SwiftUI

// UKUI (openKylin) shell pieces, from themes/kylin/DESIGN-SPEC.md §2-3. Measurements follow
// the spec's "Small" panel (48) and window-mode start menu (766 x 688).

private enum KylinMetrics {
    static let tileRadius: CGFloat = 6
    static let hoverAlpha = 0.15
    static let pressAlpha = 0.20
}

/// A transparent panel tile that fills on hover and press (spec §2, "Common tile states").
private struct KylinTileStyle: ButtonStyle {
    let isActive: Bool
    @Environment(\.desktopTheme) private var theme
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: KylinMetrics.tileRadius, style: .continuous)
                .fill(theme.primaryText.opacity(fill(pressed: configuration.isPressed))))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    private func fill(pressed: Bool) -> Double {
        if pressed { return KylinMetrics.pressAlpha }
        if isHovered || isActive { return KylinMetrics.hoverAlpha }
        return 0
    }
}

/// ukui-panel "classic": start, search and task-view tiles, a separator, icon-only task
/// buttons grouped by app with running pills; tray, two-line clock and the show-desktop strip.
struct KylinPanel: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    private var manager: WindowManager { controller.windowManager }

    /// Pinned apps first, then other running apps, one tile per app.
    private var apps: [DesktopAppDescriptor] {
        let pinned = controller.pinnedApps
        var result = pinned
        for window in manager.windowsInCurrentWorkspace() where !result.contains(where: { $0.id == window.appID }) {
            result.append(controller.launcherApps.first { $0.id == window.appID }
                ?? DesktopAppDescriptor(id: window.appID, name: window.title, symbol: window.symbol,
                                        category: .linux) { _ in AnyView(EmptyView()) })
        }
        return result
    }

    var body: some View {
        HStack(spacing: 4) {
            tile(label: "Start", identifier: "desktop.panel.applications", isActive: controller.isLauncherPresented) {
                ThemeGlyph(ThemeIconNames.launcher, symbol: "circle.hexagongrid.fill", size: 22)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.accent)
            } action: { controller.toggleLauncher() }
            tile(label: "Search", identifier: "desktop.panel.search", isActive: false) {
                Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium))
            } action: { controller.toggleLauncher() }
            tile(label: "Task View", identifier: "desktop.panel.overview", isActive: controller.isOverviewPresented) {
                Image(systemName: "rectangle.on.rectangle").font(.system(size: 16, weight: .medium))
            } action: { controller.toggleOverview() }
            theme.separator.frame(width: 1, height: 24)
            ForEach(apps) { app in
                KylinTaskButton(app: app, controller: controller)
            }
            Spacer(minLength: 32)
            TilingButton(manager: manager)
            WorkspaceSwitcher(manager: manager)
            SystemMeters(monitor: controller.systemMonitor)
            SystemTrayButtons(controller: controller)
            KylinClock()
            Button {
                for window in manager.windowsInCurrentWorkspace() where !window.isMinimized {
                    manager.minimize(window.id)
                }
            } label: {
                Color.clear.frame(width: 17, height: 48).contentShape(Rectangle())
            }
            .buttonStyle(KylinTileStyle(isActive: false))
            .accessibilityLabel("Show Desktop")
        }
        .foregroundStyle(theme.primaryText)
        .padding(.leading, 8)
        .frame(height: 48)
        .background {
            ZStack {
                Rectangle().fill(theme.panelBlur ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.clear))
                theme.panelBackground
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private func tile<Icon: View>(label: String, identifier: String, isActive: Bool,
                                  @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon().frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(KylinTileStyle(isActive: isActive))
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

private struct KylinTaskButton: View {
    let app: DesktopAppDescriptor
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    private var manager: WindowManager { controller.windowManager }
    private var windows: [DesktopWindow] { manager.windowsInCurrentWorkspace().filter { $0.appID == app.id } }

    var body: some View {
        let windows = windows
        let ownsFocus = windows.contains { $0.id == manager.focusedWindowID && !$0.isMinimized }
        Button(action: activate) {
            AppIcon(iconName: controller.iconName(forAppID: app.id), url: controller.iconURL(forAppID: app.id), symbol: app.symbol, size: 32)
                .frame(width: 40, height: 40)
                .overlay(alignment: .bottom) {
                    if !windows.isEmpty {
                        Capsule()
                            .fill(ownsFocus ? theme.accent : theme.primaryText.opacity(0.3))
                            .frame(width: windows.count > 1 ? 16 : 8, height: 4)
                            .animation(.easeOut(duration: 0.2), value: windows.count)
                    }
                }
                .background(RoundedRectangle(cornerRadius: KylinMetrics.tileRadius, style: .continuous)
                    .fill(theme.primaryText.opacity(ownsFocus ? KylinMetrics.hoverAlpha : 0)))
                .contentShape(Rectangle())
        }
        // A plain style here: a custom ButtonStyle combined with .contextMenu swallowed taps.
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .contextMenu { AppContextMenu(appID: app.id, controller: controller) } preview: {
            if windows.isEmpty {
                AppIcon(iconName: controller.iconName(forAppID: app.id), url: controller.iconURL(forAppID: app.id), symbol: app.symbol, size: 96).padding(20)
            } else {
                WindowPreviewStrip(windows: windows, controller: controller)
            }
        }
        .windowPreview(for: { windows }, controller: controller, arrowEdge: .bottom)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            for window in windows { manager.taskbarTargets[window.id] = frame }
        }
        .help(app.name)
        .accessibilityLabel(windows.count == 1 ? windows[0].title : app.name)
        .accessibilityValue(windows.isEmpty ? "" : ownsFocus ? "Active" : "Running")
        .accessibilityIdentifier(windows.isEmpty ? "desktop.dock.item" : "desktop.taskbar.item")
    }

    /// No window launches; the active window minimizes; several windows take turns (spec §10).
    private func activate() {
        let windows = windows
        guard !windows.isEmpty else {
            controller.open(appID: app.id, arguments: [:])
            return
        }
        if let index = windows.firstIndex(where: { $0.id == manager.focusedWindowID && !$0.isMinimized }) {
            if windows.count == 1 {
                manager.minimize(windows[0].id)
            } else {
                manager.focus(windows[(index + 1) % windows.count].id)
            }
        } else {
            manager.focus(manager.recentWindowsInCurrentWorkspace().first { $0.appID == app.id }?.id ?? windows[0].id)
        }
    }
}

/// `HH:mm Weekday` over `yyyy/MM/dd`.
private struct KylinClock: View {
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopController) private var controller
    @State private var isShowingCalendar = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            Button { isShowingCalendar.toggle() } label: {
                VStack(spacing: 1) {
                    Text(context.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().weekday(.abbreviated)))
                    Text(context.date.formatted(.iso8601.year().month().day().dateSeparator(.dash)))
                        .foregroundStyle(theme.secondaryText)
                }
                .font(.system(size: 11, weight: .regular).monospacedDigit())
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .calendarPopover(isPresented: $isShowingCalendar, controller: controller)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(context.date.formatted(date: .complete, time: .shortened))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("desktop.panel.clock")
        }
    }
}

/// ukui-menu in window mode: the app list with search (312), favorites (the rest) and a
/// 56 pt sidebar with User, Files, Settings and Power.
struct KylinStartMenu: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme
    @State private var query = ""
    @State private var highlighted = 0
    @State private var showsRecent = false
    @FocusState private var isSearchFocused: Bool

    private var results: [DesktopAppDescriptor] {
        LauncherSearch.results(in: controller.launcherApps, query: query)
    }

    private var favorites: [DesktopAppDescriptor] {
        if showsRecent {
            let recent = controller.windowManager.recentWindowsInCurrentWorkspace().map(\.appID)
            return recent.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .compactMap { id in controller.launcherApps.first { $0.id == id } }
        }
        return controller.launcherApps.filter { $0.category != .linux || $0.showsOnDesktop }
    }

    var body: some View {
        HStack(spacing: 0) {
            appList.frame(width: 312)
            theme.separator.frame(width: 1)
            favoritesPane.frame(maxWidth: .infinity)
            theme.separator.frame(width: 1)
            sidebar.frame(width: 56)
        }
        // Shorter while the on-screen keyboard is up, so the list stays reachable above it.
        .frame(width: 766, height: min(688, max(300, controller.windowManager.desktopSize.height - 16
                                                     - controller.windowManager.keyboardOverlap)))
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.panelBlur ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.clear))
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.panelBackground)
        }
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.separator, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 4)
        .onAppear { if HardwareKeyboardMonitor.isAttached { Task { isSearchFocused = true } } }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop.launcher")
    }

    private var appList: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.secondaryText)
                TextField("Search App", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isSearchFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(launchHighlighted)
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(results.count - 1, 0)); return .handled }
                    .accessibilityIdentifier("desktop.launcher.search")
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.primaryText.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSearchFocused ? theme.accent : theme.separator, lineWidth: 1))
            .padding(.top, 12)
            .padding(.horizontal, 16)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, app in
                        Button { launch(app) } label: {
                            HStack(spacing: 10) {
                                AppIcon(iconName: controller.iconName(forAppID: app.id), url: controller.iconURL(forAppID: app.id), symbol: app.symbol, size: 32)
                                Text(app.name).font(.system(size: 14))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(index == highlighted ? theme.primaryText.opacity(0.08) : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityLabel(app.name)
                        .accessibilityAddTraits(index == highlighted ? .isSelected : [])
                        .accessibilityIdentifier("desktop.launcher.app.\(app.id)")
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .foregroundStyle(theme.primaryText)
    }

    private var favoritesPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                tab("Favorites", selected: !showsRecent) { showsRecent = false }
                tab("Recent", selected: showsRecent) { showsRecent = true }
            }
            .frame(height: 32)
            .padding(.top, 14)
            .padding(.horizontal, 16)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(88), spacing: 4), count: 4), spacing: 4) {
                    ForEach(favorites) { app in
                        Button { launch(app) } label: {
                            VStack(spacing: 6) {
                                AppIcon(iconName: controller.iconName(forAppID: app.id), url: controller.iconURL(forAppID: app.id), symbol: app.symbol, size: 48)
                                Text(app.name).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center)
                            }
                            .frame(width: 88, height: 100)
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(KylinTileStyle(isActive: false))
                        .accessibilityLabel(app.name)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .foregroundStyle(theme.primaryText)
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.primaryText : theme.secondaryText)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var sidebar: some View {
        VStack(spacing: 4) {
            Button {
                UserDefaults.standard.set(true, forKey: DesktopSettings.kylinMenuFullScreenKey)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 14))
                    .frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(KylinTileStyle(isActive: false))
            .padding(.top, 12)
            .accessibilityLabel("Full Screen")
            .accessibilityIdentifier("desktop.launcher.fullScreen")
            Spacer()
            sideButton("person.crop.circle", "User") { controller.open(appID: AppID.settings, arguments: [:]) }
            sideButton("desktopcomputer", "Computer") { controller.open(appID: AppID.files, arguments: [:]) }
            sideButton("gearshape", "Settings") { controller.open(appID: AppID.settings, arguments: [:]) }
            PowerButton(controller: controller, size: 36)
        }
        .padding(.bottom, 12)
        .foregroundStyle(theme.primaryText)
    }

    private func sideButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button {
            controller.isLauncherPresented = false
            action()
        } label: {
            Image(systemName: symbol).font(.system(size: 16)).frame(width: 36, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(KylinTileStyle(isActive: false))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(label == "Settings" ? "desktop.launcher.settings" : "desktop.launcher.\(symbol)")
    }

    private func launchHighlighted() {
        if results.indices.contains(highlighted) { launch(results[highlighted]) }
    }

    private func launch(_ app: DesktopAppDescriptor) {
        controller.isLauncherPresented = false
        controller.open(appID: app.id, arguments: [:])
    }
}
