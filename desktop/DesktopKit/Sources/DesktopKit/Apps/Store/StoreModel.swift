import Network
import SwiftUI

/// LinPad Store's state for one Linux host: the app index, what is installed, updates, and
/// the install queue. Every install, removal and update goes through `linpad-apps` in the
/// guest, one at a time (apk locks its database); onboarding, Settings and install links
/// share this model, so progress started anywhere shows everywhere.
@Observable @MainActor
final class StoreModel {
    private(set) var index: StoreIndex?
    private(set) var appsByID: [String: StoreApp] = [:]
    private(set) var featuredIDs: Set<String> = []
    /// Where `index` came from: the app's bundled copy, or the guest's (refreshed) one.
    private(set) var indexIsFromGuest = false
    private(set) var isRefreshingIndex = false
    private(set) var refreshError: String?

    /// nil until the guest answered `linpad-apps state`.
    private(set) var state: StoreInstallState?
    private(set) var stateError: String?
    private(set) var isLoadingState = false

    private(set) var updates: [StorePackageUpdate] = []
    private(set) var lastUpdateCheck: Date?
    private(set) var isCheckingUpdates = false
    private(set) var updatesError: String?

    private(set) var plans: [String: StorePlan] = [:]
    private(set) var loadingPlans: Set<String> = []

    /// The running job first, then the waiting ones.
    private(set) var jobs: [StoreJob] = []
    /// Finished, failed and cancelled jobs, newest first.
    private(set) var history: [StoreJob] = []
    /// The output of the running (or last) job.
    private(set) var log: [String] = []
    private(set) var isRefreshingIcons = false

    private(set) var isOffline = false

    /// Called after an install or removal so the launcher re-reads the guest's .desktop files.
    @ObservationIgnored var onAppsChanged: (@MainActor () async -> Void)?

    @ObservationIgnored let host: any LinuxHost
    @ObservationIgnored private var started = false
    @ObservationIgnored private var draining = false
    @ObservationIgnored private var iconsPending = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    private static let maxLogLines = 600
    private static let historyLimit = 20

    @ObservationIgnored private static var models: [ObjectIdentifier: StoreModel] = [:]

    static func shared(for host: any LinuxHost) -> StoreModel {
        let key = ObjectIdentifier(host)
        if let model = models[key] { return model }
        let model = StoreModel(host: host)
        models[key] = model
        return model
    }

    init(host: any LinuxHost, index: StoreIndex? = nil) {
        self.host = host
        if let index { setIndex(index, fromGuest: false) }
    }

    // MARK: Lookups

    var allApps: [StoreApp] { index?.apps ?? [] }

    func app(_ id: String) -> StoreApp? { appsByID[id] }

    func apps(in collection: StoreCollection) -> [StoreApp] {
        collection.apps.compactMap { appsByID[$0] }
    }

    func isInstalled(_ app: StoreApp) -> Bool {
        state?.isInstalled(app) ?? false
    }

    var installedApps: [StoreApp] {
        guard let state else { return [] }
        return allApps.filter(state.isInstalled).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var outdated: [(app: StoreApp, update: StorePackageUpdate)] {
        StoreUpdates.outdatedApps(allApps, state: state ?? .empty, updates: updates)
    }

    var otherUpdates: [StorePackageUpdate] {
        StoreUpdates.otherPackages(allApps, state: state ?? .empty, updates: updates)
    }

    func update(for app: StoreApp) -> StorePackageUpdate? {
        outdated.first { $0.app.id == app.id }?.update
    }

    /// The queued or running job that involves `appID`.
    func job(for appID: String) -> StoreJob? {
        jobs.first { $0.appIDs.contains(appID) }
    }

    var currentJob: StoreJob? { jobs.first { $0.phase != .queued } ?? jobs.first }

    var isBusy: Bool { !jobs.isEmpty }

    var indexDate: Date? { index?.generatedDate }

    func search(_ query: String) -> [StoreApp] {
        StoreSearch.results(query, in: allApps, featured: featuredIDs)
    }

    // MARK: Loading

    /// Loads the bundled index at once, then the guest's state and (if newer) its index.
    func start() async {
        guard !started else { return }
        started = true
        startMonitoringNetwork()
        loadBundledIndexIfNeeded()
        await loadState()
        await loadGuestIndexIfNewer()
    }

    func reload() async {
        await loadState()
        await loadGuestIndexIfNewer()
    }

    func loadState() async {
        guard !isLoadingState else { return }
        isLoadingState = true
        defer { isLoadingState = false }
        let result = await host.run("command -v linpad-apps >/dev/null || exit 127; linpad-apps state")
        guard result.succeeded, let decoded = Self.decodeLastLine(StoreInstallState.self, result.stdout) else {
            stateError = result.exitCode == 127 || result.stdout.contains("usage:") || result.stderr.contains("usage:")
                ? "This Linux system has an older app installer. Run Settings › Maintenance › Repair System, or update Linux, to install apps from the Store."
                : (result.stderr.isEmpty ? "Could not read the installed apps." : result.stderr)
            return
        }
        stateError = nil
        state = decoded
    }

    private func loadGuestIndexIfNewer() async {
        let stamps = await host.run(StoreIndexSource.stampCommand)
        guard let path = StoreIndexSource.newerGuestPath(stamps: stamps.stdout, than: index?.generated ?? "") else { return }
        guard let data = try? await host.readFile(path), let guest = StoreIndexSource.decode(data) else { return }
        setIndex(guest, fromGuest: true)
    }

    private func loadBundledIndexIfNeeded() {
        if index == nil, let bundled = StoreIndexSource.bundled() { setIndex(bundled, fromGuest: false) }
    }

    private func setIndex(_ index: StoreIndex, fromGuest: Bool) {
        self.index = index
        indexIsFromGuest = fromGuest
        appsByID = Dictionary(index.apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        featuredIDs = Set(index.collections.flatMap(\.apps) + index.hero.map(\.app))
    }

    /// `apk update`, then the guest rebuilds the index from the fresh repositories.
    func refreshIndex() async {
        guard !isRefreshingIndex else { return }
        isRefreshingIndex = true
        refreshError = nil
        defer { isRefreshingIndex = false }
        var output = ""
        let code = await host.stream("linpad-apps refresh-index 2>&1", cwd: nil) { output += $0 }
        if code != 0 {
            refreshError = output.split(separator: "\n").last.map(String.init) ?? "Refreshing the catalog failed (\(code))."
            return
        }
        await loadGuestIndexIfNewer()
        await checkUpdates()
    }

    func checkUpdates() async {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        let result = await host.run("linpad-apps updates")
        struct Listing: Decodable { let updates: [StorePackageUpdate] }
        guard result.succeeded, let listing = Self.decodeLastLine(Listing.self, result.stdout) else {
            updatesError = isOffline ? "You're offline. Connect to check for updates." : "Could not check for updates."
            return
        }
        updatesError = nil
        updates = listing.updates
        lastUpdateCheck = Date()
    }

    func loadPlan(_ appID: String) async {
        guard plans[appID] == nil, !loadingPlans.contains(appID), state != nil else { return }
        loadingPlans.insert(appID)
        defer { loadingPlans.remove(appID) }
        let result = await host.run("linpad-apps plan \(appID.shellQuoted)")
        struct Listing: Decodable { let plans: [StorePlan] }
        if let plan = Self.decodeLastLine(Listing.self, result.stdout)?.plans.first {
            plans[appID] = plan
        }
    }

    // MARK: Jobs

    func install(_ ids: [String]) {
        loadBundledIndexIfNeeded()
        let ids = ids.filter { id in appsByID[id].map { !isInstalled($0) } ?? true }
        for id in ids where job(for: id) == nil {
            enqueue(StoreJob(appIDs: [id], kind: .install, title: appsByID[id]?.name ?? id))
        }
    }

    func remove(_ id: String) {
        guard job(for: id) == nil else { return }
        plans[id] = nil
        enqueue(StoreJob(appIDs: [id], kind: .remove, title: appsByID[id]?.name ?? id))
    }

    /// Updates these apps, or with no ids every upgradable package.
    func update(_ ids: [String] = []) {
        let job = StoreJob(appIDs: ids, kind: .update,
                           title: ids.count == 1 ? (appsByID[ids[0]]?.name ?? ids[0]) : (ids.isEmpty ? "All updates" : "\(ids.count) apps"))
        guard !jobs.contains(where: { $0.id == job.id }) else { return }
        enqueue(job)
    }

    func cancel(_ jobID: String) {
        guard let position = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if jobs[position].phase == .queued {
            var job = jobs.remove(at: position)
            job.phase = .cancelled
            remember(job)
            return
        }
        guard jobs[position].phase.isCancellable else { return }
        jobs[position].cancelRequested = true
        jobs[position].message = "Cancelling…"
        Task { _ = await host.run("linpad-apps cancel") }
    }

    func clearHistory() {
        history.removeAll()
    }

    private func enqueue(_ job: StoreJob) {
        jobs.append(job)
        if !draining { Task { await drain() } }
    }

    private func drain() async {
        draining = true
        defer { draining = false }
        while let job = jobs.first {
            await run(job)
        }
        if iconsPending {
            iconsPending = false
            isRefreshingIcons = true
            _ = await host.run("linpad-apps refresh-icons")
            isRefreshingIcons = false
            NotificationCenter.default.post(name: .guestFilesChanged, object: nil)
        }
    }

    private func run(_ queued: StoreJob) async {
        var parser = StoreOutputParser()
        log.removeAll()
        // The icon cache is re-rendered once, after the queue drains, not after every app.
        let skipIcons = queued.kind != .update
        if skipIcons { iconsPending = true }
        let ids = queued.appIDs.map(\.shellQuoted).joined(separator: " ")
        let env = skipIcons ? "LINPAD_NO_ICON_REFRESH=1 " : ""
        let command = "\(env)linpad-apps \(queued.kind.verb) \(ids) 2>&1"
        mutateJob(queued.id) { $0.phase = queued.kind == .remove ? .removing : .resolving }
        let code = await host.stream(command, cwd: nil) { [weak self] chunk in
            guard let self else { return }
            self.appendLog(chunk)
            let events = parser.consume(chunk)
            self.mutateJob(queued.id) { job in events.forEach { job.apply($0) } }
        }
        let tail = parser.finish()
        mutateJob(queued.id) { job in
            tail.forEach { job.apply($0) }
            job.finish(exitCode: code)
        }
        if let index = jobs.firstIndex(where: { $0.id == queued.id }) {
            remember(jobs.remove(at: index))
        }
        for id in queued.appIDs { plans[id] = nil }
        await loadState()
        if queued.kind == .update { await checkUpdates() }
        NotificationCenter.default.post(name: .guestFilesChanged, object: nil)
        await onAppsChanged?()
    }

    private func mutateJob(_ jobID: String, _ change: (inout StoreJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        change(&jobs[index])
    }

    private func remember(_ job: StoreJob) {
        history.insert(job, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    private func appendLog(_ text: String) {
        log.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            .filter { !$0.hasPrefix("==> @") })
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
    }

    // MARK: Network

    private func startMonitoringNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in self?.isOffline = offline }
        }
        monitor.start(queue: DispatchQueue(label: "linpad.store.network"))
        pathMonitor = monitor
    }

    static func decodeLastLine<T: Decodable>(_ type: T.Type, _ output: String) -> T? {
        let line = output.split(separator: "\n").last { $0.hasPrefix("{") }.map(String.init) ?? ""
        return try? JSONDecoder().decode(T.self, from: Data(line.utf8))
    }
}
