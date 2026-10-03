import Foundation
import Observation
import OSLog
import UIKit

/// A backup file on this iPad (Documents/Backups, visible in the Files app).
struct BackupRecord: Identifiable, Equatable {
    let url: URL
    let size: Int64
    let date: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isAutomatic: Bool { BackupFiles.isAutomatic(name) }
}

/// Settings › Maintenance › Back Up and Restore: /root and /home (minus caches) plus the
/// desktop's own settings, wallpapers and calendar, in one tar file the user can keep in
/// Files, iCloud Drive or on a USB drive. One per host.
@Observable @MainActor
final class BackupService {
    enum BackupState: Equatable {
        case idle
        case scanning
        case ready
        /// `fraction` is nil while the file list is being made.
        case running(fraction: Double?, detail: String)
        case finished(BackupRecord, warnings: [String])
        case cancelled
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .scanning, .running: return true
            default: return false
            }
        }
    }

    enum RestoreState: Equatable {
        case idle
        case inspected(URL)
        case running(fraction: Double?, detail: String)
        case finished(RestoreSummary)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    struct RestoreSummary: Equatable {
        var restoredFiles = 0
        var movedAsideTo: String?
        var settingsRestored = false
        var reinstalled: [String] = []
        var reinstallPending: [String] = []
        var iPadFolders: [String] = []
        var warnings: [String] = []
    }

    struct RestoreOptions: Equatable {
        var mode: BackupRestoreMode = .merge
        var reinstallApps = true
        var restoreDesktopSettings = true
    }

    enum Keys {
        static let schedule = "backup.schedule"
        static let keep = "backup.keep"
        static let excluded = "backup.excludedCategories"
        static let lastBackup = "backup.lastDate"
    }

    /// Defaults keys that hold the desktop's look and set-up. The window layout, one-off
    /// flags and iPad-specific bookmarks are left out.
    static let settingsPrefixes = ["desktop.", "calendar.", "widgets.", "wallhaven.favorites", "fastMode.setting"]
    static let settingsExcluded: Set<String> = [
        "desktop.session", "desktop.debugAutomation", "desktop.onboarding.progress", "desktop.resetWidgets",
        "desktop.ipadPlaces", "desktop.performanceOverlay", "desktop.enabled",
    ]
    /// Application Support folders with the user's own desktop files.
    static let desktopFileFolders = ["Wallpapers", "Calendar"]
    static let defaultKeep = 2

    private(set) var state = BackupState.idle
    private(set) var scan: BackupScan?
    private(set) var backups: [BackupRecord] = []
    private(set) var restoreState = RestoreState.idle
    private(set) var inspected: BackupArchive.Contents?
    private(set) var restoreLog: [String] = []
    var excluded: Set<BackupExclusionCategory> {
        didSet { defaults.set(excluded.map(\.rawValue).sorted(), forKey: Keys.excluded) }
    }
    var schedule: BackupSchedule {
        didSet { defaults.set(schedule.rawValue, forKey: Keys.schedule) }
    }
    var keep: Int {
        didSet { defaults.set(keep, forKey: Keys.keep) }
    }
    var lastBackup: Date? { defaults.object(forKey: Keys.lastBackup) as? Date }
    var isBackupSheetRequested = false
    var isRestoreSheetRequested = false

    @ObservationIgnored var notify: ((String, DesktopToast.Action?) -> Void)?
    @ObservationIgnored var restartSession: (() async -> Void)?

    @ObservationIgnored private let host: any LinuxHost
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let backupsDirectory: URL
    @ObservationIgnored private let supportDirectory: URL
    @ObservationIgnored private let guestRoot: @MainActor () -> URL?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var currentWork: String?
    @ObservationIgnored private var scheduledTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    private static let logger = Logger(subsystem: "DesktopKit", category: "Backup")

    init(host: any LinuxHost, defaults: UserDefaults = .standard, backupsDirectory: URL? = nil,
         supportDirectory: URL? = nil, guestRoot: (@MainActor () -> URL?)? = nil, now: @escaping () -> Date = Date.init) {
        self.host = host
        self.defaults = defaults
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.backupsDirectory = backupsDirectory ?? documents.appendingPathComponent(BackupFiles.directoryName, isDirectory: true)
        self.supportDirectory = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.guestRoot = guestRoot ?? { [weak host] in (host as? LinuxGraphicsHost)?.guestRootURL }
        self.now = now
        let stored = defaults.array(forKey: Keys.excluded) as? [String]
        excluded = stored.map { Set($0.compactMap(BackupExclusionCategory.init(rawValue:))) } ?? BackupExclusionCategory.defaultExcluded
        schedule = defaults.string(forKey: Keys.schedule).flatMap(BackupSchedule.init(rawValue:)) ?? .weekly
        keep = max(1, defaults.object(forKey: Keys.keep) as? Int ?? Self.defaultKeep)
    }

    @ObservationIgnored private static var services: [ObjectIdentifier: BackupService] = [:]

    static func shared(for host: any LinuxHost) -> BackupService {
        let key = ObjectIdentifier(host)
        if let service = services[key] { return service }
        let service = BackupService(host: host)
        services[key] = service
        return service
    }

    var isAvailable: Bool { guestRoot() != nil }

    var mountPoints: [String] {
        (host as? HostDirectoryMounting).map { Array($0.mountedHostDirectories).sorted() } ?? []
    }

    // MARK: Listing

    func refreshBackups() {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: keys)) ?? []
        backups = urls.filter { BackupFiles.isBackup($0.lastPathComponent) }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return BackupRecord(url: url, size: Int64(values?.fileSize ?? 0),
                                date: values?.creationDate ?? values?.contentModificationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }
    }

    func delete(_ record: BackupRecord) {
        try? FileManager.default.removeItem(at: record.url)
        refreshBackups()
    }

    // MARK: Scan

    func refreshScan() async {
        guard !state.isBusy else { return }
        state = .scanning
        let result = await host.run(BackupGuestScript.invocation(["scan"] + BackupExclusionCategory.scanPrimaries))
        guard result.succeeded else {
            state = .failed("Could not measure /root and /home: \(result.failureDescription)")
            return
        }
        scan = BackupScan.parse(result.stdout)
        state = .ready
    }

    // MARK: Back up

    /// Makes a backup in Documents/Backups. Returns it, or nil when it failed or was cancelled.
    @discardableResult
    func backUp(automatic: Bool = false) async -> BackupRecord? {
        guard !state.isBusy else { return nil }
        guard let root = guestRoot() else {
            state = .failed("Backups need the Linux system to be running.")
            return nil
        }
        let started = now()
        let work = BackupGuestScript.workRoot + "/" + UUID().uuidString
        currentWork = work
        defer { currentWork = nil }
        state = .running(fraction: nil, detail: "Looking at your files…")
        if scan == nil {
            let result = await host.run(BackupGuestScript.invocation(["scan"] + BackupExclusionCategory.scanPrimaries))
            scan = result.succeeded ? BackupScan.parse(result.stdout) : BackupScan()
        }
        let scan = self.scan ?? BackupScan()
        let estimate = scan.includedBytes(excluding: excluded)
        if let free = Self.freeSpace(at: backupsDirectory.deletingLastPathComponent()), free < estimate * 6 / 10 + (200 << 20) {
            state = .failed("Not enough free space on the iPad for a backup of about \(Self.bytes(estimate)) (\(Self.bytes(free)) free).")
            return nil
        }
        let prepare = await host.run("rm -rf \(work.shellQuoted) && mkdir -p \(work.shellQuoted) && : > \(work.shellQuoted)/backup.tar && : > \(work.shellQuoted)/excludes")
        guard prepare.succeeded else {
            state = .failed("Could not prepare the backup in Linux: \(prepare.failureDescription)")
            return nil
        }
        defer { Task { [host] in _ = await host.run("rm -rf \(work.shellQuoted)") } }
        let archiveURL = Self.hostURL(root: root, guestPath: work + "/backup.tar")
        let excludes = BackupExclusionList.lines(candidates: scan.candidates, excluding: excluded, mountPoints: mountPoints)
        do {
            try Data((excludes.joined(separator: "\n") + "\n").utf8).write(to: Self.hostURL(root: root, guestPath: work + "/excludes"))
        } catch {
            state = .failed("Could not prepare the backup: \(error.localizedDescription)")
            return nil
        }

        let facts = BackupGuestFacts.parse(await host.run(BackupGuestScript.invocation(["facts"])).stdout)
        let listing = await host.run(BackupGuestScript.invocation(["list", work]))
        let fileCount = listing.stdout.split(separator: "\n").compactMap { line -> Int? in
            line.hasPrefix("@@files ") ? Int(line.dropFirst("@@files ".count)) : nil
        }.first
        guard listing.succeeded, let fileCount else {
            state = .failed("Could not list the files to back up: \(listing.failureDescription)")
            return nil
        }
        if case .cancelled = state { return nil }

        let compression: BackupManifest.Compression = facts.hasZstd ? .zstd : .gzip
        let desktop = collectDesktop()
        let manifest = BackupManifest(
            createdAt: started, appVersion: Self.appVersion, appBuild: Self.appBuild,
            rootfsVersion: facts.rootfsVersion, repairKitVersion: facts.repairKitVersion,
            excludedCategories: BackupExclusionCategory.allCases.filter(excluded.contains),
            compression: compression, contentBytes: estimate, fileCount: fileCount,
            packages: facts.world, appPacks: facts.installedPacks, iPadFolders: mountPoints,
            desktopFiles: desktop.files.map(\.relativePath), hasDesktopSettings: desktop.settings != nil,
            automatic: automatic)
        let headerOffset: UInt64
        do {
            let writer = try BackupArchiveWriter(url: archiveURL)
            try writer.add(name: BackupManifest.memberName, data: manifest.encoded(), mtime: started)
            if let settings = desktop.settings { try writer.add(name: BackupArchive.settingsMember, data: settings, mtime: started) }
            for file in desktop.files {
                try writer.add(name: BackupArchive.desktopFilesPrefix + file.relativePath, data: Data(contentsOf: file.url), mtime: file.modified)
            }
            try writer.reservePayloadHeader()
            headerOffset = writer.payloadHeaderOffset ?? 0
            try writer.close()
        } catch {
            state = .failed("Could not write the backup: \(error.localizedDescription)")
            return nil
        }

        state = .running(fraction: 0, detail: "Backing up \(fileCount.formatted()) files…")
        let progress = NameProgress(url: Self.hostURL(root: root, guestPath: work + "/names"), total: fileCount)
        let poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, case .running = self.state else { continue }
                let done = progress.poll()
                self.state = .running(fraction: progress.fraction,
                                      detail: "Backed up \(min(done, fileCount).formatted()) of \(fileCount.formatted()) files…")
            }
        }
        var lines = LineSplitter()
        var report = GuestReport()
        _ = await host.stream(BackupGuestScript.invocation(["archive", work, compression.rawValue]), cwd: nil) { chunk in
            for line in lines.feed(chunk) { report.consume(line) }
        }
        for line in lines.finish() { report.consume(line) }
        poller.cancel()
        if report.cancelled || state == .cancelled {
            state = .cancelled
            return nil
        }
        guard report.done else {
            state = .failed(report.failure ?? "The backup did not finish.")
            return nil
        }

        do {
            _ = try BackupArchiveWriter.finish(url: archiveURL, payloadName: compression.payloadName,
                                               headerOffset: headerOffset, mtime: started)
            try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
            let destination = backupsDirectory.appendingPathComponent(BackupFiles.fileName(for: started, automatic: automatic))
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: archiveURL, to: destination)
            defaults.set(started, forKey: Keys.lastBackup)
            if automatic { rotateAutomaticBackups() }
            refreshBackups()
            let record = backups.first { $0.url.lastPathComponent == destination.lastPathComponent }
                ?? BackupRecord(url: destination, size: 0, date: started)
            Self.logger.notice("backup done: \(record.size) bytes, \(fileCount) files, \(self.now().timeIntervalSince(started), format: .fixed(precision: 1)) s")
            state = .finished(record, warnings: report.warnings)
            return record
        } catch {
            state = .failed("Could not save the backup: \(error.localizedDescription)")
            return nil
        }
    }

    func cancelBackup() async {
        guard let work = currentWork, case .running = state else { return }
        state = .cancelled
        _ = await host.run(BackupGuestScript.invocation(["cancel", work]))
    }

    func resetBackupState() {
        if !state.isBusy { state = scan == nil ? .idle : .ready }
    }

    private func rotateAutomaticBackups() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backupsDirectory.path)) ?? []
        for name in BackupFiles.automaticBackupsToDelete(names, keep: keep) {
            try? FileManager.default.removeItem(at: backupsDirectory.appendingPathComponent(name))
        }
    }

    // MARK: Schedule

    /// Called when the desktop is up and whenever the app comes to the foreground: makes an
    /// automatic backup if one is due, after the app has stayed in front for a while.
    func runScheduledBackupIfDue(after delay: Duration = .seconds(120)) {
        guard scheduledTask == nil, schedule.isDue(lastBackup: lastBackup, now: now()), isAvailable else { return }
        scheduledTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            defer { self.scheduledTask = nil }
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active,
                  self.schedule.isDue(lastBackup: self.lastBackup, now: self.now()), !self.state.isBusy,
                  !self.restoreState.isRunning else { return }
            Self.logger.notice("scheduled backup starting")
            if let record = await self.backUp(automatic: true) {
                self.notify?("LinPad backed up your Linux files (\(Self.bytes(record.size))).", nil)
            } else if case .failed(let message) = self.state {
                self.notify?("The scheduled backup failed: \(message)", DesktopToast.Action(title: "Details") { [weak self] in
                    self?.isBackupSheetRequested = true
                })
            }
        }
    }

    /// Checks the schedule now and each time LinPad comes to the foreground.
    func startScheduling() {
        runScheduledBackupIfDue()
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.runScheduledBackupIfDue() }
        }
    }

    func cancelScheduledBackup() {
        scheduledTask?.cancel()
        scheduledTask = nil
    }

    // MARK: Restore

    func inspect(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            inspected = try BackupArchive.contents(of: url)
            restoreState = .inspected(url)
        } catch {
            inspected = nil
            restoreState = .failed(error.localizedDescription)
        }
    }

    func resetRestore() {
        guard !restoreState.isRunning else { return }
        inspected = nil
        restoreState = .idle
        restoreLog = []
    }

    func restore(from url: URL, options: RestoreOptions) async {
        guard !restoreState.isRunning, !state.isBusy, let contents = inspected else { return }
        guard let root = guestRoot() else {
            restoreState = .failed("Restoring needs the Linux system to be running.")
            return
        }
        cancelScheduledBackup()
        let manifest = contents.manifest
        var summary = RestoreSummary(iPadFolders: manifest.iPadFolders)
        restoreLog = []
        let work = BackupGuestScript.workRoot + "/" + UUID().uuidString
        restoreState = .running(fraction: nil, detail: "Copying the backup into Linux…")
        let prepare = await host.run("rm -rf \(work.shellQuoted) && mkdir -p \(work.shellQuoted) && : > \(work.shellQuoted)/backup.tar")
        guard prepare.succeeded else {
            restoreState = .failed("Could not prepare the restore in Linux: \(prepare.failureDescription)")
            return
        }
        defer { Task { [host] in _ = await host.run("rm -rf \(work.shellQuoted)") } }
        let staged = Self.hostURL(root: root, guestPath: work + "/backup.tar")
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: url, to: staged)
        } catch {
            restoreState = .failed("Could not read the backup file: \(error.localizedDescription)")
            return
        }

        restoreState = .running(fraction: 0, detail: "Restoring \(manifest.fileCount.formatted()) files…")
        let progress = NameProgress(url: Self.hostURL(root: root, guestPath: work + "/names"), total: manifest.fileCount)
        let poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, case .running = self.restoreState else { continue }
                let done = progress.poll()
                self.restoreState = .running(fraction: progress.fraction,
                                             detail: "Restored \(min(done, manifest.fileCount).formatted()) of \(manifest.fileCount.formatted()) files…")
            }
        }
        var lines = LineSplitter()
        var report = GuestReport()
        _ = await host.stream(BackupGuestScript.invocation([
            "restore", work + "/backup.tar", String(contents.payload.offset), String(contents.payload.size),
            manifest.compression.rawValue, options.mode.rawValue, work,
        ]), cwd: nil) { chunk in
            for line in lines.feed(chunk) { report.consume(line) }
        }
        for line in lines.finish() { report.consume(line) }
        poller.cancel()
        summary.restoredFiles = progress.poll()
        summary.warnings = report.warnings
        summary.movedAsideTo = report.aside
        guard report.done else {
            restoreState = .failed(report.failure ?? "The restore did not finish.")
            return
        }

        if options.restoreDesktopSettings {
            restoreState = .running(fraction: nil, detail: "Restoring desktop settings…")
            summary.settingsRestored = restoreDesktop(from: url, contents: contents, warnings: &summary.warnings)
        }
        if options.reinstallApps {
            restoreState = .running(fraction: nil, detail: "Reinstalling apps…")
            await reinstallApps(manifest, summary: &summary)
        }
        restoreState = .finished(summary)
        Self.logger.notice("restore done: \(summary.restoredFiles) files, mode \(options.mode.rawValue, privacy: .public)")
        if let restartSession {
            notify?("Restore finished. Restart the Linux desktop session so open apps see the restored files.",
                    DesktopToast.Action(title: "Restart Session") { Task { await restartSession() } })
        }
    }

    private func reinstallApps(_ manifest: BackupManifest, summary: inout RestoreSummary) async {
        let current = BackupGuestFacts.parse(await host.run(BackupGuestScript.invocation(["facts"])).stdout)
        let packages = BackupReinstallPlan.missingPackages(backup: manifest.packages, current: current.world)
        let packs = BackupReinstallPlan.missingPacks(backup: manifest.appPacks, current: current.installedPacks)
        guard !packages.isEmpty || !packs.isEmpty else { return }
        if !packages.isEmpty {
            let list = packages.joined(separator: "\n") + "\n"
            let write = await host.run("mkdir -p /etc/ish && cat >> /etc/ish/reinstall-packages", cwd: nil, stdin: Data(list.utf8))
            if !write.succeeded { summary.warnings.append("Could not note the packages to reinstall: \(write.failureDescription)") }
        }
        let ids = packs + (packages.isEmpty ? [] : ["reinstall"])
        let status = await host.stream("linpad-apps install " + ids.map(\.shellQuoted).joined(separator: " ") + " 2>&1", cwd: nil) { [weak self] chunk in
            self?.restoreLog.append(contentsOf: chunk.split(separator: "\n").map(String.init))
            if let count = self?.restoreLog.count, count > 400 { self?.restoreLog.removeFirst(count - 400) }
        }
        if status == 0 {
            summary.reinstalled = packs + packages
        } else {
            summary.reinstallPending = packs + packages
        }
    }

    // MARK: Desktop settings and files

    struct DesktopFile {
        let url: URL
        let relativePath: String
        let modified: Date
    }

    func collectDesktop() -> (settings: Data?, files: [DesktopFile]) {
        let values = defaults.dictionaryRepresentation().filter { key, _ in
            Self.settingsPrefixes.contains { key.hasPrefix($0) } && !Self.settingsExcluded.contains(key)
        }
        let settings = values.isEmpty ? nil : try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        var files: [DesktopFile] = []
        for folder in Self.desktopFileFolders {
            let base = supportDirectory.appendingPathComponent(folder, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard values?.isRegularFile == true else { continue }
                let relative = folder + "/" + url.path.dropFirst(base.path.count + 1)
                guard BackupManifest.isSafeRelativeFile(relative), (try? BackupArchive.splitName(BackupArchive.desktopFilesPrefix + relative)) != nil else { continue }
                files.append(DesktopFile(url: url, relativePath: relative, modified: values?.contentModificationDate ?? Date()))
            }
        }
        return (settings, files.sorted { $0.relativePath < $1.relativePath })
    }

    /// Puts the desktop's settings and files back. They take effect when LinPad next starts.
    private func restoreDesktop(from url: URL, contents: BackupArchive.Contents, warnings: inout [String]) -> Bool {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var restored = false
        if let member = contents.members.first(where: { $0.name == BackupArchive.settingsMember }) {
            do {
                let data = try BackupArchive.read(member, from: url)
                if let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    for (key, value) in values where Self.settingsPrefixes.contains(where: { key.hasPrefix($0) }) && !Self.settingsExcluded.contains(key) {
                        defaults.set(value, forKey: key)
                    }
                    restored = true
                }
            } catch {
                warnings.append("Desktop settings: \(error.localizedDescription)")
            }
        }
        for member in contents.members where member.name.hasPrefix(BackupArchive.desktopFilesPrefix) {
            let relative = String(member.name.dropFirst(BackupArchive.desktopFilesPrefix.count))
            guard BackupManifest.isSafeRelativeFile(relative),
                  Self.desktopFileFolders.contains(where: { relative.hasPrefix($0 + "/") }) else { continue }
            do {
                let destination = supportDirectory.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try BackupArchive.read(member, from: url, limit: 512 << 20).write(to: destination, options: .atomic)
                restored = true
            } catch {
                warnings.append("\(relative): \(error.localizedDescription)")
            }
        }
        return restored
    }

    // MARK: Helpers

    static func hostURL(root: URL, guestPath: String) -> URL {
        root.appendingPathComponent(String(guestPath.drop { $0 == "/" }))
    }

    static func freeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}

/// The "@@" lines of the guest script's archive and restore commands.
struct GuestReport: Equatable {
    var done = false
    var cancelled = false
    var failure: String?
    var aside: String?
    var warnings: [String] = []

    mutating func consume(_ line: String) {
        if line == "@@done" { done = true }
        else if line == "@@cancelled" { cancelled = true }
        else if line.hasPrefix("@@fail ") { failure = String(line.dropFirst("@@fail ".count)) }
        else if line.hasPrefix("@@aside ") { aside = String(line.dropFirst("@@aside ".count)) }
        else if line.hasPrefix("@@warn "), warnings.count < 20 { warnings.append(String(line.dropFirst("@@warn ".count))) }
    }
}

/// Counts the names tar has written so far (one per line) by reading the guest's file
/// directly, from where the last poll stopped.
final class NameProgress {
    private let url: URL
    private let total: Int
    private var offset: UInt64 = 0
    private(set) var count = 0

    init(url: URL, total: Int) {
        self.url = url
        self.total = total
    }

    var fraction: Double? {
        total > 0 ? min(1, Double(count) / Double(total)) : nil
    }

    @discardableResult
    func poll() -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return count }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            count += chunk.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
            offset += UInt64(chunk.count)
        }
        return count
    }
}
