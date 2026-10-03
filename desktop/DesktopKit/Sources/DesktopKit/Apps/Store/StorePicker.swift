import SwiftUI

/// The Store's curated collections as tickable cards, for onboarding's Apps step. Nothing is
/// ticked to begin with; installed apps show as installed.
struct StorePicker: View {
    let store: StoreModel
    @Binding var selection: Set<String>
    /// Collections shown, in order; nil shows all of them.
    var collectionIDs: [String]? = ["internet", "office", "graphics", "audio-video", "developer", "utilities", "games", "windows"]
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if store.index == nil {
                HStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in StoreSkeleton(cornerRadius: 12).frame(height: 64) }
                }
            }
            ForEach(sections, id: \.collection.id) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.collection.title.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(section.apps) { app in tile(app) }
                    }
                }
            }
        }
        .task { await store.start() }
    }

    /// Each app appears once, in the first collection that lists it.
    private var sections: [(collection: StoreCollection, apps: [StoreApp])] {
        guard let index = store.index else { return [] }
        var seen: Set<String> = []
        let collections = collectionIDs.map { ids in ids.compactMap { id in index.collections.first { $0.id == id } } } ?? index.collections
        return collections.compactMap { collection in
            let apps = store.apps(in: collection).filter { seen.insert($0.id).inserted }
            return apps.isEmpty ? nil : (collection, apps)
        }
    }

    private func tile(_ app: StoreApp) -> some View {
        let installed = store.isInstalled(app)
        let selected = selection.contains(app.id)
        return Button {
            guard !installed else { return }
            if selected { selection.remove(app.id) } else { selection.insert(app.id) }
        } label: {
            HStack(spacing: 10) {
                StoreAppIcon(app: app, size: 36, mediaBase: store.index?.mediaBase)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(theme.primaryText).lineLimit(1)
                    Text(subtitle(app, installed: installed))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: installed ? "checkmark.circle" : (selected ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: 18))
                    .foregroundStyle(installed ? theme.secondaryText : (selected ? theme.accent : theme.secondaryText.opacity(0.7)))
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? theme.accent.opacity(0.14) : theme.primaryText.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? theme.accent.opacity(0.7) : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(installed)
        .hoverEffect(.highlight)
        .accessibilityLabel(app.name)
        .accessibilityValue(installed ? "Installed" : (selected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("apps.toggle.\(app.id)")
    }

    private func subtitle(_ app: StoreApp, installed: Bool) -> String {
        if installed { return "Installed" }
        var parts: [String] = []
        if let mb = app.estimatedMB { parts.append("~" + StoreFormat.megabytes(mb)) }
        if app.compatibility != .untested { parts.append(app.compatibility.title) }
        else if let summary = app.summary { parts.append(summary) }
        return parts.joined(separator: " · ")
    }

    /// "3 selected · about 1.2 GB" (the apps' own estimates; dependencies are measured at install).
    static func summary(_ ids: Set<String>, store: StoreModel) -> String {
        let megabytes = ids.compactMap { store.app($0)?.estimatedMB }.reduce(0, +)
        return "\(ids.count) selected · about \(StoreFormat.megabytes(megabytes))"
    }
}

/// Settings › Apps: the Store's summary and the way into it.
struct StoreSettingsSection: View {
    let store: StoreModel
    let desktop: any DesktopActions
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        SettingsSection(title: "Apps", symbol: "bag") {
            HStack(spacing: 14) {
                Image(systemName: "bag.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.accent.readableLabel)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.accent))
                VStack(alignment: .leading, spacing: 3) {
                    Text("LinPad Store").font(.system(size: 15, weight: .semibold))
                    Text(status).font(.system(size: 12)).foregroundStyle(theme.secondaryText).lineLimit(2)
                }
                Spacer()
                ToolbarTextButton(title: "Open Store", symbol: "arrow.up.forward.app", prominent: true) {
                    desktop.open(appID: LinPadStoreApp.id, arguments: [:])
                }
                .accessibilityIdentifier("apps.openStore")
            }
            if let job = store.currentJob {
                HStack(spacing: 8) {
                    Text(job.title).font(.system(size: 12, weight: .medium))
                    StoreProgressBar(fraction: job.fraction).frame(height: 5)
                    Text(job.statusText).font(.system(size: 11).monospacedDigit()).foregroundStyle(theme.secondaryText).lineLimit(1)
                }
            }
            Text("Install real Linux apps from Alpine's repositories: nothing is preinstalled, so LinPad stays as small as what you choose.")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
        }
        .task { await store.start() }
    }

    private var status: String {
        let installed = store.installedApps.count
        let updates = store.outdated.count
        var parts = ["\(installed) app\(installed == 1 ? "" : "s") installed"]
        if updates > 0 { parts.append("\(updates) update\(updates == 1 ? "" : "s")") }
        if store.jobs.count > 0 { parts.append("\(store.jobs.count) in the queue") }
        return parts.joined(separator: " · ")
    }
}
