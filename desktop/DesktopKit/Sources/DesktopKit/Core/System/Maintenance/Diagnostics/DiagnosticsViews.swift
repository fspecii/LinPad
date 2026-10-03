import SwiftUI

/// Settings › Maintenance row: Export Diagnostics.
struct DiagnosticsSettingsRow: View {
    let host: any LinuxHost
    @Bindable var center: DiagnosticsCenter
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        SettingsRow(title: "Diagnostics") {
            ToolbarTextButton(title: "Export Diagnostics…", symbol: "stethoscope") {
                center.isExportSheetRequested = true
            }
            .accessibilityIdentifier("settings.exportDiagnostics")
        }
        .sheet(isPresented: $center.isExportSheetRequested) { DiagnosticsExportSheet(host: host) }
        Text("Makes a zip with versions, memory figures, logs and crash reports for a bug report. You review it first; your file names and paths are removed. LinPad sends nothing by itself: you choose where to share it.")
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct DiagnosticsExportSheet: View {
    @State private var model: DiagnosticsExportModel
    @State private var expanded: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    init(host: any LinuxHost) {
        _model = State(initialValue: DiagnosticsExportModel(host: host))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch model.state {
                    case .idle, .collecting:
                        Text("Collecting diagnostics…").foregroundStyle(.secondary)
                        ProgressView()
                    case .review:
                        review
                    case .exported(let url):
                        exported(url)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Export Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("diagnostics.cancel")
                }
            }
        }
        .frame(minWidth: 560, minHeight: 640)
        .accessibilityIdentifier("desktop.diagnosticsSheet")
        .task { if model.state == .idle { await model.collect() } }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This is everything the export will contain. Untick anything you do not want to share and open an item to read it. Paths inside /root and /home, user and device names and e-mail addresses have been replaced with <redacted>, <user> and <name>.")
                .fixedSize(horizontal: false, vertical: true)
            ForEach($model.items) { $item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Toggle(isOn: $item.isIncluded) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.callout.weight(.semibold))
                                Text("\(item.fileName) · \(BackupService.bytes(Int64(item.text.utf8.count))) · \(item.detail)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityIdentifier("diagnostics.item.\(item.id)")
                    }
                    Button(expanded.contains(item.id) ? "Hide Contents" : "Show Contents") {
                        if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                    }
                    .font(.caption)
                    if expanded.contains(item.id) {
                        ScrollView {
                            Text(String(item.text.prefix(12_000)) + (item.text.count > 12_000 ? "\n…" : ""))
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            }
            Button {
                model.export()
            } label: {
                Label("Create Zip", systemImage: "doc.zipper").frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.items.contains(where: \.isIncluded))
            .accessibilityIdentifier("diagnostics.export")
        }
    }

    private func exported(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(url.lastPathComponent) is ready.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("diagnostics.ready")
            Text("Share it with the bug report (attach it to the GitHub issue or send it by mail). LinPad itself has not sent anything.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    HostPresenter.share([url])
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("diagnostics.share")
                Button {
                    DocumentPickers.export(url)
                } label: {
                    Label("Save to Files…", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
