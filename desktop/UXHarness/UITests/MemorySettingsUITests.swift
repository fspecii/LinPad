import XCTest

/// Settings › Performance › Memory with the mock host's /proc/ish/memory, in a few styles.
@MainActor
final class MemorySettingsUITests: XCTestCase {
    private func openMemory(style: String, extra: [String] = [], waitFor identifier: String) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "settings", "-desktop.style", style,
                               "-desktop.onboarded", "YES", "-desktop.colorTheme", "", "-desktop.themeAppearance", "",
                               "-desktop.styling", ""] + extra
        app.launch()
        let window = app.descendants(matching: .any)["window:settings"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let target = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 8), "\(identifier) is shown")
        for _ in 0..<40 where !target.isHittable {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        }
        XCTAssertTrue(target.isHittable)
        // Scroll until the section sits in the upper part of the window, so its lists show too.
        for _ in 0..<12 where target.frame.midY > window.frame.minY + window.frame.height * 0.35 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        }
        return app
    }

    private func shot(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["DESKTOP_SCREENSHOT_DIR"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("memory-\(name).png"))
    }

    func testMemoryPanelInThreeStyles() {
        for style in ["ish", "classic", "macos"] {
            let app = openMemory(style: style, waitFor: "settings.memory.summary")
            XCTAssertTrue(app.descendants(matching: .any)["settings.memory.processes"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["settings.memory.closes"].exists)
            sleep(1)
            shot(style)
            app.terminate()
        }
    }

    func testWithoutTheMonitorTheUnavailableStateShows() {
        let app = openMemory(style: "ish", extra: ["-mock.noMemoryReport", "YES"], waitFor: "settings.memory.unavailable")
        XCTAssertFalse(app.descendants(matching: .any)["settings.memory.summary"].exists)
        shot("unavailable")
    }
}
