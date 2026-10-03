import DesktopKit
import UIKit

/// `LinuxHost` backed by the in-process iSH kernel. Every call spawns a fresh
/// `/bin/sh -c` child of init through `ISHShellExecutor`; terminals reuse the
/// classic `TerminalViewController`, each with its own pty and login shell.
///
/// On the first launch AppDelegate unpacks the bundled rootfs on a background thread and
/// boots the kernel afterwards (`AppDelegate.bootPhase()`); `preparation` mirrors that for
/// the desktop's boot splash. Commands and terminals wait until the kernel runs.
@MainActor
final class ISHLinuxHost: LinuxGraphicsHost, LinuxSystemPreparing, FastModeControlling {
    let homeDirectory = "/root"
    private(set) var hostName: String
    let preparation = LinuxSystemPreparation(phase: .unpacking)
    let fastMode = FastModeModel { AppDelegate.retryFastMode() }
    private var bootWaiters: [CheckedContinuation<Void, Never>] = []

    /// The fakefs keeps file contents in `<root>/data`, at their guest paths, which is
    /// what lets the Linux GUI bridge share frame buffers and FIFOs with the guest.
    var guestRootURL: URL? {
        guard bootFailure() == nil else { return nil }
        return Roots.instance().defaultRootUrl.appendingPathComponent("data", isDirectory: true)
    }

    var availableSystemUpdate: String? {
        let roots = Roots.instance()
        guard roots.pendingUpdate == nil else { return nil }
        return roots.availableUpdate
    }

    func scheduleSystemUpdate() {
        let roots = Roots.instance()
        roots.pendingUpdate = roots.availableUpdate
    }

    private var isBooted: Bool {
        let phase = AppDelegate.bootPhase()
        return phase == .running || phase == .failed
    }

    /// Returns once the kernel is running (or failed to boot).
    func waitForBoot() async {
        guard !isBooted else { return }
        await withCheckedContinuation { bootWaiters.append($0) }
    }

    private func bootStateChanged(_ phase: ISHBootPhase, fraction: Double, title: String, detail: String) {
        switch phase {
        case .unpacking:
            preparation.update(phase: .unpacking, fraction: fraction, title: title, detail: detail)
        case .configuring:
            // "Configuring…", or "Enabling fast mode via StikDebug…" while boot waits for it
            preparation.update(phase: .configuring, fraction: 1, title: title.isEmpty ? "Configuring…" : title,
                               detail: detail)
        case .running:
            let jit = AppDelegate.jitStatus()
            preparation.setEngine(jit == 1 ? .nativeJIT : .compatibility, jitCompiledIn: jit >= 0)
            preparation.update(phase: .ready, fraction: 1)
        case .failed:
            let reason = AppDelegate.bootFailureMessage() ?? "error \(AppDelegate.bootError())"
            preparation.update(phase: .failed(reason))
        @unknown default:
            break
        }
        if isBooted {
            let waiters = bootWaiters
            bootWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    // ISHShellExecutor caps argv at the kernel's ARGV_MAX; leave room for "/bin/sh -c".
    private static let maxInlineScriptBytes = 96 * 1024

    /// Mirrors AppDelegate's fast mode (StikDebug handoff) into the desktop.
    private func fastModeChanged() {
        let status: FastModeModel.Status
        switch AppDelegate.fastModeState() {
        case .enabling: status = .enabling
        case .on: status = .on(newProgramsOnly: AppDelegate.fastModeNewProgramsOnly())
        case .failed: status = .failed(AppDelegate.fastModeMessage() ?? "Fast mode could not be enabled.")
        default: status = .idle
        }
        fastMode.update(status: status, unavailableReason: AppDelegate.fastModeUnavailableReason())
        // Enabled after boot: new programs run on the JIT now.
        if case .on = status, isBooted, AppDelegate.jitStatus() == 1 {
            preparation.setEngine(.nativeJIT, jitCompiledIn: true)
        }
    }

    init() {
        hostName = UIDevice.current.name
        if let crashLog = Self.crashLogURL {
            try? FileManager.default.createDirectory(at: crashLog.deletingLastPathComponent(), withIntermediateDirectories: true)
            ish_log_set_crash_path(crashLog.path)
        }
        Self.excludeSystemFromDeviceBackup()
        AppDelegate.observeFastMode { [weak self] in
            MainActor.assumeIsolated { self?.fastModeChanged() }
        }
        AppDelegate.observeBoot { [weak self] phase, fraction, title, detail in
            MainActor.assumeIsolated {
                self?.bootStateChanged(phase, fraction: fraction, title: title ?? "", detail: detail ?? "")
            }
        }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.run("hostname")
            let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.succeeded && !name.isEmpty {
                self.hostName = name
            }
        }
    }

    func run(_ command: String, cwd: String?, stdin: Data?) async -> CommandResult {
        await execute(command, cwd: cwd, stdin: stdin, onLine: nil)
    }

    func stream(_ command: String, cwd: String?, onOutput: @escaping @MainActor (String) -> Void) async -> Int32 {
        let result = await execute(command, cwd: cwd, stdin: nil) { line, _ in
            MainActor.assumeIsolated {
                onOutput(line + "\n")
            }
        }
        if result.exitCode < 0 && !result.stderr.isEmpty {
            onOutput(result.stderr + "\n")
        }
        return result.exitCode
    }

    func makeTerminalViewController(command: String?, cwd: String?) -> UIViewController {
        guard let terminal = UIStoryboard(name: "Terminal", bundle: nil)
            .instantiateInitialViewController() as? TerminalViewController else {
            return TerminalUnavailableViewController(message: "Could not load the terminal.")
        }
        if let error = bootFailure() {
            return TerminalUnavailableViewController(message: error)
        }
        if !isBooted {
            // A restored terminal window can open while the rootfs is still unpacking.
            return PendingTerminalViewController(host: self, command: command, cwd: cwd)
        }
        terminal.embedded = true
        terminal.launchCommandOverride = Self.terminalLaunchCommand(command: command, cwd: cwd)
        terminal.startNewSession()
        return terminal
    }

    // MARK: - Execution

    private func execute(_ command: String, cwd: String?, stdin: Data?,
                         onLine: ISHShellLineCallback?) async -> CommandResult {
        await waitForBoot()
        if let error = bootFailure() {
            return CommandResult(stdout: "", stderr: error, exitCode: -1)
        }

        var script = command
        if let cwd {
            script = "cd \(cwd.shellQuoted) && {\n\(command)\n}"
        }

        if script.utf8.count > Self.maxInlineScriptBytes {
            let scriptPath = "/tmp/.desktop-script-\(UUID().uuidString)"
            let upload = await spawn("cat > \(scriptPath)", stdin: Data(script.utf8), onLine: nil)
            guard upload.succeeded else { return upload }
            script = "/bin/sh \(scriptPath); __status=$?; rm -f \(scriptPath); exit $__status"
        }

        return await spawn(script, stdin: stdin, onLine: onLine)
    }

    private func spawn(_ script: String, stdin: Data?, onLine: ISHShellLineCallback?) async -> CommandResult {
        // The trailing statement stops sh from exec'ing the last command in place. A guest
        // execve made right after ISHShellExecutor starts the task crashes the JIT (pc = 0
        // in fiber_enter) about half the time; forking first does not.
        let script = script + "\nexit $?"
        return await withCheckedContinuation { continuation in
            let pid = ISHShellExecutor.executeCommand(script, stdinData: stdin, lineCallback: onLine) { result in
                continuation.resume(returning: CommandResult(
                    stdout: result.output,
                    stderr: result.errorOutput,
                    exitCode: Self.exitStatus(fromWaitStatus: result.exitCode)))
            }
            if pid < 0 {
                continuation.resume(returning: CommandResult(
                    stdout: "", stderr: "Could not start /bin/sh (error \(pid))", exitCode: -1))
            }
        }
    }

    private func bootFailure() -> String? {
        let error = AppDelegate.bootError()
        guard error < 0 else { return nil }
        if let message = AppDelegate.bootFailureMessage() {
            return "Linux failed to boot: \(message)"
        }
        return "Linux failed to boot (error \(error))"
    }

    // MARK: - Helpers

    /// The kernel reports raw wait(2) statuses; convert to what a shell would show in `$?`.
    static func exitStatus(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// nil keeps the user's configured launch command (normally `login -f root`).
    /// Otherwise the window runs `command` and then stays usable as root's login shell.
    static func terminalLaunchCommand(command: String?, cwd: String?) -> [String]? {
        if command == nil && cwd == nil {
            return nil
        }
        // TerminalViewController only passes TERM, and login(1) is skipped here.
        var lines = [
            "export HOME=/root USER=root LOGNAME=root",
            "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "cd \((cwd ?? "/root").shellQuoted) 2>/dev/null || cd",
        ]
        if let command {
            lines.append(command)
        }
        lines.append(#"__shell=$(awk -F: '$1 == "root" { print $7 }' /etc/passwd 2>/dev/null)"#)
        lines.append(#"export SHELL="${__shell:-/bin/sh}"; unset __shell"#)
        // Run the shell as a child rather than exec'ing it; see the JIT note in spawn(_:stdin:onLine:).
        lines.append(#""$SHELL" -l"#)
        return ["/bin/sh", "-c", lines.joined(separator: "\n")]
    }
}

/// Stands in for a terminal until the kernel runs, then embeds the real one.
private final class PendingTerminalViewController: UIViewController {
    private let host: ISHLinuxHost
    private let command: String?
    private let cwd: String?

    init(host: ISHLinuxHost, command: String?, cwd: String?) {
        self.host = host
        self.command = command
        self.cwd = cwd
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .secondaryLabel
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        Task { [weak self] in
            guard let self else { return }
            await self.host.waitForBoot()
            spinner.removeFromSuperview()
            let terminal = self.host.makeTerminalViewController(command: self.command, cwd: self.cwd)
            self.addChild(terminal)
            terminal.view.frame = self.view.bounds
            terminal.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            self.view.addSubview(terminal.view)
            terminal.didMove(toParent: self)
        }
    }
}

private final class TerminalUnavailableViewController: UIViewController {
    private let message: String

    init(message: String) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let label = UILabel()
        label.text = message
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])
    }
}

/// iPad folders in the guest (Files: "Add iPad Folder…"), mounted with iOSFS, which keeps
/// their security-scoped bookmarks and mounts them again at boot.
extension ISHLinuxHost: HostDirectoryMounting {
    func mountHostDirectory(_ url: URL, at guestPath: String) throws {
        let err = iosfs_mount_url(url, guestPath)
        if err != 0 { throw HostMountError(code: err) }
    }

    func unmountHostDirectory(at guestPath: String) throws {
        let err = iosfs_unmount_point(guestPath)
        if err != 0 { throw HostMountError(code: err) }
    }

    var mountedHostDirectories: Set<String> {
        Set(iosfs_mount_bookmarks().keys)
    }
}

/// Linux system updates downloaded from GitHub releases (Settings › Updates) go through
/// Roots like the app's bundled system: installed at the next launch, user data kept.
extension ISHLinuxHost: LinuxSystemUpdating {
    var installedSystemVersion: String? {
        Roots.instance().installedRootVersion
    }

    var installableSystemVersion: String? {
        Roots.instance().availableUpdate
    }

    var scheduledSystemUpdate: String? {
        Roots.instance().pendingUpdate
    }

    func installDownloadedSystem(at archive: URL, version: String) throws {
        let roots = Roots.instance()
        try roots.storeDownloadedRootArchive(archive, version: version)
        roots.pendingUpdate = roots.availableUpdate
        roots.pendingRollback = nil
    }

    func backgroundDownloadEventsFinished() {
        AppDelegate.finishBackgroundURLSessionEvents()
    }
}

/// Settings › Updates › Roll Back System: Roots swaps the system kept from before the last
/// update back in before the next boot (AppDelegate.startBoot).
extension ISHLinuxHost: LinuxSystemRollingBack {
    var previousSystemVersion: String? {
        let roots = Roots.instance()
        return roots.previousRootName == nil ? nil : roots.previousRootVersion ?? "unversioned"
    }

    var isRollbackScheduled: Bool {
        Roots.instance().pendingRollback != nil
    }

    func scheduleRollback() throws {
        let roots = Roots.instance()
        guard let previous = roots.previousRootName else {
            throw NSError(domain: "iSH", code: Int(ENOENT),
                          userInfo: [NSLocalizedDescriptionKey: "There is no earlier system to roll back to."])
        }
        roots.pendingRollback = previous
        roots.pendingUpdate = nil
    }

    func cancelRollback() {
        Roots.instance().pendingRollback = nil
    }
}

extension ISHLinuxHost: FastModeDiagnosing {
    var hasGetTaskAllow: Bool {
        AppDelegate.fastModeHasGetTaskAllow()
    }
}

/// Settings › Maintenance › Reset to Factory: Roots replaces the default root before the
/// next boot (AppDelegate.startBoot), so the app closes itself to get there.
extension ISHLinuxHost: LinuxSystemResetting {
    var scheduledFactoryReset: FactoryResetMode? {
        Roots.instance().pendingFactoryReset.flatMap(FactoryResetMode.init(rawValue:))
    }

    func scheduleFactoryReset(_ mode: FactoryResetMode) {
        Roots.instance().pendingFactoryReset = mode.rawValue
        UserDefaults.standard.synchronize() // the app exits right after this
    }

    func cancelFactoryReset() {
        Roots.instance().pendingFactoryReset = nil
    }

    /// Goes to the Home Screen and exits there. With scenes UIKit may not call the app
    /// delegate's applicationDidEnterBackground (which ends an exitApp), hence the
    /// notification and, should neither arrive, the deadline.
    func quitToApplyFactoryReset() {
        DiagnosticsCenter.shared.markCleanExit()
        UserDefaults.standard.synchronize()
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { _ in exit(0) }
        (UIApplication.shared.delegate as? AppDelegate)?.exitApp()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }
}

/// Settings › Maintenance › Export Diagnostics reads the emulator's log rings directly, so
/// they are there even when Linux no longer answers (kernel/log_tail.h).
extension ISHLinuxHost: LinuxDiagnosticsProviding {
    static let crashLogURL: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Diagnostics/emulator-crash.txt")

    var emulatorCrashLogURL: URL? { Self.crashLogURL }

    func emulatorLog(diagnostic: Bool, maxBytes: Int) -> String {
        var buffer = [CChar](repeating: 0, count: maxBytes)
        let copied = buffer.withUnsafeMutableBufferPointer { pointer in
            ish_log_copy_tail(diagnostic ? ISH_LOG_RING_DIAGNOSTIC : ISH_LOG_RING_KERNEL, pointer.baseAddress, maxBytes, nil)
        }
        return String(decoding: buffer.prefix(copied).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The Linux system (2-3 GB, rebuilt from the app on a fresh install) stays out of the
    /// iPad's iCloud/Finder device backup; the user's own data is protected by LinPad's
    /// backups in Documents/Backups, which iPadOS does back up (backup-diagnostics-report.md).
    static func excludeSystemFromDeviceBackup() {
        let roots = Roots.instance().defaultRootUrl.deletingLastPathComponent()
        let container = roots.deletingLastPathComponent()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directories = [roots, container.appendingPathComponent("roots-staging"),
                           container.appendingPathComponent("system-update"), support.appendingPathComponent("linpad-updates")]
        for var directory in directories where FileManager.default.fileExists(atPath: directory.path) {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        }
    }
}
