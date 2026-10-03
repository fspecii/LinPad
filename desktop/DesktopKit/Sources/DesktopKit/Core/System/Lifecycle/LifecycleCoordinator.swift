import Foundation
import OSLog
import UIKit

/// Something with unsaved work that must be written before iPadOS may end LinPad: the
/// Text Editor's documents. Registered weakly in `LifecycleSavers`.
@MainActor
protocol LifecycleSaving: AnyObject {
    /// Save what can be saved now. Bounded by the coordinator's timeout.
    func saveBeforeSuspension() async
}

/// Every open document that wants a last save before suspension. Apps register here
/// from their own initializers, which have no reference to the desktop.
@MainActor
final class LifecycleSavers {
    static let shared = LifecycleSavers()

    private var entries: [WeakSaver] = []

    func register(_ saver: any LifecycleSaving) {
        entries.removeAll { $0.saver == nil || $0.saver === saver }
        entries.append(WeakSaver(saver: saver))
    }

    func unregister(_ saver: any LifecycleSaving) {
        entries.removeAll { $0.saver == nil || $0.saver === saver }
    }

    var all: [any LifecycleSaving] {
        entries.removeAll { $0.saver == nil }
        return entries.compactMap(\.saver)
    }
}

/// iPadOS's grace period after leaving the screen, injectable for tests.
@MainActor
protocol BackgroundTaskRunning {
    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int
    func end(_ token: Int)
}

@MainActor
struct UIKitBackgroundTasks: BackgroundTaskRunning {
    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int {
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { expiration() }
        }
        return identifier.rawValue
    }

    func end(_ token: Int) {
        let identifier = UIBackgroundTaskIdentifier(rawValue: token)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

/// Leaving and re-entering the foreground (screen lock, app switch, Stage Manager):
///
/// * resign active: release held keys in Linux apps, save the window session
/// * enter background: within iPadOS's grace period (about 30 s), have open documents
///   saved, run the guest's suspend hooks (`linpad-lifecycle suspend`), then write the
///   Linux file system through to flash. iPadOS may end a suspended LinPad without
///   warning, so this is the last chance.
/// * enter foreground: the guest's resume hooks, the audio session back, the keep-alive
///   mode re-applied
@MainActor
final class LifecycleCoordinator {
    private static let logger = Logger(subsystem: "DesktopKit", category: "Lifecycle")
    static let saveTimeout: TimeInterval = 5
    static let flushTimeout: TimeInterval = 15

    private weak var controller: DesktopController?
    private let host: any LinuxHost
    private let lifecycleHost: (any LinuxLifecycleHosting)?
    private let tasks: any BackgroundTaskRunning
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []
    private let savers: LifecycleSavers
    private var backgroundTask: Int?
    private var flushTask: Task<Void, Never>?
    private(set) var isInBackground = false
    private(set) var lastFlush: LifecycleFlushReport?
    /// Bumped on every foreground entry, so a flush that outlived its background stint
    /// does not end the next stint's grace period.
    private var generation = 0

    init(controller: DesktopController?, host: any LinuxHost, tasks: (any BackgroundTaskRunning)? = nil,
         defaults: UserDefaults = .standard, savers: LifecycleSavers? = nil, observesApplication: Bool = true) {
        self.controller = controller
        self.savers = savers ?? .shared
        self.host = host
        lifecycleHost = host as? any LinuxLifecycleHosting
        self.tasks = tasks ?? UIKitBackgroundTasks()
        self.defaults = defaults
        guard observesApplication else { return }
        let center = NotificationCenter.default
        let handlers: [(Notification.Name, @MainActor (LifecycleCoordinator) -> Void)] = [
            (UIApplication.willResignActiveNotification, { $0.willResignActive() }),
            (UIApplication.didEnterBackgroundNotification, { $0.didEnterBackground() }),
            (UIApplication.willEnterForegroundNotification, { $0.willEnterForeground() }),
            (UIApplication.didBecomeActiveNotification, { $0.didBecomeActive() }),
        ]
        observers.append(center.addObserver(forName: .linuxAudioOutputLost, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.audioOutputLost() }
        })
        for (name, handler) in handlers {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)
                }
            })
        }
        applyBackgroundExecution()
    }

    var backgroundExecution: BackgroundExecution {
        BackgroundExecution.stored(in: defaults)
    }

    func setBackgroundExecution(_ mode: BackgroundExecution) {
        defaults.set(mode.rawValue, forKey: BackgroundExecution.storageKey)
        applyBackgroundExecution()
    }

    func applyBackgroundExecution() {
        lifecycleHost?.applyBackgroundExecution(backgroundExecution, inBackground: isInBackground)
    }

    // MARK: Transitions

    func willResignActive() {
        controller?.linux?.releaseHeldInput()
        controller?.session.saveNow()
    }

    func didEnterBackground() {
        isInBackground = true
        applyBackgroundExecution()
        guard flushTask == nil else { return }
        let stint = generation
        // Begun first thing: iPadOS counts the grace period from the moment LinPad left.
        let token = tasks.begin(name: "Save Linux files") { [weak self] in
            self?.endBackgroundTask(stint: stint)
        }
        backgroundTask = token
        flushTask = Task { [weak self] in
            guard let self else { return }
            let report = await self.flushForSuspension()
            self.lastFlush = report
            self.flushTask = nil
            Self.logger.info("background flush: \(report.appsSaved) app(s), hook \(report.guestHookFinished), fs \(report.filesystemFlushed), \(report.seconds, format: .fixed(precision: 2)) s")
            self.endBackgroundTask(stint: stint)
        }
    }

    func willEnterForeground() {
        generation += 1
        isInBackground = false
        if let token = backgroundTask {
            backgroundTask = nil
            tasks.end(token)
        }
        applyBackgroundExecution()
        lifecycleHost?.resumeAfterBackground()
        controller?.linux?.resumeAfterBackground()
        let host = self.host
        Task { _ = await withLifecycleTimeout(GuestLifecycleCommand.resumeTimeout) {
            await host.run(GuestLifecycleCommand.resume).succeeded
        } }
    }

    /// The keyboard goes back where it was: the focused Linux window takes it again and
    /// ishwl hears which surface has focus (it saw "leave" on the way out).
    func didBecomeActive() {
        guard let controller else { return }
        controller.windowFocusChanged(controller.windowManager.focusedWindowID)
        controller.input.ensureKeyCommandsReachable()
    }

    func audioOutputLost() {
        let host = self.host
        Task { _ = await host.run(LinuxMediaPause.command) }
    }

    /// Everything that must reach flash before iPadOS may end LinPad, in dependency order:
    /// documents are written by guest commands, so they go before the guest's own hooks,
    /// and the file system flush comes last.
    func flushForSuspension() async -> LifecycleFlushReport {
        let start = Date()
        var report = LifecycleFlushReport()
        if let controller {
            controller.session.saveNow()
            report.savedSession = true
        }
        for saver in savers.all {
            if await withLifecycleTimeout(Self.saveTimeout, { await saver.saveBeforeSuspension(); return true }) == true {
                report.appsSaved += 1
            }
        }
        let host = self.host
        report.guestHookFinished = await withLifecycleTimeout(GuestLifecycleCommand.suspendTimeout) {
            await host.run(GuestLifecycleCommand.suspend).succeeded
        } ?? false
        if let lifecycleHost {
            report.filesystemFlushed = await withLifecycleTimeout(Self.flushTimeout) {
                await lifecycleHost.flushFilesystem()
                return true
            } ?? false
        }
        report.seconds = Date().timeIntervalSince(start)
        return report
    }

    private func endBackgroundTask(stint: Int) {
        guard stint == generation, let token = backgroundTask else { return }
        backgroundTask = nil
        tasks.end(token)
    }
}

private struct WeakSaver {
    weak var saver: (any LifecycleSaving)?
}

extension DesktopController {
    /// After the startup windows reopened: say so when iPadOS had closed LinPad, with a
    /// way back to an empty desktop.
    func noticeRestoredSession(previousExit: PreviousExit) {
        guard session.didRestoreWindows, previousExit == .endedInBackground,
              UserDefaults.standard.object(forKey: LifecycleSettings.restoreNoticeKey) as? Bool ?? true else { return }
        notify("Restored your session after LinPad was closed by iPadOS.",
               action: DesktopToast.Action(title: "Don't Restore") { [weak self] in
                   self?.session.discardRestoredWindows()
               }, lifetime: .seconds(15))
    }
}
