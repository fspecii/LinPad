import Observation
import SwiftUI
import UIKit

/// An icon theme installed in the guest (/usr/share/icons/<id>).
struct IconPack: Identifiable, Hashable {
    let id: String
    let name: String
}

/// The icon pack choice, independent of the desktop style (themes/CONTRACT.md,
/// `ish-apply-style --icons`). The guest renders the pack into the current style's icon
/// cache, so the shell's own icons and Linux apps change together.
@Observable @MainActor
final class IconPackStore {
    static let overridePath = "/usr/share/ish/icon-theme"
    static let previewDirectory = "/usr/share/ish/icon-previews"
    static let previewNames = ["folder", "utilities-terminal", "system-file-manager",
                               "accessories-text-editor", "web-browser", "user-trash"]

    private(set) var packs: [IconPack] = []
    /// The chosen pack; nil follows the style.
    private(set) var selection: String?
    private(set) var previews: [String: [UIImage]] = [:]
    private(set) var isLoading = false
    private(set) var isRenderingPreviews = false
    /// The pack being applied ("" for Match Style) while the guest rebuilds the cache.
    private(set) var applying: String?
    /// False when the guest's theming package predates icon packs.
    private(set) var isSupported = true
    var errorMessage: String?

    func load(host: any LinuxHost) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let result = await host.run("ish-apply-style --icon-themes", cwd: nil, stdin: nil)
        guard result.succeeded else {
            isSupported = false
            return
        }
        isSupported = true
        packs = Self.parse(result.stdout)
        let override = (try? await host.readFile(Self.overridePath))
            .map { String(decoding: $0, as: UTF8.self).trimmedWhitespace }
        selection = override.flatMap { $0.isEmpty ? nil : $0 }
        await loadPreviews(host: host)
        if packs.contains(where: { previews[$0.id] == nil }) {
            isRenderingPreviews = true
            _ = await host.run("ish-apply-style --icon-previews", cwd: nil, stdin: nil)
            isRenderingPreviews = false
            await loadPreviews(host: host)
        }
    }

    /// Applies a pack (nil: match the style). Takes several seconds: the guest rasterises
    /// every icon of the pack.
    func apply(_ id: String?, icons: DesktopIconStore, host: any LinuxHost) async -> Bool {
        guard applying == nil, id != selection else { return false }
        applying = id ?? ""
        defer { applying = nil }
        let result = await host.run("ish-apply-style --icons \(ShellQuote.quote(id ?? "match"))", cwd: nil, stdin: nil)
        guard result.succeeded else {
            errorMessage = "Couldn't switch icons: \(result.failureDescription)"
            return false
        }
        errorMessage = nil
        selection = id
        icons.cacheChanged()
        return true
    }

    static func parse(_ output: String) -> [IconPack] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard let id = fields.first?.trimmedWhitespace, !id.isEmpty else { return nil }
            return IconPack(id: id, name: fields.count > 1 ? fields[1].trimmedWhitespace : id)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func loadPreviews(host: any LinuxHost) async {
        for pack in packs where previews[pack.id] == nil {
            var images: [UIImage] = []
            for name in Self.previewNames {
                let path = "\(Self.previewDirectory)/\(pack.id)/\(name).png"
                if let data = try? await host.readFile(path), let image = UIImage(data: data) { images.append(image) }
            }
            if !images.isEmpty { previews[pack.id] = images }
        }
    }
}

/// Settings > Icons: the packs with preview tiles, "Match style", and more from Packages.
struct IconPackSettingsSection: View {
    let store: IconPackStore
    let icons: DesktopIconStore
    let host: any LinuxHost
    let desktop: any DesktopActions
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopStyle) private var style

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        SettingsSection(title: "Icons", symbol: "square.grid.3x3.square") {
            if !store.isSupported {
                Text("This Linux system's theming package predates icon packs. Update it to choose icons separately from the style.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    tile(id: nil, title: "Match Style", subtitle: style.displayName, images: [])
                    ForEach(store.packs) { pack in
                        tile(id: pack.id, title: pack.name, subtitle: pack.id == pack.name ? nil : pack.id,
                             images: store.previews[pack.id] ?? [])
                    }
                }
                if let applying = store.applying {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Rendering \(applying.isEmpty ? "the style's icons" : applying) for the desktop and Linux apps…")
                            .font(.caption)
                    }
                    .accessibilityIdentifier("iconPacks.progress")
                } else if store.isLoading || store.isRenderingPreviews {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(store.isRenderingPreviews ? "Drawing previews…" : "Looking for icon packs…").font(.caption)
                    }
                }
                if let error = store.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button {
                    desktop.open(appID: AppID.packages, arguments: [PackagesApp.queryArgument: "icon-theme"])
                } label: {
                    Label("Get More Icon Packs…", systemImage: "shippingbox")
                }
                .accessibilityIdentifier("iconPacks.getMore")
                Text("Icon packs apply to the desktop and to Linux apps started afterwards, and stay when you change the style.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await store.load(host: host) }
        .onReceive(NotificationCenter.default.publisher(for: .guestFilesChanged)) { _ in
            Task { await store.load(host: host) }
        }
    }

    private func tile(id: String?, title: String, subtitle: String?, images: [UIImage]) -> some View {
        let isSelected = store.selection == id
        return Button {
            Task { _ = await store.apply(id, icons: icons, host: host) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    if images.isEmpty {
                        ForEach(["folder.fill", "terminal.fill", "doc.text.fill"], id: \.self) { symbol in
                            Image(systemName: symbol)
                                .font(.system(size: 16))
                                .frame(width: 26, height: 26)
                                .foregroundStyle(theme.accent)
                        }
                    } else {
                        ForEach(images.prefix(5).indices, id: \.self) { index in
                            Image(uiImage: images[index])
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 26, height: 26)
                        }
                    }
                }
                .frame(height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium)).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(theme.secondaryText).lineLimit(1)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.primaryText.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? theme.accent : Color.clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(store.applying != nil)
        .accessibilityIdentifier("iconPack.\(id ?? "match")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
