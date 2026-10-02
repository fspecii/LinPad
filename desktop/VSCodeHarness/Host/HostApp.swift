import SwiftUI

/// Only here because a UI test bundle needs a host app; the tests drive the iSH app.
@main
struct HostApp: App {
    var body: some Scene {
        WindowGroup { Text("VS Code UI tests drive com.valentinneagu.ish.arm64") }
    }
}
