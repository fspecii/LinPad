import SwiftUI

enum PackagesApp {
    /// Launch argument: a search to run when the window opens ("icon-theme").
    static let queryArgument = "query"

    static func descriptor() -> DesktopAppDescriptor {
        DesktopAppDescriptor(
            id: AppID.packages, name: "Packages", symbol: "shippingbox", category: .system,
            defaultSize: CGSize(width: 820, height: 580)
        ) { context in
            AnyView(PackagesAppView(context: context))
        }
    }
}

// MARK: - Model

struct EssentialPackage: Identifiable {
    let name: String
    let summary: String
    let symbol: String
    var id: String { name }
}

enum PackagesTab: String, CaseIterable, Identifiable {
    case browse = "Browse", installed = "Installed"
    var id: Self { self }
}

@MainActor
@Observable
final class PackagesModel {
    static let essentials: [EssentialPackage] = [
        EssentialPackage(name: "nodejs", summary: "JavaScript runtime", symbol: "hexagon"),
        EssentialPackage(name: "npm", summary: "Node package manager", symbol: "shippingbox"),
        EssentialPackage(name: "git", summary: "Version control", symbol: "arrow.triangle.branch"),
        EssentialPackage(name: "python3", summary: "Python interpreter", symbol: "chevron.left.forwardslash.chevron.right"),
        EssentialPackage(name: "py3-pip", summary: "Python package installer", symbol: "arrow.down.circle"),
        EssentialPackage(name: "build-base", summary: "gcc, make, libc headers", symbol: "hammer"),
        EssentialPackage(name: "curl", summary: "Transfer data from URLs", symbol: "network"),
        EssentialPackage(name: "openssh", summary: "SSH client and server", symbol: "key"),
        EssentialPackage(name: "vim", summary: "Text editor", symbol: "character.cursor.ibeam"),
    ]
    private static let logLimit = 64_000
    private static let resultLimit = 300

    @ObservationIgnored private let host: any LinuxHost
    @ObservationIgnored private let window: any WindowHandle
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false

    var tab: PackagesTab = .browse
    var query = ""
    var installedFilter = ""
    private(set) var results: [APKPackage] = []
    private(set) var lastSearchedQuery = ""
    private(set) var installed: [APKPackage] = []
    private(set) var installedNames: Set<String> = []
    private(set) var isSearching = false
    private(set) var isLoadingInstalled = false
    private(set) var activeOperation: String?
    private(set) var log = ""
    var isLogVisible = false
    var errorMessage: String?

    init(context: AppLaunchContext) {
        host = context.host
        window = context.window
        query = context.arguments[PackagesApp.queryArgument] ?? ""
    }

    var isBusy: Bool { activeOperation != nil }

    var missingEssentials: [String] {
        Self.essentials.map(\.name).filter { !installedNames.contains($0) }
    }

    var filteredInstalled: [APKPackage] {
        let filter = installedFilter.trimmedWhitespace.lowercased()
        guard !filter.isEmpty else { return installed }
        return installed.filter { $0.name.lowercased().contains(filter) || $0.summary.lowercased().contains(filter) }
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        window.setTitle("Packages")
        Task { await loadInstalled() }
        if !query.trimmedWhitespace.isEmpty { searchNow() }
    }

    func queryChanged() {
        searchTask?.cancel()
        let pattern = query.trimmedWhitespace
        guard !pattern.isEmpty else {
            results = []
            lastSearchedQuery = ""
            isSearching = false
            return
        }
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            await self?.search(pattern)
        }
    }

    func searchNow() {
        searchTask?.cancel()
        let pattern = query.trimmedWhitespace
        guard !pattern.isEmpty else { return }
        searchTask = Task { [weak self] in await self?.search(pattern) }
    }

    func loadInstalled() async {
        isLoadingInstalled = true
        defer { isLoadingInstalled = false }
        var result = await host.run("apk info -vv 2>/dev/null", cwd: nil, stdin: nil)
        if !result.succeeded || result.stdout.trimmedWhitespace.isEmpty {
            result = await host.run("apk list --installed 2>/dev/null || apk info -v", cwd: nil, stdin: nil)
        }
        guard result.succeeded else {
            errorMessage = "Couldn't list installed packages: \(result.failureDescription)"
            return
        }
        installed = APKParser.parse(result.stdout).sorted { $0.name < $1.name }
        installedNames = Set(installed.map(\.name))
    }

    func install(_ names: [String]) {
        let valid = names.filter(ShellQuote.isValidPackageName)
        guard !valid.isEmpty else { return }
        let title = valid.count == 1 ? "Installing \(valid[0])" : "Installing \(valid.count) packages"
        run(arguments: "add --no-progress " + valid.map(ShellQuote.quote).joined(separator: " "), title: title)
    }

    func remove(_ name: String) {
        guard ShellQuote.isValidPackageName(name) else { return }
        run(arguments: "del --no-progress \(ShellQuote.quote(name))", title: "Removing \(name)")
    }

    func updateIndex() {
        run(arguments: "update --no-progress", title: "Updating package index")
    }

    func clearLog() {
        log = ""
    }

    // MARK: Private

    private func search(_ pattern: String) async {
        isSearching = true
        defer { isSearching = false }
        let result = await host.run("apk search -v \(ShellQuote.quote(pattern))", cwd: nil, stdin: nil)
        guard !Task.isCancelled else { return }
        lastSearchedQuery = pattern
        let packages = APKParser.parse(result.stdout)
        if packages.isEmpty && !result.succeeded {
            errorMessage = "Search failed: \(result.failureDescription). Try “Update Index”."
        } else {
            errorMessage = nil
        }
        results = Array(packages.sorted { rank($0, for: pattern) < rank($1, for: pattern) }.prefix(Self.resultLimit))
    }

    /// Exact and prefix matches first, then everything else alphabetically.
    private func rank(_ package: APKPackage, for pattern: String) -> (Int, String) {
        let name = package.name.lowercased()
        let needle = pattern.lowercased()
        let tier = name == needle ? 0 : (name.hasPrefix(needle) ? 1 : 2)
        return (tier, name)
    }

    private func run(arguments: String, title: String) {
        guard activeOperation == nil else { return }
        activeOperation = title
        isLogVisible = true
        errorMessage = nil
        appendLog("$ apk \(arguments)\n")
        Task {
            let status = await host.stream("apk \(arguments)", cwd: nil) { chunk in
                self.appendLog(chunk)
            }
            if status == 0 {
                appendLog("✓ \(title) — done\n\n")
            } else {
                appendLog("✗ apk exited with status \(status)\n\n")
                errorMessage = "\(title) failed. See the log for details."
            }
            activeOperation = nil
            // Installed icon packs, fonts and .desktop entries are new guest files.
            NotificationCenter.default.post(name: .guestFilesChanged, object: nil)
            await loadInstalled()
        }
    }

    private func appendLog(_ chunk: String) {
        log += chunk
        if log.utf8.count > Self.logLimit {
            log = String(log.suffix(Self.logLimit / 2))
        }
    }
}

// MARK: - Views

struct PackagesAppView: View {
    @Environment(\.desktopTheme) private var theme
    @State private var model: PackagesModel
    @State private var pendingRemoval: String?

    init(context: AppLaunchContext) {
        _model = State(initialValue: PackagesModel(context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let message = model.errorMessage {
                InlineBanner(kind: .error, message: message, onDismiss: { model.errorMessage = nil })
            }
            if let operation = model.activeOperation {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(operation + "…").font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(theme.accent.opacity(0.12))
            }
            Group {
                switch model.tab {
                case .browse: browseView
                case .installed: installedView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.isLogVisible {
                logPane
            }
        }
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .animation(.easeOut(duration: 0.18), value: model.isLogVisible)
        .animation(.easeOut(duration: 0.18), value: model.activeOperation)
        .task { model.startIfNeeded() }
        .alert("Remove \(pendingRemoval ?? "")?", isPresented: isRemovalPresented, presenting: pendingRemoval) { name in
            Button("Remove", role: .destructive) { model.remove(name) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Runs `apk del`. Packages that depend on it may stop working.")
        }
    }

    private var toolbar: some View {
        AppToolbar {
            Picker("Section", selection: $model.tab) {
                ForEach(PackagesTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            Group {
                if model.tab == .browse {
                    AppSearchField(prompt: "Search Alpine packages", text: $model.query) { model.searchNow() }
                        .onChange(of: model.query) { _, _ in model.queryChanged() }
                } else {
                    AppSearchField(prompt: "Filter installed", text: $model.installedFilter)
                }
            }
            .frame(maxWidth: 300)
            .padding(.horizontal, 6)
            Spacer(minLength: 4)
            ToolbarTextButton(title: "Update Index", symbol: "arrow.triangle.2.circlepath") { model.updateIndex() }
                .disabled(model.isBusy)
            ToolbarIconButton("text.alignleft", help: "Show Log", isActive: model.isLogVisible) {
                model.isLogVisible.toggle()
            }
        }
    }

    // MARK: Browse

    @ViewBuilder
    private var browseView: some View {
        if model.query.trimmedWhitespace.isEmpty {
            essentialsView
        } else if model.results.isEmpty {
            if model.isSearching || model.lastSearchedQuery != model.query.trimmedWhitespace {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AppEmptyState(symbol: "magnifyingglass", title: "No packages found",
                              message: "Nothing matches “\(model.lastSearchedQuery)”. If the index is stale, run Update Index.")
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.results) { package in
                        packageRow(package)
                        ThemedSeparator().padding(.leading, 14)
                    }
                }
            }
        }
    }

    private var essentialsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Developer essentials")
                            .font(.title3.weight(.semibold))
                        Text("Everything you need to build a web project on this iPad.")
                            .font(.callout)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer()
                    let missing = model.missingEssentials
                    if !missing.isEmpty {
                        ToolbarTextButton(title: "Install All Missing (\(missing.count))",
                                          symbol: "arrow.down.circle", prominent: true) {
                            model.install(missing)
                        }
                        .disabled(model.isBusy)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                    ForEach(PackagesModel.essentials) { essential in
                        essentialCard(essential)
                    }
                }
            }
            .padding(16)
        }
    }

    private func essentialCard(_ essential: EssentialPackage) -> some View {
        let isInstalled = model.installedNames.contains(essential.name)
        return HStack(spacing: 10) {
            Image(systemName: essential.symbol)
                .font(.system(size: 18))
                .foregroundStyle(theme.accent)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(essential.name).font(.system(size: 14, weight: .semibold, design: .monospaced))
                Text(essential.summary)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            actionButton(for: essential.name, isInstalled: isInstalled)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
            .fill(theme.titleBarInactive))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
            .stroke(theme.separator, lineWidth: 1))
        .hoverEffect(.lift)
    }

    private func packageRow(_ package: APKPackage) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(package.name)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    Text(package.version)
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.secondaryText)
                }
                if !package.summary.isEmpty {
                    Text(package.summary)
                        .font(.callout)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            actionButton(for: package.name, isInstalled: model.installedNames.contains(package.name))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .contextMenu {
            Button { UIPasteboard.general.string = "apk add \(package.name)" } label: {
                Label("Copy Install Command", systemImage: "doc.on.doc")
            }
        }
    }

    @ViewBuilder
    private func actionButton(for name: String, isInstalled: Bool) -> some View {
        if isInstalled {
            HStack(spacing: 6) {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.green)
                ToolbarTextButton(title: "Remove") { pendingRemoval = name }
                    .disabled(model.isBusy)
            }
        } else {
            ToolbarTextButton(title: "Install", prominent: true) { model.install([name]) }
                .disabled(model.isBusy)
        }
    }

    // MARK: Installed

    @ViewBuilder
    private var installedView: some View {
        let packages = model.filteredInstalled
        if packages.isEmpty {
            if model.isLoadingInstalled {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AppEmptyState(symbol: "shippingbox", title: "No installed packages found")
            }
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("\(model.installed.count) packages installed")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                    Spacer()
                    if model.isLoadingInstalled { ProgressView().controlSize(.mini) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(packages) { package in
                            packageRow(package)
                            ThemedSeparator().padding(.leading, 14)
                        }
                    }
                }
            }
        }
    }

    // MARK: Log

    private var logPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Label("Log", systemImage: "text.alignleft")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                ToolbarIconButton("trash", help: "Clear Log") { model.clearLog() }
                    .disabled(model.log.isEmpty)
                ToolbarIconButton("chevron.down", help: "Hide Log") { model.isLogVisible = false }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(theme.titleBarInactive)
            .overlay(alignment: .top) { ThemedSeparator() }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.log.isEmpty ? "No output yet." : model.log)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(model.log.isEmpty ? theme.secondaryText : theme.primaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("logEnd")
                }
                .onChange(of: model.log) { _, _ in proxy.scrollTo("logEnd", anchor: .bottom) }
                .onAppear { proxy.scrollTo("logEnd", anchor: .bottom) }
            }
            .frame(height: 170)
            .background(Color.black.opacity(0.35))
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var isRemovalPresented: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }
}

#Preview("Packages") {
    PackagesAppView(context: AppsPreview.context())
        .frame(width: 820, height: 580)
}
