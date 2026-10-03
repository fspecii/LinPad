import Foundation

/// Compares a generated palette with the existing colour themes and suggests an icon pack
/// and a layout style. Deterministic rule tables, no network; the user can override every
/// suggestion in the match panel.
enum WallpaperMatching {
    struct Closest: Equatable, Sendable {
        var theme: ColorTheme
        /// Weighted OKLab ΔE on the key roles; below `closeDistance` reads as "close match".
        var distance: Double
    }

    struct StyleSuggestion: Equatable, Sendable {
        var style: DesktopStyle
        /// Why, in a few words, for the panel ("soft gradients").
        var reason: String
    }

    static let closeDistance = 0.06
    /// Mean neighbour lightness step (96 px sample) below which an image reads as a soft gradient.
    static let softEdgeDensity = 0.012

    /// Weighted ΔE on background (0.35), accent (0.3), foreground (0.15) and the mean of
    /// ANSI red…cyan (0.2), plus 0.1 when one is light and the other dark.
    static func distance(_ a: ColorTheme, _ b: ColorTheme) -> Double {
        func lab(_ rgb: RGB) -> OKLab { OKLab(rgb) }
        var total = 0.35 * lab(a.backgroundRGB).distance(to: lab(b.backgroundRGB))
            + 0.3 * lab(a.accentRGB).distance(to: lab(b.accentRGB))
            + 0.15 * lab(a.foregroundRGB).distance(to: lab(b.foregroundRGB))
        let left = a.terminalColors, right = b.terminalColors
        if left.count == 16, right.count == 16 {
            total += 0.2 * (1...6).reduce(0) { $0 + lab(left[$1]).distance(to: lab(right[$1])) } / 6
        } else {
            total += 0.2 * lab(a.redRGB).distance(to: lab(b.redRGB))
        }
        if a.isDark != b.isDark { total += 0.1 }
        return total
    }

    /// The existing theme nearest to `generated`, generated wallpaper themes excluded.
    static func closest(to generated: ColorTheme, in themes: [ColorTheme]) -> Closest? {
        themes.filter { $0.id != generated.id && !WallpaperMatchNaming.isGenerated($0.id) }
            .map { Closest(theme: $0, distance: distance(generated, $0)) }
            .min { $0.distance != $1.distance ? $0.distance < $1.distance : $0.theme.id < $1.theme.id }
    }

    // MARK: Icon packs

    /// Icon pack by the accent's hue and chroma (OKLCh). Each row lists theme ids in order
    /// of preference; the first installed one wins, Papirus is the last resort.
    ///
    /// | accent | packs |
    /// |---|---|
    /// | grey (chroma < 0.04) | Colloid, Adwaita |
    /// | red / orange 345°–75° | Numix-Circle (orange folders) |
    /// | yellow / olive 75°–120° | kora |
    /// | green 120°–170° | Tela-circle-green, Qogir |
    /// | teal / cyan 170°–215° | Qogir |
    /// | blue 215°–285° | Tela-circle |
    /// | purple / pink 285°–345° | Tela-circle-purple, Tela-circle |
    static func iconPackCandidates(accent: RGB) -> [String] {
        let lab = OKLab(accent)
        let hue = lab.hue
        let preferred: [String]
        if lab.chroma < 0.04 {
            preferred = ["Colloid", "Adwaita"]
        } else if hue >= 345 || hue < 75 {
            preferred = ["Numix-Circle"]
        } else if hue < 120 {
            preferred = ["kora"]
        } else if hue < 170 {
            preferred = ["Tela-circle-green", "Qogir"]
        } else if hue < 215 {
            preferred = ["Qogir"]
        } else if hue < 285 {
            preferred = ["Tela-circle"]
        } else {
            preferred = ["Tela-circle-purple", "Tela-circle"]
        }
        return preferred + ["Papirus"]
    }

    /// Packs in every image (ish-icon-packs: adwaita papirus breeze tela-circle colloid
    /// qogir numix-circle kora), used when the guest's list is not known yet.
    static let defaultInstalledPacks: Set<String> = ["Adwaita", "Papirus", "breeze", "Tela-circle", "Colloid", "Qogir",
                                                     "Numix-Circle", "kora"]

    static func iconPack(accent: RGB, installed: [String]) -> String {
        let available = installed.isEmpty ? defaultInstalledPacks : Set(installed)
        let candidates = iconPackCandidates(accent: accent)
        return candidates.first { available.contains($0) } ?? "Papirus"
    }

    // MARK: Layout style

    /// Layout style by image character; the first matching row wins, no row keeps the
    /// current style. Only ever offered: a style change always needs the user's tap.
    ///
    /// | image | style |
    /// |---|---|
    /// | flat, posterised teal/cyan (retro desktop) | Classic 98 |
    /// | soft gradient, light, blue | Aqua |
    /// | soft gradient (not grey) | macOS |
    /// | near-monochrome, dark | Tiler (minimal, flat) |
    /// | near-monochrome, light | Platinum |
    /// | high contrast, few colours (minimal / flat art) | Tiler |
    /// | dark, purple / magenta dominant | Berry |
    /// | light, green land with blue sky | Luna |
    /// | dark, blue dominant | Aero Night |
    /// | light, blue dominant | Aero |
    static func style(for analysis: WallpaperAnalysis) -> StyleSuggestion? {
        let dominant = analysis.dominant.color
        let dark = analysis.prefersDark
        let blue = 215.0...285.0
        let significant = analysis.clusters.filter { $0.share >= 0.04 }.count
        if analysis.flatness >= 0.6, dominant.chroma >= 0.05, (170.0...215.0).contains(dominant.hue),
           analysis.dominant.share >= 0.3 {
            return StyleSuggestion(style: .classic, reason: "flat retro teal")
        }
        if analysis.edgeDensity < softEdgeDensity, analysis.colorfulness >= 0.02 {
            if !dark, blue.contains(dominant.hue), dominant.chroma >= 0.02 {
                return StyleSuggestion(style: .aqua, reason: "soft blue gradients")
            }
            return StyleSuggestion(style: .macos, reason: "soft gradients")
        }
        if analysis.isNearMonochrome {
            return dark ? StyleSuggestion(style: .tiler, reason: "minimal, near-monochrome")
                        : StyleSuggestion(style: .platinum, reason: "light and near-monochrome")
        }
        if analysis.lightnessSpread >= 0.25, significant <= 4, analysis.flatness >= 0.5 {
            return StyleSuggestion(style: .tiler, reason: "high-contrast, flat")
        }
        if dark, analysis.share(hues: 285...350) >= 0.3 {
            return StyleSuggestion(style: .berry, reason: "dark purples")
        }
        if !dark || analysis.meanLightness >= 0.5,
           analysis.share(hues: 100...170) >= 0.2, analysis.share(hues: blue) >= 0.1 {
            return StyleSuggestion(style: .luna, reason: "green land, blue sky")
        }
        if (blue.contains(dominant.hue) && dominant.chroma >= 0.03) || analysis.share(hues: blue) >= 0.3 {
            return dark ? StyleSuggestion(style: .aeronight, reason: "deep blues")
                        : StyleSuggestion(style: .aero, reason: "bright blues")
        }
        return nil
    }
}

/// Names and ids of themes generated from wallpapers: one theme per wallpaper, so
/// matching the same image again replaces it instead of piling up copies.
enum WallpaperMatchNaming {
    static let namePrefix = "From wallpaper — "
    /// `ColorsToml.id(forName:)` of the name prefix, so the theme editor, which derives the
    /// id from the name, saves an edited match over the same theme.
    static let idPrefix = "from-wallpaper-"

    static func isGenerated(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    static func id(for wallpaperID: String) -> String {
        ColorsToml.id(forName: themeName(for: wallpaperID))
    }

    /// "builtin-dunes" → "Dunes", "wallhaven-abc123" → "Wallhaven abc123", "photos-1a2b" → "Photo 1a2b".
    static func displayName(for wallpaperID: String) -> String {
        if wallpaperID.hasPrefix(BuiltInWallpapers.prefix) {
            return String(wallpaperID.dropFirst(BuiltInWallpapers.prefix.count)).replacingOccurrences(of: "-", with: " ").capitalized
        }
        let parts = wallpaperID.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return wallpaperID }
        let kind = switch parts[0] {
        case "wallhaven": "Wallhaven"
        case "photos": "Photo"
        case "files": "File"
        case "guest": "Linux picture"
        case "color": "Color"
        default: parts[0].capitalized
        }
        return "\(kind) \(parts[1])"
    }

    static func themeName(for wallpaperID: String) -> String {
        namePrefix + displayName(for: wallpaperID)
    }
}
