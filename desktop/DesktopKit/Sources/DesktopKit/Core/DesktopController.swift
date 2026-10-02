import SwiftUI
import Observation

struct DesktopToast: Identifiable, Equatable {
    struct Action {
        let title: String
        let perform: @MainActor () -> Void
    }

    let id = UUID()
    let message: String
    var action: Action?
    var showsProgress = false

    static func == (lhs: DesktopToast, rhs: DesktopToast) -> Bool { lhs.id == rhs.id }
}

/// Owns the shell's state and is what apps talk to through `DesktopActions`.
@Observable @MainActor
final class DesktopController {
    private static let toastLifetime: Duration = .seconds(4)
    private static let maximumVisibleToasts = 4

    let host: any LinuxHost
    let apps: [DesktopAppDescriptor]
    let windowManager = WindowManager()
    let systemMonitor = PanelSystemMonitor()

    private(set) var toasts: [DesktopToast] = []
    var isLauncherPresented = false
    var isRunDialogPresented = false
    let wallpapers = WallpaperStore()
    let colorThemes = ColorThemeStore()
    /// Themes app › Advanced styling.
    var styling = DesktopStyling.load()
    /// Themes app › Appearance (light/dark pair and when each applies).
    var themeAppearance = ThemeAppearance.load()
    /// iPadOS's own light/dark, for the Automatic mode.
    var systemIsDark = true
    @ObservationIgnored var scheduleTask: Task<Void, Never>?
    @ObservationIgnored var linuxFontsTask: Task<Void, Never>?
    /// The colour theme picker (⌃⌥⇧Space), while open.
    var themePicker: ColorThemePicker?
    /// The Command Menu (⌘K), while open.
    var commandMenu: CommandMenuState?
    /// The keyboard shortcut cheatsheet (⌘/), while open.
    var isShortcutSheetPresented = false
    /// The volume / brightness / layout pill, while shown.
    var osd: OSDState?
    /// The screenshot area picker (⌃⌥⇧S), while open.
    var isRegionCapturePresented = false
    var isRecordingScreen = false
    @ObservationIgnored var osdObserver: OSDObserver?
    /// Toasts under the pointer, which do not time out.
    @ObservationIgnored var hoveredToasts: Set<UUID> = []
    @ObservationIgnored private var wallpaperToast: UUID?
    /// Mirrors the root view's light/dark decision, which picks the light or dark wallpaper.
    var isDarkAppearance = true
    let switcher = WindowSwitcherModel()
    private(set) var isOverviewPresented = false
    /// Apps kept in the taskbar or Dock while closed; defaults to the desktop's featured apps.
    var pinnedAppIDs: [String] = UserDefaults.standard.stringArray(forKey: DesktopController.pinnedAppsKey) ?? [] {
        didSet { UserDefaults.standard.set(pinnedAppIDs, forKey: Self.pinnedAppsKey) }
    }
    static let pinnedAppsKey = "desktop.pinnedApps"

    var pinnedApps: [DesktopAppDescriptor] {
        guard UserDefaults.standard.object(forKey: Self.pinnedAppsKey) != nil else { return desktopApps }
        return pinnedAppIDs.compactMap { id in launcherApps.first { $0.id == id } }
    }

    func isPinned(_ appID: String) -> Bool {
        pinnedApps.contains { $0.id == appID }
    }

    func togglePinned(_ appID: String) {
        var ids = pinnedApps.map(\.id)
        if let index = ids.firstIndex(of: appID) { ids.remove(at: index) } else { ids.append(appID) }
        pinnedAppIDs = ids
    }

    /// Text typed in Ubuntu's Activities search, handed to the application grid it opens.
    @ObservationIgnored var launcherInitialQuery = ""
    /// The workspace a window dragged in the overview would land on.
    var overviewDropHover: Int?
    let keyboard = HardwareKeyboardMonitor()
    private(set) var style = DesktopStyle.stored(UserDefaults.standard.string(forKey: DesktopStyle.storageKey) ?? "")
    let icons: DesktopIconStore
    @ObservationIgnored let input = DesktopInputCoordinator()
    @ObservationIgnored private(set) lazy var keyCommands = DesktopKeyCommands(controller: self)
    @ObservationIgnored private(set) lazy var session = DesktopSessionStore(controller: self)
    @ObservationIgnored private(set) lazy var nowPlaying = NowPlayingCenter(host: host)
    @ObservationIgnored private(set) lazy var calendarStore = CalendarStore()
    @ObservationIgnored private(set) lazy var widgets = DesktopWidgetStore()

    /// True while a shell overlay owns the keyboard and pointer, so windows must not react.
    var isOverlayPresented: Bool {
        isLauncherPresented || isRunDialogPresented || switcher.isPresented || isOverviewPresented
            || isQuickSettingsPresented || isNotificationCenterPresented || isPowerMenuPresented || isLocked
            || isOnboardingPresented || themePicker != nil || commandMenu != nil || isShortcutSheetPresented
            || isRegionCapturePresented
    }

    func toggleQuickSettings() {
        let show = !isQuickSettingsPresented
        dismissTopOverlay()
        isNotificationCenterPresented = false
        withAnimation(DesktopMotion.standard) { isQuickSettingsPresented = show }
    }

    func toggleNotificationCenter() {
        let show = !isNotificationCenterPresented
        isQuickSettingsPresented = false
        withAnimation(DesktopMotion.standard) { isNotificationCenterPresented = show }
        if show { notifications.markAllRead() }
    }

    /// Stops the Linux GUI session (compositor, session bus, audio) and starts a fresh one.
    /// Open Linux windows close; their apps can be reopened.
    func restartDesktopSession() async {
        guard let linux else { return }
        notify("Restarting the Linux desktop session…")
        await linux.restartSession()
    }

    /// The app bundles a newer Linux system than the installed one: offer to install it on
    /// the next launch (system directories are replaced; /root and /home are kept).
    func offerSystemUpdateIfAvailable() {
        guard let preparing = host as? LinuxSystemPreparing,
              let version = preparing.availableSystemUpdate else { return }
        notify("A Linux system update (\(version)) is available. /root and /home are kept.",
               action: DesktopToast.Action(title: "Update Linux system") { [weak self] in
                   preparing.scheduleSystemUpdate()
                   self?.notify("The Linux system update installs the next time the app starts.")
               }, lifetime: .seconds(30))
    }

    func lockScreen() {
        dismissAllOverlays()
        withAnimation(DesktopMotion.standard) { isLocked = true }
    }

    func unlockScreen() {
        withAnimation(DesktopMotion.standard) { isLocked = false }
    }

    func dismissAllOverlays() {
        isLauncherPresented = false
        isRunDialogPresented = false
        isQuickSettingsPresented = false
        isNotificationCenterPresented = false
        isPowerMenuPresented = false
        dismissTransientOverlays()
    }

    @ObservationIgnored private lazy var actionsProxy = DesktopActionsProxy(controller: self)

    /// Linux GUI apps, when the host can share its filesystem (Linux/).
    let linux: LinuxGUIBridge?
    /// Linux surface id → desktop window id.
    @ObservationIgnored var linuxWindows: [UInt32: UUID] = [:]

    /// Volume, session restart and reboot, when the host provides them.
    let systemControls: (any DesktopSystemControls)?
    let notifications = NotificationCenterModel()
    let systemStatus = SystemStatus()
    let boot = BootProgress()
    var isOnboardingPresented = false
    var isQuickSettingsPresented = false
    var isNotificationCenterPresented = false
    var isLocked = false
    var isPowerMenuPresented = false
    /// The "Enable fast mode" help (native JIT through StikDebug).
    var isFastModeHelpPresented = false

    init(host: any LinuxHost, apps: [DesktopAppDescriptor], systemControls: (any DesktopSystemControls)? = nil) {
        self.systemControls = systemControls
        self.host = host
        var seen = Set<String>()
        self.apps = apps.filter { seen.insert($0.id).inserted }
        icons = DesktopIconStore(guestRoot: (host as? any LinuxGraphicsHost)?.guestRootURL,
                                 style: DesktopStyle.stored(UserDefaults.standard.string(forKey: DesktopStyle.storageKey) ?? ""))
        linux = (host as? any LinuxGraphicsHost).map { LinuxGUIBridge(host: $0) }
        linux?.delegate = self
        linux?.start()
        input.controller = self
        osdObserver = OSDObserver(controller: self)
        colorThemes.onApplyRequest = { [weak self] id in self?.applyColorTheme(id) }
        colorThemes.onPickerRequest = { [weak self] in self?.presentThemePicker() }
        colorThemes.onFindWallpapersRequest = { [weak self] theme in self?.findWallpapers(for: theme) }
        wallpapers.onApplied = { [weak self] message, undo in
            guard let self else { return }
            // One wallpaper toast at a time, so Undo always means the latest change.
            if let previous = wallpaperToast { dismissToast(previous) }
            wallpaperToast = notify(message, action: DesktopToast.Action(title: "Undo", perform: undo))
        }
        keyboard.onSwitcherModifierReleased = { [weak self] in self?.commitSwitcher() }
        windowManager.willChangeFocus = { [weak self] window in self?.input.captureSnapshot(of: window) }
        windowManager.onLayoutChange = { [weak self] in self?.session.scheduleSave() }
        windowManager.onWorkspacesRemapped = { [weak self] mapping in self?.wallpapers.remapWorkspaces(mapping) }
        windowManager.onTilingChange = { states in
            UserDefaults.standard.set(TilingSettings.encode(states), forKey: DesktopSettings.tilingKey)
        }
    }

    /// Built-in apps plus the guest's .desktop applications.
    var launcherApps: [DesktopAppDescriptor] {
        apps + linuxApps
    }

    /// App launchers on the desktop: the featured ones until the user adds or removes one.
    var desktopApps: [DesktopAppDescriptor] {
        guard let ids = desktopAppIDs else { return launcherApps.filter(\.showsOnDesktop) }
        return ids.compactMap { id in launcherApps.first { $0.id == id } }
    }

    static let desktopAppsKey = "desktop.icons.apps"
    var desktopAppIDs: [String]? = UserDefaults.standard.stringArray(forKey: DesktopController.desktopAppsKey) {
        didSet { UserDefaults.standard.set(desktopAppIDs, forKey: Self.desktopAppsKey) }
    }

    func isOnDesktop(_ appID: String) -> Bool {
        desktopApps.contains { $0.id == appID }
    }

    /// "Add to Desktop" / "Remove from Desktop" for an app launcher.
    func toggleOnDesktop(_ appID: String) {
        var ids = desktopApps.map(\.id)
        if let index = ids.firstIndex(of: appID) { ids.remove(at: index) } else { ids.append(appID) }
        desktopAppIDs = ids
    }

    /// Keys the desktop's icons handle while the desktop itself has focus (no window does).
    @ObservationIgnored var desktopKeyHandler: ((DesktopIconKey) -> Bool)?
    /// True while desktop icons are selected and no window has focus.
    var desktopHasKeyboardFocus = false

    func app(withID id: String) -> DesktopAppDescriptor? {
        apps.first { $0.id == id }
    }

    func open(appID: String, arguments: [String: String]) {
        if appID.hasPrefix(LinuxAppID.prefix) {
            openLinuxApp(appID, arguments: arguments)
            return
        }
        guard let descriptor = app(withID: appID) else {
            notify("“\(appID)” is not installed")
            return
        }
        if !descriptor.allowsMultipleWindows,
           let existing = windowManager.windows.first(where: { $0.appID == appID }) {
            windowManager.focus(existing.id)
            return
        }

        let window = windowManager.makeWindow(appID: descriptor.id, symbol: descriptor.symbol,
                                              title: descriptor.name, preferredSize: descriptor.defaultSize,
                                              arguments: arguments)
        let context = AppLaunchContext(
            host: host, arguments: arguments,
            window: DesktopWindowHandle(window: window, manager: windowManager),
            desktop: actionsProxy)
        window.content = descriptor.makeContent(context)
        windowManager.present(window)
    }

    func notify(_ message: String) {
        notify(message, action: nil)
    }

    /// A toast with a button, e.g. "Restart Linux apps"; also kept in the notification history.
    @discardableResult
    func notify(_ message: String, action: DesktopToast.Action?, showsProgress: Bool = false,
                lifetime: Duration? = nil) -> UUID {
        notifications.record(message)
        let toast = DesktopToast(message: message, action: action, showsProgress: showsProgress)
        guard !notifications.doNotDisturb || action != nil else { return toast.id }
        withAnimation(.snappy) {
            toasts.append(toast)
            if toasts.count > Self.maximumVisibleToasts {
                toasts.removeFirst(toasts.count - Self.maximumVisibleToasts)
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: lifetime ?? (action == nil ? Self.toastLifetime : .seconds(12)))
            // A pointer resting on the toast holds it, as Mako does.
            while self?.hoveredToasts.contains(toast.id) == true {
                try? await Task.sleep(for: .milliseconds(400))
            }
            self?.dismissToast(toast.id)
        }
        return toast.id
    }

    func dismissToast(_ id: UUID) {
        withAnimation(.snappy) { toasts.removeAll { $0.id == id } }
    }

    func runCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        isRunDialogPresented = false
        guard !trimmed.isEmpty else { return }
        open(appID: AppID.terminal, arguments: [AppArgument.command: trimmed])
    }

    /// Switches the shell's look, and the guest's GTK/Qt/icon themes to match.
    func applyStyle(_ newStyle: DesktopStyle, dark: Bool) {
        guard newStyle != style || icons.style != newStyle || icons.isDark != dark else { return }
        dismissTransientOverlays()
        isLauncherPresented = false
        let changed = newStyle != style
        withAnimation(DesktopMotion.standard) { style = newStyle }
        if changed { applyStyleDefaults(newStyle) }
        Task {
            guard await icons.needsApply(newStyle, dark: dark) else {
                icons.useCache(for: newStyle, dark: dark)
                return
            }
            // ish-apply-style rasterises every icon of the theme: 12-23 s under emulation.
            let progress = notify("Applying the \(newStyle.displayName) look to Linux apps…", action: nil,
                                  showsProgress: true, lifetime: .seconds(60))
            let applied = await icons.apply(newStyle, dark: dark, host: host)
            dismissToast(progress)
            guard applied, !linuxWindows.isEmpty else { return }
            notify("Open Linux apps keep their old look until they restart.",
                   action: DesktopToast.Action(title: "Restart Linux Apps") { [weak self] in
                       Task { await self?.restartDesktopSession() }
                   })
        }
    }

    func toggleLauncher() {
        dismissTransientOverlays()
        isRunDialogPresented = false
        isLauncherPresented.toggle()
    }

    func presentRunDialog() {
        dismissTransientOverlays()
        isLauncherPresented = false
        isRunDialogPresented = true
    }

    /// Escape: closes whichever overlay is on top.
    func dismissTopOverlay() {
        if isLocked {
            unlockScreen()
        } else if isRegionCapturePresented {
            finishRegionCapture(nil)
        } else if commandMenu != nil {
            commandMenu = nil
        } else if isShortcutSheetPresented {
            isShortcutSheetPresented = false
        } else if themePicker != nil {
            cancelThemePicker()
        } else if isPowerMenuPresented {
            isPowerMenuPresented = false
        } else if isQuickSettingsPresented || isNotificationCenterPresented {
            withAnimation(DesktopMotion.standard) {
                isQuickSettingsPresented = false
                isNotificationCenterPresented = false
            }
        } else if switcher.isPresented {
            switcher.dismiss()
        } else if isOverviewPresented {
            setOverviewPresented(false)
        } else if isRunDialogPresented {
            isRunDialogPresented = false
        } else {
            isLauncherPresented = false
        }
    }

    // MARK: - Window switcher

    /// Option-Tab: opens the switcher on the previously used window, or steps through it.
    func advanceSwitcher(by step: Int) {
        if switcher.isPresented {
            switcher.move(by: step)
            return
        }
        let windows = windowManager.recentWindowsInCurrentWorkspace()
        guard !windows.isEmpty else { return }
        if let focused = windowManager.focusedWindow { input.captureSnapshot(of: focused) }
        dismissTransientOverlays()
        isLauncherPresented = false
        switcher.present(windows.map(\.id), startingAt: windows.count > 1 ? (step > 0 ? 1 : windows.count - 1) : 0,
                         commitsOnModifierRelease: keyboard.canObserveModifiers)
    }

    func commitSwitcher() {
        guard let id = switcher.selectedWindowID else {
            switcher.dismiss()
            return
        }
        switcher.dismiss()
        windowManager.focus(id)
    }

    func commitSwitcher(to id: UUID) {
        switcher.dismiss()
        windowManager.focus(id)
    }

    // MARK: - Overview

    func setOverviewPresented(_ presented: Bool) {
        guard presented != isOverviewPresented else { return }
        if presented {
            switcher.dismiss()
            isLauncherPresented = false
            isRunDialogPresented = false
        }
        withAnimation(DesktopMotion.tile) { isOverviewPresented = presented }
    }

    func toggleOverview() {
        setOverviewPresented(!isOverviewPresented)
    }

    func dismissTransientOverlays() {
        switcher.dismiss()
        if isOverviewPresented { setOverviewPresented(false) }
    }

    /// Settings > Wallpaper ("Change Wallpaper…" in the desktop menu).
    func openWallpaperSettings() {
        open(appID: AppID.settings, arguments: [SettingsApp.pageArgument: SettingsApp.wallpaperPage])
        wallpapers.pageRequest = SettingsApp.wallpaperPage
    }

}

/// Apps hold their launch context for as long as their views live; a weak hop here
/// keeps those contexts from forming a cycle back through the window list.
@MainActor
private final class DesktopActionsProxy: DesktopActions {
    private weak var controller: DesktopController?

    init(controller: DesktopController) {
        self.controller = controller
    }

    func open(appID: String, arguments: [String: String]) {
        controller?.open(appID: appID, arguments: arguments)
    }

    func notify(_ message: String) {
        controller?.notify(message)
    }
}
