import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Settings › Maintenance rows: Back Up, Restore, the schedule.
struct BackupSettingsRows: View {
    @Bindable var service: BackupService
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        SettingsRow(title: "Back Up") {
            HStack(spacing: 8) {
                ToolbarTextButton(title: service.state.isBusy ? "Backing Up…" : "Back Up…", symbol: "externaldrive.badge.timemachine") {
                    service.isBackupSheetRequested = true
                }
                .accessibilityIdentifier("settings.backUp")
                ToolbarTextButton(title: "Restore…", symbol: "clock.arrow.circlepath") {
                    service.isRestoreSheetRequested = true
                }
                .disabled(service.state.isBusy)
                .accessibilityIdentifier("settings.restore")
            }
        }
        .sheet(isPresented: $service.isBackupSheetRequested) { BackupSheet(service: service) }
        .sheet(isPresented: $service.isRestoreSheetRequested) { RestoreSheet(service: service) }
        SettingsRow(title: "Automatic backup") {
            Picker("Automatic backup", selection: $service.schedule) {
                ForEach(BackupSchedule.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            .accessibilityIdentifier("settings.backupSchedule")
        }
        if service.schedule != .off {
            SettingsRow(title: "Keep automatic backups") {
                Stepper("\(service.keep)", value: $service.keep, in: 1...10)
                    .fixedSize()
                    .accessibilityIdentifier("settings.backupKeep")
            }
        }
        Text(caption)
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings.backupStatus")
    }

    private var caption: String {
        var text = "Saves /root and /home (without caches), the apps you installed and the desktop's settings, wallpapers and calendar to one file in Files › On My iPad › LinPad › Backups. Copy it to iCloud Drive or a USB drive to keep it safe if LinPad is deleted."
        if let last = service.lastBackup {
            text += " Last backup: \(last.formatted(date: .abbreviated, time: .shortened))."
        } else {
            text += " No backup yet."
        }
        if service.schedule != .off {
            text += " Automatic backups run while LinPad is open, \(service.schedule == .daily ? "once a day" : "once a week")."
        }
        return text
    }
}

// MARK: - Back up

struct BackupSheet: View {
    @Bindable var service: BackupService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch service.state {
                    case .idle, .scanning:
                        Text("Measuring /root and /home…").foregroundStyle(.secondary)
                        ProgressView()
                    case .ready:
                        preview
                    case .running(let fraction, let detail):
                        running(fraction: fraction, detail: detail)
                    case .finished(let record, let warnings):
                        finished(record, warnings: warnings)
                    case .cancelled:
                        Label("The backup was cancelled. Nothing was saved.", systemImage: "xmark.circle")
                        backUpButton(title: "Back Up Again")
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("backup.error")
                        backUpButton(title: "Try Again")
                    }
                    if !service.backups.isEmpty, !service.state.isBusy { existingBackups }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Back Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(service.state.isBusy ? "Hide" : "Done") { dismiss() }
                        .accessibilityIdentifier("backup.done")
                }
            }
        }
        .frame(minWidth: 540, minHeight: 600)
        .accessibilityIdentifier("desktop.backupSheet")
        .task {
            service.refreshBackups()
            switch service.state {
            case .idle, .failed, .cancelled, .finished: await service.refreshScan()
            default: break
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A backup is one file with your Linux home folders, the list of apps you installed and the desktop's settings. Restore puts it back on this iPad or another one.")
                .fixedSize(horizontal: false, vertical: true)
            if let scan = service.scan {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Leave out").font(.headline)
                    ForEach(BackupExclusionCategory.allCases) { category in
                        Toggle(isOn: Binding(get: { service.excluded.contains(category) },
                                             set: { on in
                                                 if on { service.excluded.insert(category) } else { service.excluded.remove(category) }
                                             })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(category.title) · \(BackupService.bytes(scan.kilobytes(of: category) * 1024))")
                                Text(category.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityIdentifier("backup.exclude.\(category.rawValue)")
                    }
                    if !service.mountPoints.isEmpty {
                        Label("iPad folders added in Files are never included; their files stay on the iPad.", systemImage: "ipad")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
                Label("Backup size before compression: about \(BackupService.bytes(scan.includedBytes(excluding: service.excluded))) of \(BackupService.bytes(scan.totalKilobytes * 1024)) in /root and /home.",
                      systemImage: "internaldrive")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("backup.estimate")
            }
            backUpButton(title: "Back Up Now")
        }
    }

    private func backUpButton(title: String) -> some View {
        Button {
            Task { await service.backUp() }
        } label: {
            Label(title, systemImage: "externaldrive.badge.timemachine").frame(minWidth: 180)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!service.isAvailable || service.state.isBusy)
        .accessibilityIdentifier("backup.start")
    }

    private func running(fraction: Double?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
            Text(detail).font(.callout).monospacedDigit().accessibilityIdentifier("backup.progress")
            Text("You can keep using LinPad. Files changed while the backup runs may be saved as they were a moment earlier.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Cancel Backup", role: .cancel) { Task { await service.cancelBackup() } }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("backup.cancel")
        }
    }

    private func finished(_ record: BackupRecord, warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Backed up: \(record.name) (\(BackupService.bytes(record.size))).", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("backup.summary")
            Text("It is in Files › On My iPad › LinPad › Backups. If LinPad is deleted, that folder goes with it: save a copy to iCloud Drive or a USB drive.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !warnings.isEmpty {
                Text("Some files could not be read and were skipped:").font(.callout)
                ForEach(warnings, id: \.self) { Text("• \($0)").font(.caption.monospaced()).foregroundStyle(.orange) }
            }
            HStack {
                Button {
                    DocumentPickers.export(record.url)
                } label: {
                    Label("Save a Copy to Files…", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("backup.saveCopy")
                Button {
                    HostPresenter.share([record.url])
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var existingBackups: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Backups on this iPad").font(.headline).padding(.top, 8)
            ForEach(service.backups) { record in
                HStack {
                    Image(systemName: record.isAutomatic ? "clock" : "doc.zipper")
                    VStack(alignment: .leading) {
                        Text(record.date.formatted(date: .abbreviated, time: .shortened))
                        Text("\(BackupService.bytes(record.size))\(record.isAutomatic ? " · automatic" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button { DocumentPickers.export(record.url) } label: { Label("Save a Copy to Files…", systemImage: "folder") }
                        Button { HostPresenter.share([record.url]) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                        Button(role: .destructive) { service.delete(record) } label: { Label("Delete", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .accessibilityIdentifier("backup.record")
            }
        }
    }
}

// MARK: - Restore

struct RestoreSheet: View {
    @Bindable var service: BackupService
    @Environment(\.dismiss) private var dismiss
    @State private var options = BackupService.RestoreOptions()
    @State private var confirmsReplace = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch service.restoreState {
                    case .idle:
                        chooser
                    case .inspected(let url):
                        if let contents = service.inspected { review(contents, url: url) }
                    case .running(let fraction, let detail):
                        if let fraction { ProgressView(value: fraction) } else { ProgressView() }
                        Text(detail).font(.callout).monospacedDigit().accessibilityIdentifier("restore.progress")
                        Text("Keep LinPad open until the restore finishes.").font(.caption).foregroundStyle(.secondary)
                        if !service.restoreLog.isEmpty { log }
                    case .finished(let summary):
                        finished(summary)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("restore.error")
                        Button("Choose Another Backup") { service.resetRestore() }.buttonStyle(.bordered)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(service.restoreState.isRunning ? "Hide" : "Done") { dismiss() }
                        .accessibilityIdentifier("restore.done")
                }
            }
        }
        .frame(minWidth: 540, minHeight: 620)
        .accessibilityIdentifier("desktop.restoreSheet")
        .task { service.refreshBackups() }
        .onDisappear { if !service.restoreState.isRunning, case .finished = service.restoreState { service.resetRestore() } }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a LinPad backup. You will see what it holds before anything changes.")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(service.backups) { record in
                Button {
                    service.inspect(record.url)
                } label: {
                    HStack {
                        Image(systemName: record.isAutomatic ? "clock" : "doc.zipper")
                        Text(record.date.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Text(BackupService.bytes(record.size)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("restore.record")
            }
            if service.backups.isEmpty {
                Text("There are no backups in LinPad's folder on this iPad.").foregroundStyle(.secondary)
            }
            Button {
                Task {
                    if let url = await DocumentPickers.pickBackup() { service.inspect(url) }
                }
            } label: {
                Label("Choose from Files…", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("restore.pick")
        }
    }

    private func review(_ contents: BackupArchive.Contents, url: URL) -> some View {
        let manifest = contents.manifest
        let packages = manifest.packages.count
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                fact("Made", manifest.createdAt.formatted(date: .long, time: .shortened) + (manifest.automatic ? " (automatic)" : ""))
                fact("LinPad", "\(manifest.appVersion) (\(manifest.appBuild))" + (manifest.rootfsVersion.map { ", Linux system \($0)" } ?? ""))
                fact("Size", "\(BackupService.bytes(Int64(contents.fileSize))) (\(manifest.fileCount.formatted()) files, \(BackupService.bytes(manifest.contentBytes)) unpacked)")
                fact("Apps", "\(packages) package\(packages == 1 ? "" : "s")" + (manifest.appPacks.isEmpty ? "" : ", \(manifest.appPacks.count) LinPad app\(manifest.appPacks.count == 1 ? "" : "s")"))
                if !manifest.excludedCategories.isEmpty {
                    fact("Left out", manifest.excludedCategories.map(\.title).joined(separator: ", "))
                }
                if !manifest.iPadFolders.isEmpty {
                    fact("iPad folders", "not in the backup; add them again in Files: " + manifest.iPadFolders.joined(separator: ", "))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
            .accessibilityIdentifier("restore.manifest")

            Picker("How", selection: $options.mode) {
                Text("Merge with current files").tag(BackupRestoreMode.merge)
                Text("Replace /root and /home").tag(BackupRestoreMode.replace)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("restore.mode")
            Text(options.mode == .merge
                 ? "Files in the backup replace the same files in /root and /home. Files you made since are kept."
                 : "/root and /home become exactly what the backup holds. The current ones are moved to /var/lib/linpad/before-restore-…, not deleted, so you can copy anything back.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Reinstall the apps from the backup that are missing (needs internet; otherwise they install the next time you open a terminal online)", isOn: $options.reinstallApps)
                .accessibilityIdentifier("restore.reinstall")
            Toggle("Restore the desktop's settings, wallpapers and calendar (take effect when LinPad next starts)", isOn: $options.restoreDesktopSettings)
                .disabled(!manifest.hasDesktopSettings && manifest.desktopFiles.isEmpty)
            HStack {
                Button {
                    if options.mode == .replace { confirmsReplace = true } else { start(url) }
                } label: {
                    Label("Restore", systemImage: "clock.arrow.circlepath").frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .disabled(service.state.isBusy)
                .accessibilityIdentifier("restore.start")
                Button("Choose Another") { service.resetRestore() }.buttonStyle(.bordered)
            }
        }
        .confirmationDialog("Replace /root and /home with the backup?", isPresented: $confirmsReplace, titleVisibility: .visible) {
            Button("Replace", role: .destructive) { start(url) }
        } message: {
            Text("The current /root and /home are moved aside, not deleted.")
        }
    }

    private func start(_ url: URL) {
        Task { await service.restore(from: url, options: options) }
    }

    private func finished(_ summary: BackupService.RestoreSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Restored \(summary.restoredFiles.formatted()) files.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("restore.summary")
            if let aside = summary.movedAsideTo {
                Text("Your previous /root and /home are in \(aside). Delete that folder once you no longer need it.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if summary.settingsRestored {
                Text("Desktop settings, wallpapers and calendar were restored. Close and reopen LinPad to see them.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !summary.reinstalled.isEmpty {
                Text("Reinstalled: \(summary.reinstalled.joined(separator: ", ")).").fixedSize(horizontal: false, vertical: true)
            }
            if !summary.reinstallPending.isEmpty {
                Text("Not reinstalled yet (offline?): \(summary.reinstallPending.joined(separator: ", ")). They install the next time you open a terminal while online.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !summary.iPadFolders.isEmpty {
                Text("Add these iPad folders again in Files: \(summary.iPadFolders.joined(separator: ", ")).")
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(summary.warnings, id: \.self) { Text("• \($0)").font(.caption.monospaced()).foregroundStyle(.orange) }
        }
    }

    private var log: some View {
        ScrollView {
            Text(service.restoreLog.joined(separator: "\n"))
                .font(.caption2.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 100, maxHeight: 200)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.callout.weight(.semibold)).frame(width: 96, alignment: .leading)
            Text(value).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Document pickers

/// The system's document pickers, for a backup file to restore and for saving a copy of one.
@MainActor
enum DocumentPickers {
    private static var delegate: PickerDelegate?

    /// Opens (with access) a .tar the user picks; nil when cancelled.
    static func pickBackup() async -> URL? {
        guard let top = HostPresenter.topViewController else { return nil }
        return await withCheckedContinuation { continuation in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "tar") ?? .data, .data])
            picker.allowsMultipleSelection = false
            let delegate = PickerDelegate { url in
                continuation.resume(returning: url)
                Self.delegate = nil
            }
            Self.delegate = delegate
            picker.delegate = delegate
            top.present(picker, animated: true)
        }
    }

    /// "Save to Files": iCloud Drive, a USB drive, another app's folder.
    static func export(_ url: URL) {
        guard let top = HostPresenter.topViewController else { return }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        top.present(picker, animated: true)
    }

    private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
        private var finish: ((URL?) -> Void)?

        init(finish: @escaping (URL?) -> Void) {
            self.finish = finish
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish?(urls.first)
            finish = nil
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish?(nil)
            finish = nil
        }
    }
}
