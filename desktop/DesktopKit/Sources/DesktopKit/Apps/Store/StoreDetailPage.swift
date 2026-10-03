import SwiftUI

/// One app: header with the main action and its progress, what installing costs (measured
/// in the guest), screenshots, description and the facts.
struct StoreDetailPage: View {
    let app: StoreApp
    let model: StoreModel
    let nav: StoreNavigation
    var onOpen: (StoreApp) -> Void
    @Environment(\.desktopTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var showsFullDescription = false
    @State private var confirmsRemoval = false
    @State private var confirmsLargeInstall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if model.job(for: app.id) == nil, !model.isInstalled(app) { sizeLine }
                if let warning = sizeWarning, !model.isInstalled(app) {
                    InlineBanner(kind: .warning, message: warning)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityIdentifier("store.detail.sizeWarning")
                }
                if let shots = app.screenshots, !shots.isEmpty, let base = model.index?.mediaBase {
                    StoreScreenshotStrip(shots: shots, mediaBase: base, height: 230) { nav.screenshot = $0 }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("store.detail.screenshots")
                }
                if let note = compatibilityNote {
                    HStack(alignment: .top, spacing: 10) {
                        StoreCompatBadge(compatibility: app.compatibility)
                        Text(note).font(.system(size: 12.5)).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                }
                description
                facts
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .task(id: model.state == nil) { await model.loadPlan(app.id) }
        .alert("Remove \(app.name)?", isPresented: $confirmsRemoval) {
            Button("Remove", role: .destructive) { model.remove(app.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app is uninstalled from Linux. Your files in /root stay.")
        }
        .alert("\(app.name) is large", isPresented: $confirmsLargeInstall) {
            Button("Install") { model.install([app.id]) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(sizeWarning ?? "")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("store.detail.\(app.id)")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            StoreAppIcon(app: app, size: 104, mediaBase: model.index?.mediaBase)
            VStack(alignment: .leading, spacing: 8) {
                Text(app.name).font(.system(size: 28, weight: .bold)).lineLimit(2)
                if let summary = app.summary {
                    Text(summary).font(.system(size: 15)).foregroundStyle(theme.secondaryText).lineLimit(3)
                }
                HStack(spacing: 8) {
                    StoreCompatBadge(compatibility: app.compatibility)
                        .accessibilityIdentifier("store.detail.compat")
                    Button { nav.show(.category(app.category)) } label: {
                        Label(app.category, systemImage: app.categorySymbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                }
                actions.padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let job = model.job(for: app.id) {
            StoreJobProgress(job: job, model: model, compact: false)
        } else if model.isInstalled(app) {
            HStack(spacing: 8) {
                StoreActionButton(app: app, model: model, prominent: true, onOpen: onOpen)
                if app.id != "apk:firefox-esr" {
                    ToolbarTextButton(title: "Remove", symbol: "trash") { confirmsRemoval = true }
                        .accessibilityIdentifier("store.detail.remove")
                }
            }
        } else {
            HStack(spacing: 10) {
                ToolbarTextButton(title: "Install", symbol: "arrow.down.circle", prominent: true) {
                    if sizeWarning != nil { confirmsLargeInstall = true } else { model.install([app.id]) }
                }
                .disabled(model.isOffline || model.state == nil)
                .accessibilityIdentifier("store.detail.install")
                if model.isOffline {
                    Text("Connect to the internet to install").font(.system(size: 12)).foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    // MARK: Size

    @ViewBuilder
    private var sizeLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive").foregroundStyle(theme.secondaryText)
            if let plan = model.plans[app.id] {
                if let error = plan.error {
                    Text(error).font(.system(size: 12.5)).foregroundStyle(theme.urgent).lineLimit(3)
                } else if let download = plan.downloadBytes, let installed = plan.installedBytes, plan.packageCount > 0 {
                    Text("Downloads \(StoreFormat.bytes(download)) · uses \(StoreFormat.bytes(installed)) · \(plan.packageCount) package\(plan.packageCount == 1 ? "" : "s") including what it needs")
                        .font(.system(size: 12.5).monospacedDigit())
                } else if let estimate = plan.estimateMB {
                    Text("About \(StoreFormat.megabytes(estimate)), downloaded by its installer").font(.system(size: 12.5))
                } else {
                    Text("Everything it needs is already installed").font(.system(size: 12.5))
                }
            } else if model.loadingPlans.contains(app.id) {
                ProgressView().controlSize(.mini)
                Text("Measuring what it needs…").font(.system(size: 12.5)).foregroundStyle(theme.secondaryText)
            } else if let mb = app.estimatedMB {
                Text("About \(StoreFormat.megabytes(mb))\(app.isPack ? "" : " for the app itself; dependencies are measured when Linux is running")")
                    .font(.system(size: 12.5)).foregroundStyle(theme.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("store.detail.size")
    }

    private var plannedMB: Int? {
        if let bytes = model.plans[app.id]?.installedBytes, bytes > 0 { return Int(bytes / 1_000_000) }
        return app.sizeMB
    }

    private var sizeWarning: String? {
        guard let mb = plannedMB, mb >= (model.index?.sizeWarningMB ?? 400) else { return nil }
        return "\(app.name) needs about \(StoreFormat.megabytes(mb)) of space and a while to install; the first start is slow under emulation. Keep LinPad open while it installs."
    }

    private var compatibilityNote: String? {
        if let note = app.compatNote { return note }
        switch app.compatibility {
        case .works: return "Tested on LinPad: installs from the Store and opens as a window."
        case .experimental: return "Starts on LinPad, but some parts may be slow or not work."
        case .broken: return "Known not to run on LinPad yet."
        case .untested: return app.displayServer.map { "Not tested on LinPad yet. It uses \($0)." }
        }
    }

    // MARK: Text

    @ViewBuilder
    private var description: some View {
        if let text = app.description, !text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("About this app").font(.system(size: 17, weight: .bold))
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.primaryText.opacity(0.92))
                    .lineSpacing(3)
                    .lineLimit(showsFullDescription ? nil : 7)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if text.count > 420 {
                    Button(showsFullDescription ? "Less" : "More") { withAnimation { showsFullDescription.toggle() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Information").font(.system(size: 17, weight: .bold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .topLeading)], alignment: .leading, spacing: 14) {
                fact("Version", StoreFormat.version(model.state?.installedVersion(app) ?? app.version))
                if let update = model.update(for: app) { fact("Available", StoreFormat.version(update.available)) }
                fact("Licence", app.license)
                fact("Packages", (app.packages ?? [app.mainPackage].compactMap { $0 }).joined(separator: ", "))
                fact("Display", app.displayServer)
                fact("Category", app.category)
                if let homepage = app.homepage, let url = URL(string: homepage) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Website").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(theme.secondaryText)
                        Button(url.host ?? homepage) { openURL(url) }
                            .buttonStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.accent)
                            .lineLimit(1)
                    }
                }
                fact("Details from", app.isBarePackage ? "Alpine package" : (app.metadataSource == "flathub" ? "AppStream (Alpine, Flathub)" : "AppStream (Alpine)"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("store.detail.facts")
    }

    @ViewBuilder
    private func fact(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(theme.secondaryText)
                Text(value).font(.system(size: 13)).textSelection(.enabled).lineLimit(3)
            }
        }
    }
}
