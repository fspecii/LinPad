import XCTest

/// Dock and taskbar buttons behave like the Windows taskbar: tap opens, tap again
/// minimizes, tap again restores.
@MainActor
final class DockTapUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(style: String, extra: [String] = []) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "", "-desktop.style", style,
                               "-desktop.tiling", "", "-desktop.onboarded", "YES", "-wallhaven.mock", "YES",
                               "-desktop.colorTheme", ""] + extra
        app.launch()
        XCTAssertTrue(app.buttons["desktop.panel.applications"].waitForExistence(timeout: 10))
    }

    private func dockButton(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "(identifier == 'desktop.dock.item' OR identifier == 'desktop.taskbar.item') AND label == %@", name)).firstMatch
    }

    private func window(_ appID: String) -> XCUIElement {
        app.descendants(matching: .any)["window:\(appID)"].firstMatch
    }

    private func waitFor(_ description: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(condition(), description)
    }

    private func shot(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["DESKTOP_SCREENSHOT_DIR"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("dock-\(name).png"))
    }

    /// A minimized window stays in the accessibility tree (transparent); its value says so.
    private func isShown(_ element: XCUIElement) -> Bool {
        element.exists && !((element.value as? String) ?? "").contains("minimized")
    }

    func testDockOpensMinimizesAndRestores() {
        launch(style: "macos")
        let files = dockButton("Files")
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        files.tap()
        waitFor("tap opens Files") { isShown(window("files")) }
        shot("opened")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        files.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot("after-second-tap")
        waitFor("tap on the app in front minimizes it") { !isShown(window("files")) }
        shot("minimized")
        files.tap()
        waitFor("tap restores it") { isShown(window("files")) }
        shot("restored")
    }

    func testDockBringsAWindowBehindOthersForward() {
        launch(style: "macos")
        dockButton("Files").tap()
        waitFor("Files opens") { isShown(window("files")) }
        dockButton("Terminal").tap()
        waitFor("Terminal opens") { isShown(window("terminal")) }
        dockButton("Files").tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(isShown(window("files")), "a window behind another comes forward, not minimized")
    }

    func testLinuxWindowFromTheDock() {
        launch(style: "macos", extra: ["-desktop.fakeLinuxWindow", "firefox"])
        let firefox = dockButton("Firefox")
        XCTAssertTrue(firefox.waitForExistence(timeout: 5))
        waitFor("the Linux window is up") { isShown(window("linux:firefox")) }
        window("linux:firefox").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        firefox.tap()
        waitFor("tap minimizes the Linux window in front") { !isShown(window("linux:firefox")) }
        firefox.tap()
        waitFor("tap restores it") { isShown(window("linux:firefox")) }
    }

    func testWindowsTaskbarButton() {
        launch(style: "windows")
        app.buttons["desktop.panel.applications"].tap()
        let search = app.textFields["desktop.launcher.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Files")
        let row = app.buttons["desktop.launcher.app.files"]
        waitFor("Files is listed") { row.exists && row.isHittable }
        row.tap()
        waitFor("Files opens") { isShown(window("files")) }
        let button = app.buttons.matching(identifier: "desktop.taskbar.item").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.tap()
        waitFor("tap on the active window's button minimizes it") { !isShown(window("files")) }
        shot("windows-minimized")
        button.tap()
        waitFor("tap restores it") { isShown(window("files")) }
    }
}
