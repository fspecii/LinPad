import XCTest

/// Desktop widgets, the panel clock's calendar and Quick Settings' new tiles, in landscape.
/// With DESKTOP_SCREENSHOT_DIR set (TEST_RUNNER_ prefix on the command line),
/// `testCaptureScreenshots` saves them for review.
@MainActor
final class WidgetsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func launch(style: String = "ish", resetWidgets: Bool) {
        app = XCUIApplication()
        app.launchArguments = ["-desktop.autostart", "", "-desktop.style", style, "-desktop.onboarded", "YES",
                               "-wallhaven.mock", "YES", "-desktop.wallpaper", "", "-desktop.resetIcons", "YES",
                               "-desktop.colorTheme", "", "-desktop.themeAppearance", "", "-desktop.styling", "",
                               "-desktop.resetSession", "YES"]
            + (resetWidgets ? ["-desktop.resetWidgets", "YES"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["desktop.panel.applications"].waitForExistence(timeout: 10))
        waitFor("boot splash gone", timeout: 15) { !self.app.descendants(matching: .any)["desktop.bootSplash"].exists }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func waitFor(_ description: @autoclosure () -> String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(condition(), description())
    }

    private func beginEditingWidgets() {
        element("desktop.surface").coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.7)).press(forDuration: 1.2)
        let edit = app.buttons["Edit Widgets…"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(element("widgets.editBar").waitForExistence(timeout: 5))
    }

    private func addWidget(_ title: String) {
        app.buttons["widgets.add"].firstMatch.tap()
        let item = app.buttons[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        waitFor("the add menu closed") { !item.isHittable }
    }

    // MARK: Tests

    func testMovedWidgetKeepsItsPlaceAfterRelaunch() {
        launch(resetWidgets: true)
        beginEditingWidgets()
        addWidget("Clock")
        let clock = element("desktop.widget.clock")
        XCTAssertTrue(clock.waitForExistence(timeout: 5))
        let before = clock.frame

        let start = clock.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: -243, dy: 205)), withVelocity: .slow,
                    thenHoldForDuration: 0.2)
        waitFor("clock moved: \(clock.frame) from \(before)") { clock.frame.minX < before.minX - 150 }
        // Snapped to the 40 pt grid.
        XCTAssertEqual((before.minX - clock.frame.minX).truncatingRemainder(dividingBy: 40), 0, accuracy: 1.5)
        XCTAssertEqual((clock.frame.minY - before.minY).truncatingRemainder(dividingBy: 40), 0, accuracy: 1.5)

        app.buttons["widgets.done"].tap()
        waitFor("edit mode ended") { !self.element("widgets.editBar").exists }
        let placed = clock.frame

        app.terminate()
        launch(resetWidgets: false)
        let relaunched = element("desktop.widget.clock")
        XCTAssertTrue(relaunched.waitForExistence(timeout: 5))
        XCTAssertEqual(relaunched.frame.minX, placed.minX, accuracy: 1)
        XCTAssertEqual(relaunched.frame.minY, placed.minY, accuracy: 1)
    }

    func testPanelClockOpensTheCalendar() {
        launch(resetWidgets: true)
        element("desktop.panel.clock").tap()
        XCTAssertTrue(element("calendar.popover").waitForExistence(timeout: 5))
        XCTAssertTrue(element("calendar.upcoming").exists)
        app.buttons["calendar.popover.open"].tap()
        XCTAssertTrue(element("window:calendar").waitForExistence(timeout: 5))
        XCTAssertTrue(element("calendar.month").waitForExistence(timeout: 5))
    }

    // MARK: Screenshots

    func testCaptureScreenshots() throws {
        let directory = ProcessInfo.processInfo.environment["DESKTOP_SCREENSHOT_DIR"]
        try XCTSkipIf(directory == nil, "DESKTOP_SCREENSHOT_DIR not set")
        launch(resetWidgets: true)

        app.buttons["desktop.panel.quickSettings"].tap()
        XCTAssertTrue(element("quickSettings.darkMode").waitForExistence(timeout: 5))
        waitFor("now playing filled in", timeout: 8) { self.element("nowPlaying.title").label != "Not Playing" }
        save(to: directory!, name: "quick-settings")
        app.buttons["desktop.panel.quickSettings"].tap()

        element("desktop.panel.clock").tap()
        XCTAssertTrue(element("calendar.popover").waitForExistence(timeout: 5))
        sleep(1)
        save(to: directory!, name: "calendar-popover")
        app.buttons["calendar.popover.open"].tap()
        XCTAssertTrue(element("calendar.month").waitForExistence(timeout: 5))
        for title in ["Design review", "Dentist", "Ship LinPad"] {
            app.buttons["calendar.new"].firstMatch.tap()
            let field = app.textFields["calendar.editor.title"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.typeText(title)
            app.buttons["calendar.editor.save"].tap()
            waitFor("editor closed") { !field.exists }
            app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
            app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        }
        sleep(1)
        save(to: directory!, name: "calendar-month")
        app.typeKey("w", modifierFlags: [.control, .option])
        waitFor("calendar closed") { !self.element("window:calendar").exists }

        beginEditingWidgets()
        for title in ["Clock", "Calendar", "System Monitor", "Now Playing", "Notes"] { addWidget(title) }
        app.buttons["widgets.done"].tap()
        waitFor("edit mode ended") { !self.element("widgets.editBar").exists }
        let notes = app.textViews["widget.notes.text"].firstMatch
        if notes.waitForExistence(timeout: 3) {
            notes.tap()
            notes.typeText("Buy milk\nCall the plumber")
            let hide = app.keyboards.buttons["Hide keyboard"].firstMatch
            if hide.exists { hide.tap() }
        }
        sleep(2)
        save(to: directory!, name: "widgets-ish")
        app.terminate()

        launch(style: "macos", resetWidgets: false)
        sleep(3)
        save(to: directory!, name: "widgets-macos")
        app.terminate()

        launch(style: "windows", resetWidgets: false)
        sleep(3)
        save(to: directory!, name: "widgets-windows")
    }

    private func save(to directory: String, name: String) {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        let shot = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: shot.size, format: format).image { _ in
            shot.draw(in: CGRect(origin: .zero, size: shot.size))
        }
        try? upright.pngData()?.write(to: url)
    }
}
