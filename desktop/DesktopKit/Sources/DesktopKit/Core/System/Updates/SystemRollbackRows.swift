import SwiftUI

/// Settings › Updates: the repair kit's version and "Roll back system".
struct SystemVersionDetailRows: View {
    let service: UpdateService
    @Environment(\.desktopTheme) private var theme
    @State private var installedKit: String?
    @State private var previous: String?
    @State private var isScheduled = false
    @State private var confirming = false
    @State private var failure: String?

    private var bundledKit: String? { RepairKit.bundled()?.manifest.version }

    var body: some View {
        SettingsRow(title: "Repair kit") {
            Text(kitText)
                .font(.callout.monospaced())
                .foregroundStyle(theme.secondaryText)
                .accessibilityIdentifier("settings.updates.repairKitVersion")
        }
        if let rollback = service.rollback {
            if isScheduled {
                HStack(alignment: .firstTextBaseline) {
                    Label("Rolls back to \(previous.map(LinuxSystemVersion.displayName) ?? "the earlier system") the next time LinPad starts.",
                          systemImage: "clock.arrow.circlepath")
                        .font(.callout)
                        .foregroundStyle(theme.secondaryText)
                    Spacer(minLength: 8)
                    ToolbarTextButton(title: "Cancel", symbol: "xmark") {
                        rollback.cancelRollback()
                        refresh()
                    }
                    .accessibilityIdentifier("settings.updates.cancelRollback")
                }
            } else if let previous {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Previous system: \(LinuxSystemVersion.displayName(previous))").font(.callout)
                        Text("Kept from before the last update.").font(.caption).foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 8)
                    ToolbarTextButton(title: "Roll Back System…", symbol: "arrow.uturn.backward") { confirming = true }
                        .accessibilityIdentifier("settings.updates.rollback")
                }
            }
            if let failure {
                InlineBanner(kind: .warning, message: failure).clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        Text("In a terminal, `linpad update` upgrades the Linux packages and then checks here for a newer app and system.")
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .task { await load() }
            .alert("Roll back the Linux system?", isPresented: $confirming) {
                Button("Roll Back at Next Launch", role: .destructive) {
                    do {
                        try service.rollback?.scheduleRollback()
                        service.notify?("The Linux system rolls back the next time LinPad starts.", nil)
                    } catch {
                        failure = error.localizedDescription
                    }
                    refresh()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("LinPad goes back to \(previous.map(LinuxSystemVersion.displayName) ?? "the earlier system") the next time it starts. /root, /home and your other files are kept; packages you added are reinstalled. The current system is kept too, under Filesystems.")
            }
    }

    private var kitText: String {
        let installed = installedKit ?? "none"
        guard let bundled = bundledKit, RepairKitVersion.isNewer(bundled, than: installedKit) else { return installed }
        return "\(installed) (\(bundled) installs at the next start)"
    }

    private func refresh() {
        previous = service.rollback?.previousSystemVersion
        isScheduled = service.rollback?.isRollbackScheduled ?? false
    }

    private func load() async {
        refresh()
        if let data = try? await service.linuxHost.readFile(RepairKit.installedVersionPath) {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            installedKit = text.isEmpty ? nil : text
        }
    }
}
