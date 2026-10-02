import XCTest

/// Saves a landscape screenshot of each style with a few windows open, for review.
/// Set DESKTOP_SCREENSHOT_DIR in the scheme's test environment (TEST_RUNNER_ prefix on the
/// command line) to choose where they go.
@MainActor
final class StyleScreenshots: XCTestCase {
    func testCaptureEveryStyle() throws {
        let directory = ProcessInfo.processInfo.environment["DESKTOP_SCREENSHOT_DIR"]
        try XCTSkipIf(directory == nil, "DESKTOP_SCREENSHOT_DIR not set")
        XCUIDevice.shared.orientation = .landscapeLeft
        for style in ["ish", "windows", "macos", "ubuntu", "kylin"] {
            let app = XCUIApplication()
            app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "files,terminal",
                                   "-desktop.style", style, "-desktop.onboarded", "YES"]
            app.launch()
            XCTAssertTrue(app.buttons["desktop.panel.applications"].waitForExistence(timeout: 10))
            sleep(2)
            save(app, to: directory!, name: "\(style)-desktop")
            app.buttons["desktop.panel.applications"].tap()
            sleep(1)
            save(app, to: directory!, name: "\(style)-launcher")
            app.buttons["desktop.panel.applications"].firstMatch.tap()
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            app.typeKey("o", modifierFlags: [.control, .option])
            sleep(1)
            save(app, to: directory!, name: "\(style)-overview")
            app.typeKey("o", modifierFlags: [.control, .option])
            app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: .option)
            sleep(1)
            save(app, to: directory!, name: "\(style)-switcher")
            app.terminate()
        }
    }

    /// The desktop before and after flicking the Terminal icon (press and move, no hold), in
    /// two styles. DESKTOP_SHOT_TAG names the build ("before"/"after" a fix).
    func testCaptureIconDrag() throws {
        let directory = ProcessInfo.processInfo.environment["DESKTOP_SCREENSHOT_DIR"]
        try XCTSkipIf(directory == nil, "DESKTOP_SCREENSHOT_DIR not set")
        let tag = ProcessInfo.processInfo.environment["DESKTOP_SHOT_TAG"] ?? "current"
        XCUIDevice.shared.orientation = .landscapeLeft
        for style in ["windows", "macos"] {
            let app = XCUIApplication()
            app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "", "-desktop.style", style,
                                   "-desktop.onboarded", "YES", "-desktop.resetIcons", "YES", "-desktop.wallpaper", "",
                                   "-desktop.icons.cells", ""]
            app.launch()
            let icon = app.descendants(matching: .any)["desktop.icon.Terminal"].firstMatch
            XCTAssertTrue(icon.waitForExistence(timeout: 10))
            sleep(3)
            save(app, to: directory!, name: "icon-drag-\(tag)-\(style)-1-start")
            let start = icon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 300, dy: 220)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
            sleep(1)
            save(app, to: directory!, name: "icon-drag-\(tag)-\(style)-2-dropped")
            app.terminate()
        }
    }

    /// Each section of the Themes app, maximized, in landscape.
    func testCaptureThemesApp() throws {
        let directory = ProcessInfo.processInfo.environment["DESKTOP_SCREENSHOT_DIR"]
        try XCTSkipIf(directory == nil, "DESKTOP_SCREENSHOT_DIR not set")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "themes", "-desktop.style", "ish",
                               "-desktop.onboarded", "YES", "-desktop.colorTheme", "tokyo-night", "-desktop.tiling", "",
                               "-desktop.wallpaper", "", "-desktop.styling", "", "-desktop.themeAppearance", ""]
        app.launch()
        let window = app.descendants(matching: .any)["window:themes"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        sleep(2)
        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [.control, .option])
        sleep(2)
        for section in ["gallery", "appearance", "editor", "styling", "icons", "looks"] {
            app.buttons["themes.section.\(section)"].tap()
            sleep(2)
            save(app, to: directory!, name: "themes-\(section)")
        }
        app.terminate()
    }

    /// The Tiler style with two tiled windows, and its region picker.
    func testCaptureTiler() throws {
        let directory = ProcessInfo.processInfo.environment["DESKTOP_SCREENSHOT_DIR"]
        try XCTSkipIf(directory == nil, "DESKTOP_SCREENSHOT_DIR not set")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "files,terminal", "-desktop.style", "tiler",
                               "-desktop.onboarded", "YES", "-desktop.tiling", "", "-desktop.colorTheme", "tokyo-night"]
        app.launch()
        XCTAssertTrue(app.buttons["desktop.panel.applications"].waitForExistence(timeout: 10))
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        app.typeKey("t", modifierFlags: [.control, .option, .shift])
        sleep(2)
        save(app, to: directory!, name: "tiler-desktop")
        app.typeKey("s", modifierFlags: [.control, .option, .shift])
        sleep(1)
        save(app, to: directory!, name: "tiler-region")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25))
        start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.6)),
                    withVelocity: .slow, thenHoldForDuration: 0.6)
        sleep(2)
        save(app, to: directory!, name: "tiler-after-capture")
        app.terminate()
    }

    private func save(_ app: XCUIApplication, to directory: String, name: String) {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        // Redraw so the device orientation is baked into the pixels; the raw PNG is portrait.
        let shot = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: shot.size, format: format).image { _ in
            shot.draw(in: CGRect(origin: .zero, size: shot.size))
        }
        try? upright.pngData()?.write(to: url)
    }
}
