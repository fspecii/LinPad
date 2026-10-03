import CoreText
import SwiftUI

/// The chrome of the desktop themes' styles (Luna, Aero, Classic 98, Platinum, Aqua, Berry,
/// Dot Matrix): title bars, window frames, buttons, panels and launchers drawn from data.
/// Every colour is LinPad's own reading of its era; no vendor artwork or fonts are used.
enum EraSkin: String, CaseIterable, Sendable {
    case luna, aero, aeroNight, classic, platinum, aqua, berry, dotMatrix

    init?(style: DesktopStyle) {
        switch style {
        case .luna: self = .luna
        case .aero: self = .aero
        case .aeronight: self = .aeroNight
        case .classic: self = .classic
        case .platinum: self = .platinum
        case .aqua: self = .aqua
        case .berry: self = .berry
        case .dotmatrix: self = .dotMatrix
        default: return nil
        }
    }

    var isGlass: Bool { self == .aero || self == .aeroNight }

    /// Luna and Aqua round only the top corners, as their eras did.
    var squaresBottomCorners: Bool { self == .luna || self == .aqua }

    var showsTitleSeparator: Bool {
        switch self {
        case .berry, .dotMatrix: true
        default: false
        }
    }

    /// Classic 98's start menu and Platinum's system menu sit in the panel's corner.
    var launcherAlignment: Alignment { self == .platinum ? .topLeading : .bottomLeading }

    // MARK: Title text

    func titleFont(compact: Bool) -> Font {
        switch self {
        case .luna: .custom("TrebuchetMS-Bold", size: 14)
        case .aero, .aeroNight: .system(size: 13, weight: .regular)
        case .classic: .system(size: 12, weight: .bold)
        case .platinum: .system(size: 12, weight: .bold).width(.condensed)
        case .aqua: .system(size: 13, weight: .regular)
        case .berry: .system(size: 13, weight: .semibold)
        case .dotMatrix: EraFonts.dot(size: 18)
        }
    }

    func titleColor(isFocused: Bool, theme: DesktopTheme) -> Color {
        switch self {
        case .luna: isFocused ? .white : Color(rgb: 0xD8E4F8)
        case .aero, .aeroNight: isFocused ? .black : Color.black.opacity(0.55)
        case .classic: isFocused ? .white : Color(rgb: 0xD4D0C8)
        case .platinum, .aqua: isFocused ? .black : Color(rgb: 0x8A8A8A)
        case .berry: isFocused ? .white : Color(white: 0.6)
        case .dotMatrix: isFocused ? theme.primaryText : theme.secondaryText
        }
    }

    /// Luna's drop shadow and Aero's glow behind the title.
    func titleShadow(isFocused: Bool) -> (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat)? {
        switch self {
        case .luna where isFocused: (Color(rgb: 0x0A1883).opacity(0.9), 0, 1, 1)
        case .aero, .aeroNight: (Color.white.opacity(0.9), 6, 0, 0)
        default: nil
        }
    }

    /// Platinum leaves a plain patch behind the centred title between its stripes.
    func titlePlate(isFocused: Bool) -> Color? {
        self == .platinum && isFocused ? Self.platinumFace : nil
    }

    // MARK: Palette

    static let platinumFace = Color(rgb: 0xDDDDDD)
    static let classicFace = Color(rgb: 0xC0C0C0)
}

// MARK: - Specs

extension DesktopStyleSpec {
    static func era(_ style: DesktopStyle) -> DesktopStyleSpec {
        switch style {
        case .luna: .luna
        case .aero: .aero
        case .aeronight: .aeroNight
        case .classic: .classic
        case .platinum: .platinum
        case .aqua: .aqua
        case .berry: .berry
        default: .dotMatrix
        }
    }

    /// 44 pt bars and buttons in touch mode: still finger-sized, closer to the eras' proportions.
    private static let eraTouch = WindowMetrics(titleBarHeight: 44, buttonSize: 44, isTouch: true)

    private static func palette(title: UInt32, panel: Color, window: UInt32, text: Color, secondary: Color,
                                separator: UInt32) -> Palette {
        Palette(titleBarActive: Color(rgb: title), titleBarInactive: Color(rgb: title).opacity(0.85),
                panelBackground: panel, windowBackground: Color(rgb: window), primaryText: text,
                secondaryText: secondary, separator: Color(rgb: separator))
    }

    private static let eraDark = palette(title: 0x2B2B2B, panel: Color(rgb: 0x1E1E1E).opacity(0.94), window: 0x1F1F1F,
                                         text: Color(white: 0.94), secondary: Color(white: 0.62), separator: 0x3A3A3A)

    private static func make(_ skin: EraSkin, shell: Shell, dock: DockEdge? = nil, placement: ButtonPlacement = .trailing,
                             centersTitle: Bool = false, launcher: Launcher, radius: CGFloat, accent: UInt32,
                             light: Palette, dark: Palette = eraDark, prefersLight: Bool = true,
                             top: CGFloat = 0, bottom: CGFloat = 0, dockThickness: CGFloat = 0,
                             colorTheme: String) -> DesktopStyleSpec {
        var spec = DesktopStyleSpec(
            shell: shell, dockEdge: dock, buttonPlacement: placement, buttonShape: .era, centersTitle: centersTitle,
            launcher: launcher, overviewSearches: false, cornerRadius: radius, accent: Color(rgb: accent),
            dark: dark, light: light, topBarHeight: top, bottomBarHeight: bottom, dockThickness: dockThickness)
        spec.prefersLight = prefersLight
        spec.touchMetrics = eraTouch
        spec.skin = skin
        spec.defaultColorTheme = colorTheme
        return spec
    }

    static let luna = make(.luna, shell: .taskbar, launcher: .eraMenu, radius: 8, accent: 0x316AC5,
                           light: palette(title: 0x0054E3, panel: Color(rgb: 0x245EDC), window: 0xECE9D8,
                                          text: .black, secondary: Color(rgb: 0x5A5A5A), separator: 0xACA899),
                           bottom: EraTaskbar.height(.luna), colorTheme: "luna")

    static let aero = make(.aero, shell: .taskbar, launcher: .eraMenu, radius: 8, accent: 0x3399FF,
                           light: palette(title: 0xB9D1EA, panel: Color(rgb: 0x16304C).opacity(0.55), window: 0xF0F0F0,
                                          text: Color(rgb: 0x1E1E1E), secondary: Color(rgb: 0x6D6D6D), separator: 0xD0D7E0),
                           bottom: EraTaskbar.height(.aero), colorTheme: "aero")

    static let aeroNight = make(.aeroNight, shell: .taskbar, launcher: .eraMenu, radius: 8, accent: 0x4CC2FF,
                                light: palette(title: 0x8FA6B8, panel: Color.black.opacity(0.85), window: 0xF0F0F0,
                                               text: Color(rgb: 0x1E1E1E), secondary: Color(rgb: 0x6D6D6D), separator: 0xD0D7E0),
                                bottom: EraTaskbar.height(.aeroNight), colorTheme: "aero")

    static let classic: DesktopStyleSpec = {
        var spec = make(.classic, shell: .taskbar, launcher: .eraMenu, radius: 0, accent: 0x000080,
                        light: palette(title: 0x000080, panel: EraSkin.classicFace, window: 0xC0C0C0,
                                       text: .black, secondary: Color(rgb: 0x404040), separator: 0x808080),
                        bottom: EraTaskbar.height(.classic), colorTheme: "classic-98")
        spec.windowShadows = false
        spec.panelBlur = false
        return spec
    }()

    static let platinum: DesktopStyleSpec = {
        var spec = make(.platinum, shell: .menuBarAndDock, placement: .split, centersTitle: true, launcher: .eraMenu,
                        radius: 0, accent: 0x6666CC,
                        light: palette(title: 0xDDDDDD, panel: EraSkin.platinumFace, window: 0xDDDDDD,
                                       text: .black, secondary: Color(rgb: 0x555555), separator: 0x999999),
                        top: EraMenuBar.height, colorTheme: "platinum")
        spec.windowShadows = false
        spec.panelBlur = false
        return spec
    }()

    static let aqua = make(.aqua, shell: .menuBarAndDock, dock: .bottom, placement: .leading, centersTitle: true,
                           launcher: .fullScreenGrid, radius: 7, accent: 0x3875D7,
                           light: palette(title: 0xE9E9E9, panel: Color.white.opacity(0.9), window: 0xECECEC,
                                          text: .black, secondary: Color(rgb: 0x6B6B6B), separator: 0xB5B5B5),
                           top: EraMenuBar.height, dockThickness: 72, colorTheme: "aqua")

    static let berry = make(.berry, shell: .topBarAndDock, dock: .bottom, launcher: .fullScreenGrid, radius: 10,
                            accent: 0x1E8BFF,
                            light: palette(title: 0x2E333A, panel: Color(rgb: 0x0B0C0E), window: 0xF2F4F7,
                                           text: Color(rgb: 0x111417), secondary: Color(rgb: 0x5A626C), separator: 0xC9CED6),
                            dark: palette(title: 0x2E333A, panel: Color(rgb: 0x0B0C0E), window: 0x111417,
                                          text: Color(rgb: 0xE8EBEF), secondary: Color(rgb: 0x8A939E), separator: 0x2A3038),
                            prefersLight: false, top: EraStatusBar.height, dockThickness: 70, colorTheme: "berry")

    static let dotMatrix: DesktopStyleSpec = {
        var spec = make(.dotMatrix, shell: .topBarAndDock, dock: .bottom, launcher: .fullScreenGrid, radius: 18,
                        accent: 0xD71921,
                        light: palette(title: 0xF4F4F4, panel: Color(rgb: 0xF4F4F4), window: 0xF4F4F4,
                                       text: Color(rgb: 0x111111), secondary: Color(rgb: 0x8A8A8A), separator: 0xDDDDDD),
                        dark: palette(title: 0x0A0A0A, panel: Color.black, window: 0x000000,
                                      text: Color(rgb: 0xF2F2F2), secondary: Color(rgb: 0x8A8A8A), separator: 0x262626),
                        top: EraStatusBar.height, dockThickness: 76, colorTheme: "dot-matrix")
        spec.panelBlur = false
        spec.windowShadows = false
        return spec
    }()
}

// MARK: - Fonts

/// LinPad Dot: Doto (OFL 1.1, The Doto Project Authors) instanced at round dots, weight 800,
/// and renamed as the OFL asks of modified fonts (Resources/Fonts/OFL.txt).
enum EraFonts {
    static let dotFamily = "LinPadDot"

    private static let registered: Bool = {
        guard let url = Bundle.module.url(forResource: "LinPadDot", withExtension: "ttf", subdirectory: "Fonts") else {
            return false
        }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return true
    }()

    /// A UIFont-backed Font, so the desktop's font-design setting cannot swap it for SF.
    static func dot(size: CGFloat) -> Font {
        if registered, let font = UIFont(name: dotFamily, size: size) { return Font(font) }
        return .system(size: size, weight: .heavy, design: .monospaced)
    }
}

// MARK: - Title bar

/// What the title bar is painted with: Luna's blue, Aero's glass, 98's navy ramp, Platinum's
/// stripes, Aqua's pinstripes or brushed metal, Berry's dark chrome, Dot Matrix's flat panel.
struct EraTitleBarBackground: View {
    let skin: EraSkin
    let isFocused: Bool
    @Environment(\.desktopTheme) private var theme
    @AppStorage(EraSettings.brushedMetalKey) private var brushedMetalSetting = false
    @Environment(\.brushedMetalPreview) private var brushedMetalPreview

    private var brushedMetal: Bool { brushedMetalSetting || brushedMetalPreview }

    var body: some View {
        switch skin {
        case .luna: luna
        case .aero, .aeroNight: glass
        case .classic: classic
        case .platinum: platinum
        case .aqua: brushedMetal ? AnyView(BrushedMetal(isFocused: isFocused)) : AnyView(pinstripes)
        case .berry: berry
        case .dotMatrix: isFocused ? theme.titleBarActive : theme.titleBarInactive
        }
    }

    private var luna: some View {
        LinearGradient(stops: isFocused ? [
            .init(color: Color(rgb: 0x3D95FF), location: 0), .init(color: Color(rgb: 0x0A63F8), location: 0.1),
            .init(color: Color(rgb: 0x0054E3), location: 0.45), .init(color: Color(rgb: 0x0256EA), location: 0.8),
            .init(color: Color(rgb: 0x0042CE), location: 1),
        ] : [
            .init(color: Color(rgb: 0xA9C3F2), location: 0), .init(color: Color(rgb: 0x8AA9E8), location: 0.15),
            .init(color: Color(rgb: 0x7B9DE6), location: 0.6), .init(color: Color(rgb: 0x6F92DD), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    private var glass: some View {
        let night = skin == .aeroNight
        let top = night ? Color(rgb: 0x9BB3C4) : Color(rgb: 0xC9DCF2)
        let bottom = night ? Color(rgb: 0x6C8597) : Color(rgb: 0x9FBDE0)
        return ZStack {
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
                .opacity(isFocused ? 0.94 : 0.86)
            LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.08)], startPoint: .top, endPoint: .center)
            GlassStreaks().opacity(isFocused ? 0.5 : 0.25)
        }
    }

    private var classic: some View {
        ZStack {
            EraSkin.classicFace
            LinearGradient(colors: isFocused ? [Color(rgb: 0x000080), Color(rgb: 0x1084D0)]
                                             : [Color(rgb: 0x808080), Color(rgb: 0xB5B5B5)],
                           startPoint: .leading, endPoint: .trailing)
                .padding(EdgeInsets(top: 4.5, leading: 4.5, bottom: 1.5, trailing: 4.5))
        }
    }

    private var platinum: some View {
        ZStack {
            EraSkin.platinumFace
            if isFocused {
                Canvas { context, size in
                    var y: CGFloat = 7
                    while y < size.height - 6 {
                        context.fill(Path(CGRect(x: 6, y: y, width: size.width - 12, height: 1)), with: .color(Color(rgb: 0x9A9A9A)))
                        context.fill(Path(CGRect(x: 6, y: y + 1, width: size.width - 12, height: 1)), with: .color(.white))
                        y += 3
                    }
                }
            }
        }
        .overlay(alignment: .top) { Color.white.frame(height: 1) }
    }

    private var pinstripes: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(rgb: isFocused ? 0xE6E6E6 : 0xF1F1F1)))
            var y: CGFloat = 0
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                             with: .color(Color.white.opacity(isFocused ? 0.85 : 0.55)))
                y += 2
            }
        }
        .overlay(alignment: .bottom) { Color(rgb: 0xA6A6A6).frame(height: 1) }
    }

    private var berry: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: isFocused ? [Color(rgb: 0x454B54), Color(rgb: 0x1A1D22)]
                                             : [Color(rgb: 0x2A2D32), Color(rgb: 0x16181B)],
                           startPoint: .top, endPoint: .bottom)
            Color.white.opacity(isFocused ? 0.35 : 0.15).frame(height: 1)
        }
    }
}

/// The few diagonal light streaks of the glass eras.
private struct GlassStreaks: View {
    var body: some View {
        Canvas { context, size in
            for (offset, width) in [(0.18, 26.0), (0.24, 8.0), (0.62, 34.0), (0.7, 10.0)] {
                let x = size.width * offset
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + width, y: 0))
                path.addLine(to: CGPoint(x: x + width - size.height * 0.9, y: size.height))
                path.addLine(to: CGPoint(x: x - size.height * 0.9, y: size.height))
                context.fill(path, with: .color(.white.opacity(0.22)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Aqua's brushed metal: a grey ramp with fine horizontal grain (fixed seed, so it never shimmers).
struct BrushedMetal: View {
    var isFocused = true

    var body: some View {
        Canvas { context, size in
            let ramp = Gradient(colors: [Color(rgb: isFocused ? 0xD2D2D2 : 0xDCDCDC), Color(rgb: isFocused ? 0xA9A9A9 : 0xC4C4C4)])
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(ramp, startPoint: .zero, endPoint: CGPoint(x: 0, y: max(size.height, 1) * 4)))
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
            }
            for _ in 0..<Int(size.height * 3) {
                let y = next() * size.height
                let x = next() * size.width
                let length = 40 + next() * size.width * 0.6
                context.fill(Path(CGRect(x: x - length / 2, y: y, width: length, height: 0.5)),
                             with: .color(next() > 0.5 ? .white.opacity(0.35) : .black.opacity(0.08)))
            }
        }
    }
}

enum EraSettings {
    /// Aqua: brushed-metal title bars instead of pinstripes.
    static let brushedMetalKey = "desktop.era.brushedMetal"
}

// MARK: - Window frame

/// The border each era draws around a window, over the content's outer edge: Luna's blue
/// frame, the glass frame, 98's two-tone bevel, Platinum's outline, Berry's chrome bezel.
struct EraWindowFrame<S: InsettableShape>: View {
    let skin: EraSkin
    let shape: S
    let isFocused: Bool

    var body: some View {
        switch skin {
        case .luna:
            shape.strokeBorder(isFocused ? Color(rgb: 0x0831D9) : Color(rgb: 0x7B9DE6), lineWidth: 3)
        case .aero, .aeroNight:
            let night = skin == .aeroNight
            ZStack {
                shape.strokeBorder(LinearGradient(colors: night ? [Color(rgb: 0x9BB3C4), Color(rgb: 0x5E7687)]
                                                                 : [Color(rgb: 0xC9DCF2), Color(rgb: 0x8FB0D8)],
                                                  startPoint: .top, endPoint: .bottom)
                                       .opacity(isFocused ? 0.95 : 0.75), lineWidth: 5)
                shape.strokeBorder(Color.black.opacity(0.45), lineWidth: 1)
                shape.inset(by: 4).strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
            }
        case .classic:
            ZStack {
                Rectangle().strokeBorder(EraSkin.classicFace, lineWidth: 4.5)
                ClassicBevel(raised: true, thick: true)
            }
        case .platinum:
            ZStack {
                Rectangle().strokeBorder(Color(rgb: 0xDDDDDD), lineWidth: 4)
                ClassicBevel(raised: true, thick: false, palette: .platinum).padding(1)
                Rectangle().strokeBorder(isFocused ? Color.black : Color(rgb: 0x777777), lineWidth: 1)
            }
        case .aqua:
            shape.strokeBorder(Color.black.opacity(isFocused ? 0.35 : 0.2), lineWidth: 1)
        case .berry:
            shape.strokeBorder(LinearGradient(colors: [Color(rgb: 0xE1E5EA), Color(rgb: 0x6C727C), Color(rgb: 0xB8BEC6)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 2)
        case .dotMatrix:
            shape.strokeBorder(Color.primary.opacity(isFocused ? 0.25 : 0.12), lineWidth: 1)
        }
    }
}

/// The 98-era 3D edge: light top-left, dark bottom-right, two lines deep when `thick`
/// (raised: light grey + white over black + dark grey; sunken: the reverse). Platinum's
/// softer edge uses white and mid grey. Lines are 1.5 pt so the bevel reads on Retina.
struct ClassicBevel: View {
    enum Palette { case classic, platinum }

    var raised = true
    var thick = false
    var palette = Palette.classic
    var line: CGFloat = 1.5

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            let colors = self.colors
            ZStack(alignment: .topLeading) {
                edge(colors.0, colors.1, w, h, inset: 0)
                if thick { edge(colors.2, colors.3, w, h, inset: line) }
            }
        }
        .allowsHitTesting(false)
    }

    private var colors: (Color, Color, Color, Color) {
        switch (palette, raised, thick) {
        case (.classic, true, true): (Color(rgb: 0xDFDFDF), .black, .white, Color(rgb: 0x808080))
        case (.classic, true, false): (.white, Color(rgb: 0x808080), .clear, .clear)
        case (.classic, false, true): (Color(rgb: 0x808080), .white, .black, Color(rgb: 0xDFDFDF))
        case (.classic, false, false): (Color(rgb: 0x808080), .white, .clear, .clear)
        case (.platinum, true, _): (.white, Color(rgb: 0x777777), Color(rgb: 0xEEEEEE), Color(rgb: 0xAAAAAA))
        case (.platinum, false, _): (Color(rgb: 0x777777), .white, Color(rgb: 0xAAAAAA), Color(rgb: 0xEEEEEE))
        }
    }

    private func edge(_ light: Color, _ dark: Color, _ w: CGFloat, _ h: CGFloat, inset i: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            light.frame(width: max(w - 2 * i, 0), height: line).offset(x: i, y: i)
            light.frame(width: line, height: max(h - 2 * i, 0)).offset(x: i, y: i)
            dark.frame(width: max(w - 2 * i, 0), height: line).offset(x: i, y: h - line - i)
            dark.frame(width: line, height: max(h - 2 * i, 0)).offset(x: w - line - i, y: i)
        }
    }
}

/// A grey 98-era (or Platinum) box: face colour plus a bevel, raised or sunken.
struct ClassicBox: ViewModifier {
    var sunken = false
    var thick = true
    var face = EraSkin.classicFace
    var palette = ClassicBevel.Palette.classic

    func body(content: Content) -> some View {
        content
            .background(face)
            .overlay(ClassicBevel(raised: !sunken, thick: thick, palette: palette))
    }
}

extension View {
    /// Luna's drop shadow, Aero's glow and Platinum's plain patch behind a window title.
    @ViewBuilder
    func eraTitleTreatment(_ skin: EraSkin?, isFocused: Bool) -> some View {
        if skin == .dotMatrix {
            fontDesign(nil)
        } else if let skin {
            let shadow = skin.titleShadow(isFocused: isFocused)
            self.shadow(color: shadow?.color ?? .clear, radius: shadow?.radius ?? 0, x: shadow?.x ?? 0, y: shadow?.y ?? 0)
                .padding(.horizontal, skin == .platinum ? 6 : 0)
                .background((skin.titlePlate(isFocused: isFocused) ?? .clear).padding(.vertical, -9))
        } else {
            self
        }
    }
}

extension View {
    /// The dot-matrix face; the desktop's font-design setting would otherwise swap it for SF.
    func dotMatrixFont(size: CGFloat) -> some View {
        font(EraFonts.dot(size: size)).fontDesign(nil)
    }
}

/// A window's outline: continuous rounded corners, the bottom pair square when the era drew
/// them so (Luna, Aqua). Used for strokes only: clipping a window with a non-uniform shape
/// (UnevenRoundedRectangle or this) hid parts of its text on iOS 26, so windows clip to a
/// plain rounded rectangle and fill the square corners in behind.
struct WindowShape: InsettableShape {
    var radius: CGFloat
    var squareBottom = false
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let corner = max(0, min(radius - inset, min(r.width, r.height) / 2))
        guard squareBottom else {
            return RoundedRectangle(cornerRadius: corner, style: .continuous).path(in: r)
        }
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + corner))
        path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + corner, y: r.minY), radius: corner)
        path.addLine(to: CGPoint(x: r.maxX - corner, y: r.minY))
        path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + corner), radius: corner)
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> WindowShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}

extension DesktopStyle {
    /// Style pickers' sections: today's layouts, then the desktop themes' era styles.
    struct Group: Identifiable {
        let title: String
        let styles: [DesktopStyle]
        var id: String { title }
    }

    static var groups: [Group] {
        [Group(title: "Modern", styles: allCases.filter { $0.spec.skin == nil }),
         Group(title: "Retro", styles: allCases.filter { $0.spec.skin != nil })]
    }
}

/// Every layout style as wrapping chips under "Modern" and "Retro" headers: fits any window
/// width (Settings, the Themes app) where a segmented control of 14 no longer does.
struct DesktopStyleChooser: View {
    @Binding var selection: String
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(DesktopStyle.groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(group.styles) { chip($0) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.style")
    }

    private func chip(_ style: DesktopStyle) -> some View {
        let isSelected = selection == style.rawValue
        return Button { selection = style.rawValue } label: {
            Text(style.displayName)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isSelected ? theme.accent.readableLabel : theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? theme.accent : theme.primaryText.opacity(0.07)))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(style.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.style.\(style.rawValue)")
    }
}
