import XCTest

/// Screensaver and idle, clipboard history, the sectioned Command Menu, and Settings › Updates.
@MainActor
final class IdleClipboardMenuUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(_ extra: [String] = [], autostart: String = "", tap: Bool = true) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", autostart, "-desktop.style", "ish",
                               "-desktop.tiling", "", "-desktop.onboarded", "YES", "-wallhaven.mock", "YES",
                               "-desktop.wallpaper", "", "-desktop.resetIcons", "YES", "-desktop.colorTheme", "", "-desktop.themeAppearance", "",
                               "-desktop.styling", "", "-desktop.screensaver.afterMinutes", "0",
                               "-desktop.autoLock.afterMinutes", "0", "-desktop.idle.keepAwake", "NO",
                               "-desktop.clipboard.reset", "YES"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["desktop.panel.applications"].waitForExistence(timeout: 10))
        waitFor("boot splash gone", timeout: 15) { !self.app.descendants(matching: .any)["desktop.bootSplash"].exists }
        if tap { app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.7)).tap() }
    }

    private func waitFor(_ description: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertTrue(condition(), description)
    }

    private func shot(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["DESKTOP_SCREENSHOT_DIR"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("r9-\(name).png"))
    }

    /// Presses a desktop shortcut and waits for `element`. In this simulator a fresh app
    /// launch after the first of a run loses its first hardware key (commit 2ee72bae, which
    /// passed before, fails the same way now), so the key-driven tests run first.
    private func press(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags, until element: XCUIElement) {
        let start = Date()
        app.typeKey(key, modifierFlags: modifiers)
        if !element.waitForExistence(timeout: 10) {
            shot("shortcut-failed-\(key)")
            print("FOCUS-TREE", app.debugDescription.split(separator: "\n").filter { $0.contains("Keyboard") || $0.contains("TextField") || $0.contains("TextView") || $0.contains("Alert") || $0.contains("window:") }.joined(separator: "\n"))
        }
        XCTAssertTrue(element.exists, "\(key) opens it")
        print(String(format: "SHORTCUT %@ opened after %.1f s", key, Date().timeIntervalSince(start)))
    }

    private var screensaver: XCUIElement { app.descendants(matching: .any)["desktop.screensaver"].firstMatch }
    private var menu: XCUIElement { app.textFields["commandMenu.search"] }

    private func runMenuItem(_ id: String) {
        let item = app.descendants(matching: .any)["commandMenu.item.\(id)"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), id)
        item.tap()
    }

    func testScreensaverStylesAndDismiss() {
        for style in ["logo", "matrix", "clock"] {
            launch(["-desktop.screensaver.style", style, "-desktop.screensaver.showNow", "YES"], tap: false)
            XCTAssertTrue(screensaver.waitForExistence(timeout: 12))
            sleep(2)
            shot("screensaver-\(style)")
            screensaver.tap()
            waitFor("a tap ends the screensaver") { !self.screensaver.exists }
            app.terminate()
        }
    }

    /// The menu's "Start Screensaver" item (first launch of a run: see press(_:_:until:)).
    func testAStartScreensaverFromTheMenu() {
        launch()
        press("k", .command, until: menu)
        menu.typeText("screensaver")
        runMenuItem("system:screensaver")
        XCTAssertTrue(screensaver.waitForExistence(timeout: 3))
    }

    func testScreensaverStartsAfterTheIdleTimeout() {
        launch(["-desktop.screensaver.afterMinutes", "1"])
        waitFor("the screensaver starts after a minute idle", timeout: 90) { self.screensaver.exists }
        app.typeKey("x", modifierFlags: [])
        app.tap()
        waitFor("input ends it") { !self.screensaver.exists }
    }

    func testSettingsPreview() {
        launch(["-desktop.screensaver.style", "matrix"], autostart: "settings")
        let preview = app.descendants(matching: .any)["settings.screensaver.preview"].firstMatch
        let window = app.descendants(matching: .any)["window:settings"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        for _ in 0..<15 where !preview.isHittable { window.swipeUp() }
        XCTAssertTrue(preview.isHittable)
        sleep(1)
        shot("settings-screensaver")
    }

    /// Runs last (name order): typing into a text view leaves the simulator's keyboard
    /// routing changed for later launches, and bare-desktop shortcuts then go missing.
    func testZClipboardHistoryRecordsPinsAndRestores() {
        launch(autostart: "editor")
        let editor = app.descendants(matching: .any)["window:editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let text = editor.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap()
        for word in ["first copy", "second copy"] {
            text.typeKey("a", modifierFlags: .command)
            text.typeText(word)
            text.typeKey("a", modifierFlags: .command)
            text.typeKey("c", modifierFlags: .command)
            sleep(1)
        }
        press("v", [.control, .option], until: menu)
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'commandMenu.item.clipboard:'"))
        waitFor("both copies are listed") { rows.count >= 2 }
        XCTAssertEqual(rows.element(boundBy: 0).label.contains("second copy") || app.staticTexts["second copy"].exists, true)
        let pins = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'clipboard.pin.'"))
        waitFor("each entry has a pin button") { pins.count >= 2 }
        pins.element(boundBy: 1).tap()
        waitFor("the older entry shows as pinned") {
            self.app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Pinned'")).count > 0
                || rows.element(boundBy: 1).label.contains("Pinned")
        }
        shot("clipboard-history")
        app.descendants(matching: .any)["clipboard.clear"].firstMatch.tap()
        shot("clipboard-after-clear")
        waitFor("clear keeps the pinned entry", timeout: 8) { rows.count == 1 }
        rows.element(boundBy: 0).tap()
        waitFor("choosing an entry closes the panel") { !self.menu.exists }
    }

    func testSectionMenu() {
        launch()
        press("m", [.control, .option, .shift], until: menu)
        XCTAssertTrue(app.descendants(matching: .any)["commandMenu.item.menu:Capture"].exists)
        shot("menu-index")
        app.textFields["commandMenu.search"].typeText("c")
        XCTAssertTrue(app.descendants(matching: .any)["commandMenu.item.command:capture.full"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["commandMenu.item.theme:nord"].exists, "only Capture is listed")
        XCTAssertEqual(app.textFields["commandMenu.search"].value as? String ?? "", "Search Capture",
                       "the section's letter does not stay in the search field")
        shot("menu-capture")
    }

    func testUpdatesShowsVersionsAndRollsBack() {
        launch(["-harness.previousSystem", "2026092001"], autostart: "settings")
        let window = app.descendants(matching: .any)["window:settings"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let rollback = app.buttons["settings.updates.rollback"]
        XCTAssertTrue(rollback.waitForExistence(timeout: 5), "the rollback button exists when an earlier system is kept")
        for _ in 0..<40 where !rollback.isHittable {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
        if !rollback.isHittable {
            shot("updates-debug")
            print("UPDATES-TREE", app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings.updates'")).debugDescription)
        }
        XCTAssertTrue(rollback.isHittable, "the rollback button shows when an earlier system is kept")
        XCTAssertTrue(app.descendants(matching: .any)["settings.updates.repairKitVersion"].exists)
        shot("updates-rollback")
        rollback.tap()
        let confirm = app.buttons["Roll Back at Next Launch"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        shot("updates-rollback-confirm")
        confirm.tap()
        XCTAssertTrue(app.buttons["settings.updates.cancelRollback"].waitForExistence(timeout: 3))
        shot("updates-rollback-scheduled")
    }
}
