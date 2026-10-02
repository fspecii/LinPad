import DesktopKit
import SwiftUI

/// The desktop on an in-memory Linux host, for UI tests and quick iteration without
/// booting the emulator.
@main
struct HarnessApp: App {
    var body: some Scene {
        WindowGroup {
            DesktopRootView(host: MockLinuxHost(), apps: BuiltinApps.all())
                .ignoresSafeArea()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}
