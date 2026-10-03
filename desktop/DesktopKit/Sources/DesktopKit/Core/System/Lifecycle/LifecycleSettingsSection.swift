import SwiftUI
import UIKit

/// Settings › Background: keeping Linux running when LinPad leaves the screen, and what
/// LinPad does so nothing is lost when iPadOS ends it.
struct LifecycleSettingsSection: View {
    let controller: DesktopController?
    let host: any LinuxHost
    @Environment(\.desktopTheme) private var theme
    @AppStorage(BackgroundExecution.storageKey) private var modeID = BackgroundExecution.defaultValue.rawValue
    @AppStorage(LifecycleSettings.editorAutosaveKey) private var editorAutosaves = true
    @State private var locationAccess: BackgroundLocationAccess?
    @State private var isRequestingLocation = false

    private var lifecycleHost: (any LinuxLifecycleHosting)? {
        host as? any LinuxLifecycleHosting
    }

    private var mode: BackgroundExecution {
        BackgroundExecution(rawValue: modeID) ?? .defaultValue
    }

    var body: some View {
        SettingsSection(title: "Background", symbol: "moon.zzz") {
            SettingsRow(title: "Keep Linux running in the background") {
                Picker("Keep Linux running in the background", selection: $modeID) {
                    ForEach(BackgroundExecution.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .accessibilityIdentifier("settings.background.mode")
            }
            Text(mode.explanation)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.background.explanation")
            if mode == .always {
                locationStatus
            }
            ThemedSeparator()
            SettingsRow(title: "Text Editor saves automatically") {
                Toggle("Text Editor saves automatically", isOn: $editorAutosaves)
                    .labelsHidden()
                    .tint(theme.accent)
                    .accessibilityIdentifier("settings.background.editorAutosave")
            }
            Text("When LinPad leaves the screen it saves open documents, asks Linux apps to save, and writes the Linux files to storage. If iPadOS later closes LinPad to free memory, your windows reopen at the next start; VS Code, Firefox and LibreOffice bring back their own unsaved work.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let report = controller?.lifecycle.lastFlush {
                Text(lastFlushText(report))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("settings.background.lastFlush")
            }
        }
        .onChange(of: modeID) { _, _ in
            controller?.lifecycle.applyBackgroundExecution()
            refreshLocationAccess()
        }
        .onAppear { refreshLocationAccess() }
    }

    @ViewBuilder
    private var locationStatus: some View {
        switch locationAccess ?? .unavailable {
        case .allowed:
            Label("Location allowed: Linux keeps running in the background.", systemImage: "location.fill")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .accessibilityIdentifier("settings.background.location")
        case .notDetermined:
            HStack {
                Text("Needs location permission.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Button(isRequestingLocation ? "Asking…" : "Allow Location…") {
                    requestLocation()
                }
                .disabled(isRequestingLocation)
                .foregroundStyle(theme.accent)
                .accessibilityIdentifier("settings.background.allowLocation")
            }
        case .denied:
            HStack {
                Text("Location is off for LinPad, so Linux pauses in the background as with \u{201C}While audio plays\u{201D}.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("iPad Settings…") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .foregroundStyle(theme.accent)
                .accessibilityIdentifier("settings.background.openSettings")
            }
        case .unavailable:
            Text("Location is not available on this device, so Linux pauses in the background as with \u{201C}While audio plays\u{201D}.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.background.location")
        }
    }

    private func refreshLocationAccess() {
        locationAccess = lifecycleHost?.backgroundLocationAccess ?? .unavailable
    }

    private func requestLocation() {
        guard let lifecycleHost else { return }
        isRequestingLocation = true
        Task {
            locationAccess = await lifecycleHost.requestBackgroundLocationAccess()
            isRequestingLocation = false
            controller?.lifecycle.applyBackgroundExecution()
        }
    }

    private func lastFlushText(_ report: LifecycleFlushReport) -> String {
        var parts = ["Last saved on leaving the screen in \(String(format: "%.1f", report.seconds)) s"]
        if report.appsSaved > 0 { parts.append("\(report.appsSaved) document\(report.appsSaved == 1 ? "" : "s")") }
        if !report.guestHookFinished { parts.append("Linux apps did not answer in time") }
        if !report.filesystemFlushed { parts.append("file system not confirmed") }
        return parts.joined(separator: " · ") + "."
    }
}
