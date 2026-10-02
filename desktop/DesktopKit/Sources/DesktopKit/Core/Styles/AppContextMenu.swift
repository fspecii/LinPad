import SwiftUI

/// The taskbar and Dock menu for an app: its windows, a new window, pinning, closing all.
struct AppContextMenu: View {
    let appID: String
    let controller: DesktopController

    private var manager: WindowManager { controller.windowManager }
    private var windows: [DesktopWindow] { manager.windows.filter { $0.appID == appID } }

    var body: some View {
        let windows = windows
        ForEach(windows) { window in
            Button(window.title, systemImage: window.isMinimized ? "minus.square" : "macwindow") {
                manager.focus(window.id)
            }
        }
        if !windows.isEmpty { Divider() }
        Button("New Window", systemImage: "plus.rectangle.on.rectangle") {
            controller.open(appID: appID, arguments: [:])
        }
        Button(controller.isPinned(appID) ? "Unpin" : "Pin", systemImage: controller.isPinned(appID) ? "pin.slash" : "pin") {
            controller.togglePinned(appID)
        }
        let onDesktop = controller.isOnDesktop(appID)
        Button(onDesktop ? "Remove from Desktop" : "Add to Desktop", systemImage: onDesktop ? "minus.circle" : "plus.circle") {
            controller.toggleOnDesktop(appID)
        }
        if !windows.isEmpty {
            Divider()
            Button(windows.count > 1 ? "Close All Windows" : "Close", systemImage: "xmark", role: .destructive) {
                for window in windows { manager.requestClose(window.id) }
            }
        }
    }
}
