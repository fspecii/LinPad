import SwiftUI
import UIKit

/// Share a colour theme: a `linpad://` link that installs it in LinPad (the git repository
/// for themes installed from one, otherwise the colours inline), and the theme folder as a
/// zip (colors.toml, Omarchy's format, so it works on Omarchy too).
struct ShareThemeSheet: View {
    let theme: ColorTheme
    @Environment(\.dismiss) private var dismiss
    @State private var archive: URL?
    @State private var archiveError: String?
    @State private var copied = false

    private var link: URL { LinPadLink.share(theme).url }

    private var linkKind: String {
        if case .installTheme = LinPadLink.share(theme) {
            return "The link installs the theme from its git repository."
        }
        return "The link carries the theme's colours, so it works without a repository."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ThemePreviewCard(theme: theme, fallback: nil, showsNotification: true)
                        .frame(height: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("LinPad link").font(.headline)
                        Text(link.absoluteString)
                            .font(.caption.monospaced())
                            .lineLimit(3)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                        Text(linkKind + " Anyone with LinPad who opens it is asked before anything is installed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc") {
                                UIPasteboard.general.url = link
                                UIPasteboard.general.string = link.absoluteString
                                copied = true
                            }
                            .accessibilityIdentifier("shareTheme.copyLink")
                            ShareLink(item: link, subject: Text(theme.name), message: Text("\(theme.name), a LinPad colour theme")) {
                                Label("Share Link", systemImage: "square.and.arrow.up")
                            }
                            .accessibilityIdentifier("shareTheme.shareLink")
                        }
                        .buttonStyle(.bordered)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Theme folder").font(.headline)
                        Text("\(theme.id).zip: colors.toml and theme.conf, the layout ish-colors and Omarchy install from a git repository. Put it in a repository to get an install link that follows your updates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let archive {
                            ShareLink(item: archive) {
                                Label("Export \(theme.id).zip", systemImage: "archivebox")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("shareTheme.exportZip")
                        } else if let archiveError {
                            Label(archiveError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("Share “\(theme.name)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 520)
        .accessibilityIdentifier("desktop.shareTheme")
        .task {
            let theme = theme
            do {
                archive = try await Task.detached { try ThemeFiles.exportZip(theme) }.value
            } catch {
                archiveError = "Could not make the zip: \(error.localizedDescription)"
            }
        }
    }
}
