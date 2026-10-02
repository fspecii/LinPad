import SwiftUI

/// Browse and set wallpapers from Wallhaven (wallhaven.cc), SFW only.
enum WallpapersApp {
    static let id = "wallpapers"
    /// Launch arguments for a search ("Find wallpapers for this theme").
    static let queryArgument = "query"
    static let colorArgument = "color"
    /// Posted with the same keys in `userInfo` when the app is already open.
    static let searchRequested = Notification.Name("DesktopKit.wallpaperSearchRequested")

    static func descriptor() -> DesktopAppDescriptor {
        DesktopAppDescriptor(
            id: id, name: "Wallpapers", symbol: "photo.stack", category: .accessories,
            defaultSize: CGSize(width: 980, height: 640), allowsMultipleWindows: false
        ) { context in
            AnyView(WallpapersAppView(context: context))
        }
    }
}
