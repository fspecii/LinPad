import SwiftUI
import Observation
import UIKit

/// Notes input anywhere on the desktop and, after the idle timeouts in Settings,
/// shows the screensaver and locks the screen. Never while a screen recording runs or a
/// maximized window plays media (a fullscreen video), or while Keep Awake is on.
@Observable @MainActor
final class IdleMonitor {
    private(set) var isScreensaverShown = false
    @ObservationIgnored private weak var controller: DesktopController?
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let checkInterval: Duration = .seconds(5)

    init(controller: DesktopController) {
        self.controller = controller
    }

    func start() {
        guard task == nil else { return }
        lastActivity = Date()
        #if DEBUG || DESKTOP_AUTOMATION
        // UI tests: `-desktop.screensaver.showNow YES` starts with the screensaver on.
        if UserDefaults.standard.bool(forKey: "desktop.screensaver.showNow") {
            Task { [weak self] in
                while self?.controller?.boot.isFinished == false { try? await Task.sleep(for: .milliseconds(200)) }
                try? await Task.sleep(for: .seconds(1))
                self?.showScreensaver()
            }
        }
        #endif
        let center = NotificationCenter.default
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteActivity() }
            })
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.checkInterval)
                await self?.check()
            }
        }
    }

    /// Any touch or click (DesktopInputCoordinator's touch-down recognizer) or key press
    /// (HardwareKeyboardMonitor).
    func noteActivity() {
        lastActivity = Date()
        if isScreensaverShown { dismissScreensaver() }
    }

    func showScreensaver() {
        controller?.dismissAllOverlays()
        withAnimation(DesktopMotion.standard) { isScreensaverShown = true }
    }

    func dismissScreensaver() {
        lastActivity = Date()
        withAnimation(DesktopMotion.standard) { isScreensaverShown = false }
    }

    private func check() async {
        guard let controller, controller.boot.isFinished, !controller.isOnboardingPresented else { return }
        let policy = IdleSettings.policy
        let idle = Date().timeIntervalSince(lastActivity)
        guard let shortest = policy.shortestTimeout, idle >= shortest else { return }
        let inhibited = await isInhibited(controller)
        let actions = policy.actions(idle: Date().timeIntervalSince(lastActivity), isLocked: controller.isLocked,
                                     isScreensaverShown: isScreensaverShown, inhibited: inhibited)
        if actions.lock { controller.lockScreen() }
        if actions.showScreensaver { showScreensaver() }
    }

    private func isInhibited(_ controller: DesktopController) async -> Bool {
        if controller.isRecordingScreen { return true }
        guard controller.windowManager.focusedWindow?.isMaximized == true else { return false }
        await controller.nowPlaying.refresh()
        return controller.nowPlaying.player?.isPlaying == true
    }
}
