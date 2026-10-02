import SwiftUI

/// Browse and set wallpapers from Wallhaven (wallhaven.cc), SFW only.
enum WallpapersApp {
    static let id = "wallpapers"

    static func descriptor() -> DesktopAppDescriptor {
        DesktopAppDescriptor(
            id: id, name: "Wallpapers", symbol: "photo.stack", category: .accessories,
            defaultSize: CGSize(width: 980, height: 640), allowsMultipleWindows: false
        ) { context in
            AnyView(WallpapersAppView(context: context))
        }
    }
}
