import DesktopKit
import SwiftUI
import UIKit

/// Entry point the Objective-C scene delegate looks up at runtime (by class name,
/// since SceneDelegate.m is also built into targets without Swift).
@objc(DesktopBridge)
final class DesktopBridge: NSObject {
    /// Set to NO (Settings app, or `defaults write`) to get the classic single-terminal UI back.
    static let enabledDefaultsKey = "desktop.enabled"

    @objc static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// linpad:// links (SceneDelegate); the desktop asks before acting on them.
    @MainActor
    @objc static func openURL(_ url: URL) -> Bool {
        LinPadLinkInbox.shared.receive(url)
    }

    @MainActor
    @objc static func makeRootViewController() -> UIViewController {
        // White terminals clash with the dark desktop; only overrides the untouched default.
        let preferences = UserPreferences.shared()
        if preferences.colorScheme == .ColorSchemeMatchSystem {
            preferences.colorScheme = .ColorSchemeAlwaysDark
        }
        let host = ISHLinuxHost()
        // Before anything else can crash: how the last session ended, MetricKit, the marker.
        DiagnosticsCenter.shared.beginSession(host: host)
        // Waits for the guest's PulseAudio FIFO, which the Linux session (ishwl-session)
        // creates; until sound plays it holds no audio session.
        ISHAudioBridge.shared.start(guestRoot: host.guestRootURL)
        // Microphone for Linux apps: idle (no prompt, no indicator) until one records.
        ISHMicBridge.shared.start(guestRoot: host.guestRootURL)
        // Light or dark is the desktop's choice (Settings > Desktop > Appearance); DesktopKit
        // sets the window's interface style itself.
        let root = DesktopRootView(host: host, apps: BuiltinApps.all(), systemControls: ISHSystemControls())
            .ignoresSafeArea()
        let controller = DesktopHostingController(rootView: root)
        controller.view.backgroundColor = .black
        return controller
    }
}

/// The desktop's own panel replaces the iOS status bar.
private final class DesktopHostingController<Content: View>: UIHostingController<Content> {
    override var prefersStatusBarHidden: Bool { true }
    // UIHostingController otherwise lets an embedded TerminalViewController decide.
    override var childForStatusBarHidden: UIViewController? { nil }
    override var childForStatusBarStyle: UIViewController? { nil }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

/// Quick-settings hooks into the iSH app: the Linux audio bridge's volume. The kernel runs
/// inside this process, so the guest cannot be rebooted on its own.
@MainActor
final class ISHSystemControls: DesktopSystemControls {
    var volume: Float? {
        get { ISHAudioBridge.shared.volume }
        set { ISHAudioBridge.shared.volume = newValue ?? 1 }
    }

    var isMuted: Bool {
        get { ISHAudioBridge.shared.isMuted }
        set { ISHAudioBridge.shared.isMuted = newValue }
    }

    let canRebootLinux = false

    func rebootLinux() async {}
}
