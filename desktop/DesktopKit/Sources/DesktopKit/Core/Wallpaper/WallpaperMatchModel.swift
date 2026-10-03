import Observation
import SwiftUI

/// A proposed match for one wallpaper: the generated theme, the nearest existing one and
/// the icon pack and layout style the rule tables suggest, plus the user's choices.
struct WallpaperMatchProposal: Identifiable, Equatable, Sendable {
    let id = UUID()
    let wallpaperID: String
    let source: WallpaperSource
    let analysis: WallpaperAnalysis
    let generated: ColorTheme
    let closest: WallpaperMatching.Closest?
    let iconPack: String
    let style: WallpaperMatching.StyleSuggestion?

    var usesClosest = false
    var includesIconPack = true
    /// Off by default: a layout change is only ever made on an explicit tap.
    var includesStyle = false

    var chosenTheme: ColorTheme {
        if usesClosest, let closest { return closest.theme }
        var theme = generated
        theme.iconTheme = includesIconPack ? iconPack : nil
        return theme
    }

    static func make(analysis: WallpaperAnalysis, source: WallpaperSource, wallpaperID: String,
                     themes: [ColorTheme], installedPacks: [String]) -> WallpaperMatchProposal {
        let draft = WallpaperPalette.theme(from: analysis, id: WallpaperMatchNaming.id(for: wallpaperID),
                                           name: WallpaperMatchNaming.themeName(for: wallpaperID))
        let pack = WallpaperMatching.iconPack(accent: draft.accentRGB, installed: installedPacks)
        return WallpaperMatchProposal(wallpaperID: wallpaperID, source: source, analysis: analysis, generated: draft,
                                      closest: WallpaperMatching.closest(to: draft, in: themes), iconPack: pack,
                                      style: WallpaperMatching.style(for: analysis))
    }

    static func == (lhs: WallpaperMatchProposal, rhs: WallpaperMatchProposal) -> Bool {
        lhs.id == rhs.id && lhs.usesClosest == rhs.usesClosest && lhs.includesIconPack == rhs.includesIconPack
            && lhs.includesStyle == rhs.includesStyle
    }
}

/// "Match to Wallpaper": the prompt after a wallpaper change and the auto-match setting.
@Observable @MainActor
final class WallpaperMatchModel {
    static let autoMatchKey = "desktop.wallpaperMatch.auto"
    static let promptLifetime: Duration = .seconds(60)

    /// Off by default. On: palette and accent follow each new wallpaper; style never does.
    var autoMatch: Bool {
        didSet { defaults.set(autoMatch, forKey: Self.autoMatchKey) }
    }
    /// The non-blocking card shown after a wallpaper change.
    var prompt: WallpaperMatchProposal?
    var isAnalyzing: Bool { analysesInFlight > 0 }
    private var analysesInFlight = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var promptTimeout: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoMatch = defaults.bool(forKey: Self.autoMatchKey)
    }

    func showPrompt(_ proposal: WallpaperMatchProposal) {
        withAnimation(.snappy) { prompt = proposal }
        promptTimeout?.cancel()
        let id = proposal.id
        promptTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.promptLifetime)
            guard !Task.isCancelled, self?.prompt?.id == id else { return }
            self?.dismissPrompt()
        }
    }

    func dismissPrompt() {
        promptTimeout?.cancel()
        withAnimation(.snappy) { prompt = nil }
    }

    /// Analyses a wallpaper off the main thread; returns the analysis and the id the
    /// generated theme is named after.
    func analyze(_ source: WallpaperSource, store: WallpaperStore) async -> (WallpaperAnalysis, String)? {
        analysesInFlight += 1
        defer { analysesInFlight -= 1 }
        let result: (WallpaperAnalysis, String)?
        switch source {
        case .image(let id):
            guard let item = store.item(id) else { return nil }
            let url = store.cache.originalURL(fileName: item.fileName)
            let analysis = await Task.detached(priority: .userInitiated) { WallpaperAnalyzer.analyze(url: url) }.value
            result = analysis.map { ($0, id) }
        case .color(let rgb):
            let lab = OKLab(RGB(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255,
                                blue: Double(rgb & 0xFF) / 255))
            result = WallpaperAnalyzer.analyze(pixels: Array(repeating: lab, count: 16), width: 4, height: 4)
                .map { ($0, String(format: "color-%06x", rgb)) }
        case .gradient(let name):
            guard let gradient = DesktopWallpaper(rawValue: name) else { return nil }
            let renderer = ImageRenderer(content: gradient.view.frame(width: 192, height: 120))
            renderer.scale = 1
            guard let image = renderer.cgImage else { return nil }
            let analysis = await Task.detached(priority: .userInitiated) { WallpaperAnalyzer.analyze(image: image) }.value
            result = analysis.map { ($0, "gradient-\(name)") }
        }
        return result
    }
}
