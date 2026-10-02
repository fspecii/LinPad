import XCTest

/// Manual live check against the real Wallhaven API in the installed iSH app: browse,
/// open a wallpaper, download it to ~/Pictures and set it, then show the desktop in two
/// styles. Skipped unless DESKTOP_LIVE=1 and DESKTOP_SCREENSHOT_DIR are set
/// (TEST_RUNNER_ prefix on the xcodebuild command line).
@MainActor
final class LiveWallhavenScreenshots: XCTestCase {
    func testBrowseDownloadAndSetWallpaper() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = try XCTUnwrap(environment["DESKTOP_SCREENSHOT_DIR"], "DESKTOP_SCREENSHOT_DIR not set")
        try XCTSkipIf(environment["DESKTOP_LIVE"] != "1", "live network check not requested")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(bundleIdentifier: "com.valentinneagu.ish.arm64")
        app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "wallpapers",
                               "-desktop.style", "windows", "-desktop.onboarded", "YES"]
        app.launch()
        let thumbs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'wallhaven.thumb.'"))
        XCTAssertTrue(thumbs.firstMatch.waitForExistence(timeout: 60), "the live grid loads")
        sleep(6)
        save("live-grid", to: directory)

        thumbs.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["wallhaven.detail"].waitForExistence(timeout: 10))
        sleep(8)
        save("live-detail", to: directory)
        app.buttons["Download to Pictures"].firstMatch.tap()
        let status = app.descendants(matching: .any)["wallhaven.detailStatus"].firstMatch
        _ = waitUntil(timeout: 60) { (status.label).contains("Saved") }
        app.descendants(matching: .any)["wallhaven.setWallpaper"].firstMatch.tap()
        app.buttons["All Workspaces"].firstMatch.tap()
        let wallpaper = app.descendants(matching: .any)["desktop.wallpaper"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 60) { (wallpaper.value as? String ?? "").hasPrefix("image:wallhaven-") })
        app.buttons["Close"].firstMatch.tap()
        app.typeKey("m", modifierFlags: [.control, .option])
        sleep(3)
        save("live-desktop-windows", to: directory)

        app.terminate()
        app.launchArguments = ["-desktop.autostart", "", "-desktop.style", "macos", "-desktop.onboarded", "YES"]
        app.launch()
        sleep(25)
        save("live-desktop-macos", to: directory)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        return condition()
    }

    private func save(_ name: String, to directory: String) {
        let shot = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: shot.size, format: format).image { _ in
            shot.draw(in: CGRect(origin: .zero, size: shot.size))
        }
        try? upright.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
