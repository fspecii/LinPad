import Foundation
import MetricKit
import Observation
import OSLog
import UIKit

/// Optional host capability for Settings › Maintenance › Export Diagnostics: the emulator's
/// own logs, which stay readable even when the guest no longer answers.
@MainActor
public protocol LinuxDiagnosticsProviding: AnyObject {
    /// The newest bytes of the kernel log (what dmesg shows) or, with `diagnostic`, of the
    /// messages only printed with ISH_LOG=1.
    func emulatorLog(diagnostic: Bool, maxBytes: Int) -> String
    /// Where the emulator writes its log tail when it dies (die(), abort()).
    var emulatorCrashLogURL: URL? { get }
}

/// Crash and hang bookkeeping for the whole app: the unclean-exit marker, MetricKit
/// payloads, the main-thread and guest watchdogs, and the events the diagnostics export
/// lists. Nothing here leaves the iPad unless the user shares an export.
@Observable @MainActor
public final class DiagnosticsCenter {
    public static let shared = DiagnosticsCenter()

    /// Set at launch when the previous session ended while LinPad was in front.
    private(set) var previousSessionEndedUncleanly = false
    private(set) var events: [DiagnosticsEvent] = []
    var isExportSheetRequested = false
    /// The guest stopped answering; cleared when it answers again.
    private(set) var guestIsUnresponsive = false

    @ObservationIgnored var notify: ((String, DesktopToast.Action?) -> Void)?
    @ObservationIgnored var restartSession: (() async -> Void)?
    @ObservationIgnored var showRepair: (() -> Void)?

    let directory: URL
    /// systemUptime when the app started, for the export's "running for" line.
    let launchUptime = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var marker: DiagnosticsSessionMarker?
    @ObservationIgnored private var began = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var metricSubscriber: MetricSubscriber?
    @ObservationIgnored private var mainWatchdog: MainThreadWatchdog?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var lastStallToast: Date?
    @ObservationIgnored private weak var diagnosticsHost: (any LinuxDiagnosticsProviding)?
    private static let logger = Logger(subsystem: "DesktopKit", category: "Diagnostics")
    static let maxEvents = 200
    static let maxPayloads = 10

    @ObservationIgnored private let isInForeground: @MainActor () -> Bool
    @ObservationIgnored private let observesSystem: Bool

    /// `observesSystem` false (tests): no app notifications, MetricKit or watchdog threads.
    init(directory: URL? = nil, now: @escaping () -> Date = Date.init,
         isInForeground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState != .background },
         observesSystem: Bool = true) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        self.now = now
        self.isInForeground = isInForeground
        self.observesSystem = observesSystem
    }

    var markerURL: URL { directory.appendingPathComponent("session.json") }
    var eventsURL: URL { directory.appendingPathComponent("events.jsonl") }
    var payloadsDirectory: URL { directory.appendingPathComponent("MetricKit", isDirectory: true) }
    var crashLogsDirectory: URL { directory.appendingPathComponent("EmulatorCrashes", isDirectory: true) }
    var logSnapshotURL: URL { directory.appendingPathComponent("emulator-log-snapshot.txt") }

    // MARK: Session

    /// Reads how the previous session ended and starts this one. Call once, early.
    public func beginSession(host: (any LinuxHost)? = nil) {
        guard !began else { return }
        began = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        events = loadEvents()
        if let data = try? Data(contentsOf: markerURL),
           let previous = try? JSONDecoder.diagnostics.decode(DiagnosticsSessionMarker.self, from: data),
           previous.endedUncleanly {
            previousSessionEndedUncleanly = true
            var detail = "LinPad \(previous.appVersion), launched \(previous.launchedAt.formatted(.iso8601))"
            if let stall = previous.stallInProgressSince {
                detail += "; the main thread had been stalled since \(stall.formatted(.iso8601))"
            }
            record(.uncleanExit, detail)
        }
        diagnosticsHost = host as? LinuxDiagnosticsProviding
        collectEmulatorCrashLog()
        marker = DiagnosticsSessionMarker(launchedAt: now(), appVersion: BackupService.appVersion,
                                          inForeground: isInForeground())
        writeMarker()
        guard observesSystem else { return }
        observeApplication()
        let subscriber = MetricSubscriber { [weak self] payloads in self?.store(payloads) }
        MXMetricManager.shared.add(subscriber)
        metricSubscriber = subscriber
    }

    /// The app is about to exit on purpose (Reset to Factory closes it).
    public func markCleanExit() {
        marker?.inForeground = false
        writeMarker()
    }

    private func observeApplication() {
        let center = NotificationCenter.default
        let foreground: [Notification.Name] = [UIApplication.didBecomeActiveNotification, UIApplication.willEnterForegroundNotification]
        let background: [Notification.Name] = [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification]
        for name in foreground {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setForeground(true) }
            })
        }
        for name in background {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setForeground(false) }
            })
        }
    }

    private func setForeground(_ inForeground: Bool) {
        guard marker?.inForeground != inForeground else { return }
        marker?.inForeground = inForeground
        writeMarker()
        if inForeground {
            mainWatchdog?.start()
        } else {
            mainWatchdog?.stop()
            snapshotEmulatorLog()
        }
    }

    private func writeMarker() {
        guard let marker, let data = try? JSONEncoder.diagnostics.encode(marker) else { return }
        try? data.write(to: markerURL, options: .atomic)
    }

    /// Written from the watchdog thread while the main thread is stuck, so a kill by iPadOS's
    /// own watchdog is recognisable at the next launch.
    nonisolated func writeStallMarker(since: Date, url: URL) {
        guard let data = try? Data(contentsOf: url),
              var current = try? JSONDecoder.diagnostics.decode(DiagnosticsSessionMarker.self, from: data) else { return }
        current.stallInProgressSince = since
        if let updated = try? JSONEncoder.diagnostics.encode(current) { try? updated.write(to: url, options: .atomic) }
    }

    // MARK: After boot

    /// Called once the desktop is up: the unclean-exit notice and the watchdogs.
    func desktopStarted(host: any LinuxHost) {
        if previousSessionEndedUncleanly {
            previousSessionEndedUncleanly = false
            notify?("LinPad closed unexpectedly last time.", DesktopToast.Action(title: "Export Diagnostics") { [weak self] in
                self?.isExportSheetRequested = true
            })
            if UncleanExitPolicy.suggestsRepair(events: events, now: now()) {
                notify?("LinPad has closed unexpectedly more than once recently. Repair System may fix it; your files are kept.",
                        DesktopToast.Action(title: "Repair…") { [weak self] in self?.showRepair?() })
            }
        }
        guard observesSystem else { return }
        startMainThreadWatchdog()
        startGuestHeartbeat(host: host)
        startLogSnapshots()
    }

    private func startMainThreadWatchdog() {
        guard mainWatchdog == nil else { return }
        let markerURL = self.markerURL
        let watchdog = MainThreadWatchdog { [weak self] event, startedAt in
            switch event {
            case .stalled:
                self?.writeStallMarker(since: startedAt, url: markerURL)
            case .recovered(let duration):
                Task { @MainActor in self?.mainThreadRecovered(after: duration) }
            }
        }
        watchdog.start()
        mainWatchdog = watchdog
    }

    private func mainThreadRecovered(after duration: TimeInterval) {
        marker?.stallInProgressSince = nil
        writeMarker()
        record(.mainThreadStall, String(format: "the desktop did not respond for %.1f s", duration))
        Self.logger.error("main thread stalled for \(duration, format: .fixed(precision: 1)) s")
        guard duration >= 5, let restartSession else { return }
        if let last = lastStallToast, now().timeIntervalSince(last) < 300 { return }
        lastStallToast = now()
        notify?(String(format: "The desktop stopped responding for %.0f seconds.", duration),
                DesktopToast.Action(title: "Restart Linux Session") { Task { await restartSession() } })
    }

    private func startGuestHeartbeat(host: any LinuxHost) {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            var monitor = GuestHeartbeatMonitor()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, UIApplication.shared.applicationState == .active else { continue }
                let answered = await Self.answers(host, within: monitor.timeout)
                switch monitor.record(answered: answered) {
                case .wedged: self.guestStoppedAnswering()
                case .recovered: self.guestAnswersAgain()
                case nil: break
                }
            }
        }
    }

    /// Runs `true` in the guest; false when it has not finished within `timeout`.
    static func answers(_ host: any LinuxHost, within timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in await host.run("true").succeeded }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func guestStoppedAnswering() {
        guestIsUnresponsive = true
        record(.guestUnresponsive, "Linux did not run a command within 20 s, twice in a row")
        snapshotEmulatorLog()
        Self.logger.error("guest is not answering")
        notify?("Linux is not responding. Restarting the Linux session usually helps; LinPad and your windows stay open.",
                restartSession.map { restart in DesktopToast.Action(title: "Restart Linux Session") { Task { await restart() } } })
    }

    private func guestAnswersAgain() {
        guestIsUnresponsive = false
        record(.guestRecovered, "Linux answers again")
    }

    /// Keeps a recent copy of the emulator's log on disk, so a crash that MetricKit reports
    /// comes with what Linux was doing.
    private func startLogSnapshots() {
        guard snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, UIApplication.shared.applicationState == .active else { continue }
                self.snapshotEmulatorLog()
            }
        }
    }

    func snapshotEmulatorLog() {
        guard let host = diagnosticsHost else { return }
        let text = "--- kernel log ---\n" + host.emulatorLog(diagnostic: false, maxBytes: 64 << 10)
            + "\n--- diagnostic log ---\n" + host.emulatorLog(diagnostic: true, maxBytes: 64 << 10)
        try? Data(text.utf8).write(to: logSnapshotURL, options: .atomic)
    }

    // MARK: Crash reports

    private func collectEmulatorCrashLog() {
        guard let url = diagnosticsHost?.emulatorCrashLogURL, FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: crashLogsDirectory, withIntermediateDirectories: true)
        let name = "emulator-crash-\(Int(now().timeIntervalSince1970)).txt"
        if (try? FileManager.default.moveItem(at: url, to: crashLogsDirectory.appendingPathComponent(name))) != nil {
            record(.emulatorCrashLog, "the emulator stopped with a fatal error; its log is in the export")
        }
        prune(crashLogsDirectory, keep: Self.maxPayloads)
    }

    func store(_ payloads: [MXDiagnosticPayload]) {
        try? FileManager.default.createDirectory(at: payloadsDirectory, withIntermediateDirectories: true)
        for payload in payloads {
            let stamp = Int(payload.timeStampEnd.timeIntervalSince1970)
            try? payload.jsonRepresentation().write(to: payloadsDirectory.appendingPathComponent("diagnostic-\(stamp)-\(UUID().uuidString.prefix(8)).json"))
            if let crashes = payload.crashDiagnostics, !crashes.isEmpty {
                let signals = crashes.compactMap { $0.signal.map { "signal \($0)" } ?? $0.exceptionType.map { "exception \($0)" } }
                record(.crashReport, "iPadOS reported \(crashes.count) crash(es)" + (signals.isEmpty ? "" : ": " + signals.joined(separator: ", ")))
            }
            if let hangs = payload.hangDiagnostics, !hangs.isEmpty {
                record(.hangReport, "iPadOS reported \(hangs.count) hang(s) of " + hangs.map { $0.hangDuration.description }.joined(separator: ", "))
            }
        }
        prune(payloadsDirectory, keep: Self.maxPayloads)
    }

    private func prune(_ directory: URL, keep: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Events

    func record(_ kind: DiagnosticsEvent.Kind, _ detail: String) {
        let event = DiagnosticsEvent(date: now(), kind: kind, detail: detail)
        events.append(event)
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        let lines = events.compactMap { try? JSONEncoder.diagnostics.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: eventsURL, options: .atomic)
    }

    private func loadEvents() -> [DiagnosticsEvent] {
        guard let text = try? String(contentsOf: eventsURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder.diagnostics.decode(DiagnosticsEvent.self, from: Data($0.utf8)) }
    }
}

extension JSONEncoder {
    static var diagnostics: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var diagnostics: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private final class MetricSubscriber: NSObject, MXMetricManagerSubscriber {
    private let receive: @MainActor ([MXDiagnosticPayload]) -> Void

    init(receive: @escaping @MainActor ([MXDiagnosticPayload]) -> Void) {
        self.receive = receive
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Task { @MainActor in receive(payloads) }
    }
}

/// Pings the main queue from a background timer and feeds `MainThreadStallDetector`.
final class MainThreadWatchdog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "linpad.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var detector = MainThreadStallDetector()
    private var pendingSince: TimeInterval?
    private let onEvent: (MainThreadStallDetector.Event, Date) -> Void
    static let interval: TimeInterval = 0.25

    init(onEvent: @escaping (MainThreadStallDetector.Event, Date) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            detector = MainThreadStallDetector()
            pendingSince = nil
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let event = detector.tick(now: now, pendingSince: pendingSince)
        if let event {
            let started = Date(timeIntervalSinceNow: -(now - (pendingSince ?? now)))
            onEvent(event, started)
        }
        if pendingSince == nil {
            pendingSince = now
            DispatchQueue.main.async { [weak self] in
                self?.queue.async { self?.pendingSince = nil }
            }
        }
    }
}
