import SwiftUI

/// Launcher ids for guest applications: "linux:<desktop id>", or "linux:<command>"
/// for anything not in /usr/share/applications (e.g. `-desktop.autostart linux:thunar`).
enum LinuxAppID {
    static let prefix = "linux:"
    /// The user's terminal (see LinuxTerminal), opened at `AppArgument.cwd`. "@" cannot
    /// occur in a desktop id.
    static let preferredTerminal = prefix + "@terminal"
}

/// Which terminal "Open Terminal Here" and similar actions use: foot in the Linux
/// session, or the built-in Terminal app.
enum LinuxTerminal: String {
    case foot
    case builtin

    static let settingKey = "desktop.terminal"

    static var preferred: LinuxTerminal {
        UserDefaults.standard.string(forKey: settingKey).flatMap(LinuxTerminal.init(rawValue:)) ?? .foot
    }

    /// The guest command that starts foot, coloured for the current desktop style.
    static func footCommand(workingDirectory: String?) -> String {
        guard let workingDirectory, !workingDirectory.isEmpty else { return "ish-terminal" }
        return "ish-terminal --working-directory=" + ShellQuote.quote(workingDirectory)
    }
}

/// Linux apps promoted to first-class desktop entries. They appear in the launcher and on
/// the desktop even before /usr/share/applications has been read, and their .desktop
/// duplicates are hidden. Commands get the session environment from ishwl-session.
struct LinuxFeaturedApp {
    let id: String
    let name: String
    let symbol: String
    let category: AppCategory
    let showsOnDesktop: Bool
    /// Freedesktop icon names, best first; icon packs name the same app differently.
    let iconNames: [String]
    let command: String
    /// The .desktop file this replaces in the Linux category.
    let desktopID: String
    /// Further .desktop files of the same app that the launcher should not list.
    var alsoHides: [String] = []

    static let all = [
        LinuxFeaturedApp(id: "firefox", name: "Firefox", symbol: "globe", category: .internet,
                         showsOnDesktop: true, iconNames: ["firefox", "firefox-esr", "org.mozilla.firefox", "web-browser"],
                         command: "firefox-esr", desktopID: "firefox-esr"),
        // Lighter alternative; `apk add falkon qt6-qtwayland` if the rootfs lacks it.
        LinuxFeaturedApp(id: "falkon", name: "Browser (Falkon)", symbol: "globe", category: .internet,
                         showsOnDesktop: false, iconNames: ["falkon", "org.kde.falkon", "web-browser"],
                         command: "falkon", desktopID: "org.kde.falkon"),
        LinuxFeaturedApp(id: "foot", name: "Terminal (foot)", symbol: "apple.terminal", category: .system,
                         showsOnDesktop: false, iconNames: ["foot", "utilities-terminal"],
                         command: LinuxTerminal.footCommand(workingDirectory: nil),
                         desktopID: "foot", alsoHides: ["footclient", "foot-server"]),
        LinuxFeaturedApp(id: "code", name: "Visual Studio Code", symbol: "chevron.left.forwardslash.chevron.right",
                         category: .development, showsOnDesktop: true,
                         iconNames: ["vscode", "com.visualstudio.code", "code", "visual-studio-code", "code-oss",
                                     "accessories-text-editor"],
                         command: "code", desktopID: "code",
                         alsoHides: ["code-url-handler"]),
    ]

    var appID: String { LinuxAppID.prefix + id }
}

extension DesktopController: LinuxGUIBridgeDelegate {
    var linuxApps: [DesktopAppDescriptor] {
        guard let linux else { return [] }
        // Until the .desktop files are read, assume the featured apps are installed.
        let installed = Set(linux.applications.map(\.id))
        let available = LinuxFeaturedApp.all.filter { installed.isEmpty || installed.contains($0.desktopID) }
        let icons = linux.iconCache
        let style = icons?.currentStyle
        func iconURL(_ icon: String) -> URL? { style.flatMap { icons?.url(forIcon: icon, style: $0) } }
        let featured = available.map { app in
            let icon = linux.applications.first { $0.id == app.desktopID }?.icon ?? app.desktopID
            return DesktopAppDescriptor(id: app.appID, name: app.name, symbol: app.symbol, category: app.category,
                                        showsOnDesktop: app.showsOnDesktop,
                                        iconURL: iconURL(icon)) { _ in AnyView(EmptyView()) }
        }
        let hidden = Set(LinuxFeaturedApp.all.flatMap { [$0.desktopID] + $0.alsoHides })
        let entries = linux.applications.filter { !hidden.contains($0.id) }.map { entry in
            DesktopAppDescriptor(id: LinuxAppID.prefix + entry.id, name: entry.name,
                                 symbol: entry.symbol, category: .linux,
                                 iconURL: iconURL(entry.icon)) { _ in AnyView(EmptyView()) }
        }
        return featured + entries
    }

    func openLinuxApp(_ appID: String, arguments: [String: String] = [:]) {
        if appID == LinuxAppID.preferredTerminal {
            openPreferredTerminal(at: arguments[AppArgument.cwd])
            return
        }
        guard let linux else {
            notify("Linux apps need a host that shares its filesystem")
            return
        }
        let name = String(appID.dropFirst(LinuxAppID.prefix.count))
        let command = LinuxFeaturedApp.all.first { $0.id == name }?.command
            ?? linux.applications.first { $0.id == name }?.command
            ?? name
        if case .failed(let reason) = linux.state {
            notify(reason)
        }
        linux.launch(command: command)
    }

    /// foot when the setting asks for it and the guest has it, else the built-in Terminal.
    private func openPreferredTerminal(at directory: String?) {
        // Before /usr/share/applications has been read, assume foot is there, as the
        // featured apps do.
        let applications = linux?.applications ?? []
        let footInstalled = applications.isEmpty || applications.contains { $0.id == "foot" }
        if LinuxTerminal.preferred == .foot, let linux, footInstalled {
            linux.launch(command: LinuxTerminal.footCommand(workingDirectory: directory))
        } else {
            open(appID: AppID.terminal, arguments: directory.map { [AppArgument.cwd: $0] } ?? [:])
        }
    }

    func linuxBridge(_ bridge: LinuxGUIBridge, didRequestPreview url: URL) {
        open(appID: AppID.browser, arguments: [AppArgument.url: url.absoluteString])
    }

    func linuxBridge(_ bridge: LinuxGUIBridge, didRequestOpen url: URL) {
        if UserDefaults.standard.string(forKey: LinuxGUIBridge.urlHandlerKey) == "firefox" {
            bridge.launch(command: "firefox-esr " + ShellQuote.quote(url.absoluteString))
        } else {
            open(appID: AppID.browser, arguments: [AppArgument.url: url.absoluteString])
        }
    }

    func windowFocusChanged(_ windowID: UUID?) {
        guard let linux, linux.state == .running else { return }
        let surfaceID = linuxWindows.first { $0.value == windowID }?.key
        linux.focus(surfaceID)
        if let surfaceID {
            linux.surface(withID: surfaceID)?.view?.focusKeyboard()
        }
    }

    func linuxBridge(_ bridge: LinuxGUIBridge, didMap surface: LinuxSurface) {
        guard let view = surface.view else { return }
        let entry = bridge.applications.first { $0.matches(appID: surface.appID) }
        let appID = LinuxAppID.prefix + (entry?.id ?? surface.appID)
        // "Don't Restore" was chosen while this restored app was still starting.
        if session.shouldDiscardMappedLinuxWindow(appID: appID) {
            bridge.requestClose(surface.id)
            return
        }
        let window = windowManager.makeWindow(
            appID: appID,
            symbol: entry?.symbol ?? "macwindow",
            title: windowTitle(for: surface, entry: entry),
            preferredSize: CGSize(width: surface.size.width,
                                  height: surface.size.height + WindowManager.titleBarHeight))
        window.content = AnyView(LinuxWindowContent(view: view))
        let surfaceID = surface.id
        window.onCloseRequest = { [weak bridge] in bridge?.requestClose(surfaceID) }
        linuxWindows[surfaceID] = window.id
        windowManager.present(window)
    }

    func linuxBridge(_ bridge: LinuxGUIBridge, didUnmap surface: LinuxSurface) {
        guard let windowID = linuxWindows.removeValue(forKey: surface.id) else { return }
        windowManager.close(windowID)
    }

    func linuxBridge(_ bridge: LinuxGUIBridge, didRetitle surface: LinuxSurface) {
        guard let windowID = linuxWindows[surface.id], let window = windowManager.window(withID: windowID) else { return }
        let entry = bridge.applications.first { $0.matches(appID: surface.appID) }
        window.title = windowTitle(for: surface, entry: entry)
    }

    func linuxBridge(_ bridge: LinuxGUIBridge, didRequestActivation surface: LinuxSurface) {
        guard let windowID = linuxWindows[surface.id] else { return }
        windowManager.focus(windowID)
    }

    func linuxBridge(_ bridge: LinuxGUIBridge, didRequest state: String, for surface: LinuxSurface) {
        guard let windowID = linuxWindows[surface.id], let window = windowManager.window(withID: windowID) else { return }
        switch state {
        case "maximize" where !window.isMaximized, "unmaximize" where window.isMaximized:
            windowManager.toggleMaximize(windowID)
        case "minimize":
            windowManager.minimize(windowID)
        default:
            break
        }
    }

    func linuxBridgeSessionEnded(_ bridge: LinuxGUIBridge) {
        if !linuxWindows.isEmpty {
            for windowID in linuxWindows.values { windowManager.close(windowID) }
            linuxWindows.removeAll()
            if !bridge.isRestarting {
                notify("Linux apps stopped unexpectedly; the next launch restarts them")
            }
        }
    }

    private func windowTitle(for surface: LinuxSurface, entry: LinuxDesktopEntry?) -> String {
        if !surface.title.isEmpty { return surface.title }
        return entry?.name ?? surface.appID
    }
}
