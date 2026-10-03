import SwiftUI

/// A complete desktop theme: a layout style with its era chrome, a colour theme (with a dark
/// partner where the era had one), styling, an original wallpaper and the GTK/Qt/icon/font
/// pairing the guest applies (themes/guest/styles/<style>.conf). Applying one is one tap in
/// the Themes app; Revert restores what was there before the first one was applied.
struct DesktopThemePreset: Identifiable, Equatable, Sendable {
    enum Wallpaper: Equatable, Sendable {
        case builtIn(String)
        case color(UInt32)

        var source: WallpaperSource {
            switch self {
            case .builtIn(let name): .image(BuiltInWallpapers.prefix + name)
            case .color(let rgb): .color(rgb)
            }
        }
    }

    /// What Linux apps get, for the card (the guest's style conf is the source of truth).
    struct LinuxPairing: Equatable, Sendable {
        var gtk: String
        var icons: String
        var font: String
        /// The GTK theme downloads on first use (ish-style-packs).
        var downloads = false
    }

    var id: String
    var name: String
    var tagline: String
    var style: DesktopStyle
    /// "" keeps the style's own colours.
    var lightColorTheme: String
    /// The dark member of the pair, when the era had a dark look.
    var darkColorTheme: String?
    var startsDark = false
    var wallpaper: Wallpaper
    var darkWallpaper: Wallpaper?
    /// DesktopAppearance for presets without colour themes ("system" follows the iPad).
    var appearanceID: String?
    var styling = DesktopStyling()
    var brushedMetal = false
    /// Widgets put on the first workspace when it has none (Dot Matrix is widget-forward).
    var widgets: [DesktopWidgetKind] = []
    var linux: LinuxPairing

    static let storageKey = "desktop.themePreset"
    static let snapshotKey = "desktop.themePreset.snapshot"
    /// Widgets a preset put on the desktop, removed again when another preset or Revert applies.
    static let widgetsKey = "desktop.themePreset.widgets"
    /// Appended to the stored preset id when its dark member is applied.
    static let darkSuffix = ":dark"

    var hasDarkPair: Bool { darkColorTheme != nil || appearanceID == "system" }

    static let all: [DesktopThemePreset] = {
        var luna = DesktopStyling()
        luna.cornerRadius = 8
        luna.linuxUIFont = "DejaVu Sans"
        var glass = DesktopStyling()
        glass.cornerRadius = 8
        glass.linuxUIFont = "Noto Sans"
        var square = DesktopStyling()
        square.cornerRadius = 0
        square.windowShadows = false
        square.panelBlur = false
        square.linuxUIFont = "DejaVu Sans"
        var aqua = DesktopStyling()
        aqua.cornerRadius = 7
        aqua.linuxUIFont = "DejaVu Sans"
        var mac = DesktopStyling()
        mac.cornerRadius = 12
        mac.innerGap = 8
        mac.outerGap = 16
        mac.linuxUIFont = "Inter"
        var berry = DesktopStyling()
        berry.cornerRadius = 10
        berry.linuxUIFont = "Noto Sans"
        var dot = DesktopStyling()
        dot.cornerRadius = 18
        dot.windowShadows = false
        dot.panelBlur = false
        dot.uiFont = .monospaced
        dot.linuxUIFont = "Noto Sans Mono"
        dot.linuxMonoFont = "Noto Sans Mono"

        return [
            DesktopThemePreset(id: "luna", name: "Luna", tagline: "Inspired by the XP era: blue taskbar, green start, rolling hills",
                               style: .luna, lightColorTheme: "luna", wallpaper: .builtIn("meadow"), styling: luna,
                               linux: LinuxPairing(gtk: "Luna (B00merang, GPL-3.0)", icons: "Papirus", font: "DejaVu Sans", downloads: true)),
            DesktopThemePreset(id: "aero", name: "Aero", tagline: "Inspired by the 7 era: glass title bars, light glass taskbar, orb",
                               style: .aero, lightColorTheme: "aero", darkColorTheme: "aero-night",
                               wallpaper: .builtIn("aurora"), darkWallpaper: .builtIn("aurora-night"), styling: glass,
                               linux: LinuxPairing(gtk: "Aero (B00merang, GPL-3.0)", icons: "Fluent", font: "Noto Sans", downloads: true)),
            DesktopThemePreset(id: "aero-night", name: "Aero Night", tagline: "Inspired by the Vista era: glass windows over a black glass taskbar",
                               style: .aeronight, lightColorTheme: "aero", darkColorTheme: "aero-night",
                               wallpaper: .builtIn("aurora-night"), darkWallpaper: .builtIn("aurora-night"), styling: glass,
                               linux: LinuxPairing(gtk: "Aero Night (B00merang, GPL-3.0)", icons: "Fluent", font: "Noto Sans", downloads: true)),
            DesktopThemePreset(id: "classic-98", name: "Classic 98", tagline: "Inspired by the 98 era: grey bevels, navy titles, a teal desktop",
                               style: .classic, lightColorTheme: "classic-98", wallpaper: .color(0x008080), styling: square,
                               linux: LinuxPairing(gtk: "Chicago95 GTK (GPL-3.0+/MIT)", icons: "Papirus", font: "DejaVu Sans", downloads: true)),
            DesktopThemePreset(id: "platinum", name: "Platinum", tagline: "Inspired by the classic Mac era: striped title bars, a menu bar on top",
                               style: .platinum, lightColorTheme: "platinum", wallpaper: .builtIn("platinum"), styling: square,
                               linux: LinuxPairing(gtk: "Platinum (B00merang, GPL-3.0)", icons: "Qogir", font: "DejaVu Sans Condensed", downloads: true)),
            DesktopThemePreset(id: "aqua", name: "Aqua", tagline: "Inspired by early OS X: pinstripes, gel buttons, a white Dock",
                               style: .aqua, lightColorTheme: "aqua", wallpaper: .builtIn("aqua"), styling: aqua,
                               linux: LinuxPairing(gtk: "Aqua (B00merang, GPL-3.0)", icons: "WhiteSur", font: "DejaVu Sans", downloads: true)),
            DesktopThemePreset(id: "aqua-metal", name: "Aqua Metal", tagline: "Aqua with brushed-metal title bars",
                               style: .aqua, lightColorTheme: "aqua", wallpaper: .builtIn("aqua"), styling: aqua, brushedMetal: true,
                               linux: LinuxPairing(gtk: "Aqua (B00merang, GPL-3.0)", icons: "WhiteSur", font: "DejaVu Sans", downloads: true)),
            DesktopThemePreset(id: "modern-mac", name: "Modern Mac", tagline: "Today's Mac look: traffic lights, a frosted Dock, light and dark",
                               style: .macos, lightColorTheme: "", wallpaper: .builtIn("sonora"), appearanceID: "system", styling: mac,
                               linux: LinuxPairing(gtk: "WhiteSur (MIT)", icons: "WhiteSur", font: "Inter")),
            DesktopThemePreset(id: "berry", name: "Berry", tagline: "Inspired by the handheld era: dark chrome bezels, blue focus",
                               style: .berry, lightColorTheme: "berry", startsDark: true, wallpaper: .builtIn("berry"), styling: berry,
                               linux: LinuxPairing(gtk: "Adwaita, recoloured", icons: "Papirus Dark", font: "Noto Sans")),
            DesktopThemePreset(id: "dot-matrix", name: "Dot Matrix", tagline: "Monochrome, one red accent, dot-matrix type and widgets",
                               style: .dotmatrix, lightColorTheme: "dot-matrix", darkColorTheme: "dot-matrix-dark",
                               wallpaper: .builtIn("dots-light"), darkWallpaper: .builtIn("dots-dark"), styling: dot,
                               widgets: [.clock, .weather, .battery],
                               linux: LinuxPairing(gtk: "Adwaita, recoloured", icons: "kora pgrey", font: "Noto Sans Mono")),
        ]
    }()

    static func preset(_ id: String) -> DesktopThemePreset? {
        all.first { $0.id == id }
    }

    /// Every desktop theme (and the dark member of paired ones) as a built-in Look, so Looks,
    /// the Command Menu and shared links apply them through the same path.
    static let looks: [DesktopLook] = all.flatMap { preset -> [DesktopLook] in
        func look(dark: Bool?) -> DesktopLook {
            let isDark = dark == true
            return DesktopLook(id: "desktop-theme-\(preset.id)\(isDark ? "-dark" : "")",
                               name: preset.name + (isDark ? " Dark" : ""), styleID: preset.style.rawValue,
                               colorThemeID: isDark ? (preset.darkColorTheme ?? preset.lightColorTheme) : preset.lightColorTheme,
                               styling: preset.styling, wallpaperQuery: nil, appearanceID: preset.appearanceID,
                               isBuiltIn: true, presetID: preset.id, presetDark: dark,
                               brushedMetal: preset.brushedMetal)
        }
        return preset.darkColorTheme != nil ? [look(dark: false), look(dark: true)] : [look(dark: nil)]
    }
}

/// What was set before the first desktop theme, so Revert can bring it back.
struct DesktopThemeSnapshot: Codable, Equatable {
    var styleID: String
    var colorThemeID: String
    var appearanceID: String
    var styling: DesktopStyling
    var wallpaper: WallpaperSettings
    var themeAppearance: ThemeAppearance
    var brushedMetal: Bool
}

extension DesktopController {
    var activeDesktopThemePresetID: String {
        UserDefaults.standard.string(forKey: DesktopThemePreset.storageKey) ?? ""
    }

    /// `dark` picks the dark member of a paired preset (Aero, Dot Matrix); nil uses the
    /// preset's own default.
    func applyDesktopThemePreset(_ preset: DesktopThemePreset, dark: Bool? = nil) {
        let wantsDark = (dark ?? preset.startsDark) && (preset.darkColorTheme != nil || preset.startsDark || preset.appearanceID != nil)
        let defaults = UserDefaults.standard
        if defaults.data(forKey: DesktopThemePreset.snapshotKey) == nil {
            let snapshot = DesktopThemeSnapshot(
                styleID: defaults.string(forKey: DesktopStyle.storageKey) ?? DesktopStyle.defaultStyle.rawValue,
                colorThemeID: colorThemes.currentID,
                appearanceID: defaults.string(forKey: DesktopAppearance.storageKey) ?? "",
                styling: styling, wallpaper: wallpapers.settings, themeAppearance: themeAppearance,
                brushedMetal: defaults.bool(forKey: EraSettings.brushedMetalKey))
            if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: DesktopThemePreset.snapshotKey) }
        }

        defaults.set(preset.brushedMetal, forKey: EraSettings.brushedMetalKey)
        let appearanceID = dark == nil ? preset.appearanceID : nil
        defaults.set(appearanceID ?? (wantsDark ? DesktopAppearance.dark.rawValue : DesktopAppearance.light.rawValue),
                     forKey: DesktopAppearance.storageKey)
        defaults.set(preset.style.rawValue, forKey: DesktopStyle.storageKey)
        // The style switches before the colours so its defaults cannot override them later.
        applyStyle(preset.style, dark: wantsDark)

        // The pair is recorded for Themes › Light & Dark, but switching stays off: an enabled
        // mode would pin one member and undo a later pick of the other (the Dot Matrix Dark bug).
        var appearance = themeAppearance
        if let darkID = preset.darkColorTheme {
            appearance.lightThemeID = preset.lightColorTheme
            appearance.darkThemeID = darkID
            appearance.pairs[preset.lightColorTheme] = darkID
            appearance.mode = wantsDark ? .dark : .light
        }
        appearance.isEnabled = false
        updateThemeAppearance(appearance)
        let colors = wantsDark ? (preset.darkColorTheme ?? preset.lightColorTheme) : preset.lightColorTheme
        applyColorTheme(colors)
        updateStyling(preset.styling)

        wallpapers.update { settings in
            settings.light = preset.wallpaper.source
            settings.dark = (preset.darkWallpaper ?? preset.wallpaper).source
            settings.perWorkspace = [:]
            settings.usesPerWorkspace = false
            settings.slideshow.isEnabled = false
        }
        removePresetWidgets()
        if !preset.widgets.isEmpty, widgets.widgets(workspace: 0).isEmpty {
            var added: [String] = []
            for kind in preset.widgets {
                let widget = widgets.add(kind, workspace: 0)
                if kind == .clock { widgets.setOption("style", "digital", for: widget.id, workspace: 0) }
                added.append(widget.id.uuidString)
            }
            widgets.selectedID = nil
            defaults.set(added, forKey: DesktopThemePreset.widgetsKey)
        }
        defaults.set(preset.id + (preset.darkColorTheme != nil && wantsDark ? DesktopThemePreset.darkSuffix : ""),
                     forKey: DesktopThemePreset.storageKey)
        notify("Desktop theme: \(preset.name)\(preset.darkColorTheme != nil && wantsDark ? " (Dark)" : "")")
    }

    /// A plain look or style pick leaves the desktop theme: its widgets go, the gallery stops
    /// marking it applied; the Revert snapshot stays.
    func clearDesktopThemePreset() {
        removePresetWidgets()
        UserDefaults.standard.removeObject(forKey: DesktopThemePreset.storageKey)
    }

    private func removePresetWidgets() {
        let defaults = UserDefaults.standard
        let ids = Set(defaults.stringArray(forKey: DesktopThemePreset.widgetsKey) ?? [])
        for widget in widgets.widgets(workspace: 0) where ids.contains(widget.id.uuidString) {
            widgets.remove(widget.id, workspace: 0)
        }
        defaults.removeObject(forKey: DesktopThemePreset.widgetsKey)
    }

    /// Back to the style, colours, styling and wallpaper from before the first desktop theme.
    func revertDesktopThemePreset() {
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: DesktopThemePreset.snapshotKey)
            defaults.removeObject(forKey: DesktopThemePreset.storageKey)
        }
        removePresetWidgets()
        guard let data = defaults.data(forKey: DesktopThemePreset.snapshotKey),
              let snapshot = try? JSONDecoder().decode(DesktopThemeSnapshot.self, from: data) else { return }
        defaults.set(snapshot.brushedMetal, forKey: EraSettings.brushedMetalKey)
        defaults.set(snapshot.appearanceID, forKey: DesktopAppearance.storageKey)
        defaults.set(snapshot.styleID, forKey: DesktopStyle.storageKey)
        updateThemeAppearance(snapshot.themeAppearance)
        applyColorTheme(snapshot.colorThemeID)
        updateStyling(snapshot.styling)
        wallpapers.update { $0 = snapshot.wallpaper }
        notify("Desktop theme reverted")
    }
}

// MARK: - Themes app › Gallery

/// The desktop themes at the top of the Themes gallery.
struct DesktopThemesSection: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme
    @AppStorage(DesktopThemePreset.storageKey) private var activeID = ""
    @AppStorage(DesktopThemePreset.snapshotKey) private var snapshot: Data?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Desktop Themes").font(.system(size: 17, weight: .semibold))
                    Text("Window chrome, panels, colours, wallpaper, and the matching GTK, icon and font set for Linux apps.")
                        .font(.caption).foregroundStyle(theme.secondaryText)
                }
                Spacer()
                if snapshot != nil {
                    Button("Revert to Previous Look") { controller.revertDesktopThemePreset() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("themes.desktop.revert")
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 16)], spacing: 18) {
                ForEach(DesktopThemePreset.all) { card($0) }
            }
            HStack {
                Text("Colour Themes").font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            .padding(.top, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("themes.desktop")
    }

    private func card(_ preset: DesktopThemePreset) -> some View {
        let isActive = activeID == preset.id || activeID == preset.id + DesktopThemePreset.darkSuffix
        return VStack(alignment: .leading, spacing: 8) {
            DesktopThemePreviewCard(preset: preset, colors: controller.colorThemes)
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isActive ? theme.accent : theme.separator, lineWidth: isActive ? 3 : 1))
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(preset.name).font(.system(size: 14, weight: .semibold))
                        if preset.hasDarkPair {
                            Image(systemName: "circle.lefthalf.filled").font(.caption).foregroundStyle(theme.secondaryText)
                                .accessibilityLabel("Light and dark")
                        }
                    }
                    Text(preset.tagline).font(.caption).foregroundStyle(theme.secondaryText).lineLimit(2)
                    Text("Linux: \(preset.linux.gtk) · \(preset.linux.icons) · \(preset.linux.font)"
                         + (preset.linux.downloads ? " · downloads on first use" : ""))
                        .font(.caption2).foregroundStyle(theme.secondaryText).lineLimit(2)
                }
                Spacer()
                if preset.darkColorTheme != nil {
                    // Paired presets apply either member directly.
                    let lightActive = activeID == preset.id, darkActive = activeID == preset.id + DesktopThemePreset.darkSuffix
                    Button(lightActive ? "Light ✓" : "Light") { controller.applyDesktopThemePreset(preset, dark: false) }
                        .buttonStyle(.primary)
                        .disabled(lightActive)
                        .accessibilityIdentifier("themes.desktop.apply.\(preset.id)")
                    Button(darkActive ? "Dark ✓" : "Dark") { controller.applyDesktopThemePreset(preset, dark: true) }
                        .buttonStyle(.primary)
                        .disabled(darkActive)
                        .accessibilityIdentifier("themes.desktop.apply.\(preset.id).dark")
                } else {
                    Button(isActive ? "Applied" : "Apply") { controller.applyDesktopThemePreset(preset) }
                        .buttonStyle(.primary)
                        .disabled(isActive)
                        .accessibilityIdentifier("themes.desktop.apply.\(preset.id)")
                }
            }
            .font(.system(size: 13))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("themes.desktop.card.\(preset.id)")
    }
}

/// A desktop theme drawn small with its real chrome: wallpaper, one window with the era's
/// title bar, buttons and frame, and the era's panel. Laid out at 640 x 400 and scaled.
struct DesktopThemePreviewCard: View {
    let preset: DesktopThemePreset
    let colors: ColorThemeStore

    private static let canvas = CGSize(width: 640, height: 400)

    private var desktopTheme: DesktopTheme {
        let spec = preset.style.spec
        var theme = spec.theme(base: .dark, isDark: preset.startsDark)
        let id = preset.startsDark ? (preset.darkColorTheme ?? preset.lightColorTheme) : preset.lightColorTheme
        if let colorTheme = colors.theme(id) {
            theme = colorTheme.applied(to: theme, panelOpacity: theme.panelBackground.opacityComponent)
        }
        return theme
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = max(proxy.size.width / Self.canvas.width, proxy.size.height / Self.canvas.height)
            content
                .frame(width: Self.canvas.width, height: Self.canvas.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .clipped()
        .environment(\.desktopTheme, desktopTheme)
        .environment(\.desktopStyle, preset.style)
        .environment(\.colorScheme, preset.startsDark ? .dark : .light)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var content: some View {
        let spec = preset.style.spec
        let skin = spec.skin
        let theme = desktopTheme
        return ZStack(alignment: .topLeading) {
            PresetWallpaper(wallpaper: preset.startsDark ? (preset.darkWallpaper ?? preset.wallpaper) : preset.wallpaper)
            VStack(spacing: 0) {
                topBar(skin)
                ZStack {
                    window(skin: skin, theme: theme, spec: spec)
                        .frame(width: 400, height: 250)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBar(skin)
            }
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
        .environment(\.brushedMetalPreview, preset.brushedMetal)
    }

    @ViewBuilder
    private func topBar(_ skin: EraSkin?) -> some View {
        switch skin {
        case .platinum?, .aqua?:
            HStack(spacing: 14) {
                EraMark(size: 13, color: Color(rgb: skin == .platinum ? 0x6666CC : 0x3875D7))
                Text("Files").bold()
                Text("Window")
                Text("Go")
                Spacer()
                Text("12:30")
            }
            .font(.system(size: 12))
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(skin == .platinum ? EraSkin.platinumFace : Color.white.opacity(0.95))
            .overlay(alignment: .bottom) { Color.black.opacity(skin == .platinum ? 1 : 0.35).frame(height: 1) }
        case .berry?:
            HStack(spacing: 6) {
                Text("12:30").font(.system(size: 15, weight: .bold))
                Text("Fri 2 Oct").font(.system(size: 10)).opacity(0.65)
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
            }
            .foregroundStyle(.white).padding(.horizontal, 10).frame(height: 28)
            .background(LinearGradient(colors: [Color(rgb: 0x2B2F35), Color(rgb: 0x0B0C0E)], startPoint: .top, endPoint: .bottom))
        case .dotMatrix?:
            HStack {
                Text("12:30").dotMatrixFont(size: 18)
                Spacer()
                Image(systemName: "battery.75percent")
            }
            .foregroundStyle(desktopTheme.primaryText).padding(.horizontal, 12).frame(height: 28)
        case nil where preset.style == .macos:
            HStack(spacing: 14) {
                Image(systemName: "circle.hexagongrid.fill")
                Text("Files").bold()
                Text("Window")
                Spacer()
                Text("12:30")
            }
            .font(.system(size: 12)).foregroundStyle(desktopTheme.primaryText)
            .padding(.horizontal, 10).frame(height: 22)
            .background(.ultraThinMaterial)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func bottomBar(_ skin: EraSkin?) -> some View {
        if let skin, [.luna, .aero, .aeroNight, .classic].contains(skin) {
            let height = EraTaskbar.height(skin)
            HStack(spacing: 4) {
                EraStartFace(skin: skin, height: height)
                ForEach(["Files", "Terminal"], id: \.self) { title in
                    Text(title).font(.system(size: 12)).foregroundStyle(skin == .classic ? Color.black : .white)
                        .padding(.horizontal, 8).frame(width: skin == .aero ? 48 : 120, height: height - 8, alignment: .leading)
                        .background(taskFace(skin, focused: title == "Files"))
                }
                Spacer()
                Text("12:30").font(.system(size: 12)).foregroundStyle(skin == .classic ? Color.black : .white).padding(.horizontal, 10)
            }
            .frame(height: height)
            .background(EraTaskbarBackground(skin: skin))
        } else if let skin {
            dock(skin)
        } else if preset.style == .macos {
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(hue: Double(index) / 6, saturation: 0.55, brightness: 0.9)).frame(width: 38, height: 38)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func taskFace(_ skin: EraSkin, focused: Bool) -> some View {
        switch skin {
        case .luna:
            RoundedRectangle(cornerRadius: 3).fill(Color(rgb: focused ? 0x1E52B7 : 0x3C81F3))
        case .classic:
            Rectangle().fill(focused ? Color(rgb: 0xE4E4E4) : EraSkin.classicFace).overlay(ClassicBevel(raised: !focused, thick: true))
        default:
            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(focused ? 0.3 : 0.12))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
        }
    }

    private func dock(_ skin: EraSkin) -> some View {
        let icons = HStack(spacing: 10) {
            ForEach(0..<6, id: \.self) { index in
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(hue: Double(index) / 6, saturation: skin == .dotMatrix ? 0 : 0.55, brightness: skin == .dotMatrix ? 0.35 + Double(index) * 0.1 : 0.9))
                    .frame(width: 36, height: 36)
                    .background {
                        if skin == .berry && index == 1 {
                            RoundedRectangle(cornerRadius: 9).fill(Color(rgb: 0x1E8BFF)).padding(-4).shadow(color: Color(rgb: 0x1E8BFF), radius: 6)
                        }
                    }
            }
        }
        return Group {
            switch skin {
            case .berry:
                icons.padding(.horizontal, 14).frame(maxWidth: .infinity, alignment: .leading).frame(height: 54)
                    .background(LinearGradient(colors: [Color(rgb: 0x1C1F24), Color(rgb: 0x060708)], startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .top) { Color(rgb: 0xC9CED6).frame(height: 1) }
            case .dotMatrix:
                icons.padding(10).background(Capsule().fill(desktopTheme.panelBackground)).padding(.bottom, 8)
            default:
                icons.padding(.horizontal, 10).padding(.vertical, 6)
                    .background(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 10, topTrailing: 10)).fill(Color.white.opacity(0.4)))
            }
        }
    }

    private func window(skin: EraSkin?, theme: DesktopTheme, spec: DesktopStyleSpec) -> some View {
        let radius = theme.cornerRadius
        let squareBottom = skin?.squaresBottomCorners == true
        let shape = WindowShape(radius: radius, squareBottom: squareBottom)
        let metrics = WindowMetrics.pointer
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                if spec.buttonPlacement != .trailing { buttons(skin, side: .leading, spec: spec, metrics: metrics) }
                if spec.centersTitle { Spacer() }
                Text("Files")
                    .font(skin?.titleFont(compact: true) ?? .system(size: 13, weight: .semibold))
                    .foregroundStyle(skin?.titleColor(isFocused: true, theme: theme) ?? theme.primaryText)
                    .eraTitleTreatment(skin, isFocused: true)
                    .padding(.horizontal, 10)
                Spacer()
                if spec.buttonPlacement != .leading { buttons(skin, side: .trailing, spec: spec, metrics: metrics) }
            }
            .frame(height: 34)
            .background {
                if let skin { EraTitleBarBackground(skin: skin, isFocused: true) } else { theme.titleBarActive }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3).fill(theme.accent.opacity(row == 1 ? 1 : 0.55)).frame(width: 22, height: 18)
                        RoundedRectangle(cornerRadius: 3).fill(theme.primaryText.opacity(0.25)).frame(width: CGFloat(120 + row * 40), height: 8)
                    }
                }
                HStack(spacing: 4) {
                    ForEach(Array(theme.terminalPalette.prefix(8).enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 18, height: 10)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.windowBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .background(alignment: .bottom) {
            if squareBottom && radius > 0 { theme.windowBackground.frame(height: radius) }
        }
        .overlay {
            if let skin { EraWindowFrame(skin: skin, shape: shape, isFocused: true) } else { shape.strokeBorder(theme.separator, lineWidth: 1) }
        }
        .shadow(color: .black.opacity(spec.windowShadows ? 0.35 : 0), radius: 12, y: 6)
    }

    @ViewBuilder
    private func buttons(_ skin: EraSkin?, side: DesktopStyleSpec.ButtonPlacement, spec: DesktopStyleSpec, metrics: WindowMetrics) -> some View {
        if let skin {
            EraWindowButtons(skin: skin, kinds: EraWindowButtons.kinds(for: skin, side: side), isMaximized: false,
                             isFocused: true, metrics: metrics, titleBarHeight: 34) { _ in }
        } else if spec.buttonShape == .trafficLight {
            HStack(spacing: 8) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) { Circle().fill(Color(rgb: $0)).frame(width: 12, height: 12) }
            }
            .padding(.horizontal, 12)
        }
    }
}

/// A preset's wallpaper, decoded small for the card.
private struct PresetWallpaper: View {
    let wallpaper: DesktopThemePreset.Wallpaper

    var body: some View {
        switch wallpaper {
        case .color(let rgb):
            Color(rgb: rgb)
        case .builtIn(let name):
            if let image = PresetWallpaperCache.image(name) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.gray
            }
        }
    }
}

@MainActor
private enum PresetWallpaperCache {
    private static var images: [String: UIImage] = [:]

    static func image(_ name: String) -> UIImage? {
        if let image = images[name] { return image }
        guard let url = BuiltInWallpapers.url(for: BuiltInWallpapers.prefix + name + ".jpg"),
              let cg = WallpaperImageCache.thumbnail(url: url, maxPixel: 700) else { return nil }
        let image = UIImage(cgImage: cg)
        images[name] = image
        return image
    }
}

private struct BrushedMetalPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Preview cards draw Aqua's brushed metal without changing the user's setting.
    var brushedMetalPreview: Bool {
        get { self[BrushedMetalPreviewKey.self] }
        set { self[BrushedMetalPreviewKey.self] = newValue }
    }
}

extension DesktopLook {
    /// "Save Current Look" also keeps the desktop theme (and its member), the wallpaper and
    /// brushed metal, so applying the look later gives back the same desktop.
    @MainActor
    func capturingDesktopTheme(controller: DesktopController) -> DesktopLook {
        var look = self
        let active = controller.activeDesktopThemePresetID
        if !active.isEmpty {
            let isDark = active.hasSuffix(DesktopThemePreset.darkSuffix)
            let id = isDark ? String(active.dropLast(DesktopThemePreset.darkSuffix.count)) : active
            if let preset = DesktopThemePreset.preset(id), preset.style.rawValue == styleID {
                look.presetID = id
                look.presetDark = preset.darkColorTheme != nil ? isDark : nil
            }
        }
        look.brushedMetal = UserDefaults.standard.bool(forKey: EraSettings.brushedMetalKey) ? true : nil
        look.wallpaper = controller.wallpapers.settings.light
        look.appearanceID = UserDefaults.standard.string(forKey: DesktopAppearance.storageKey)
        return look
    }
}

// MARK: - Tolerant decoding of saved looks and styling

// Looks and styling are stored as JSON (and shared in links); a field added in a later build
// must not make an older saved value undecodable, which would silently drop every user look.
extension DesktopStyling {
    /// The same names the synthesized encoder writes (its CodingKeys are private to the
    /// type's file).
    private enum DecodingKeys: String, CodingKey {
        case cornerRadius, borderWidth, focusRing, innerGap, outerGap, windowShadows, panelOpacity, panelBlur, uiFont,
             fontScale, linuxUIFont, linuxMonoFont, monoFontSize, animation, cursorSize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DecodingKeys.self)
        self.init()
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius)
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth)
        focusRing = (try? c.decodeIfPresent(FocusRing.self, forKey: .focusRing)) ?? .accent
        innerGap = try c.decodeIfPresent(Double.self, forKey: .innerGap)
        outerGap = try c.decodeIfPresent(Double.self, forKey: .outerGap)
        windowShadows = try c.decodeIfPresent(Bool.self, forKey: .windowShadows) ?? true
        panelOpacity = try c.decodeIfPresent(Double.self, forKey: .panelOpacity)
        panelBlur = try c.decodeIfPresent(Bool.self, forKey: .panelBlur) ?? true
        uiFont = (try? c.decodeIfPresent(UIFontDesign.self, forKey: .uiFont)) ?? .system
        fontScale = try c.decodeIfPresent(Double.self, forKey: .fontScale) ?? 1
        linuxUIFont = try c.decodeIfPresent(String.self, forKey: .linuxUIFont)
        linuxMonoFont = try c.decodeIfPresent(String.self, forKey: .linuxMonoFont)
        monoFontSize = try c.decodeIfPresent(Double.self, forKey: .monoFontSize)
        animation = (try? c.decodeIfPresent(AnimationSpeed.self, forKey: .animation)) ?? .normal
        cursorSize = try c.decodeIfPresent(Int.self, forKey: .cursorSize)
    }
}

extension DesktopLook {
    private enum DecodingKeys: String, CodingKey {
        case id, name, styleID, colorThemeID, styling, wallpaperQuery, appearanceID, isBuiltIn, presetID, presetDark,
             brushedMetal, wallpaper
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DecodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        styleID = try c.decodeIfPresent(String.self, forKey: .styleID) ?? DesktopStyle.defaultStyle.rawValue
        colorThemeID = try c.decodeIfPresent(String.self, forKey: .colorThemeID) ?? ""
        styling = (try? c.decodeIfPresent(DesktopStyling.self, forKey: .styling)) ?? DesktopStyling()
        wallpaperQuery = try c.decodeIfPresent(String.self, forKey: .wallpaperQuery)
        appearanceID = try c.decodeIfPresent(String.self, forKey: .appearanceID)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID)
        presetDark = try c.decodeIfPresent(Bool.self, forKey: .presetDark)
        brushedMetal = try c.decodeIfPresent(Bool.self, forKey: .brushedMetal)
        wallpaper = try? c.decodeIfPresent(WallpaperSource.self, forKey: .wallpaper)
    }
}
