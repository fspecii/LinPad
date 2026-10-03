import SwiftUI

/// One optional app from the guest's catalog (/usr/share/linpad/catalog.json, listed by
/// `linpad-apps list --json`). Nothing in it ships preinstalled.
struct CatalogPack: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let category: String
    let sizeMB: Int
    var recommended: Bool?
    var experimental: Bool?
    var installed: Bool?

    var isInstalled: Bool { installed ?? false }

    var symbol: String {
        switch category {
        case "Mail": "envelope"
        case "Office": "doc.text"
        case "Graphics": "photo"
        case "Utilities": "archivebox"
        case "Development": "chevron.left.forwardslash.chevron.right"
        case "Multimedia": "play.rectangle"
        case "Internet": "globe"
        default: "shippingbox"
        }
    }

    var sizeText: String {
        sizeMB >= 1000 ? String(format: "~%.1f GB", Double(sizeMB) / 1000) : "~\(sizeMB) MB"
    }
}

/// The guest's optional-apps catalog (`linpad-apps list --json`) with installed state, for
/// onboarding's bookkeeping and install links. Installs and removals go through LinPad
/// Store's queue (StoreModel), so they show their progress in the Store.
@Observable @MainActor
final class AppCatalogModel {
    private(set) var packs: [CatalogPack] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    /// Nil when the catalog loaded; otherwise why it did not (e.g. an older Linux system).
    private(set) var unavailableReason: String?

    @ObservationIgnored private let host: any LinuxHost

    private init(host: any LinuxHost) {
        self.host = host
    }

    @ObservationIgnored private static var models: [ObjectIdentifier: AppCatalogModel] = [:]

    static func shared(for host: any LinuxHost) -> AppCatalogModel {
        let key = ObjectIdentifier(host)
        if let model = models[key] { return model }
        let model = AppCatalogModel(host: host)
        models[key] = model
        return model
    }

    var categories: [String] {
        var seen: [String] = []
        for pack in packs where !seen.contains(pack.category) { seen.append(pack.category) }
        return seen
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let result = await host.run("command -v linpad-apps >/dev/null || exit 127; linpad-apps list --json")
        hasLoaded = true
        guard result.succeeded else {
            unavailableReason = result.exitCode == 127
                ? "This Linux system has no app catalog yet. Update Linux (Settings › About) to get it."
                : (result.stderr.isEmpty ? "Could not read the app catalog." : result.stderr)
            return
        }
        struct Listing: Decodable { let packs: [CatalogPack] }
        let line = result.stdout.split(separator: "\n").last.map(String.init) ?? ""
        guard let listing = try? JSONDecoder().decode(Listing.self, from: Data(line.utf8)) else {
            unavailableReason = "The app catalog could not be read."
            return
        }
        unavailableReason = nil
        packs = listing.packs
    }

    /// Pack ids or Store ids ("apk:<package>"); already installed packs are skipped.
    func install(_ ids: [String]) {
        let ids = ids.filter { id in !(packs.first { $0.id == id }?.isInstalled ?? false) }
        StoreModel.shared(for: host).install(ids)
    }

    func remove(_ id: String) {
        StoreModel.shared(for: host).remove(id)
    }
}
