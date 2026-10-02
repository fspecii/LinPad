import SwiftUI

/// The desktop's look and layout: where the panels go, how window chrome is drawn, how the
/// launcher, switcher and overview are presented. Window management, input and shortcuts are
/// identical in every style; only presentation reads this.
public enum DesktopStyle: String, CaseIterable, Identifiable, Sendable {
    /// XFCE-like: one top panel with the whisker menu, taskbar and tray.
    case ish
    /// Bottom taskbar with a Start menu and Snap layouts.
    case windows
    /// Top menu bar, bottom Dock with magnification, traffic-light window buttons.
    case macos
    /// GNOME / Ubuntu: top bar with Activities, Dock on the left edge.
    case ubuntu
    /// UKUI (openKylin): light-first, bottom panel, three-column start menu
    /// (themes/kylin/DESIGN-SPEC.md).
    case kylin
    /// Tiling-first and minimal: a thin top bar (workspaces, clock, status), square corners,
    /// no shadows or blur, a coloured focus ring; auto-tiling on, Tokyo Night by default.
    case tiler
    // Desktop themes (EraStyles.swift): era looks drawn from data, each with its own chrome.
    /// Blue taskbar, green start button, rounded blue title bars (XP era).
    case luna
    /// Glass title bars and a light glass taskbar with an orb (7 era).
    case aero
    /// Glass title bars over a black glass taskbar (Vista era).
    case aeronight
    /// Grey bevelled 3D chrome and navy gradient titles (98 era).
    case classic
    /// Striped grey title bars, close box left, menu bar on top (classic Mac era).
    case platinum
    /// Pinstripes, gel lights, a white Dock (early OS X era).
    case aqua
    /// Dark chrome bezels and blue focus (handheld era).
    case berry
    /// Monochrome, a red accent, dot-matrix type and widgets.
    case dotmatrix

    public static let storageKey = "desktop.style"
    public static let defaultStyle = DesktopStyle.ish

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ish: "iSH"
        case .windows: "Windows"
        case .macos: "macOS"
        case .ubuntu: "Ubuntu"
        case .kylin: "Kylin"
        case .tiler: "Tiler"
        case .luna: "Luna"
        case .aero: "Aero"
        case .aeronight: "Aero Night"
        case .classic: "Classic 98"
        case .platinum: "Platinum"
        case .aqua: "Aqua"
        case .berry: "Berry"
        case .dotmatrix: "Dot Matrix"
        }
    }

    var spec: DesktopStyleSpec {
        switch self {
        case .ish: .ish
        case .windows: .windows
        case .macos: .macos
        case .ubuntu: .ubuntu
        case .kylin: .kylin
        case .tiler: .tiler
        case .luna, .aero, .aeronight, .classic, .platinum, .aqua, .berry, .dotmatrix: .era(self)
        }
    }

    static func stored(_ raw: String) -> DesktopStyle {
        DesktopStyle(rawValue: raw) ?? defaultStyle
    }
}

/// Everything a style decides, as data, so views branch on capabilities rather than on
/// style names.
struct DesktopStyleSpec {
    enum Shell {
        /// One panel holding launcher button, taskbar, workspaces and tray.
        case panel
        /// A menu bar on top and a Dock.
        case menuBarAndDock
        /// A taskbar along the bottom.
        case taskbar
        /// A top bar with Activities and clock, plus a Dock.
        case topBarAndDock
        /// UKUI's classic panel: start, search and task-view tiles, grouped icons, two-line clock.
        case kylinPanel
    }

    enum DockEdge {
        case bottom
        case leading
    }

    enum ButtonPlacement {
        case leading
        case trailing
        /// Close on the left, the rest on the right (Platinum).
        case split
    }

    enum ButtonShape {
        /// Compact rounded glyph buttons (XFCE).
        case glyph
        /// Flush rectangular caption buttons; close turns red (Windows).
        case caption
        /// Red, yellow and green lights whose glyphs show on hover (macOS).
        case trafficLight
        /// Round buttons, close filled (Yaru).
        case round
        /// 30 pt line glyphs on a radius-6 hover tile; close turns #E7202B (UKUI).
        case kylin
        /// Drawn by the style's `EraSkin` (EraWindowButtons.swift).
        case era
    }

    enum Launcher {
        /// The whisker menu dropping from the panel.
        case menu
        /// A Start menu rising from the taskbar.
        case startMenu
        /// A full-screen grid over a dimmed desktop.
        case fullScreenGrid
        /// UKUI's window-mode menu: app list, favorites and a sidebar.
        case kylinMenu
        /// The era start menus and Platinum's system menu (EraLaunchers.swift).
        case eraMenu
    }

    /// Colors for one appearance.
    struct Palette {
        var titleBarActive: Color
        var titleBarInactive: Color
        var panelBackground: Color
        var windowBackground: Color
        var primaryText: Color
        var secondaryText: Color
        var separator: Color
    }

    var shell: Shell
    var dockEdge: DockEdge?
    var buttonPlacement: ButtonPlacement
    var buttonShape: ButtonShape
    var centersTitle: Bool
    var launcher: Launcher
    /// Ubuntu's Activities: the overview has an app search field.
    var overviewSearches: Bool
    var cornerRadius: CGFloat
    var accent: Color?
    var dark: Palette
    var light: Palette
    /// The appearance when the user has not chosen one; UKUI ships light.
    var prefersLight = false
    /// UKUI's task view puts the workspaces along the bottom.
    var overviewStripAtBottom = false
    /// Touch metrics; UKUI defines its own tablet mode.
    var touchMetrics = WindowMetrics.touch
    var topBarHeight: CGFloat
    var bottomBarHeight: CGFloat
    var dockThickness: CGFloat
    /// Tiler: windows without shadows, flat panels, the focus ring always on.
    var windowShadows = true
    var panelBlur = true
    var alwaysShowsFocusRing = false
    /// Turns auto-tiling on for every workspace when the style is chosen.
    var tilesByDefault = false
    /// The colour theme applied when the style is chosen and none is active.
    var defaultColorTheme: String?
    /// Era chrome: title bars, frames, buttons and panels drawn from data (EraStyles.swift).
    var skin: EraSkin?

    static let ish = DesktopStyleSpec(
        shell: .panel, dockEdge: nil, buttonPlacement: .trailing, buttonShape: .glyph, centersTitle: false,
        launcher: .menu, overviewSearches: false, cornerRadius: 10, accent: nil,
        dark: Palette(titleBarActive: Color(white: 0.19), titleBarInactive: Color(white: 0.15),
                      panelBackground: Color(white: 0.09).opacity(0.92), windowBackground: Color(white: 0.13),
                      primaryText: Color(white: 0.94), secondaryText: Color(white: 0.62), separator: Color(white: 0.26)),
        light: .neutralLight,
        topBarHeight: PanelView.height, bottomBarHeight: 0, dockThickness: 0)

    static let tiler: DesktopStyleSpec = {
        var spec = DesktopStyleSpec(
            shell: .panel, dockEdge: nil, buttonPlacement: .trailing, buttonShape: .glyph, centersTitle: false,
            launcher: .menu, overviewSearches: false, cornerRadius: 0, accent: nil,
            dark: Palette(titleBarActive: Color(white: 0.12), titleBarInactive: Color(white: 0.09),
                          panelBackground: Color(white: 0.06), windowBackground: Color(white: 0.09),
                          primaryText: Color(white: 0.92), secondaryText: Color(white: 0.58), separator: Color(white: 0.2)),
            light: .neutralLight,
            topBarHeight: TilerBar.height, bottomBarHeight: 0, dockThickness: 0)
        spec.windowShadows = false
        spec.panelBlur = false
        spec.alwaysShowsFocusRing = true
        spec.tilesByDefault = true
        spec.defaultColorTheme = "tokyo-night"
        return spec
    }()

    static let windows = DesktopStyleSpec(
        shell: .taskbar, dockEdge: nil, buttonPlacement: .trailing, buttonShape: .caption, centersTitle: false,
        launcher: .startMenu, overviewSearches: false, cornerRadius: 8,
        accent: Color(red: 0.30, green: 0.63, blue: 0.98),
        dark: Palette(titleBarActive: Color(red: 0.13, green: 0.13, blue: 0.14),
                      titleBarInactive: Color(red: 0.16, green: 0.16, blue: 0.17),
                      panelBackground: Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.94),
                      windowBackground: Color(red: 0.125, green: 0.125, blue: 0.13),
                      primaryText: Color(white: 0.94), secondaryText: Color(white: 0.62), separator: Color(white: 0.26)),
        light: .neutralLight,
        topBarHeight: 0, bottomBarHeight: 48, dockThickness: 0)

    static let macos = DesktopStyleSpec(
        shell: .menuBarAndDock, dockEdge: .bottom, buttonPlacement: .leading, buttonShape: .trafficLight,
        centersTitle: true, launcher: .fullScreenGrid, overviewSearches: false, cornerRadius: 12,
        accent: Color(red: 0.04, green: 0.52, blue: 1.0),
        dark: Palette(titleBarActive: Color(red: 0.19, green: 0.19, blue: 0.2),
                      titleBarInactive: Color(red: 0.16, green: 0.16, blue: 0.17),
                      panelBackground: Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.72),
                      windowBackground: Color(red: 0.14, green: 0.14, blue: 0.15),
                      primaryText: Color(white: 0.94), secondaryText: Color(white: 0.62), separator: Color(white: 0.26)),
        light: .neutralLight,
        topBarHeight: 28, bottomBarHeight: 0, dockThickness: 70)

    static let ubuntu = DesktopStyleSpec(
        shell: .topBarAndDock, dockEdge: .leading, buttonPlacement: .trailing, buttonShape: .round,
        centersTitle: true, launcher: .fullScreenGrid, overviewSearches: true, cornerRadius: 12,
        accent: Color(red: 0.91, green: 0.33, blue: 0.13),
        dark: Palette(titleBarActive: Color(red: 0.19, green: 0.19, blue: 0.19),
                      titleBarInactive: Color(red: 0.16, green: 0.16, blue: 0.16),
                      panelBackground: Color.black.opacity(0.92),
                      windowBackground: Color(red: 0.17, green: 0.17, blue: 0.17),
                      primaryText: Color(white: 0.94), secondaryText: Color(white: 0.62), separator: Color(white: 0.26)),
        light: .neutralLight,
        topBarHeight: 30, bottomBarHeight: 0, dockThickness: 62)

    static let kylin = DesktopStyleSpec(
        shell: .kylinPanel, dockEdge: nil, buttonPlacement: .trailing, buttonShape: .kylin, centersTitle: false,
        launcher: .kylinMenu, overviewSearches: false, cornerRadius: 12,
        accent: Color(red: 55 / 255, green: 144 / 255, blue: 250 / 255),
        // KGray ramp and KFont tokens, DESIGN-SPEC.md §1.2-1.3 and the decoration colors of §4.
        dark: Palette(titleBarActive: Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255),
                      titleBarInactive: Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1C / 255),
                      panelBackground: Color(red: 0x2E / 255, green: 0x2E / 255, blue: 0x2E / 255).opacity(0.65),
                      windowBackground: Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255),
                      primaryText: Color.white.opacity(0.9), secondaryText: Color.white.opacity(0.6),
                      separator: Color.white.opacity(0.1)),
        light: Palette(titleBarActive: .white,
                       titleBarInactive: Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF5 / 255),
                       panelBackground: Color(red: 0xF6 / 255, green: 0xF6 / 255, blue: 0xF6 / 255).opacity(0.65),
                       windowBackground: .white,
                       primaryText: Color.black.opacity(0.85), secondaryText: Color.black.opacity(0.6),
                       separator: Color.black.opacity(0.1)),
        prefersLight: true, overviewStripAtBottom: true, touchMetrics: .tablet,
        topBarHeight: 0, bottomBarHeight: 48, dockThickness: 0)

    /// The theme with this style's materials; a user-chosen accent wins only in the iSH style,
    /// whose identity is the accent.
    func theme(base: DesktopTheme, isDark: Bool) -> DesktopTheme {
        let palette = isDark ? dark : light
        var theme = base
        if let accent { theme.accent = accent }
        theme.cornerRadius = cornerRadius
        theme.titleBarActive = palette.titleBarActive
        theme.titleBarInactive = palette.titleBarInactive
        theme.panelBackground = palette.panelBackground
        theme.windowBackground = palette.windowBackground
        theme.primaryText = palette.primaryText
        theme.secondaryText = palette.secondaryText
        theme.separator = palette.separator
        if !windowShadows { theme.showsWindowShadows = false }
        if !panelBlur { theme.panelBlur = false }
        if alwaysShowsFocusRing, theme.borderWidth == 0 { theme.borderWidth = 2 }
        return theme
    }
}

extension DesktopStyleSpec.Palette {
    static let neutralLight = DesktopStyleSpec.Palette(
        titleBarActive: Color(white: 0.96), titleBarInactive: Color(white: 0.92),
        panelBackground: Color(white: 0.97).opacity(0.85), windowBackground: Color(white: 1),
        primaryText: Color(white: 0.1), secondaryText: Color(white: 0.4), separator: Color(white: 0.82))
}

/// Light, dark, or the system's choice. The empty value means "the style's own default".
enum DesktopAppearance: String, CaseIterable, Identifiable {
    case styleDefault = ""
    case system
    case light
    case dark

    static let storageKey = "desktop.appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .styleDefault: "Style Default"
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    func isDark(style: DesktopStyle, system: ColorScheme) -> Bool {
        switch self {
        case .styleDefault: !style.spec.prefersLight
        case .system: system == .dark
        case .light: false
        case .dark: true
        }
    }
}

private struct DesktopStyleKey: EnvironmentKey {
    static let defaultValue = DesktopStyle.defaultStyle
}

extension EnvironmentValues {
    var desktopStyle: DesktopStyle {
        get { self[DesktopStyleKey.self] }
        set { self[DesktopStyleKey.self] = newValue }
    }
}
