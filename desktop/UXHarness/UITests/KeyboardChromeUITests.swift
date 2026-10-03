import XCTest

/// The keyboard's chrome over a Linux window (iPadOS's shortcuts bar, an extra-keys row)
/// never covers the dock or taskbar: it is either part of an on-screen keyboard that the
/// focused window lifts above, or not there at all.
@MainActor
final class KeyboardChromeUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(style: String, window spec: String) -> XCUIElement {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "", "-desktop.style", style,
                               "-desktop.tiling", "", "-desktop.onboarded", "YES", "-wallhaven.mock", "YES",
                               "-desktop.colorTheme", "", "-desktop.keyboard.linuxOnScreen", "onDemand",
                               "-desktop.fakeLinuxWindow", spec]
        app.launch()
        let window = app.descendants(matching: .any)["window:linux:\(spec.split(separator: ":")[0])"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        return window
    }

    /// The dock (macOS style) or the taskbar's items (Windows style).
    private var bottomBar: CGRect {
        let dock = app.descendants(matching: .any)["desktop.dock"].firstMatch
        if dock.exists { return dock.frame }
        let items = app.descendants(matching: .any).matching(identifier: "desktop.taskbar.item").allElementsBoundByIndex
        return items.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    }

    private var keyboardFrame: CGRect? {
        let value = app.descendants(matching: .any)["harness.keyboardFrame"].firstMatch.value as? String ?? "none"
        let parts = value.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    private func shot(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["DESKTOP_SCREENSHOT_DIR"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("kbd-\(name).png"))
    }

    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    }

    private func assertBottomBarClear(_ state: String, file: StaticString = #filePath, line: UInt = #line) {
        let bar = bottomBar
        XCTAssertFalse(bar.isNull, "the bottom bar is on screen", file: file, line: line)
        if let keyboard = keyboardFrame {
            XCTAssertFalse(keyboard.intersects(bar), "\(state): keyboard chrome \(keyboard) covers the bottom bar \(bar)",
                           file: file, line: line)
        }
    }

    private func checkTouchOnly(style: String) {
        let window = launch(style: style, window: "firefox")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        settle()
        shot("\(style)-focused")
        assertBottomBarClear("Linux window focused, keyboard down")

        let keyboardButton = app.buttons["desktop.panel.keyboard"]
        XCTAssertTrue(keyboardButton.waitForExistence(timeout: 3))
        keyboardButton.tap()
        settle()
        shot("\(style)-keyboard-up")
        let keyboard = try? XCTUnwrap(keyboardFrame, "the on-screen keyboard is up")
        if let keyboard {
            XCTAssertLessThanOrEqual(window.frame.maxY, keyboard.minY + 1, "the window is lifted above the keyboard")
        }

        app.keyboards.buttons["Hide keyboard"].firstMatch.tap()
        settle()
        shot("\(style)-keyboard-hidden")
        XCTAssertNil(keyboardFrame, "nothing of the keyboard is left behind")
        assertBottomBarClear("keyboard dismissed")
    }

    func testTouchOnlyMacOSDock() {
        checkTouchOnly(style: "macos")
    }

    func testTouchOnlyWindowsTaskbar() {
        checkTouchOnly(style: "windows")
    }

    /// A Linux text field brings the keyboard up by itself (text-input-v3); once it is
    /// dismissed nothing stays over the dock.
    func testTextFieldKeyboardLeavesNothingBehind() {
        let window = launch(style: "macos", window: "firefox:text")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        settle()
        shot("text-keyboard-up")
        if app.keyboards.firstMatch.exists {
            app.keyboards.buttons["Hide keyboard"].firstMatch.tap()
            settle()
        }
        shot("text-keyboard-hidden")
        assertBottomBarClear("text field, keyboard dismissed")
    }
}
