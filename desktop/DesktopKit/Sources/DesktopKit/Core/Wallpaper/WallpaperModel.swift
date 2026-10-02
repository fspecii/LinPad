import Foundation
import Observation
import SwiftUI
import UIKit

/// What a wallpaper is made of.
enum WallpaperSource: Codable, Hashable, Sendable {
    /// One of the built-in gradients (`DesktopWallpaper`).
    case gradient(String)
    /// A solid color, 0xRRGGBB.
    case color(UInt32)
    /// An image in the wallpaper library, by library id.
    case image(String)

    static let `default` = WallpaperSource.gradient(DesktopWallpaper.midnight.rawValue)

    /// A stable string for accessibility and tests ("gradient:aurora", "image:wallhaven-abc").
    var identifier: String {
        switch self {
        case .gradient(let name): "gradient:\(name)"
        case .color(let rgb): String(format: "color:%06X", rgb)
        case .image(let id): "image:\(id)"
        }
    }
}

enum WallpaperFill: String, Codable, CaseIterable, Identifiable, Sendable {
    case fill
    case fit
    case center
    case tile
    case stretch

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct WallpaperSlideshow: Codable, Equatable, Sendable {
    enum Source: String, Codable, CaseIterable, Sendable {
        /// Every image marked as a favorite in the library.
        case favorites
        /// Every image in the library.
        case library
    }

    var isEnabled = false
    var source = Source.favorites
    var interval: TimeInterval = 15 * 60
    var shuffle = false
}

/// Everything the user chose; persisted as JSON under `desktop.wallpaper`.
struct WallpaperSettings: Codable, Equatable, Sendable {
    var light = WallpaperSource.default
    var dark = WallpaperSource.default
    var fill = WallpaperFill.fill
    /// When true, `perWorkspace` overrides the shared wallpaper for those workspaces.
    var usesPerWorkspace = false
    var perWorkspace: [Int: WallpaperSource] = [:]
    var slideshow = WallpaperSlideshow()

    func source(workspace: Int, isDark: Bool) -> WallpaperSource {
        if usesPerWorkspace, let own = perWorkspace[workspace] { return own }
        return isDark ? dark : light
    }
}

/// An image the user added: the original lives in Application Support/Wallpapers, with
/// where it came from and whom to credit.
struct WallpaperItem: Codable, Identifiable, Hashable, Sendable {
    enum Origin: String, Codable, Sendable {
        case builtIn
        case photos
        case files
        case guest
        case wallhaven
    }

    let id: String
    var fileName: String
    var origin: Origin
    var attribution: String?
    var sourceURL: URL?
    var isFavorite = false
    var addedAt = Date()
}

/// Which slot a "Set as Wallpaper" fills. Everything but `.currentWorkspace` covers all
/// workspaces and clears their own wallpapers.
enum WallpaperTarget: String, CaseIterable, Identifiable, Sendable {
    case both
    case light
    case dark
    case currentWorkspace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: "All Workspaces"
        case .light: "All Workspaces, Light Appearance"
        case .dark: "All Workspaces, Dark Appearance"
        case .currentWorkspace: "This Workspace Only"
        }
    }
}

/// The wallpaper library, the settings, and the one decoded bitmap per visible wallpaper.
@Observable @MainActor
final class WallpaperStore {
    static let settingsKey = "desktop.wallpaper"
    static let libraryKey = "desktop.wallpaperLibrary"

    private(set) var settings: WallpaperSettings
    private(set) var library: [WallpaperItem]
    /// Decoded, screen-sized images by library id; only the ones on screen stay loaded.
    private(set) var decoded: [String: UIImage] = [:]
    /// Blurred, dimmed variants for the overview and lock screen.
    private(set) var blurred: [String: UIImage] = [:]
    /// The slideshow's current pick; nil shows the configured wallpaper.
    private(set) var slideshowCurrent: String?
    /// Mirrors of the desktop's state, for Settings and the Wallpapers app.
    var currentWorkspace = 0
    var isDark = true
    /// A Settings page an already open Settings window should scroll to.
    var pageRequest: String?

    @ObservationIgnored let cache: WallpaperImageCache
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var slideshowTask: Task<Void, Never>?
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored var targetPixelSize: CGSize = CGSize(width: 2732, height: 2732)
    /// Reports a wallpaper change with a way to undo it (the desktop shows a toast).
    @ObservationIgnored var onApplied: ((String, @escaping @MainActor () -> Void) -> Void)?

    init(defaults: UserDefaults = .standard, cache: WallpaperImageCache = WallpaperImageCache()) {
        self.defaults = defaults
        self.cache = cache
        settings = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(WallpaperSettings.self, from: $0) } ?? WallpaperSettings()
        library = defaults.data(forKey: Self.libraryKey)
            .flatMap { try? JSONDecoder().decode([WallpaperItem].self, from: $0) } ?? []
        BuiltInWallpapers.install(into: &library, cache: cache)
    }

    func item(_ id: String) -> WallpaperItem? {
        library.first { $0.id == id }
    }

    /// The source shown on `workspace` right now, slideshow included.
    func activeSource(workspace: Int, isDark: Bool) -> WallpaperSource {
        if settings.slideshow.isEnabled, let current = slideshowCurrent { return .image(current) }
        return settings.source(workspace: workspace, isDark: isDark)
    }

    // MARK: Changing settings

    func update(_ change: (inout WallpaperSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        settings = copy
        if let data = try? JSONEncoder().encode(copy) { defaults.set(data, forKey: Self.settingsKey) }
        restartSlideshow()
    }

    /// Workspaces were reordered or deleted (old index → new index); deleted ones are absent.
    func remapWorkspaces(_ mapping: [Int: Int]) {
        update { settings in
            var moved: [Int: WallpaperSource] = [:]
            for (old, source) in settings.perWorkspace {
                if let new = mapping[old] { moved[new] = source }
            }
            settings.perWorkspace = moved
        }
        if let new = mapping[currentWorkspace] { currentWorkspace = new }
    }

    func set(_ source: WallpaperSource, target: WallpaperTarget, workspace: Int) {
        let previous = settings
        update { settings in
            switch target {
            case .both:
                settings.light = source
                settings.dark = source
            case .light: settings.light = source
            case .dark: settings.dark = source
            case .currentWorkspace:
                settings.usesPerWorkspace = true
                settings.perWorkspace[workspace] = source
            }
            if target != .currentWorkspace {
                settings.perWorkspace = [:]
                settings.usesPerWorkspace = false
            }
            settings.slideshow.isEnabled = false
        }
        slideshowCurrent = nil
        guard settings != previous else { return }
        let message = target == .currentWorkspace ? "Wallpaper set for workspace \(workspace + 1)."
                                                  : "Wallpaper set for all workspaces."
        onApplied?(message) { [weak self] in self?.update { $0 = previous } }
    }

    // MARK: Library

    /// Copies an image into the library. The original is kept; displays use a downsampled copy.
    @discardableResult
    func add(imageData: Data, suggestedName: String, origin: WallpaperItem.Origin, attribution: String? = nil,
             sourceURL: URL? = nil, id: String? = nil) throws -> WallpaperItem {
        let id = id ?? "\(origin.rawValue)-\(UUID().uuidString.prefix(8).lowercased())"
        if let existing = item(id) { return existing }
        guard WallpaperImageCache.isDecodableImage(imageData) else { throw WallpaperError.notAnImage }
        let ext = (suggestedName as NSString).pathExtension.lowercased()
        let fileName = "\(id).\(ext.isEmpty ? "img" : ext)"
        try cache.storeOriginal(imageData, fileName: fileName)
        let item = WallpaperItem(id: id, fileName: fileName, origin: origin, attribution: attribution,
                                 sourceURL: sourceURL)
        library.insert(item, at: 0)
        saveLibrary()
        return item
    }

    func toggleFavorite(_ id: String) {
        guard let index = library.firstIndex(where: { $0.id == id }) else { return }
        library[index].isFavorite.toggle()
        saveLibrary()
        restartSlideshow()
    }

    func remove(_ id: String) {
        guard let index = library.firstIndex(where: { $0.id == id }), library[index].origin != .builtIn else { return }
        let item = library.remove(at: index)
        cache.removeOriginal(item.fileName, id: item.id)
        decoded[id] = nil
        blurred[id] = nil
        update { settings in
            if settings.light == .image(id) { settings.light = .default }
            if settings.dark == .image(id) { settings.dark = .default }
            settings.perWorkspace = settings.perWorkspace.filter { $0.value != .image(id) }
        }
        saveLibrary()
    }

    private func saveLibrary() {
        if let data = try? JSONEncoder().encode(library.filter { $0.origin != .builtIn || $0.isFavorite }) {
            defaults.set(data, forKey: Self.libraryKey)
        }
    }

    // MARK: Decoding

    /// Loads the screen-sized bitmap for `id` (and its blurred twin) off the main thread,
    /// keeping only the images in `visible` in memory.
    func ensureDecoded(_ visible: Set<String>) {
        for id in decoded.keys where !visible.contains(id) { decoded[id] = nil }
        for id in blurred.keys where !visible.contains(id) { blurred[id] = nil }
        for id in visible where decoded[id] == nil && !loading.contains(id) {
            guard let item = item(id) else { continue }
            loading.insert(id)
            let cache = cache
            let size = targetPixelSize
            Task { [weak self] in
                let images = await cache.screenImages(fileName: item.fileName, id: item.id, maxPixelSize: size)
                guard let self else { return }
                self.loading.remove(id)
                if let images {
                    self.decoded[id] = images.sharp
                    self.blurred[id] = images.blurred
                }
            }
        }
    }

    // MARK: Slideshow

    private func restartSlideshow() {
        slideshowTask?.cancel()
        guard settings.slideshow.isEnabled else {
            slideshowCurrent = nil
            return
        }
        let candidates = slideshowCandidates()
        guard !candidates.isEmpty else { return }
        if slideshowCurrent == nil || !candidates.contains(slideshowCurrent!) {
            slideshowCurrent = settings.slideshow.shuffle ? candidates.randomElement() : candidates[0]
        }
        let interval = max(settings.slideshow.interval, 10)
        slideshowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self?.advanceSlideshow()
            }
        }
    }

    func advanceSlideshow() {
        let candidates = slideshowCandidates()
        guard !candidates.isEmpty else { return }
        if settings.slideshow.shuffle, candidates.count > 1 {
            slideshowCurrent = candidates.filter { $0 != slideshowCurrent }.randomElement()
        } else {
            let index = slideshowCurrent.flatMap(candidates.firstIndex(of:)).map { $0 + 1 } ?? 0
            slideshowCurrent = candidates[index % candidates.count]
        }
    }

    private func slideshowCandidates() -> [String] {
        switch settings.slideshow.source {
        case .favorites: library.filter(\.isFavorite).map(\.id)
        case .library: library.map(\.id)
        }
    }

    func startSlideshowIfNeeded() {
        if settings.slideshow.isEnabled && slideshowTask == nil { restartSlideshow() }
    }
}

enum WallpaperError: LocalizedError {
    case notAnImage

    var errorDescription: String? { "That file is not an image the desktop can show." }
}

private struct WallpaperStoreKey: EnvironmentKey {
    static let defaultValue: WallpaperStore? = nil
}

extension EnvironmentValues {
    var desktopWallpapers: WallpaperStore? {
        get { self[WallpaperStoreKey.self] }
        set { self[WallpaperStoreKey.self] = newValue }
    }
}
