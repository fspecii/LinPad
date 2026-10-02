import SwiftUI
import UIKit

struct DesktopMenuItem {
    let title: String
    let symbol: String
    let action: @MainActor () -> Void
}

/// The desktop: ~/Desktop's icons and the desktop menu (Desktop/DesktopFolderSurface),
/// with the shell's own entries merged into that menu.
struct DesktopSurface: View {
    let controller: DesktopController

    var body: some View {
        // ~/Desktop as icons, drag and drop, and the full desktop menu: Desktop/ (DnD agent).
        DesktopFolderSurface(controller: controller, shellItems: menuItems)
    }

    private var menuItems: [DesktopMenuItem] {
        [
            DesktopMenuItem(title: "Open Terminal", symbol: "terminal") {
                controller.open(appID: AppID.terminal, arguments: [:])
            },
            DesktopMenuItem(title: "Open Files", symbol: "folder") {
                controller.open(appID: AppID.files, arguments: [:])
            },
            DesktopMenuItem(title: "Overview", symbol: "rectangle.3.group") {
                controller.setOverviewPresented(true)
            },
            DesktopMenuItem(title: "Change Wallpaper…", symbol: "photo.on.rectangle") {
                controller.openWallpaperSettings()
            },
            DesktopMenuItem(title: "Settings", symbol: "gearshape") {
                controller.open(appID: AppID.settings, arguments: [:])
            },
        ]
    }
}
