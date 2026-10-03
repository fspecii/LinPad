import SwiftUI

// MARK: - Home

struct StoreHomePage: View {
    let model: StoreModel
    let nav: StoreNavigation
    var onOpen: (StoreApp) -> Void
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let hero = model.index?.hero, !hero.isEmpty {
                    StoreHeroCarousel(heroes: hero, model: model, nav: nav, onOpen: onOpen)
                }
                ForEach(model.index?.collections ?? []) { collection in
                    let apps = model.apps(in: collection)
                    if !apps.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            StoreSectionHeader(title: collection.title, subtitle: collection.subtitle,
                                               actionTitle: apps.count > 4 ? "See all" : nil) { nav.show(.collection(collection.id)) }
                                .padding(.horizontal, 20)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 12) {
                                    ForEach(apps) { app in
                                        StoreAppCard(app: app, model: model, onSelect: { nav.show(.app($0.id)) }, onOpen: onOpen)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 2)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("store.collection.\(collection.id)")
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    StoreSectionHeader(title: "Browse by category")
                    StoreCategoryGrid(model: model, nav: nav)
                }
                .padding(.horizontal, 20)
                Text("Apps come from Alpine Linux \(model.index?.branch ?? "") (main and community), descriptions and screenshots from AppStream and Flathub. \(model.allApps.count) apps.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 20)
            }
            .padding(.vertical, 20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("store.home")
    }
}

struct StoreHeroCarousel: View {
    let heroes: [StoreHero]
    let model: StoreModel
    let nav: StoreNavigation
    var onOpen: (StoreApp) -> Void
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 14) {
                ForEach(heroes) { hero in
                    if let app = model.app(hero.app) {
                        card(hero, app: app)
                            .containerRelativeFrame(.horizontal) { width, _ in max(320, min(width - 40, 860)) }
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
        }
        .scrollTargetBehavior(.viewAligned)
        .frame(height: 230)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("store.hero")
    }

    private func card(_ hero: StoreHero, app: StoreApp) -> some View {
        let tint = hero.tint.flatMap(RGB.init(hex:))?.color ?? theme.accent
        return ZStack(alignment: .leading) {
            LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
            // The screenshot only when the banner is wide enough to keep it clear of the text.
            GeometryReader { proxy in
            if proxy.size.width >= 680, let shot = app.screenshots?.first, let base = model.index?.mediaBase {
                HStack {
                    Spacer()
                    StoreRemoteImage(url: shot.url.hasPrefix("https://") ? URL(string: shot.url) : URL(string: base + "/" + shot.url), contentMode: .fill) { Color.clear }
                        .frame(width: 340, height: 212)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                        .rotationEffect(.degrees(-3))
                        .offset(x: 40, y: 34)
                        .accessibilityHidden(true)
                }
            }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    StoreAppIcon(app: app, size: 44, mediaBase: model.index?.mediaBase)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.18)))
                    Text(app.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                }
                Text(hero.title)
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(hero.subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    StoreActionButton(app: app, model: model, onOpen: onOpen)
                        .environment(\.desktopTheme, heroTheme)
                    if app.compatibility != .untested { StoreCompatBadge(compatibility: app.compatibility, compact: true).colorScheme(.dark) }
                }
            }
            .frame(maxWidth: 380, alignment: .leading)
            .padding(22)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { nav.show(.app(app.id)) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("store.hero.\(app.id)")
    }

    /// Buttons on the coloured banner stay white-on-dark in every theme.
    private var heroTheme: DesktopTheme {
        var hero = theme
        hero.accent = .white
        hero.primaryText = .white
        return hero
    }
}

// MARK: - Categories

struct StoreCategoryGrid: View {
    let model: StoreModel
    let nav: StoreNavigation
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
            ForEach(model.index?.categories ?? [], id: \.self) { category in
                let count = model.index?.apps(inCategory: category).count ?? 0
                if count > 0 {
                    Button { nav.show(.category(category)) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: StoreCategory.symbol(for: category))
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(theme.accent)
                                .frame(width: 38, height: 38)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.accent.opacity(0.14)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(category).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.primaryText)
                                Text("\(count) apps").font(.system(size: 11.5)).foregroundStyle(theme.secondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondaryText)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).fill(theme.titleBarInactive))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityIdentifier("store.category.\(category)")
                }
            }
        }
    }
}

struct StoreCategoriesPage: View {
    let model: StoreModel
    let nav: StoreNavigation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                StoreSectionHeader(title: "Categories", subtitle: "Desktop apps from Alpine's repositories, by what they do")
                StoreCategoryGrid(model: model, nav: nav)
            }
            .padding(20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("store.categories")
    }
}

/// A category or collection as a grid of cards.
struct StoreGridPage: View {
    let title: String
    let subtitle: String?
    let apps: [StoreApp]
    let model: StoreModel
    let nav: StoreNavigation
    var onOpen: (StoreApp) -> Void
    @State private var sort = Sort.recommended

    enum Sort: String, CaseIterable { case recommended = "Recommended", name = "Name", size = "Size" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .lastTextBaseline) {
                    StoreSectionHeader(title: title, subtitle: subtitle ?? "\(apps.count) apps")
                    Picker("Sort", selection: $sort) { ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                        .frame(width: 270)
                }
                if apps.isEmpty {
                    AppEmptyState(symbol: "shippingbox", title: "Nothing here yet", message: "Refresh the catalog to look for more apps.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 196, maximum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(sorted) { app in
                            StoreAppCard(app: app, model: model, onSelect: { nav.show(.app($0.id)) }, onOpen: onOpen)
                        }
                    }
                }
            }
            .padding(20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("store.grid")
    }

    private var sorted: [StoreApp] {
        switch sort {
        case .recommended:
            return apps.sorted { rank($0) != rank($1) ? rank($0) > rank($1) : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .name:
            return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size:
            return apps.sorted { ($0.estimatedMB ?? .max) < ($1.estimatedMB ?? .max) }
        }
    }

    private func rank(_ app: StoreApp) -> Int {
        (model.featuredIDs.contains(app.id) ? 4 : 0) + (app.compatibility == .works ? 2 : 0) + (app.screenshots != nil ? 1 : 0)
    }
}

// MARK: - Search

struct StoreSearchPage: View {
    let model: StoreModel
    let nav: StoreNavigation
    var onOpen: (StoreApp) -> Void
    @Environment(\.desktopTheme) private var theme
    @State private var results: [StoreApp] = []
    @State private var searched = ""

    var body: some View {
        Group {
            if nav.query.trimmingCharacters(in: .whitespaces).isEmpty {
                suggestions
            } else if results.isEmpty && searched == nav.query {
                AppEmptyState(symbol: "magnifyingglass", title: "No apps match “\(nav.query)”",
                              message: "Try a shorter word or the program's name, or refresh the catalog. Every Alpine package is also in the Packages app.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let apps = results.filter { !$0.isBarePackage }
                        let packages = results.filter(\.isBarePackage)
                        Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                            .font(.system(size: 12)).foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                        ForEach(apps) { row($0) }
                        if !packages.isEmpty {
                            Text("More packages with a desktop app")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.secondaryText)
                                .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 6)
                            ForEach(packages) { row($0) }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .task(id: nav.query) {
            // Instant: one frame of debounce so fast typing does not search every keystroke.
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            results = model.search(nav.query)
            searched = nav.query
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("store.searchResults")
    }

    private func row(_ app: StoreApp) -> some View {
        VStack(spacing: 0) {
            StoreAppRow(app: app, model: model, detail: "\(app.category) · \(app.summary ?? "")", onSelect: { nav.show(.app($0.id)) }) {
                StoreActionButton(app: app, model: model, onOpen: onOpen)
            }
            ThemedSeparator().padding(.leading, 70)
        }
    }

    private var suggestions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                StoreSectionHeader(title: "Search \(model.allApps.count) apps", subtitle: "By name, what it does, or its package name")
                let ideas = ["photo editor", "ftp", "video player", "office", "music", "pdf", "chess", "torrent", "paint", "terminal"]
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(ideas, id: \.self) { idea in
                        Button { nav.query = idea } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass").font(.system(size: 11))
                                Text(idea).font(.system(size: 13))
                            }
                            .foregroundStyle(theme.primaryText)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(Capsule().fill(theme.primaryText.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Installed

struct StoreInstalledPage: View {
    let model: StoreModel
    let nav: StoreNavigation
    var onOpen: (StoreApp) -> Void
    @Environment(\.desktopTheme) private var theme
    @State private var pendingRemoval: StoreApp?

    var body: some View {
        Group {
            if model.state == nil {
                if model.isLoadingState { ProgressView("Reading installed apps…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { AppEmptyState(symbol: "externaldrive.badge.questionmark", title: "Installed apps are unavailable", message: model.stateError) }
            } else if model.installedApps.isEmpty {
                AppEmptyState(symbol: "bag", title: "No apps installed yet",
                              message: "LinPad starts small. Pick what you need on the Home tab; it installs in the background.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Text("\(model.installedApps.count) apps installed from the Store")
                            .font(.system(size: 12)).foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                        ForEach(model.installedApps) { app in
                            StoreAppRow(app: app, model: model, detail: detail(app), onSelect: { nav.show(.app($0.id)) }) {
                                HStack(spacing: 6) {
                                    StoreActionButton(app: app, model: model, onOpen: onOpen)
                                    if model.job(for: app.id) == nil, app.id != "apk:firefox-esr" {
                                        ToolbarIconButton("trash", help: "Remove \(app.name)") { pendingRemoval = app }
                                            .accessibilityIdentifier("store.remove.\(app.id)")
                                    }
                                }
                            }
                            ThemedSeparator().padding(.leading, 70)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .alert("Remove \(pendingRemoval?.name ?? "")?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
               presenting: pendingRemoval) { app in
            Button("Remove", role: .destructive) { model.remove(app.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The app is uninstalled from Linux. Your files in /root stay.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("store.installed")
    }

    private func detail(_ app: StoreApp) -> String {
        [StoreFormat.version(model.state?.installedVersion(app)), app.category].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Updates

struct StoreUpdatesPage: View {
    let model: StoreModel
    let nav: StoreNavigation
    var onOpen: (StoreApp) -> Void
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    StoreSectionHeader(title: "Updates", subtitle: subtitle)
                    if model.isCheckingUpdates { ProgressView().controlSize(.small) }
                    ToolbarTextButton(title: "Check Now", symbol: "arrow.clockwise") { Task { await model.checkUpdates() } }
                        .disabled(model.isCheckingUpdates || model.isOffline || model.state == nil)
                        .accessibilityIdentifier("store.updates.check")
                    if !model.updates.isEmpty {
                        ToolbarTextButton(title: "Update All", symbol: "arrow.down.circle", prominent: true) { model.update() }
                            .disabled(model.isOffline || model.jobs.contains { $0.kind == .update && $0.appIDs.isEmpty })
                            .accessibilityIdentifier("store.updates.all")
                    }
                }
                if let error = model.updatesError {
                    InlineBanner(kind: .warning, message: error, actionTitle: "Retry", action: { Task { await model.checkUpdates() } })
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if model.outdated.isEmpty && model.otherUpdates.isEmpty && !model.isCheckingUpdates {
                    AppEmptyState(symbol: "checkmark.seal", title: "Everything is up to date",
                                  message: model.lastUpdateCheck == nil ? "Check for updates to see what's new." : nil)
                        .frame(height: 260)
                }
                VStack(spacing: 0) {
                    ForEach(model.outdated, id: \.app.id) { item in
                        StoreAppRow(app: item.app, model: model,
                                    detail: "\(StoreFormat.version(item.update.installed) ?? item.update.installed) → \(StoreFormat.version(item.update.available) ?? item.update.available)",
                                    onSelect: { nav.show(.app($0.id)) }) {
                            StoreActionButton(app: item.app, model: model, onOpen: onOpen)
                        }
                        ThemedSeparator().padding(.leading, 70)
                    }
                }
                .background(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).fill(theme.titleBarInactive.opacity(model.outdated.isEmpty ? 0 : 0.5)))
                if !model.otherUpdates.isEmpty {
                    DisclosureGroup {
                        Text(model.otherUpdates.map { "\($0.name) \(StoreFormat.version($0.available) ?? $0.available)" }.joined(separator: ", "))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } label: {
                        Text("\(model.otherUpdates.count) system packages and libraries can be updated; Update All includes them.")
                            .font(.system(size: 13))
                    }
                    .accessibilityIdentifier("store.updates.other")
                }
            }
            .padding(20)
        }
        .task { if model.lastUpdateCheck == nil, model.state != nil { await model.checkUpdates() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("store.updates")
    }

    private var subtitle: String {
        if let date = model.lastUpdateCheck { return "Checked \(date.formatted(.relative(presentation: .named)))" }
        return model.isCheckingUpdates ? "Checking…" : "Not checked yet"
    }
}
