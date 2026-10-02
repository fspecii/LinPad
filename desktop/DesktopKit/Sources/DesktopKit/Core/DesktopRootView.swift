import SwiftUI

/// The whole desktop: wallpaper edge to edge, the panel under the status bar,
/// and the window area filling the rest of the screen.
public struct DesktopRootView: View {
    @State private var controller: DesktopController
    @AppStorage(DesktopSettings.accentColorKey) private var accentID = DesktopSettings.defaultAccentColor
    @AppStorage(DesktopSettings.monospacedFontSizeKey) private var monospacedFontSize = DesktopSettings.defaultMonospacedFontSize
    @AppStorage(DesktopSettings.performanceOverlayKey) private var showsPerformanceOverlay = false
    @AppStorage(DesktopStyle.storageKey) private var styleID = DesktopStyle.defaultStyle.rawValue
    @AppStorage(DesktopSettings.dockAutoHideKey) private var dockAutoHides = false
    @AppStorage(DesktopSettings.taskbarCenteredKey) private var taskbarCentered = true
    @AppStorage(DesktopSettings.tilingKey) private var tilingJSON = ""
    @AppStorage(DesktopSettings.tilingGapKey) private var tilingGap = DesktopSettings.defaultTilingGap
    @State private var isDockRevealed = false
    /// The home indicator's strip. Bottom bars keep their controls above it so taps there
    /// are not taken for the home gesture.
    @State private var bottomInset: CGFloat = 0
    @AppStorage(DesktopAppearance.storageKey) private var appearanceID = DesktopAppearance.styleDefault.rawValue
    @AppStorage(DesktopSettings.windowMetricsKey) private var metricsID = ""
    @AppStorage(DesktopSettings.kylinMenuFullScreenKey) private var kylinMenuFullScreen = false
    @AppStorage(DesktopShortcutModifier.storageKey) private var shortcutModifier = DesktopShortcutModifier.controlOption
    @Environment(\.colorScheme) private var systemColorScheme

    public init(host: any LinuxHost, apps: [DesktopAppDescriptor]) {
        _controller = State(initialValue: DesktopController(host: host, apps: apps))
    }

    /// `systemControls` adds volume, session restart and reboot to quick settings and the power menu.
    public init(host: any LinuxHost, apps: [DesktopAppDescriptor], systemControls: any DesktopSystemControls) {
        _controller = State(initialValue: DesktopController(host: host, apps: apps, systemControls: systemControls))
    }

    public var body: some View {
        ZStack {
            WallpaperView(store: controller.wallpapers, source: controller.wallpaperSource(),
                          variant: controller.isOverviewPresented ? .blurred : .sharp)
                .ignoresSafeArea()
                .onChange(of: controller.visibleWallpaperIDs, initial: true) { _, ids in
                    controller.wallpapers.ensureDecoded(ids)
                }
                .onAppear {
                    controller.wallpapers.targetPixelSize = UIScreen.main.nativeBounds.size
                    controller.wallpapers.startSlideshowIfNeeded()
                }

            shell
                .overlay {
                    if controller.isOnboardingPresented {
                        ZStack {
                            Color.black.opacity(0.45).ignoresSafeArea()
                            OnboardingView(controller: controller)
                        }
                        .transition(.opacity)
                    }
                }
                .overlay {
                    if controller.isLocked {
                        LockScreen(controller: controller).transition(.opacity)
                    }
                }
                .overlay {
                    if !controller.boot.isFinished {
                        BootSplash(controller: controller).transition(.opacity)
                    }
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { bottomInset = proxy.safeAreaInsets.bottom }
                            .onChange(of: proxy.safeAreaInsets.bottom) { _, inset in bottomInset = inset }
                    }
                }
        }
        .onChange(of: styleID, initial: true) { _, id in
            let style = DesktopStyle.stored(id)
            controller.applyStyle(style, dark: (DesktopAppearance(rawValue: appearanceID) ?? .styleDefault)
                .isDark(style: style, system: systemColorScheme))
        }
        .onChange(of: tilingJSON, initial: true) { _, json in
            guard let states = TilingSettings.decode(json), states != controller.windowManager.tiling else { return }
            withAnimation(DesktopMotion.tile) { controller.windowManager.restoreTiling(states) }
        }
        .onChange(of: tilingGap, initial: true) { _, gap in
            withAnimation(DesktopMotion.tile) { controller.windowManager.tilingGap = CGFloat(gap) }
        }
        .onChange(of: controller.windowManager.currentWorkspace, initial: true) { _, workspace in
            controller.wallpapers.currentWorkspace = workspace
        }
        .onChange(of: controller.windowManager.focusedWindowID) { _, id in
            controller.keyboardFocusChanged(to: id)
            controller.windowFocusChanged(id)
            controller.keyCommands.syncOverlayCommands()
        }
        .onChange(of: shortcutModifier) { _, _ in
            controller.keyCommands.syncOverlayCommands()
        }
        .onChange(of: controller.isOverlayPresented) { _, presented in
            controller.keyCommands.syncOverlayCommands()
            if !presented { controller.keyboardFocusChanged(to: controller.windowManager.focusedWindowID) }
        }
        .onChange(of: controller.switcher.isPresented) { _, _ in
            controller.keyCommands.syncOverlayCommands()
        }
        .onChange(of: controller.desktopHasKeyboardFocus) { _, _ in
            controller.keyCommands.syncOverlayCommands()
        }
        .task {
            openStartupWindows()
            await controller.boot.run(host: controller.host, linux: controller.linux)
            controller.offerSystemUpdateIfAvailable()
            controller.offerFastModeRetryIfFailed()
            if !UserDefaults.standard.bool(forKey: OnboardingView.completedKey) {
                withAnimation(DesktopMotion.standard) { controller.isOnboardingPresented = true }
            }
        }
        .animation(DesktopMotion.standard, value: controller.boot.isFinished)
        .sheet(isPresented: Binding(get: { controller.isFastModeHelpPresented },
                                    set: { controller.isFastModeHelpPresented = $0 })) {
            FastModeHelpSheet()
        }
        .onChange(of: isDark, initial: true) { _, dark in
            controller.isDarkAppearance = dark
            controller.wallpapers.isDark = dark
            // Automatic leaves the window alone so the system's choice keeps coming through.
            let followsSystem = DesktopAppearance(rawValue: appearanceID) == .system
            controller.input.setInterfaceStyle(followsSystem ? .unspecified : (dark ? .dark : .light))
        }
        .onChange(of: appearanceID) { _, id in
            let followsSystem = DesktopAppearance(rawValue: id) == .system
            controller.input.setInterfaceStyle(followsSystem ? .unspecified : (isDark ? .dark : .light))
            controller.applyStyle(style, dark: isDark)
        }
        .onChange(of: metrics, initial: true) { _, value in
            withAnimation(DesktopMotion.standard) { controller.windowManager.setMetrics(value) }
        }
        .environment(\.desktopTheme, theme)
        .environment(\.desktopStyle, style)
        .environment(\.desktopIcons, controller.icons)
        .environment(\.desktopWallpapers, controller.wallpapers)
        .environment(\.colorScheme, isDark ? .dark : .light)
    }

    private var isDark: Bool {
        (DesktopAppearance(rawValue: appearanceID) ?? .styleDefault).isDark(style: style, system: systemColorScheme)
    }

    /// Touch metrics unless a hardware keyboard or pointer is attached, or the user chose.
    private var metrics: WindowMetrics {
        let touch = style.spec.touchMetrics
        switch metricsID {
        case "touch": return touch
        case "pointer": return .pointer
        default: return controller.keyboard.hasPointerOrKeyboard ? .pointer : touch
        }
    }

    private var style: DesktopStyle { controller.style }

    /// The style's panels around the desktop area. Every arrangement keeps the desktop area
    /// a single rectangle, so window management is the same in all of them.
    @ViewBuilder
    private var shell: some View {
        let spec = style.spec
        VStack(spacing: 0) {
            switch spec.shell {
            case .panel: PanelView(controller: controller).zIndex(1)
            case .menuBarAndDock: MenuBar(controller: controller).zIndex(1)
            case .topBarAndDock: TopBar(controller: controller).zIndex(1)
            case .taskbar, .kylinPanel: EmptyView()
            }
            HStack(spacing: 0) {
                if spec.dockEdge == .leading && !dockAutoHides {
                    Dock(controller: controller, axis: .vertical).zIndex(1)
                }
                desktopArea
                    .overlay(alignment: .leading) {
                        if spec.dockEdge == .leading && dockAutoHides { autoHidingDock }
                    }
                    .overlay(alignment: .bottom) {
                        if spec.dockEdge == .bottom && dockAutoHides { autoHidingBottomDock }
                    }
            }
            if spec.dockEdge == .bottom && !dockAutoHides {
                Dock(controller: controller, axis: .horizontal).zIndex(2)
                    .padding(.bottom, bottomInset)
            }
            if spec.shell == .taskbar {
                WindowsTaskbar(controller: controller).zIndex(1)
                    .padding(.bottom, bottomInset)
                    .background(alignment: .bottom) { bottomInsetFill }
            }
            if spec.shell == .kylinPanel {
                KylinPanel(controller: controller).zIndex(1)
                    .padding(.bottom, bottomInset)
                    .background(alignment: .bottom) { bottomInsetFill }
            }
        }
    }

    /// macOS auto-hide: the Dock rises when the pointer reaches the bottom edge.
    private var autoHidingBottomDock: some View {
        let isShown = isDockRevealed || controller.isOverviewPresented
        return ZStack(alignment: .bottom) {
            Color.clear
                .frame(height: 8)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onHover { if $0 { isDockRevealed = true } }
            Dock(controller: controller, axis: .horizontal)
                .onHover { isDockRevealed = $0 }
                .offset(y: isShown ? -bottomInset : DesktopStyleSpec.macos.dockThickness + 8)
                .animation(DesktopMotion.standard, value: isShown)
        }
    }

    private var bottomInsetFill: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            theme.panelBackground
        }
        .frame(height: bottomInset)
    }

    /// Ubuntu's auto-hide: a thin strip at the left edge reveals the Dock under the pointer,
    /// and it is always shown in the overview so touch users can reach it.
    private var autoHidingDock: some View {
        let isShown = isDockRevealed || controller.isOverviewPresented
        return ZStack(alignment: .leading) {
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
                .onHover { if $0 { isDockRevealed = true } }
            Dock(controller: controller, axis: .vertical)
                .onHover { isDockRevealed = $0 }
                .offset(x: isShown ? 0 : -DesktopStyleSpec.ubuntu.dockThickness - 4)
                .animation(DesktopMotion.standard, value: isShown)
        }
        .frame(maxHeight: .infinity)
    }

    /// The previous session's windows first, then autostart apps that are not open yet.
    private func openStartupWindows() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: DesktopSettings.resetSessionArgument) {
            controller.session.clear()
        }
        let restored = controller.session.restore()
        let ids = defaults.string(forKey: DesktopSettings.autostartKey) ?? ""
        for id in ids.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !restored.contains(id) {
            controller.open(appID: id, arguments: [:])
        }
    }

    private var theme: DesktopTheme {
        var theme = DesktopTheme.dark
        theme.accent = DesktopSettings.accentColor(for: accentID)
        theme.monospacedFontSize = CGFloat(monospacedFontSize)
        return style.spec.theme(base: theme, isDark: isDark)
    }

    private var desktopArea: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                DesktopInputAnchor(coordinator: controller.input)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                DesktopSurface(controller: controller)
                WindowLayer(controller: controller)
                if let linux = controller.linux {
                    LinuxPopupLayerHost(bridge: linux)
                }
            }
            .coordinateSpace(name: DesktopCoordinateSpace.name)
            .onAppear {
                controller.windowManager.desktopGlobalOrigin = proxy.frame(in: .global).origin
                controller.windowManager.updateDesktopSize(proxy.size)
            }
            .onChange(of: proxy.size) { _, size in
                controller.windowManager.desktopGlobalOrigin = proxy.frame(in: .global).origin
                controller.windowManager.updateDesktopSize(size)
            }
        }
        .clipped()
        .overlay(alignment: .topTrailing) {
            ToastStack(controller: controller)
        }
        .overlay(alignment: style.quickSettingsAlignment) {
            if controller.isQuickSettingsPresented {
                ZStack(alignment: style.quickSettingsAlignment) {
                    dismissalScrim { controller.toggleQuickSettings() }
                    QuickSettingsPanel(controller: controller).padding(10)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
            }
        }
        .overlay(alignment: style.notificationCenterAlignment) {
            if controller.isNotificationCenterPresented {
                ZStack(alignment: style.notificationCenterAlignment) {
                    dismissalScrim { controller.toggleNotificationCenter() }
                    NotificationCenterPanel(controller: controller, isColumn: style.notificationCenterIsColumn)
                        .padding(10)
                }
                .transition(style.notificationCenterIsColumn ? .move(edge: .trailing).combined(with: .opacity) : .opacity)
            }
        }
        .overlay {
            if controller.switcher.isPresented {
                WindowSwitcherView(controller: controller)
                    .padding(24)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showsPerformanceOverlay {
                PerformanceOverlay()
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .animation(DesktopMotion.quick, value: controller.switcher.isPresented)
        .overlay(alignment: launcherAlignment) {
            if controller.isLauncherPresented {
                launcher
            }
        }
        .overlay {
            if controller.isRunDialogPresented {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.isRunDialogPresented = false }
                    .transition(.opacity)
                RunDialog(controller: controller)
                    .offset(y: -60)
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: controller.isLauncherPresented)
        .animation(.snappy(duration: 0.2), value: controller.isRunDialogPresented)
        .ignoresSafeArea(edges: style.spec.shell == .taskbar || style.spec.shell == .kylinPanel
                         || style.spec.dockEdge == .bottom
                         ? [.horizontal] : [.bottom, .horizontal])
    }

    private var launcherAlignment: Alignment {
        switch style.spec.launcher {
        case .menu: .topLeading
        case .startMenu: taskbarCentered ? .bottom : .bottomLeading
        case .fullScreenGrid: .center
        case .kylinMenu: kylinMenuFullScreen ? .center : .bottomLeading
        }
    }

    @ViewBuilder
    private var launcher: some View {
        switch style.spec.launcher {
        case .menu:
            dismissalScrim { controller.isLauncherPresented = false }
            LauncherView(controller: controller)
                .padding(.leading, 8)
                .padding(.top, 6)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.96, anchor: .topLeading).combined(with: .opacity),
                    removal: .opacity))
        case .startMenu:
            dismissalScrim { controller.isLauncherPresented = false }
            StartMenu(controller: controller)
                .padding(12)
                .padding(.bottom, controller.windowManager.keyboardOverlap)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .fullScreenGrid:
            AppGridLauncher(controller: controller)
                .transition(.opacity.combined(with: .scale(scale: 1.04)))
        case .kylinMenu:
            if kylinMenuFullScreen {
                AppGridLauncher(controller: controller) { kylinMenuFullScreen = false }
                    .transition(.opacity)
            } else {
                dismissalScrim { controller.isLauncherPresented = false }
                KylinStartMenu(controller: controller)
                    .padding(8)
                    .padding(.bottom, controller.windowManager.keyboardOverlap)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func dismissalScrim(_ dismiss: @escaping () -> Void) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: dismiss)
            .accessibilityHidden(true)
    }
}

#Preview("Desktop") {
    let note = DesktopAppDescriptor(
        id: "note", name: "Note", symbol: "note.text", category: .accessories,
        defaultSize: CGSize(width: 420, height: 300), showsOnDesktop: true
    ) { context in
        AnyView(
            Text(context.arguments[AppArgument.path] ?? "An empty note")
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity))
    }
    let terminal = DesktopAppDescriptor(
        id: AppID.terminal, name: "Terminal", symbol: "terminal", category: .system,
        showsOnDesktop: true
    ) { context in
        AnyView(PreviewTerminal(host: context.host, command: context.arguments[AppArgument.command]))
    }
    let about = DesktopAppDescriptor(
        id: "about", name: "About This iPad", symbol: "info.circle", category: .settings,
        defaultSize: CGSize(width: 380, height: 240), allowsMultipleWindows: false
    ) { context in
        AnyView(
            Button("Say hello") { context.desktop.notify("Hello from \(context.host.hostName)") }
                .frame(maxWidth: .infinity, maxHeight: .infinity))
    }
    return DesktopRootView(host: MockLinuxHost(), apps: [terminal, note, about])
}

private struct PreviewTerminal: UIViewControllerRepresentable {
    let host: any LinuxHost
    let command: String?

    func makeUIViewController(context: Context) -> UIViewController {
        host.makeTerminalViewController(command: command, cwd: nil)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
