import SwiftUI

/// Settings › Maintenance: Repair System and Reset to Factory.
struct MaintenanceSettingsSection: View {
    @Bindable var service: SystemMaintenanceService
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        SettingsSection(title: "Maintenance", symbol: "wrench.and.screwdriver") {
            SettingsRow(title: "Repair System") {
                ToolbarTextButton(title: service.state.isRunning ? "Repairing…" : "Repair…", symbol: "bandage") {
                    service.isRepairSheetRequested = true
                }
                .disabled(service.kit == nil)
                .accessibilityIdentifier("settings.repairSystem")
            }
            .sheet(isPresented: $service.isRepairSheetRequested) { RepairSystemSheet(service: service) }
            caption("Puts back LinPad's own system files as this version of the app ships them: Firefox's settings (video playback), desktop styles and session scripts, the optional-apps catalog, permissions and caches, and base packages that went missing (when online). Your files, your settings in /root and the apps you installed are kept.")
            statusLine
            ThemedSeparator()
            SettingsRow(title: "Reset to Factory") {
                ToolbarTextButton(title: "Reset…", symbol: "arrow.counterclockwise") {
                    service.isResetSheetRequested = true
                }
                .disabled(service.resetter == nil || service.state.isRunning)
                .accessibilityIdentifier("settings.resetToFactory")
            }
            .sheet(isPresented: $service.isResetSheetRequested) { FactoryResetSheet(service: service) }
            caption("Reinstalls the Linux system that comes with the app, keeping your files or erasing everything. LinPad closes and finishes the reset the next time you open it.")
        }
        .task { await service.refreshInstalledKitVersion() }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusTint)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.repairStatus")
    }

    private var statusText: String {
        guard let kit = service.kit else { return "This build has no repair kit." }
        switch service.state {
        case .running: return "Repairing: \(service.report.currentStep ?? "starting")…"
        case .failed(let message): return message
        case .finished: return service.report.summary
        case .idle:
            let applied = service.installedKitVersion.map { "applied \($0)" } ?? "not applied yet"
            return "Repair kit \(kit.manifest.version) (\(applied))."
        }
    }

    private var statusSymbol: String {
        switch service.state {
        case .running: return "hourglass"
        case .failed: return "exclamationmark.triangle"
        case .finished: return service.report.succeeded == true ? "checkmark.circle" : "exclamationmark.triangle"
        case .idle: return "shippingbox"
        }
    }

    private var statusTint: Color {
        switch service.state {
        case .failed: return .orange
        case .finished: return service.report.succeeded == true ? .green : .orange
        default: return theme.secondaryText
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Repair

struct RepairSystemSheet: View {
    @Bindable var service: SystemMaintenanceService
    @Environment(\.dismiss) private var dismiss

    /// linpad-repair's steps, in order (release/guest/linpad-repair).
    static let steps = ["Permissions", "Firefox", "System files", "Styles and audio", "Packages", "Caches"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch service.state {
                    case .idle, .failed:
                        intro
                    case .running, .finished:
                        progress
                    }
                    if case .failed(let message) = service.state {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !service.log.isEmpty { logView }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Repair System")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(service.state.isRunning ? "Hide" : "Done") { dismiss() }
                        .accessibilityIdentifier("repair.done")
                }
            }
        }
        .frame(minWidth: 520, minHeight: 560)
        .accessibilityIdentifier("desktop.repairSheet")
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Repair puts LinPad's system files back the way this version of the app ships them. It is safe to run any time, as often as you like.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                bullet("Firefox settings, so videos (YouTube) play again")
                bullet("Desktop styles, colour themes, audio and session scripts")
                bullet("The optional-apps catalog and LinPad's helper commands")
                bullet("Permissions of /, /root and /tmp, and Firefox, font and icon caches")
                bullet("Base packages that went missing, when the iPad is online")
            }
            Text("Your files, your settings in /root and the apps you installed are not touched. If anything is repaired, open Linux apps restart at the end.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await service.repair(automatic: false) }
            } label: {
                Label("Start Repair", systemImage: "bandage")
                    .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .disabled(service.kit == nil)
            .accessibilityIdentifier("repair.start")
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.steps, id: \.self) { step in
                HStack(spacing: 10) {
                    stepIcon(step)
                        .frame(width: 18)
                    Text(step)
                }
            }
            if case .finished = service.state {
                let ok = service.report.succeeded == true
                Label(service.report.summary, systemImage: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .accessibilityIdentifier("repair.summary")
                ForEach(service.report.failures, id: \.self) { failure in
                    Text("• \(failure)").font(.callout).foregroundStyle(.orange)
                }
                ForEach(service.report.notes, id: \.self) { note in
                    Text("• \(note)").font(.callout).foregroundStyle(.secondary)
                }
                if !service.state.isRunning {
                    Button("Repair Again") { Task { await service.repair(automatic: false) } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("repair.again")
                }
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ step: String) -> some View {
        let reached = service.report.steps
        let finished: Bool = { if case .finished = service.state { return true } else { return false } }()
        if reached.contains(step) && (finished || reached.last != step) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if reached.last == step {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(service.log.joined(separator: "\n"))
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Color.clear.frame(height: 1).id("end")
            }
            .frame(minHeight: 120, maxHeight: 220)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
            .onChange(of: service.log.count) { _, _ in proxy.scrollTo("end") }
        }
        .accessibilityIdentifier("repair.log")
    }

    private func bullet(_ text: String) -> some View {
        Label(text, systemImage: "checkmark")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Reset to factory

struct FactoryResetSheet: View {
    let service: SystemMaintenanceService
    @Environment(\.dismiss) private var dismiss
    @State private var mode: FactoryResetMode?
    @State private var confirmation = ""
    @State private var isClosing = false
    static let confirmationWord = "RESET"

    static func isConfirmed(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == confirmationWord
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Reset to Factory replaces the whole Linux system with the one that comes with this version of LinPad. Try Repair System first: it fixes most problems and keeps everything.")
                        .fixedSize(horizontal: false, vertical: true)
                    choice(.keepFiles, title: "Keep my files", symbol: "folder.badge.person.crop",
                           detail: "Keeps /root and /home: your projects, documents, downloads and settings files, and the iPad folders you added in Files. Removes the apps and packages you installed and every change outside /root and /home.")
                    choice(.eraseEverything, title: "Erase everything", symbol: "trash",
                           detail: "Deletes /root and /home and forgets the iPad folders you added. LinPad starts as if newly installed. The files inside those iPad folders stay on the iPad.")
                    Text("LinPad closes now. Open it again to install the fresh system (a few minutes), then it starts as usual. Nothing changes until then.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Type \(Self.confirmationWord) to confirm")
                            .font(.callout.weight(.semibold))
                        TextField(Self.confirmationWord, text: $confirmation)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .frame(maxWidth: 220)
                            .accessibilityIdentifier("reset.confirmation")
                    }
                    Button(role: .destructive) {
                        guard let mode else { return }
                        isClosing = true
                        service.resetToFactory(mode)
                    } label: {
                        Label(isClosing ? "Closing LinPad…" : "Reset and Close LinPad", systemImage: "arrow.counterclockwise")
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(mode == nil || !Self.isConfirmed(confirmation) || isClosing)
                    .accessibilityIdentifier("reset.confirm")
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Reset to Factory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("reset.cancel")
                }
            }
        }
        .frame(minWidth: 520, minHeight: 600)
        .accessibilityIdentifier("desktop.factoryResetSheet")
    }

    private func choice(_ value: FactoryResetMode, title: String, symbol: String, detail: String) -> some View {
        let selected = mode == value
        return Button {
            mode = value
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? (value == .eraseEverything ? Color.red : Color.accentColor) : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Label(title, systemImage: symbol).font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("reset.mode.\(value.rawValue)")
    }
}
