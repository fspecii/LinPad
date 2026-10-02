import SwiftUI

/// Window controls of the desktop themes' eras. Each keeps the same accessibility
/// identifiers as the other styles and a hit area of at least 32 x 40 pt (44 in touch mode),
/// whatever its drawn size.
struct EraWindowButtons: View {
    let skin: EraSkin
    let kinds: [WindowButtonKind]
    let isMaximized: Bool
    let isFocused: Bool
    let metrics: WindowMetrics
    let titleBarHeight: CGFloat
    let perform: (WindowButtonKind) -> Void

    @State private var isGroupHovered = false

    /// The order each era puts its controls in, per side of the title bar.
    static func kinds(for skin: EraSkin, side: DesktopStyleSpec.ButtonPlacement) -> [WindowButtonKind] {
        switch (skin, side) {
        case (.platinum, .leading): [.close]
        case (.platinum, _): [.maximize, .minimize]
        case (.aqua, _): [.close, .minimize, .maximize]
        default: [.minimize, .maximize, .close]
        }
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(kinds, id: \.self) { kind in
                EraWindowButton(skin: skin, kind: kind, isMaximized: isMaximized, isFocused: isFocused,
                                isGroupHovered: isGroupHovered, metrics: metrics, height: titleBarHeight,
                                isFirst: kind == kinds.first, isLast: kind == kinds.last) { perform(kind) }
                    .accessibilityLabel(kind.label(isMaximized: isMaximized))
                    .accessibilityIdentifier("desktop.window.\(kind.rawValue)")
            }
        }
        .padding(.horizontal, outerPadding)
        .onHover { isGroupHovered = $0 }
    }

    private var spacing: CGFloat {
        switch skin {
        case .aero, .aeroNight: 0
        case .classic: 0
        default: metrics.isTouch ? 4 : 2
        }
    }

    private var outerPadding: CGFloat {
        switch skin {
        case .aero, .aeroNight: 6
        case .classic, .platinum: 3
        default: 4
        }
    }
}

private struct EraWindowButton: View {
    let skin: EraSkin
    let kind: WindowButtonKind
    let isMaximized: Bool
    let isFocused: Bool
    let isGroupHovered: Bool
    let metrics: WindowMetrics
    let height: CGFloat
    let isFirst: Bool
    let isLast: Bool
    let action: () -> Void

    @Environment(\.desktopTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            face
                .frame(width: hitWidth, height: height, alignment: alignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var touch: Bool { metrics.isTouch }

    /// Aero's caption buttons hang from the top edge; everything else is centred.
    private var alignment: Alignment { skin.isGlass ? .top : .center }

    private var hitWidth: CGFloat {
        switch skin {
        case .aero, .aeroNight: kind == .close ? (touch ? 56 : 48) : (touch ? 44 : 32)
        case .classic: kind == .close ? (touch ? 48 : 34) : (touch ? 44 : 32)
        default: touch ? 44 : 32
        }
    }

    @ViewBuilder
    private var face: some View {
        switch skin {
        case .luna: luna
        case .aero, .aeroNight: aero
        case .classic: classic
        case .platinum: platinum
        case .aqua: aqua
        case .berry: berry
        case .dotMatrix: dot
        }
    }

    // MARK: Glyphs drawn as shapes, so they stay crisp at every size

    private func glyph(_ color: Color, size: CGFloat, weight: CGFloat) -> some View {
        EraGlyph(kind: kind, isMaximized: isMaximized, lineWidth: weight)
            .stroke(color, style: StrokeStyle(lineWidth: weight, lineCap: .square))
            .frame(width: size, height: size)
    }

    // MARK: Luna

    private var luna: some View {
        let side: CGFloat = touch ? 28 : 23
        let close = kind == .close
        let colors: [Color] = close
            ? [Color(rgb: 0xF2A388), Color(rgb: 0xE2643A), Color(rgb: 0xC2350E)]
            : [Color(rgb: 0x6FA6FF), Color(rgb: 0x2A6BF0), Color(rgb: 0x1E50D8)]
        return RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(Color.white.opacity(0.9), lineWidth: 1.2))
            .overlay(glyph(.white, size: side * 0.42, weight: close ? 2.2 : 2))
            .brightness(isHovered ? 0.08 : 0)
            .saturation(isFocused ? 1 : 0.55)
            .opacity(isFocused ? 1 : 0.75)
            .frame(width: side, height: side)
    }

    // MARK: Aero

    private var aero: some View {
        let close = kind == .close
        let width: CGFloat = close ? (touch ? 52 : 44) : (touch ? 30 : 26)
        let height: CGFloat = touch ? 22 : 19
        let shape = UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: isFirst ? 4 : 0,
                                                              bottomTrailing: isLast ? 4 : 0, topTrailing: 0))
        let fill: LinearGradient = close
            ? LinearGradient(stops: [.init(color: Color(rgb: isHovered ? 0xF6B5A6 : 0xE9A99B), location: 0),
                                     .init(color: Color(rgb: isHovered ? 0xE25A3C : 0xD2583F), location: 0.5),
                                     .init(color: Color(rgb: isHovered ? 0xD43A1B : 0xC0381F), location: 0.51),
                                     .init(color: Color(rgb: 0xD9634A), location: 1)], startPoint: .top, endPoint: .bottom)
            : LinearGradient(stops: [.init(color: Color.white.opacity(isHovered ? 0.85 : 0.6), location: 0),
                                     .init(color: Color(rgb: isHovered ? 0xBFE3FF : 0xC2D3E8).opacity(0.75), location: 0.5),
                                     .init(color: Color(rgb: isHovered ? 0x8ACBFF : 0x9DB3CF).opacity(0.8), location: 0.51),
                                     .init(color: Color(rgb: 0xB9CDE5).opacity(0.8), location: 1)], startPoint: .top, endPoint: .bottom)
        return shape.fill(fill)
            .overlay(shape.stroke(Color.black.opacity(0.45), lineWidth: 0.8))
            .overlay(glyph(.white, size: 9, weight: close ? 2.2 : 1.8).shadow(color: .black.opacity(0.7), radius: 0.8))
            .opacity(isFocused || isGroupHovered ? 1 : 0.7)
            .frame(width: width, height: height)
    }

    // MARK: Classic 98

    private var classic: some View {
        let width: CGFloat = touch ? 30 : 22
        let height: CGFloat = touch ? 26 : 20
        return glyph(isFocused ? .black : Color(rgb: 0x808080), size: touch ? 11 : 9, weight: kind == .close ? 2 : 1.6)
            .frame(width: width, height: height)
            .modifier(ClassicBox())
            .padding(.leading, kind == .close ? 2 : 0)
    }

    // MARK: Platinum

    private var platinum: some View {
        let side: CGFloat = touch ? 18 : 13
        return ZStack {
            Rectangle().fill(LinearGradient(colors: [Color(rgb: 0xFFFFFF), Color(rgb: 0xB5B5B5)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
            Rectangle().strokeBorder(Color(rgb: 0x555555), lineWidth: 1)
            switch kind {
            case .maximize:
                Rectangle().strokeBorder(Color(rgb: 0x555555), lineWidth: 1)
                    .frame(width: side * 0.55, height: side * 0.55)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(2)
            case .minimize:
                VStack(spacing: 2) {
                    Color(rgb: 0x555555).frame(height: 1)
                    Color(rgb: 0x555555).frame(height: 1)
                }
                .padding(.horizontal, 2)
            case .close:
                EmptyView()
            }
        }
        .frame(width: side, height: side)
        .opacity(isFocused ? 1 : 0)
        .background(isHovered ? Color.black.opacity(0.12) : .clear)
    }

    // MARK: Aqua gel

    private var aqua: some View {
        let side: CGFloat = touch ? 18 : 14
        let tint: (UInt32, UInt32) = switch kind {
        case .close: (0xFF8A78, 0xC1281B)
        case .minimize: (0xFFE07A, 0xD08A12)
        case .maximize: (0x9BE57A, 0x2E9A1C)
        }
        let active = isFocused || isGroupHovered
        let colors: [Color] = active ? [Color(rgb: tint.0), Color(rgb: tint.1)] : [Color(rgb: 0xDADADA), Color(rgb: 0x8E8E8E)]
        return ZStack {
            Circle().fill(RadialGradient(colors: colors, center: UnitPoint(x: 0.5, y: 0.75), startRadius: 0, endRadius: side * 0.65))
            Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.7)
            Ellipse().fill(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                .frame(width: side * 0.62, height: side * 0.4)
                .offset(y: -side * 0.2)
            if isGroupHovered || touch {
                glyph(Color.black.opacity(0.6), size: side * 0.42, weight: 1.4)
            }
        }
        .frame(width: side, height: side)
    }

    // MARK: Berry

    private var berry: some View {
        let side: CGFloat = touch ? 30 : 24
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isHovered ? AnyShapeStyle(Color(rgb: kind == .close ? 0xE5484D : 0x1E8BFF))
                            : AnyShapeStyle(LinearGradient(colors: [Color(rgb: 0x3B4048), Color(rgb: 0x1B1E23)],
                                                           startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color(rgb: 0xD9DEE4), Color(rgb: 0x5E646D)], startPoint: .top, endPoint: .bottom),
                              lineWidth: 1))
            .overlay(glyph(.white, size: side * 0.36, weight: 1.6))
            .opacity(isFocused ? 1 : 0.6)
            .frame(width: side, height: side)
    }

    // MARK: Dot Matrix

    private var dot: some View {
        let side: CGFloat = touch ? 22 : 17
        let close = kind == .close
        return ZStack {
            if close {
                Circle().fill(isFocused ? theme.accent : theme.secondaryText.opacity(0.5))
            } else {
                Circle().strokeBorder(theme.primaryText.opacity(isFocused ? 0.85 : 0.35), lineWidth: 1.5)
            }
            if isHovered || touch {
                glyph(close ? .white : theme.primaryText, size: side * 0.4, weight: 1.5)
            }
        }
        .frame(width: side, height: side)
    }
}

/// Minimize bar, maximize box (with a heavier top edge, as the eras drew it) or its restore
/// pair, and the close cross, in a unit square.
private struct EraGlyph: Shape {
    let kind: WindowButtonKind
    let isMaximized: Bool
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        switch kind {
        case .minimize:
            path.move(to: CGPoint(x: r.minX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.minX + r.width * 0.75, y: r.maxY))
        case .maximize where isMaximized:
            let back = CGRect(x: r.minX + r.width * 0.3, y: r.minY, width: r.width * 0.7, height: r.height * 0.7)
            let front = CGRect(x: r.minX, y: r.minY + r.height * 0.3, width: r.width * 0.7, height: r.height * 0.7)
            path.addRect(front)
            path.move(to: CGPoint(x: back.minX, y: front.minY))
            path.addLine(to: CGPoint(x: back.minX, y: back.minY))
            path.addLine(to: CGPoint(x: back.maxX, y: back.minY))
            path.addLine(to: CGPoint(x: back.maxX, y: back.maxY))
            path.addLine(to: CGPoint(x: front.maxX, y: back.maxY))
        case .maximize:
            path.addRect(r)
            path.move(to: CGPoint(x: r.minX, y: r.minY + lineWidth * 0.6))
            path.addLine(to: CGPoint(x: r.maxX, y: r.minY + lineWidth * 0.6))
        case .close:
            path.move(to: CGPoint(x: r.minX, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            path.move(to: CGPoint(x: r.maxX, y: r.minY))
            path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        }
        return path
    }
}
