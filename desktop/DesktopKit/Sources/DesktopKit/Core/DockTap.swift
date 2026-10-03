import Foundation

/// What a tap on an app's dock or taskbar button does, the Windows taskbar way: open the
/// app, bring it forward (from another workspace or out of the dock too), and put it away
/// when it is already in front. An app with several windows takes turns instead.
enum DockTapAction: Equatable {
    case launch
    case focus(UUID)
    case minimize(UUID)

    struct Window: Equatable {
        let id: UUID
        let isMinimized: Bool
    }

    /// `windows` are the app's windows, most recently focused first.
    static func resolve(_ windows: [Window], focused: UUID?) -> DockTapAction {
        guard let mostRecent = windows.first else { return .launch }
        guard let front = windows.first(where: { $0.id == focused && !$0.isMinimized }) else {
            return .focus((windows.first { !$0.isMinimized } ?? mostRecent).id)
        }
        if windows.count == 1 { return .minimize(front.id) }
        // The least recently used window next: repeated taps visit every window in turn.
        return .focus(windows[windows.count - 1].id)
    }
}

extension DesktopController {
    /// A tap on the app's button. `windows` narrows it to the windows the button stands for
    /// (a taskbar that shows the current workspace); by default every workspace's.
    func activateApp(_ appID: String, windows: [DesktopWindow]? = nil) {
        let windows = windows ?? windowManager.recentWindows(ofApp: appID)
        let action = DockTapAction.resolve(windows.map { .init(id: $0.id, isMinimized: $0.isMinimized) },
                                           focused: windowManager.focusedWindowID)
        switch action {
        case .launch: open(appID: appID, arguments: [:])
        case .focus(let id): windowManager.focus(id)
        case .minimize(let id): windowManager.minimize(id)
        }
    }
}
