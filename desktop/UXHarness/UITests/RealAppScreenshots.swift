import XCTest

/// Drives the installed iSH app (real emulator, real Linux windows) in landscape and saves
/// screenshots. Install it first with desktop/simrun-ux.sh; skipped unless
/// DESKTOP_SCREENSHOT_DIR is set (TEST_RUNNER_DESKTOP_SCREENSHOT_DIR on the command line).
@MainActor
final class RealAppScreenshots: XCTestCase {
    func testLinuxAndNativeWindowsInLandscape() throws {
        let directory = ProcessInfo.processInfo.environment["DESKTOP_SCREENSHOT_DIR"]
        try XCTSkipIf(directory == nil, "DESKTOP_SCREENSHOT_DIR not set")
        XCUIDevice.shared.orientation = .landscapeLeft
        let styles = ProcessInfo.processInfo.environment["DESKTOP_STYLES"]?.split(separator: ",").map(String.init)
            ?? ["ish", "windows", "macos", "ubuntu", "kylin"]
        for style in styles {
            let app = XCUIApplication(bundleIdentifier: "com.valentinneagu.ish.arm64")
            app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "terminal,files,linux:thunar",
                                   "-desktop.style", style, "-desktop.onboarded", "YES"]
            app.launch()
            let thunar = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'window:linux:'")).firstMatch
            XCTAssertTrue(thunar.waitForExistence(timeout: 90), "Thunar opened as a desktop window")
            // Switching the guest's themes (ish-apply-style) takes up to ~25 s; then icons reload.
            sleep(UInt32(ProcessInfo.processInfo.environment["DESKTOP_SETTLE_SECONDS"].flatMap(Int.init) ?? 3))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [.control, .option])
            sleep(1)
            save(app, to: directory!, name: "real-\(style)")
            app.terminate()
        }
    }

    private func save(_ app: XCUIApplication, to directory: String, name: String) {
        let shot = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: shot.size, format: format).image { _ in
            shot.draw(in: CGRect(origin: .zero, size: shot.size))
        }
        try? upright.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
