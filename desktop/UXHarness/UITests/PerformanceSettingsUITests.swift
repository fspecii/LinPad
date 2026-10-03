import XCTest

@MainActor
final class PerformanceSettingsUITests: XCTestCase {
    func testFirefoxRenderingPicker() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "settings", "-desktop.style", "ish",
                               "-desktop.onboarded", "YES", "-desktop.colorTheme", ""]
        app.launch()
        let picker = app.descendants(matching: .any)["settings.firefoxRendering"].firstMatch
        let window = app.descendants(matching: .any)["window:settings"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        for _ in 0..<12 where !picker.isHittable { window.swipeUp() }
        XCTAssertTrue(picker.isHittable, "the Performance section shows the Firefox picker")
        picker.tap()
        app.buttons["Smooth Video"].firstMatch.tap()
        let note = app.descendants(matching: .any)["settings.firefoxRendering.note"].firstMatch
        let deadline = Date().addingTimeInterval(5)
        while !note.label.contains("reopen Firefox") && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertTrue(note.label.contains("reopen Firefox"), note.label)
        if let directory = ProcessInfo.processInfo.environment["DESKTOP_SCREENSHOT_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("perf-settings.png"))
        }
    }
}
