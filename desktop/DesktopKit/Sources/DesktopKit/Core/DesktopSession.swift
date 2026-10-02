import Foundation
import UIKit

/// What session restore writes: every window's app, launch arguments and placement,
/// bottom of the stack first, so reopening them in order rebuilds the stacking order.
struct DesktopSessionSnapshot: Codable, Equatable {
    static let currentVersion = 1

    struct Window: Codable, Equatable {
        var appID: String
        var arguments: [String: String]
        var placement: WindowPlacement
    }

    var version = Self.currentVersion
    var currentWorkspace: Int
    var windows: [Window]
    /// One name per workspace ("" for none); absent in sessions from before workspaces
    /// could be added, which had four.
    var workspaceNames: [String]?

    /// Commands are never replayed: reopening a Terminal that ran `rm -rf build` must not
    /// run it again. The window comes back as a plain shell in the same directory.
    static let unsafeArguments: Set<String> = [AppArgument.command]

    @MainActor
    init(manager: WindowManager) {
        currentWorkspace = manager.currentWorkspace
        workspaceNames = manager.workspaceNames
        windows = manager.windows
            .sorted { $0.zIndex < $1.zIndex }
            .map { window in
                Window(appID: window.appID,
                       arguments: window.arguments.filter { !Self.unsafeArguments.contains($0.key) },
                       placement: manager.placement(of: window))
            }
    }
}

/// Saves the open windows shortly after every layout change and when the app leaves the
/// foreground, and reopens them on the next launch (Settings > Desktop > Reopen Windows).
@MainActor
final class DesktopSessionStore {
    static let storageKey = "desktop.session"
    private static let saveDelay: Duration = .milliseconds(800)

    private weak var controller: DesktopController?
    private let defaults: UserDefaults
    private var saveTask: Task<Void, Never>?
    private var isRestoring = false
    private var backgroundObserver: NSObjectProtocol?

    init(controller: DesktopController, defaults: UserDefaults = .standard) {
        self.controller = controller
        self.defaults = defaults
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    var isEnabled: Bool {
        defaults.object(forKey: DesktopSettings.restoreSessionKey) as? Bool ?? true
    }

    func scheduleSave() {
        guard !isRestoring else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard !isRestoring, let manager = controller?.windowManager else { return }
        guard isEnabled else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        if let data = try? JSONEncoder().encode(DesktopSessionSnapshot(manager: manager)) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Reopens the saved windows. Returns the app ids it reopened so autostart can skip them.
    @discardableResult
    func restore() -> Set<String> {
        guard isEnabled, let controller,
              let data = defaults.data(forKey: Self.storageKey),
              let snapshot = try? JSONDecoder().decode(DesktopSessionSnapshot.self, from: data),
              snapshot.version == DesktopSessionSnapshot.currentVersion else { return [] }
        isRestoring = true
        defer { isRestoring = false }
        if let names = snapshot.workspaceNames {
            controller.windowManager.restoreWorkspaces(names: names)
            if let states = TilingSettings.decode(defaults.string(forKey: DesktopSettings.tilingKey) ?? "") {
                controller.windowManager.restoreTiling(states)
            }
        }
        var reopened = Set<String>()
        var linuxWindows: [DesktopSessionSnapshot.Window] = []
        for window in snapshot.windows {
            controller.windowManager.enqueuePlacement(window.placement, forAppID: window.appID)
            reopened.insert(window.appID)
            if window.appID.hasPrefix(LinuxAppID.prefix) {
                linuxWindows.append(window)
            } else {
                controller.open(appID: window.appID, arguments: window.arguments)
            }
        }
        controller.windowManager.restoreWorkspace(snapshot.currentWorkspace)
        if !linuxWindows.isEmpty {
            Task { await relaunchLinuxWindows(linuxWindows) }
        }
        return reopened
    }

    /// A Linux window's app id names its .desktop entry, which only resolves to a command
    /// once the bridge has read /usr/share/applications.
    private func relaunchLinuxWindows(_ windows: [DesktopSessionSnapshot.Window]) async {
        let deadline = ContinuousClock.now + .seconds(30)
        while let linux = controller?.linux, linux.applications.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(500))
        }
        for window in windows {
            controller?.open(appID: window.appID, arguments: window.arguments)
        }
    }

    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}
