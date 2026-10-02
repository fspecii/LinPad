import SwiftUI

/// Settings › Updates: automatic checks, channel, the installed versions, the app and
/// Linux system updates the latest release offers, and Alpine package upgrades.
struct UpdatesSettingsSection: View {
    @Bindable var service: UpdateService
    @Environment(\.desktopTheme) private var theme
    @State private var showsNotes = false
    @State private var showsIloaderHelp = false
    @State private var showsPackages = false

    var body: some View {
        SettingsSection(title: "Updates", symbol: "arrow.triangle.2.circlepath", trailing: {
            if service.checkState == .checking {
                ProgressView().controlSize(.small)
            } else {
                ToolbarTextButton(title: "Check Now", symbol: "arrow.clockwise") {
                    Task { await service.checkNow() }
                }
                .disabled(service.network == .offline)
                .accessibilityIdentifier("settings.updates.checkNow")
            }
        }) {
            if case .failed(let message) = service.checkState {
                InlineBanner(kind: .warning, message: "Could not check for updates: \(message)")
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            SettingsRow(title: "Check automatically") {
                Toggle("Check automatically", isOn: $service.autoCheck)
                    .labelsHidden()
                    .tint(theme.accent)
                    .accessibilityIdentifier("settings.updates.autoCheck")
            }
            SettingsRow(title: "Channel") {
                Picker("Channel", selection: $service.channel) {
                    ForEach(UpdateService.Channel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("settings.updates.channel")
            }
            SettingsRow(title: "Last checked") {
                Text(lastCheckedText)
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("settings.updates.lastChecked")
            }
            ThemedSeparator()
            appRows
            ThemedSeparator()
            systemRows
            ThemedSeparator()
            packageRows
            Text(footnote)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // MARK: App

    @ViewBuilder private var appRows: some View {
        SettingsRow(title: "LinPad app") {
            Text(service.appVersion)
                .font(.callout.monospaced())
                .foregroundStyle(theme.secondaryText)
                .accessibilityIdentifier("settings.updates.appVersion")
        }
        if let app = service.offer.app {
            VStack(alignment: .leading, spacing: 8) {
                Label("LinPad \(app.version.description) is available", systemImage: "sparkles")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.accent)
                    .accessibilityIdentifier("settings.updates.appAvailable")
                if let notes = app.release.body?.trimmedWhitespace, !notes.isEmpty {
                    Button(showsNotes ? "Hide release notes" : "Show release notes") { showsNotes.toggle() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(theme.accent)
                    if showsNotes {
                        ScrollView {
                            Text(Self.markdown(notes))
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 180)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.primaryText.opacity(0.05)))
                    }
                }
                appButtons
                if showsIloaderHelp {
                    Text(Self.iloaderHelp(release: app.release))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent.opacity(0.1)))
        } else if service.release != nil {
            statusLine("Up to date", symbol: "checkmark.circle", tint: .green)
        }
    }

    private var appButtons: some View {
        let installed = service.installedSideloaders
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { appButtonList(installed) }
            VStack(alignment: .leading, spacing: 8) { appButtonList(installed) }
        }
    }

    @ViewBuilder private func appButtonList(_ installed: [UpdateService.Sideloader]) -> some View {
        if installed.isEmpty {
            ToolbarTextButton(title: "Update via SideStore / AltStore", symbol: "arrow.down.app", prominent: true) {
                service.update(with: .sideStore)
            }
            .disabled(true)
            .help("Neither SideStore nor AltStore is installed on this iPad.")
        }
        ForEach(installed) { loader in
            ToolbarTextButton(title: "Update via \(loader.name)", symbol: "arrow.down.app", prominent: true) {
                service.update(with: loader)
            }
            .accessibilityIdentifier("settings.updates.via.\(loader.rawValue)")
        }
        ToolbarTextButton(title: "Open Release on GitHub", symbol: "safari") { service.openReleasePage() }
            .accessibilityIdentifier("settings.updates.openRelease")
        ToolbarTextButton(title: showsIloaderHelp ? "Hide iloader steps" : "Using iloader?", symbol: "questionmark.circle") {
            showsIloaderHelp.toggle()
        }
    }

    // MARK: Linux system

    @ViewBuilder private var systemRows: some View {
        SettingsRow(title: "Linux system") {
            Text(service.installedSystemVersion.map(LinuxSystemVersion.displayName) ?? "Unknown")
                .font(.callout)
                .foregroundStyle(theme.secondaryText)
                .accessibilityIdentifier("settings.updates.systemVersion")
        }
        switch service.download {
        case .downloading(let received, let total):
            progressRow(title: "Downloading the Linux system…",
                        fraction: total > 0 ? Double(received) / Double(total) : nil,
                        detail: total > 0 ? "\(UpdateService.megabytes(received)) of \(UpdateService.megabytes(total))" : "")
            HStack {
                Spacer()
                ToolbarTextButton(title: "Cancel", symbol: "xmark") { service.cancelDownload() }
            }
        case .verifying:
            progressRow(title: "Checking the download…", fraction: nil, detail: "SHA-256")
        case .paused(let message):
            statusLine("Download paused: \(message)", symbol: "pause.circle", tint: theme.secondaryText)
            HStack(spacing: 8) {
                Spacer()
                ToolbarTextButton(title: "Cancel", symbol: "xmark") { service.cancelDownload() }
                ToolbarTextButton(title: "Resume", symbol: "arrow.down.circle", prominent: true) { service.resumeDownload() }
            }
        case .scheduled:
            statusLine("Update downloaded. It installs the next time LinPad starts; /root and /home are kept.",
                       symbol: "checkmark.circle", tint: .green)
        case .failed(let message):
            statusLine(message, symbol: "exclamationmark.triangle", tint: .orange)
            systemOfferRow
        case .idle:
            if let scheduled = service.scheduledSystemUpdate {
                statusLine("Version \(LinuxSystemVersion.displayName(scheduled)) installs the next time LinPad starts.",
                           symbol: "clock", tint: theme.secondaryText)
            } else {
                systemOfferRow
            }
        }
    }

    @ViewBuilder private var systemOfferRow: some View {
        if let system = service.offer.system {
            HStack(alignment: .firstTextBaseline) {
                Text("Version \(LinuxSystemVersion.displayName(system.manifest.version)) is available.")
                    .font(.callout)
                Spacer(minLength: 8)
                ToolbarTextButton(title: "Update Linux system (\(UpdateService.megabytes(system.manifest.size)))",
                                  symbol: "arrow.down.circle", prominent: true) {
                    service.downloadSystemUpdate()
                }
                .accessibilityIdentifier("settings.updates.downloadSystem")
            }
        } else if let needed = service.offer.systemNeedsApp {
            statusLine("A newer Linux system needs LinPad \(needed) or later. Update the app first.",
                       symbol: "info.circle", tint: theme.secondaryText)
        } else if service.release != nil {
            statusLine("Up to date", symbol: "checkmark.circle", tint: .green)
        }
    }

    // MARK: Packages

    @ViewBuilder private var packageRows: some View {
        SettingsRow(title: "Linux packages") {
            HStack(spacing: 8) {
                Text(packageSummary)
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("settings.updates.packages")
                switch service.packages {
                case .checking, .upgrading:
                    ProgressView().controlSize(.small)
                case .available:
                    ToolbarTextButton(title: "Upgrade", symbol: "arrow.up.circle", prominent: true) {
                        showsPackages = true
                        Task { await service.upgradePackages() }
                    }
                    .accessibilityIdentifier("settings.updates.upgradePackages")
                default:
                    ToolbarTextButton(title: "Check", symbol: "arrow.clockwise") {
                        Task { await service.checkPackages() }
                    }
                    .accessibilityIdentifier("settings.updates.checkPackages")
                }
            }
        }
        if case .available(let updates) = service.packages {
            Button(showsPackages ? "Hide packages" : "Show packages") { showsPackages.toggle() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(theme.accent)
            if showsPackages {
                Text(updates.map { "\($0.name)  \($0.installed) → \($0.available)" }.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.secondaryText)
                    .textSelection(.enabled)
            }
        }
        if case .failed(let message) = service.packages {
            statusLine(message, symbol: "exclamationmark.triangle", tint: .orange)
        }
        if !service.packageLog.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(service.packageLog.joined(separator: "\n"))
                        .font(.caption2.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxHeight: 160)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                .onChange(of: service.packageLog.count) { _, _ in proxy.scrollTo("end") }
            }
        }
    }

    private var packageSummary: String {
        switch service.packages {
        case .unknown: return service.lastPackageCheck == nil ? "Not checked" : "—"
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .available(let updates): return "\(updates.count) update\(updates.count == 1 ? "" : "s") available"
        case .upgrading: return "Upgrading…"
        case .failed: return "Check failed"
        }
    }

    // MARK: Helpers

    private var lastCheckedText: String {
        guard let date = service.lastChecked else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }

    private var footnote: String {
        """
        Get app updates automatically: add \(LinPadProject.sourceURL.absoluteString) as a source in SideStore or \
        AltStore. A Linux system update replaces the system and keeps /root, /home, /opt and the packages you added. \
        Automatic checks skip Low Data Mode.
        """
    }

    private func statusLine(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func progressRow(title: String, fraction: Double?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(theme.secondaryText)
            }
            if let fraction {
                ProgressView(value: fraction).tint(theme.accent)
            } else {
                ProgressView().progressViewStyle(.linear).tint(theme.accent)
            }
        }
        .accessibilityIdentifier("settings.updates.systemProgress")
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func iloaderHelp(release: GitHubRelease) -> String {
        let ipa = release.appAsset?.name ?? "the .ipa"
        return """
            iloader: download \(ipa) from the release page on your computer, open iloader, sign in with the same \
            Apple ID as before and install the .ipa over LinPad. Using the same Apple ID keeps the bundle ID, so \
            your Linux system and files stay. The free certificate still expires after 7 days; refresh it in iloader.
            """
    }
}

/// A compact line for Quick Settings and the notification center while an update needs
/// attention: a download in progress, a downloaded system, or a new app version.
struct UpdateStatusRow: View {
    let service: UpdateService
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        if let content {
            Button {
                service.showSettings?()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: content.symbol)
                        .foregroundStyle(theme.accent)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(content.title).font(.system(size: 13, weight: .medium))
                        if let fraction = content.fraction {
                            ProgressView(value: fraction).tint(theme.accent)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                    .fill(theme.primaryText.opacity(0.06)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("desktop.updateStatus")
        }
    }

    private var content: (title: String, symbol: String, fraction: Double?)? {
        switch service.download {
        case .downloading(let received, let total):
            let percent = total > 0 ? " \(Int(Double(received) / Double(total) * 100))%" : ""
            return ("Downloading Linux update\(percent)", "arrow.down.circle", total > 0 ? Double(received) / Double(total) : nil)
        case .verifying:
            return ("Checking the Linux update…", "checkmark.shield", nil)
        case .paused:
            return ("Linux update download paused", "pause.circle", nil)
        case .scheduled:
            return ("Linux update installs at next launch", "clock.arrow.circlepath", nil)
        case .idle, .failed:
            if let app = service.offer.app { return ("LinPad \(app.version) is available", "sparkles", nil) }
            if let system = service.offer.system {
                return ("Linux system update (\(UpdateService.megabytes(system.manifest.size)))", "arrow.down.circle", nil)
            }
            if case .available(let updates) = service.packages {
                return ("\(updates.count) Linux package update\(updates.count == 1 ? "" : "s")", "shippingbox", nil)
            }
            return nil
        }
    }
}
