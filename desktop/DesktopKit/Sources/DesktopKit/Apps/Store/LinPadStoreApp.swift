import SwiftUI

/// LinPad Store: real Linux apps from Alpine's repositories and LinPad's own packs, with a
/// Play Store / App Store feel. Installs run `linpad-apps` in the guest; installed apps
/// open as native windows through the Wayland bridge.
enum LinPadStoreApp {
    static let id = "store"
    /// Launch argument: an app id to show ("apk:filezilla", "image-editor").
    static let appArgument = "app"
    /// Launch argument: "updates" or "installed" to open on that tab.
    static let tabArgument = "tab"
    /// Posted with `object` = app id to bring an open Store to that app.
    static let showAppNotification = Notification.Name("DesktopKit.store.showApp")

    static func descriptor() -> DesktopAppDescriptor {
        DesktopAppDescriptor(
            id: id, name: "LinPad Store", symbol: "bag", category: .system,
            defaultSize: CGSize(width: 1080, height: 720), allowsMultipleWindows: false, showsOnDesktop: true
        ) { context in
            AnyView(StoreRootView(context: context))
        }
    }
}

enum StoreTab: String, CaseIterable, Identifiable {
    case home = "Home", categories = "Categories", search = "Search", installed = "Installed", updates = "Updates"
    var id: Self { self }

    var symbol: String {
        switch self {
        case .home: "house"
        case .categories: "square.grid.2x2"
        case .search: "magnifyingglass"
        case .installed: "checkmark.circle"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

enum StoreRoute: Hashable {
    case app(String)
    case category(String)
    case collection(String)
}

/// Navigation state of one Store window.
@Observable @MainActor
final class StoreNavigation {
    var tab: StoreTab = .home
    var stack: [StoreRoute] = []
    var query = ""
    var screenshot: Int?

    func show(_ route: StoreRoute) {
        if stack.last != route { stack.append(route) }
    }

    func select(_ tab: StoreTab) {
        self.tab = tab
        stack.removeAll()
    }

    func back() {
        if screenshot != nil { screenshot = nil; return }
        if !stack.isEmpty { stack.removeLast() }
    }
}

struct StoreRootView: View {
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopController) private var desktopController
    @State private var model: StoreModel
    @State private var nav = StoreNavigation()
    @State private var showsLog = false
    @FocusState private var searchFocused: Bool
    private let context: AppLaunchContext

    init(context: AppLaunchContext) {
        self.context = context
        _model = State(initialValue: StoreModel.shared(for: context.host))
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 760
            HStack(spacing: 0) {
                if wide {
                    sidebar
                    ThemedSeparator(vertical: true)
                }
                VStack(spacing: 0) {
                    toolbar(wide: wide)
                    banners
                    ZStack {
                        page
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if !model.jobs.isEmpty || failedRecently != nil {
                        StoreQueueBar(model: model, showsLog: $showsLog, failed: failedRecently) { nav.show(.app($0)) }
                    }
                    if showsLog { logPane }
                }
            }
        }
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .overlay {
            if case .app(let id) = nav.stack.last, let app = model.app(id), let shots = app.screenshots, let base = model.index?.mediaBase {
                StoreScreenshotViewer(shots: shots, mediaBase: base, selection: $nav.screenshot)
            }
        }
        .animation(.easeOut(duration: 0.18), value: nav.screenshot)
        .animation(.easeOut(duration: 0.2), value: model.jobs.map(\.id))
        .task {
            context.window.setTitle("LinPad Store")
            if let id = context.arguments[LinPadStoreApp.appArgument] { nav.show(.app(id)) }
            if let tab = context.arguments[LinPadStoreApp.tabArgument].flatMap({ StoreTab(rawValue: $0.capitalized) }) { nav.tab = tab }
            let controller = desktopController
            model.onAppsChanged = { await controller?.linux?.loadApplications() }
            await model.start()
            if model.lastUpdateCheck == nil, model.state != nil { await model.checkUpdates() }
        }
        .onReceive(NotificationCenter.default.publisher(for: LinPadStoreApp.showAppNotification)) { note in
            if let id = note.object as? String { nav.show(.app(id)) }
        }
        .onChange(of: nav.query) { _, query in
            if !query.isEmpty, nav.tab != .search { nav.select(.search) }
        }
        .accessibilityIdentifier("store.root")
    }

    // MARK: Chrome

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "bag.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.accent.readableLabel)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.accent))
                Text("LinPad Store").font(.system(size: 16, weight: .bold))
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 12)
            ForEach(StoreTab.allCases) { tab in
                sidebarRow(tab)
            }
            Spacer()
            catalogStamp
                .padding(12)
        }
        .frame(width: 196)
        .background(theme.titleBarInactive.opacity(0.6))
    }

    private func sidebarRow(_ tab: StoreTab) -> some View {
        let selected = nav.tab == tab
        return Button { nav.select(tab) } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol).font(.system(size: 14, weight: .medium)).frame(width: 20)
                Text(tab.rawValue).font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer()
                if let count = badge(for: tab) {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(tab == .updates ? theme.accent.readableLabel : theme.secondaryText)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(tab == .updates ? theme.accent : theme.primaryText.opacity(0.08)))
                }
            }
            .foregroundStyle(selected ? theme.accent : theme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? theme.accent.opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .hoverEffect(.highlight)
        .accessibilityIdentifier("store.tab.\(tab.rawValue.lowercased())")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func badge(for tab: StoreTab) -> Int? {
        switch tab {
        case .installed: let n = model.installedApps.count; return n > 0 ? n : nil
        case .updates: let n = model.outdated.count + (model.otherUpdates.isEmpty ? 0 : 1); return n > 0 ? model.outdated.count + model.otherUpdates.count : nil
        default: return nil
        }
    }

    private var catalogStamp: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let date = model.indexDate {
                Text("Catalog updated \(date.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("store.catalogStamp")
            }
            Button {
                Task { await model.refreshIndex() }
            } label: {
                HStack(spacing: 5) {
                    if model.isRefreshingIndex { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)) }
                    Text(model.isRefreshingIndex ? "Refreshing…" : "Refresh catalog").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(model.isRefreshingIndex || model.isOffline || model.state == nil)
            .accessibilityIdentifier("store.refreshCatalog")
        }
    }

    private func toolbar(wide: Bool) -> some View {
        AppToolbar {
            if !nav.stack.isEmpty {
                ToolbarIconButton("chevron.left", icon: ThemeIconNames.goBack, help: "Back") { nav.back() }
                    .keyboardShortcut("[", modifiers: .command)
                    .accessibilityIdentifier("store.back")
            }
            if !wide {
                Picker("Section", selection: Binding(get: { nav.tab }, set: { nav.select($0) })) {
                    ForEach(StoreTab.allCases.filter { $0 != .search }) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
            } else {
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).padding(.leading, nav.stack.isEmpty ? 6 : 0)
            }
            Spacer(minLength: 8)
            AppSearchField(prompt: "Search apps", text: $nav.query) { nav.select(.search) }
                .focused($searchFocused)
                .frame(maxWidth: wide ? 300 : 220)
                .accessibilityIdentifier("store.search")
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
                .accessibilityHidden(true)
            Button("") { nav.back() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0).frame(width: 0, height: 0)
                .accessibilityHidden(true)
            ToolbarIconButton("text.alignleft", help: "Install log", isActive: showsLog) { showsLog.toggle() }
                .disabled(model.log.isEmpty)
        }
    }

    private var title: String {
        switch nav.stack.last {
        case .app(let id): model.app(id)?.name ?? "App"
        case .category(let name): name
        case .collection(let id): model.index?.collections.first { $0.id == id }?.title ?? "Collection"
        case nil: nav.tab.rawValue
        }
    }

    @ViewBuilder
    private var banners: some View {
        if model.isOffline {
            InlineBanner(kind: .warning, message: "You're offline. You can browse and open installed apps; installing needs a connection.")
        }
        if let error = model.stateError {
            InlineBanner(kind: .info, message: error, actionTitle: "Retry", action: { Task { await model.reload() } })
        }
        if let error = model.refreshError {
            InlineBanner(kind: .error, message: "Refreshing the catalog failed: \(error)", actionTitle: "Retry", action: { Task { await model.refreshIndex() } })
        }
    }

    @ViewBuilder
    private var page: some View {
        if model.index == nil {
            StoreLoadingPage()
        } else if let route = nav.stack.last {
            switch route {
            case .app(let id):
                if let app = model.app(id) {
                    StoreDetailPage(app: app, model: model, nav: nav, onOpen: open).id(id)
                } else {
                    AppEmptyState(symbol: "questionmark.app", title: "App not found", message: "“\(id)” is not in this catalog. Refresh the catalog and try again.")
                }
            case .category(let name):
                StoreGridPage(title: name, subtitle: nil, apps: model.index?.apps(inCategory: name) ?? [], model: model, nav: nav, onOpen: open)
            case .collection(let id):
                if let collection = model.index?.collections.first(where: { $0.id == id }) {
                    StoreGridPage(title: collection.title, subtitle: collection.subtitle, apps: model.apps(in: collection), model: model, nav: nav, onOpen: open)
                }
            }
        } else {
            switch nav.tab {
            case .home: StoreHomePage(model: model, nav: nav, onOpen: open)
            case .categories: StoreCategoriesPage(model: model, nav: nav)
            case .search: StoreSearchPage(model: model, nav: nav, onOpen: open)
            case .installed: StoreInstalledPage(model: model, nav: nav, onOpen: open)
            case .updates: StoreUpdatesPage(model: model, nav: nav, onOpen: open)
            }
        }
    }

    private var failedRecently: StoreJob? {
        guard model.jobs.isEmpty, let last = model.history.first, case .failed = last.phase else { return nil }
        return last
    }

    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(model.log.isEmpty ? "No output yet." : model.log.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(model.log.isEmpty ? theme.secondaryText : theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Color.clear.frame(height: 1).id("end")
            }
            .onChange(of: model.log.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(height: 150)
        .background(Color.black.opacity(0.3))
        .overlay(alignment: .top) { ThemedSeparator() }
        .accessibilityIdentifier("store.log")
    }

    // MARK: Opening apps

    private func open(_ app: StoreApp) {
        if app.isCommandLine {
            context.desktop.open(appID: AppID.terminal, arguments: [:])
        } else if let desktopID = app.desktopID {
            context.desktop.open(appID: LinuxAppID.prefix + desktopID, arguments: [:])
        } else if let main = app.mainPackage {
            context.desktop.open(appID: LinuxAppID.prefix + main, arguments: [:])
        }
    }
}

/// The running job, how many wait behind it, and the last failure with its reason.
struct StoreQueueBar: View {
    let model: StoreModel
    @Binding var showsLog: Bool
    let failed: StoreJob?
    var onSelect: (String) -> Void
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            if let job = model.currentJob {
                if let app = job.appIDs.first.flatMap(model.app) {
                    Button { onSelect(app.id) } label: { StoreAppIcon(app: app, size: 30, mediaBase: model.index?.mediaBase) }
                        .buttonStyle(.plain)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 18)).foregroundStyle(theme.accent).frame(width: 30)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(job.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("· " + job.statusText).font(.system(size: 12).monospacedDigit()).foregroundStyle(theme.secondaryText).lineLimit(1)
                    }
                    StoreProgressBar(fraction: job.fraction).frame(height: 5)
                }
                if model.jobs.count > 1 {
                    Text("\(model.jobs.count - 1) waiting")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityIdentifier("store.queue.waiting")
                }
                if job.phase.isCancellable && !job.cancelRequested {
                    ToolbarTextButton(title: "Cancel") { model.cancel(job.id) }
                        .accessibilityIdentifier("store.queue.cancel")
                }
            } else if model.isRefreshingIcons {
                ProgressView().controlSize(.small)
                Text("Updating app icons…").font(.system(size: 13))
                Spacer()
            } else if let failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.urgent)
                Text("\(failed.title): \(failed.statusText)").font(.system(size: 13)).lineLimit(2)
                Spacer()
                ToolbarTextButton(title: "Show Log") { showsLog = true }
                ToolbarTextButton(title: "Try Again", prominent: true) {
                    switch failed.kind {
                    case .install: model.install(failed.appIDs)
                    case .remove: failed.appIDs.forEach(model.remove)
                    case .update: model.update(failed.appIDs)
                    }
                }
                .disabled(model.isOffline)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(theme.titleBarInactive)
        .overlay(alignment: .top) { ThemedSeparator() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("store.queue")
    }
}

/// Skeleton of the home page while the index loads.
struct StoreLoadingPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StoreSkeleton(cornerRadius: 16).frame(height: 200)
            StoreSkeleton().frame(width: 220, height: 20)
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in StoreSkeleton(cornerRadius: 12).frame(width: 196, height: 150) }
            }
            Spacer()
        }
        .padding(20)
        .accessibilityLabel("Loading the catalog")
    }
}
