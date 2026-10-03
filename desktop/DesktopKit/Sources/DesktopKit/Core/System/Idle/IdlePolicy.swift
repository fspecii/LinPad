import Foundation

/// The screensaver's look.
enum ScreensaverStyle: String, CaseIterable, Identifiable {
    case logo, matrix, clock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .logo: "LinPad Logo"
        case .matrix: "Matrix"
        case .clock: "Clock"
        }
    }
}

/// Idle settings, stored in UserDefaults. Both timeouts are off by default.
enum IdleSettings {
    static let styleKey = "desktop.screensaver.style"
    static let screensaverMinutesKey = "desktop.screensaver.afterMinutes"
    static let lockMinutesKey = "desktop.autoLock.afterMinutes"
    static let keepAwakeKey = "desktop.idle.keepAwake"

    /// 0 is Never.
    static let screensaverChoices = [0, 1, 2, 5, 10, 15, 30]
    static let lockChoices = [0, 5, 10, 15, 30, 60]

    static func title(minutes: Int) -> String {
        minutes == 0 ? "Never" : minutes == 60 ? "1 hour" : "\(minutes) min"
    }

    static var style: ScreensaverStyle {
        UserDefaults.standard.string(forKey: styleKey).flatMap(ScreensaverStyle.init) ?? .logo
    }

    static var policy: IdlePolicy {
        let defaults = UserDefaults.standard
        func seconds(_ key: String) -> TimeInterval? {
            let minutes = defaults.integer(forKey: key)
            return minutes > 0 ? TimeInterval(minutes * 60) : nil
        }
        return IdlePolicy(screensaverAfter: seconds(screensaverMinutesKey), lockAfter: seconds(lockMinutesKey),
                          keepAwake: defaults.bool(forKey: keepAwakeKey))
    }
}

/// What idleness leads to. Kept free of UIKit so it can be tested on its own.
struct IdlePolicy: Equatable {
    var screensaverAfter: TimeInterval?
    var lockAfter: TimeInterval?
    /// The "Keep Awake" toggle: nothing happens while it is on.
    var keepAwake = false

    struct Actions: Equatable {
        var showScreensaver = false
        var lock = false
        var isEmpty: Bool { !showScreensaver && !lock }
    }

    /// `inhibited`: something the user watches without touching (fullscreen video, a screen
    /// recording) is going on, so the desktop stays as it is.
    func actions(idle: TimeInterval, isLocked: Bool, isScreensaverShown: Bool, inhibited: Bool) -> Actions {
        guard !keepAwake, !inhibited else { return Actions() }
        var actions = Actions()
        if let screensaverAfter, idle >= screensaverAfter, !isScreensaverShown { actions.showScreensaver = true }
        if let lockAfter, idle >= lockAfter, !isLocked { actions.lock = true }
        return actions
    }

    /// The earliest moment anything can be due, for scheduling the next check.
    var shortestTimeout: TimeInterval? {
        [screensaverAfter, lockAfter].compactMap { $0 }.min()
    }
}
