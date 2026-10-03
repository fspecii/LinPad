import Foundation
import Observation
import OSLog

/// How "Reset to Factory" treats the user's data.
public enum FactoryResetMode: String, CaseIterable, Identifiable, Sendable {
    /// A fresh system; /root and /home (and the iPad folders added in Files) are kept.
    case keepFiles = "keep-files"
    /// A fresh system and nothing else: /root, /home and the iPad folder list are gone.
    case eraseEverything = "erase"

    public var id: String { rawValue }
}

/// Optional host capability: replace the whole Linux system with the one the app ships.
/// The root filesystem is in use while Linux runs, so the reset is scheduled and done at
/// the next launch, before boot (app/Roots.m), and the app closes itself to get there.
@MainActor
public protocol LinuxSystemResetting: AnyObject {
    var scheduledFactoryReset: FactoryResetMode? { get }
    func scheduleFactoryReset(_ mode: FactoryResetMode)
    func cancelFactoryReset()
    /// Closes the app; the reset runs when it is opened again.
    func quitToApplyFactoryReset()
}

/// Settings › Maintenance: "Repair System" (re-applies the bundled repair kit in the
/// guest, keeping all user data), the silent repair after an app update, and scheduling
/// "Reset to Factory". One per host.
@Observable @MainActor
final class SystemMaintenanceService {
    enum RepairState: Equatable {
        case idle
        case running(automatic: Bool)
        case finished(automatic: Bool)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    enum Keys {
        /// Settings app (app/Settings.bundle): repair once at the next launch.
        static let repairAtLaunch = "linux.repairAtLaunch"
    }

    private(set) var state = RepairState.idle
    private(set) var report = RepairReport()
    private(set) var log: [String] = []
    private(set) var installedKitVersion: String?
    /// Shown by Settings › Maintenance; set by the Command Menu.
    var isRepairSheetRequested = false
    var isResetSheetRequested = false

    @ObservationIgnored var notify: ((String, DesktopToast.Action?) -> Void)?
    @ObservationIgnored var restartSession: (() async -> Void)?
    @ObservationIgnored var showSettings: (() -> Void)?

    @ObservationIgnored private let host: any LinuxHost
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let kit: RepairKit?
    @ObservationIgnored private var startedAutomaticCheck = false
    @ObservationIgnored private var splitter = LineSplitter()
    private static let logger = Logger(subsystem: "DesktopKit", category: "Maintenance")
    private static let maxLogLines = 600
    private static let guestKitDirectory = "/tmp/linpad-repair-kit"

    init(host: any LinuxHost, kit: RepairKit? = RepairKit.bundled(), defaults: UserDefaults = .standard) {
        self.host = host
        self.kit = kit
        self.defaults = defaults
    }

    @ObservationIgnored private static var services: [ObjectIdentifier: SystemMaintenanceService] = [:]

    static func shared(for host: any LinuxHost) -> SystemMaintenanceService {
        let key = ObjectIdentifier(host)
        if let service = services[key] { return service }
        let service = SystemMaintenanceService(host: host)
        services[key] = service
        return service
    }

    var resetter: (any LinuxSystemResetting)? { host as? LinuxSystemResetting }
    var linuxHost: any LinuxHost { host }

    // MARK: Repair

    func refreshInstalledKitVersion() async {
        let result = await host.run("cat \(RepairKit.installedVersionPath) 2>/dev/null")
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        installedKitVersion = result.succeeded && !text.isEmpty ? text : nil
    }

    /// After boot: repairs silently once when the app bundles a newer kit than the guest
    /// last applied (an app update), or when the Settings app asked for a repair.
    func runAutomaticRepairIfNeeded() async {
        guard !startedAutomaticCheck, let kit else {
            if kit == nil { Self.logger.notice("no repair kit in this build") }
            return
        }
        startedAutomaticCheck = true
        await refreshInstalledKitVersion()
        let requested = defaults.bool(forKey: Keys.repairAtLaunch)
        Self.logger.notice("repair kit \(kit.manifest.version, privacy: .public), guest has \(self.installedKitVersion ?? "none", privacy: .public), requested \(requested)")
        if requested {
            defaults.set(false, forKey: Keys.repairAtLaunch)
            isRepairSheetRequested = true
            showSettings?()
            await repair(automatic: false)
        } else if RepairKitVersion.isNewer(kit.manifest.version, than: installedKitVersion) {
            await repair(automatic: true)
        }
    }

    /// Unpacks the kit in the guest and runs linpad-repair as root, streaming its log.
    /// A manual repair restarts the Linux session when something changed, so running apps
    /// pick up the repaired files; the silent one only tells the user.
    func repair(automatic: Bool) async {
        guard !state.isRunning else { return }
        guard let kit else {
            state = .failed("This build of LinPad has no repair kit.")
            return
        }
        state = .running(automatic: automatic)
        report = RepairReport()
        log = []
        let archive: Data
        do {
            archive = try kit.verifiedArchive()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let directory = Self.guestKitDirectory
        appendLog("Unpacking the repair kit \(kit.manifest.version)…")
        let unpack = await host.run("rm -rf \(directory) && mkdir -p \(directory) && tar -xf - -C \(directory)",
                                    cwd: nil, stdin: archive)
        guard unpack.succeeded else {
            state = .failed("Could not unpack the repair kit in Linux: \(unpack.failureDescription)")
            return
        }
        splitter = LineSplitter()
        let flags = automatic ? " --quick" : ""
        let status = await host.stream("sh \(directory)/\(kit.manifest.entry)\(flags) 2>&1; status=$?; rm -rf \(directory); exit $status",
                                       cwd: nil) { [weak self] chunk in
            guard let self else { return }
            for line in self.splitter.feed(chunk) { self.handle(line) }
        }
        for line in splitter.finish() { handle(line) }
        if report.succeeded == nil {
            report.succeeded = false
            if report.failures.isEmpty { report.failures.append("linpad-repair exited with status \(status)") }
        }
        await refreshInstalledKitVersion()
        Self.logger.notice("repair finished: ok \(self.report.succeeded == true), changes \(self.report.changes), status \(status)")
        state = .finished(automatic: automatic)
        await finish(automatic: automatic)
    }

    private func finish(automatic: Bool) async {
        let report = self.report
        if automatic {
            guard report.succeeded == false || report.changes > 0 else { return }
            let message = report.succeeded == true
                ? "LinPad repaired the Linux system after the update (\(report.changes) change\(report.changes == 1 ? "" : "s")). Restart Firefox and other Linux apps to use them."
                : "LinPad could not finish repairing the Linux system after the update."
            notify?(message, DesktopToast.Action(title: "Details") { [weak self] in
                self?.isRepairSheetRequested = true
                self?.showSettings?()
            })
            return
        }
        if report.succeeded == true, report.changes > 0, let restartSession {
            appendLog("Restarting the Linux session so the repaired files take effect…")
            await restartSession()
        }
    }

    private func handle(_ line: String) {
        if !report.consume(line) { appendLog(line) }
        else if line.hasPrefix("@@step ") { appendLog("— \(report.currentStep ?? "")") }
        else if line.hasPrefix("@@fail ") || line.hasPrefix("@@note ") { appendLog(String(line.dropFirst(2))) }
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
    }

    // MARK: Factory reset

    func resetToFactory(_ mode: FactoryResetMode) {
        guard let resetter else { return }
        resetter.scheduleFactoryReset(mode)
        resetter.quitToApplyFactoryReset()
    }
}
