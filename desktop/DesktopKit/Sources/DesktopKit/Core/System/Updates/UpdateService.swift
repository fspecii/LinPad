import Network
import Observation
import SwiftUI
import UIKit

/// Checks GitHub for new LinPad releases and Alpine for package upgrades, downloads Linux
/// system updates and hands them to the host's update path. One per host, shared by
/// Settings › Updates, Quick Settings and the notification center.
@Observable @MainActor
final class UpdateService {
    enum Channel: String, CaseIterable, Identifiable {
        case stable
        case prerelease

        var id: String { rawValue }
        var title: String { self == .stable ? "Stable" : "Pre-release" }
    }

    enum CheckState: Equatable {
        case idle
        case checking
        case failed(String)
    }

    enum DownloadState: Equatable {
        case idle
        case downloading(received: Int64, total: Int64)
        /// Stopped with resume data (network lost, app killed by the system).
        case paused(String)
        case verifying
        /// Downloaded, verified and scheduled for the next launch.
        case scheduled(version: String)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .downloading, .verifying: return true
            default: return false
            }
        }
    }

    enum PackageState: Equatable {
        case unknown
        case checking
        case upToDate
        case available([PackageUpdate])
        case upgrading
        case failed(String)
    }

    enum Keys {
        static let autoCheck = "linpad.updates.autoCheck"
        static let channel = "linpad.updates.channel"
        static let lastChecked = "linpad.updates.lastChecked"
        static let lastPackageCheck = "linpad.updates.lastPackageCheck"
        static let notifiedApp = "linpad.updates.notifiedAppVersion"
        static let notifiedSystem = "linpad.updates.notifiedSystemVersion"
        static let notifiedPackages = "linpad.updates.notifiedPackageCount"
        /// A file or URL to read releases from instead of the GitHub API (testing).
        static let feedURL = "linpad.updates.feedURL"
    }

    var autoCheck: Bool {
        didSet { defaults.set(autoCheck, forKey: Keys.autoCheck) }
    }
    var channel: Channel {
        didSet {
            defaults.set(channel.rawValue, forKey: Keys.channel)
            if channel != oldValue { Task { await checkNow() } }
        }
    }
    private(set) var lastChecked: Date?
    private(set) var lastPackageCheck: Date?
    private(set) var release: GitHubRelease?
    private(set) var offer = UpdateOffer.none
    private(set) var checkState = CheckState.idle
    private(set) var download = DownloadState.idle
    private(set) var packages = PackageState.unknown
    private(set) var packageLog: [String] = []
    private(set) var installedSystemVersion: String?
    private(set) var network = UpdateSchedule.Network.available
    let appVersion: String

    /// Shows a toast (and records it in the notification center); set by the desktop.
    @ObservationIgnored var notify: ((String, DesktopToast.Action?) -> Void)?
    /// Opens Settings › Updates; set by the desktop.
    @ObservationIgnored var showSettings: (() -> Void)?

    @ObservationIgnored private let host: any LinuxHost
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let client: ReleaseClient
    @ObservationIgnored private var downloader: SystemUpdateDownloader?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var lastProgressUpdate = Date.distantPast
    private static let maxLogLines = 400

    init(host: any LinuxHost, defaults: UserDefaults = .standard, appVersion: String? = nil) {
        self.host = host
        self.defaults = defaults
        self.appVersion = appVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        autoCheck = defaults.object(forKey: Keys.autoCheck) as? Bool ?? true
        channel = Channel(rawValue: defaults.string(forKey: Keys.channel) ?? "") ?? .stable
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
        lastPackageCheck = defaults.object(forKey: Keys.lastPackageCheck) as? Date
        let feed = defaults.string(forKey: Keys.feedURL).flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : URL(string: $0) }
        client = ReleaseClient(feedOverride: feed)
    }

    @ObservationIgnored private static var services: [ObjectIdentifier: UpdateService] = [:]

    static func shared(for host: any LinuxHost) -> UpdateService {
        let key = ObjectIdentifier(host)
        if let service = services[key] { return service }
        let service = UpdateService(host: host)
        services[key] = service
        return service
    }

    private var systemHost: (any LinuxSystemUpdating)? { host as? LinuxSystemUpdating }

    // MARK: Scheduling

    /// Starts network monitoring and the checks: one at launch (a conditional request, so
    /// usually a free 304), then every 30 min it looks whether a check is due. Safe to call
    /// more than once.
    func start() {
        guard schedule == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let network: UpdateSchedule.Network = path.status != .satisfied ? .offline
                : path.isConstrained ? .constrained : .available
            Task { @MainActor in self?.network = network }
        }
        monitor.start(queue: DispatchQueue(label: "linpad.updates.network"))
        self.monitor = monitor
        Task { await reattachDownload() }
        schedule = Task { [weak self] in
            // Let the path monitor report before the first check.
            try? await Task.sleep(for: .seconds(3))
            await self?.checkAtLaunch()
            while !Task.isCancelled {
                await self?.checkIfDue()
                await self?.checkPackagesIfDue()
                try? await Task.sleep(for: .seconds(1800))
            }
        }
    }

    func checkIfDue(now: Date = Date()) async {
        guard UpdateSchedule.shouldCheckAutomatically(enabled: autoCheck, lastCheck: lastChecked, now: now, network: network)
        else { return }
        await check(manual: false)
    }

    private func checkAtLaunch() async {
        guard autoCheck, network == .available else { return }
        await check(manual: false)
    }

    func checkNow() async {
        await check(manual: true)
    }

    private func check(manual: Bool) async {
        guard checkState != .checking else { return }
        guard UpdateSchedule.canCheckManually(network: network) else {
            checkState = .failed("No internet connection.")
            return
        }
        checkState = .checking
        await refreshInstalledSystemVersion()
        do {
            let allowsConstrained = manual
            let release = try await client.latestRelease(includePrereleases: channel == .prerelease,
                                                         allowsConstrainedNetwork: allowsConstrained)
            var manifest: RootfsManifest?
            if let release {
                manifest = try? await client.manifest(for: release, allowsConstrainedNetwork: allowsConstrained)
            }
            self.release = release
            offer = UpdateOffer.evaluate(release: release, manifest: manifest,
                                         appVersion: SemanticVersion(appVersion),
                                         installedSystem: installedSystemVersion,
                                         availableSystem: systemHost?.scheduledSystemUpdate ?? systemHost?.installableSystemVersion)
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Keys.lastChecked)
            checkState = .idle
            announce(manual: manual)
        } catch {
            checkState = .failed(error.localizedDescription)
        }
    }

    /// One toast per new version, so a 6-hourly check does not repeat itself.
    private func announce(manual: Bool) {
        if let app = offer.app, manual || defaults.string(forKey: Keys.notifiedApp) != app.version.description {
            defaults.set(app.version.description, forKey: Keys.notifiedApp)
            notify?("LinPad \(app.version) is available.", DesktopToast.Action(title: "Details") { [weak self] in
                self?.showSettings?()
            })
        }
        if let system = offer.system, download == .idle,
           manual || defaults.string(forKey: Keys.notifiedSystem) != system.manifest.version {
            defaults.set(system.manifest.version, forKey: Keys.notifiedSystem)
            notify?("A Linux system update (\(Self.megabytes(system.manifest.size))) is available. /root and /home are kept.",
                    DesktopToast.Action(title: "Download") { [weak self] in self?.downloadSystemUpdate() })
        }
        if manual, offer.app == nil, offer.system == nil, release != nil {
            notify?("LinPad is up to date.", nil)
        } else if manual, release == nil {
            notify?("No LinPad release has been published yet.", nil)
        }
    }

    private func refreshInstalledSystemVersion() async {
        if let systemHost {
            installedSystemVersion = systemHost.installedSystemVersion
            return
        }
        let result = await host.run("cat /usr/share/ish/rootfs-version 2>/dev/null")
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        installedSystemVersion = result.succeeded && !text.isEmpty ? text : nil
    }

    var scheduledSystemUpdate: String? {
        if case .scheduled(let version) = download { return version }
        return systemHost?.scheduledSystemUpdate
    }

    // MARK: Linux system download

    private func makeDownloader() -> SystemUpdateDownloader {
        if let downloader { return downloader }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linpad-updates", isDirectory: true)
        let identifier = (Bundle.main.bundleIdentifier ?? "linpad") + ".system-update"
        let downloader = SystemUpdateDownloader(identifier: identifier, directory: directory) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        self.downloader = downloader
        return downloader
    }

    private func reattachDownload() async {
        let downloader = makeDownloader()
        if await downloader.reattach() {
            download = .downloading(received: 0, total: downloader.resumableManifest?.size ?? 0)
        } else if downloader.resumableManifest != nil {
            download = .paused("The download was interrupted.")
        }
    }

    func downloadSystemUpdate() {
        guard let system = offer.system, !download.isActive else { return }
        download = .downloading(received: 0, total: system.manifest.size)
        makeDownloader().start(manifest: system.manifest, url: system.download)
        notify?("Downloading the Linux system update (\(Self.megabytes(system.manifest.size)))…", nil)
    }

    func resumeDownload() {
        let downloader = makeDownloader()
        if downloader.resume() {
            download = .downloading(received: 0, total: downloader.resumableManifest?.size ?? offer.system?.manifest.size ?? 0)
        } else {
            download = .idle
            downloadSystemUpdate()
        }
    }

    func cancelDownload() {
        downloader?.cancel()
        download = .idle
    }

    private func handle(_ event: SystemUpdateDownloader.Event) {
        switch event {
        case .progress(let received, let total):
            // Background sessions report often; a few redraws a second are enough.
            let now = Date()
            guard now.timeIntervalSince(lastProgressUpdate) > 0.25 || received == total else { return }
            lastProgressUpdate = now
            download = .downloading(received: received, total: total)
        case .finished(let file, let manifest):
            download = .verifying
            Task { await verifyAndInstall(file, manifest: manifest) }
        case .failed(let message, let resumable):
            download = resumable ? .paused(message) : .failed(message)
            notify?("The Linux system update download stopped: \(message)", resumable
                ? DesktopToast.Action(title: "Resume") { [weak self] in self?.resumeDownload() } : nil)
        case .cancelled:
            download = .idle
        case .backgroundEventsDelivered:
            systemHost?.backgroundDownloadEventsFinished()
        }
    }

    private func verifyAndInstall(_ file: URL, manifest: RootfsManifest) async {
        let matches = await Task.detached(priority: .userInitiated) {
            (try? FileDigest.matches(file, sha256: manifest.sha256)) ?? false
        }.value
        guard matches else {
            try? FileManager.default.removeItem(at: file)
            download = .failed("The download is damaged (SHA-256 does not match). Try again.")
            notify?("The Linux system update was damaged in transit and was discarded.", nil)
            return
        }
        guard let systemHost else {
            try? FileManager.default.removeItem(at: file)
            download = .failed("This build cannot install Linux system updates.")
            return
        }
        do {
            try systemHost.installDownloadedSystem(at: file, version: manifest.version)
            download = .scheduled(version: manifest.version)
            notify?("The Linux system update is ready. It installs the next time LinPad starts; /root and /home are kept.", nil)
        } catch {
            try? FileManager.default.removeItem(at: file)
            download = .failed(error.localizedDescription)
        }
    }

    // MARK: Alpine packages

    func checkPackagesIfDue(now: Date = Date()) async {
        guard UpdateSchedule.shouldCheckAutomatically(enabled: autoCheck, lastCheck: lastPackageCheck, now: now,
                                                      network: network, interval: UpdateSchedule.packageInterval)
        else { return }
        await checkPackages(manual: false)
    }

    func checkPackages(manual: Bool = true) async {
        switch packages {
        case .checking, .upgrading: return
        default: break
        }
        guard UpdateSchedule.canCheckManually(network: network) else {
            packages = .failed("No internet connection.")
            return
        }
        packages = .checking
        let result = await host.run(ApkCommands.listUpgrades)
        lastPackageCheck = Date()
        defaults.set(lastPackageCheck, forKey: Keys.lastPackageCheck)
        guard result.succeeded else {
            packages = .failed(result.stderr.isEmpty ? result.stdout.trimmedWhitespace : result.stderr.trimmedWhitespace)
            return
        }
        let updates = ApkCommands.parseUpgradable(result.stdout)
        packages = updates.isEmpty ? .upToDate : .available(updates)
        if !updates.isEmpty, manual || defaults.integer(forKey: Keys.notifiedPackages) != updates.count {
            defaults.set(updates.count, forKey: Keys.notifiedPackages)
            notify?("Linux packages: \(updates.count) update\(updates.count == 1 ? "" : "s") available.",
                    DesktopToast.Action(title: "Details") { [weak self] in self?.showSettings?() })
        }
    }

    func upgradePackages() async {
        if case .upgrading = packages { return }
        packages = .upgrading
        packageLog = []
        let status = await host.stream(ApkCommands.upgrade, cwd: nil) { [weak self] chunk in
            guard let self else { return }
            self.packageLog.append(contentsOf: chunk.split(whereSeparator: \.isNewline).map(String.init))
            if self.packageLog.count > Self.maxLogLines {
                self.packageLog.removeFirst(self.packageLog.count - Self.maxLogLines)
            }
        }
        if status == 0 {
            notify?("Linux packages are up to date.", nil)
            packages = .upToDate
            defaults.set(0, forKey: Keys.notifiedPackages)
        } else {
            packages = .failed("apk upgrade failed (exit \(status)). See the log below.")
        }
    }

    // MARK: Installing the app update

    enum Sideloader: String, CaseIterable, Identifiable {
        case sideStore = "sidestore"
        case altStore = "altstore"

        var id: String { rawValue }
        var name: String { self == .sideStore ? "SideStore" : "AltStore" }

        /// Installs (or updates) the IPA at `ipa`.
        func installURL(ipa: URL) -> URL? {
            URL(string: "\(rawValue)://install?url=\(Self.escape(ipa.absoluteString))")
        }

        /// Adds LinPad's source, which then updates the app automatically.
        var addSourceURL: URL? {
            URL(string: "\(rawValue)://source?url=\(Self.escape(LinPadProject.sourceURL.absoluteString))")
        }

        private static func escape(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? text
        }

        /// Needs the scheme in LSApplicationQueriesSchemes (app/Info.plist).
        @MainActor var isInstalled: Bool {
            URL(string: "\(rawValue)://").map(UIApplication.shared.canOpenURL) ?? false
        }
    }

    var installedSideloaders: [Sideloader] { Sideloader.allCases.filter(\.isInstalled) }

    func update(with sideloader: Sideloader) {
        let url = offer.app?.release.appAsset.flatMap { sideloader.installURL(ipa: $0.downloadURL) } ?? sideloader.addSourceURL
        if let url { UIApplication.shared.open(url) }
    }

    func addSource(to sideloader: Sideloader) {
        if let url = sideloader.addSourceURL { UIApplication.shared.open(url) }
    }

    func openReleasePage() {
        UIApplication.shared.open(offer.app?.release.pageURL ?? release?.pageURL ?? LinPadProject.releasesPage)
    }

    static func megabytes(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_048_576).rounded())) MB"
    }
}
