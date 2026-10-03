import DesktopKit
import SwiftUI

/// The desktop on an in-memory Linux host, for UI tests and quick iteration without
/// booting the emulator.
@main
struct HarnessApp: App {
    private static let host: any LinuxHost =
        UserDefaults.standard.string(forKey: "desktop.fakeLinuxWindow") == nil ? MockLinuxHost() : HarnessGraphicsHost()

    var body: some Scene {
        WindowGroup {
            DesktopRootView(host: Self.host, apps: BuiltinApps.all())
                .ignoresSafeArea()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .overlay(alignment: .topLeading) { KeyboardFrameProbe() }
        }
    }
}
