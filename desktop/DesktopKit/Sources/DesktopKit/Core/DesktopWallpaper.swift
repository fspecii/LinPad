import SwiftUI

enum DesktopWallpaper: String, CaseIterable {
    case midnight
    case aurora
    case dusk

    private var base: [Color] {
        switch self {
        case .midnight:
            [Color(red: 0.04, green: 0.06, blue: 0.18), Color(red: 0.12, green: 0.10, blue: 0.36),
             Color(red: 0.27, green: 0.13, blue: 0.45)]
        case .aurora:
            [Color(red: 0.02, green: 0.10, blue: 0.20), Color(red: 0.05, green: 0.25, blue: 0.40),
             Color(red: 0.22, green: 0.15, blue: 0.45)]
        case .dusk:
            [Color(red: 0.10, green: 0.05, blue: 0.20), Color(red: 0.32, green: 0.10, blue: 0.40),
             Color(red: 0.55, green: 0.20, blue: 0.42)]
        }
    }

    private var glow: (color: Color, center: UnitPoint) {
        switch self {
        case .midnight: (Color(red: 0.40, green: 0.45, blue: 1.0), UnitPoint(x: 0.8, y: 0.15))
        case .aurora: (Color(red: 0.20, green: 0.85, blue: 0.75), UnitPoint(x: 0.2, y: 0.25))
        case .dusk: (Color(red: 1.0, green: 0.55, blue: 0.45), UnitPoint(x: 0.75, y: 0.85))
        }
    }

    var view: some View {
        GeometryReader { proxy in
            let extent = max(proxy.size.width, proxy.size.height)
            ZStack {
                LinearGradient(colors: base, startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [glow.color.opacity(0.35), .clear],
                               center: glow.center, startRadius: 0, endRadius: extent * 0.6)
                RadialGradient(colors: [.black.opacity(0.35), .clear],
                               center: .bottomLeading, startRadius: 0, endRadius: extent * 0.7)
            }
        }
        .drawingGroup()
    }
}
