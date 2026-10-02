import SwiftUI

/// One optional app from the guest's catalog (/usr/share/linpad/catalog.json, listed by
/// `linpad-apps list --json`). Nothing in it ships preinstalled.
struct CatalogPack: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let category: String
    let sizeMB: Int
    var recommended: Bool?
    var experimental: Bool?
    var installed: Bool?

    var isInstalled: Bool { installed ?? false }

    var symbol: String {
        switch category {
        case "Mail": "envelope"
        case "Office": "doc.text"
        case "Graphics": "photo"
        case "Utilities": "archivebox"
        case "Development": "chevron.left.forwardslash.chevron.right"
        case "Multimedia": "play.rectangle"
        case "Internet": "globe"
        default: "shippingbox"
        }
    }

    var sizeText: String {
        sizeMB >= 1000 ? String(format: "~%.1f GB", Double(sizeMB) / 1000) : "~\(sizeMB) MB"
    }
}

/// The guest's optional-apps catalog with installed state, and installs and removals
/// through `linpad-apps`, streaming its log. One model per host, shared by onboarding and
/// Settings › Apps, so an install started in one shows its progress in the other.
@Observable @MainActor
final class AppCatalogModel {
    private(set) var packs: [CatalogPack] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    /// Nil when the catalog loaded; otherwise why it did not (e.g. an older Linux system).
    private(set) var unavailableReason: String?
    /// The pack ids an install or removal is running for, and what it is doing.
    private(set) var busy: [String: String] = [:]
    /// The latest "==>" progress line, and the full log of the current operation.
    private(set) var status = ""
    private(set) var log: [String] = []
    private(set) var lastFailure: String?

    @ObservationIgnored private let host: any LinuxHost
    @ObservationIgnored private var queue: [(ids: [String], remove: Bool)] = []
    @ObservationIgnored private var running = false
    private static let maxLogLines = 400

    private init(host: any LinuxHost) {
        self.host = host
    }

    @ObservationIgnored private static var models: [ObjectIdentifier: AppCatalogModel] = [:]

    static func shared(for host: any LinuxHost) -> AppCatalogModel {
        let key = ObjectIdentifier(host)
        if let model = models[key] { return model }
        let model = AppCatalogModel(host: host)
        models[key] = model
        return model
    }

    var categories: [String] {
        var seen: [String] = []
        for pack in packs where !seen.contains(pack.category) { seen.append(pack.category) }
        return seen
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let result = await host.run("command -v linpad-apps >/dev/null || exit 127; linpad-apps list --json")
        hasLoaded = true
        guard result.succeeded else {
            unavailableReason = result.exitCode == 127
                ? "This Linux system has no app catalog yet. Update Linux (Settings › About) to get it."
                : (result.stderr.isEmpty ? "Could not read the app catalog." : result.stderr)
            return
        }
        struct Listing: Decodable { let packs: [CatalogPack] }
        let line = result.stdout.split(separator: "\n").last.map(String.init) ?? ""
        guard let listing = try? JSONDecoder().decode(Listing.self, from: Data(line.utf8)) else {
            unavailableReason = "The app catalog could not be read."
            return
        }
        unavailableReason = nil
        packs = listing.packs
    }

    func install(_ ids: [String]) {
        enqueue(ids.filter { id in !(packs.first { $0.id == id }?.isInstalled ?? false) }, remove: false)
    }

    func remove(_ id: String) {
        enqueue([id], remove: true)
    }

    private func enqueue(_ ids: [String], remove: Bool) {
        let ids = ids.filter { busy[$0] == nil }
        guard !ids.isEmpty else { return }
        for id in ids { busy[id] = remove ? "Waiting to remove…" : "Waiting to install…" }
        queue.append((ids, remove))
        if !running { Task { await drain() } }
    }

    /// One `linpad-apps` at a time: apk holds a lock on its database.
    private func drain() async {
        running = true
        defer { running = false }
        while !queue.isEmpty {
            let job = queue.removeFirst()
            for id in job.ids { busy[id] = job.remove ? "Removing…" : "Installing…" }
            log.removeAll()
            lastFailure = nil
            let verb = job.remove ? "remove" : "install"
            let code = await host.stream("linpad-apps \(verb) \(job.ids.joined(separator: " ")) 2>&1", cwd: nil) { [weak self] text in
                self?.append(text)
            }
            if code != 0 {
                lastFailure = status.isEmpty ? "linpad-apps \(verb) failed (\(code))" : status
            }
            for id in job.ids { busy[id] = nil }
            await load()
        }
        status = ""
    }

    private func append(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)
            log.append(line)
            if line.hasPrefix("==> ") {
                status = String(line.dropFirst(4))
                for (id, _) in busy where status.localizedCaseInsensitiveContains(name(of: id)) {
                    busy[id] = status
                }
            }
        }
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
    }

    private func name(of id: String) -> String {
        packs.first { $0.id == id }?.name ?? id
    }
}

/// The catalog as a list: checkboxes in onboarding (`selection`), install and remove
/// buttons in Settings › Apps (`selection == nil`).
struct AppCatalogList: View {
    @Environment(\.desktopTheme) private var theme
    let catalog: AppCatalogModel
    var selection: Binding<Set<String>>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let reason = catalog.unavailableReason {
                Text(reason).font(.callout).foregroundStyle(theme.secondaryText)
            } else if !catalog.hasLoaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the app catalog…").font(.callout).foregroundStyle(theme.secondaryText)
                }
            }
            ForEach(catalog.categories, id: \.self) { category in
                Text(category.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.top, 2)
                ForEach(catalog.packs.filter { $0.category == category }) { pack in
                    row(pack)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ pack: CatalogPack) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: pack.symbol)
                .frame(width: 22)
                .foregroundStyle(theme.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pack.name).font(.system(size: 14, weight: .medium))
                    if pack.recommended == true {
                        tag("Recommended", color: theme.accent)
                    }
                    if pack.experimental == true {
                        tag("Experimental", color: .orange)
                    }
                }
                Text(pack.description)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let state = catalog.busy[pack.id] {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(state).font(.system(size: 11)).foregroundStyle(theme.secondaryText).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            Text(pack.sizeText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(theme.secondaryText)
                .padding(.top, 2)
            control(pack)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("apps.pack.\(pack.id)")
    }

    @ViewBuilder
    private func control(_ pack: CatalogPack) -> some View {
        if let selection {
            if pack.isInstalled {
                Text("Installed").font(.system(size: 12)).foregroundStyle(theme.secondaryText)
            } else {
                Toggle("", isOn: Binding(
                    get: { selection.wrappedValue.contains(pack.id) },
                    set: { on in
                        if on { selection.wrappedValue.insert(pack.id) } else { selection.wrappedValue.remove(pack.id) }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(pack.name)
                    .accessibilityIdentifier("apps.toggle.\(pack.id)")
            }
        } else if catalog.busy[pack.id] != nil {
            EmptyView()
        } else if pack.isInstalled {
            ToolbarTextButton(title: "Remove", symbol: "trash") { catalog.remove(pack.id) }
                .accessibilityIdentifier("apps.remove.\(pack.id)")
        } else {
            ToolbarTextButton(title: "Install", symbol: "arrow.down.circle", prominent: true) { catalog.install([pack.id]) }
                .accessibilityIdentifier("apps.install.\(pack.id)")
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().stroke(color.opacity(0.6), lineWidth: 1))
    }
}

/// Settings › Apps: the catalog with install and remove buttons, and the log of the
/// running operation.
struct AppsSettingsSection: View {
    @Environment(\.desktopTheme) private var theme
    let catalog: AppCatalogModel
    @State private var showsLog = false

    var body: some View {
        SettingsSection(title: "Apps", symbol: "square.grid.2x2", trailing: {
            if catalog.isLoading {
                ProgressView().controlSize(.small)
            } else {
                ToolbarIconButton("arrow.clockwise", help: "Refresh") { Task { await catalog.load() } }
            }
        }) {
            Text("Optional apps for LinPad. Nothing here is preinstalled; sizes are what the app adds to the Linux system.")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
            if let failure = catalog.lastFailure {
                InlineBanner(kind: .error, message: failure)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            AppCatalogList(catalog: catalog)
            if !catalog.log.isEmpty {
                ThemedSeparator()
                DisclosureGroup(isExpanded: $showsLog) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(catalog.log.joined(separator: "\n"))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            Color.clear.frame(height: 1).id("end")
                        }
                        .frame(height: 160)
                        .onChange(of: catalog.log.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                    }
                } label: {
                    Text(catalog.status.isEmpty ? "Log" : catalog.status)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .accessibilityIdentifier("apps.log")
            }
        }
        .task { if !catalog.hasLoaded { await catalog.load() } }
    }
}
