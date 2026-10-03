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
            Button {
                manager.focus(window.id)
            } label: { ThemedLabel(window.title, systemImage: window.isMinimized ? "minus.square" : "macwindow") }
        }
        if !windows.isEmpty { Divider() }
        Button {
            controller.open(appID: appID, arguments: [:])
        } label: { ThemedLabel("New Window", systemImage: "plus.rectangle.on.rectangle") }
        Button {
            controller.togglePinned(appID)
        } label: { ThemedLabel(controller.isPinned(appID) ? "Unpin" : "Pin", systemImage: controller.isPinned(appID) ? "pin.slash" : "pin") }
        let onDesktop = controller.isOnDesktop(appID)
        Button {
            controller.toggleOnDesktop(appID)
        } label: { ThemedLabel(onDesktop ? "Remove from Desktop" : "Add to Desktop", systemImage: onDesktop ? "minus.circle" : "plus.circle") }
        if !windows.isEmpty {
            Divider()
            Button(role: .destructive) {
                for window in windows { manager.requestClose(window.id) }
            } label: { ThemedLabel(windows.count > 1 ? "Close All Windows" : "Close", systemImage: "xmark") }
        }
    }
}
