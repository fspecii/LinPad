import XCTest

/// First-run onboarding, driven by keyboard and by touch, plus screenshots of every step.
@MainActor
final class OnboardingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        // No -desktop.style: the argument domain would override the style onboarding saves.
        // An empty progress value starts from the first step whatever an earlier run left.
        app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "", "-desktop.tiling", "",
                               "-desktop.onboarded", "NO", "-desktop.onboarding.progress", "",
                               "-desktop.wallpaper", "", "-wallhaven.mock", "YES"]
    }

    private var onboarding: XCUIElement { app.descendants(matching: .any)["desktop.onboarding"].firstMatch }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func waitFor(_ description: String, timeout: TimeInterval = 8, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), "timed out waiting for \(description)")
    }

    private func expectStep(_ step: String) {
        XCTAssertTrue(element("onboarding.step.\(step)").waitForExistence(timeout: 5), "step \(step) is showing")
    }

    private func launchToIntro() {
        app.launch()
        XCTAssertTrue(onboarding.waitForExistence(timeout: 15), "onboarding opens at first launch")
        expectStep("intro")
    }

    // MARK: Keyboard only

    func testCompleteOnboardingWithKeyboardOnly() {
        launchToIntro()
        // The simulator delivers hardware key events only after the app has seen one touch;
        // this lands on the intro's backdrop, which has no controls. Right arrow walks the
        // steps (Return does the same on a device; see the note on typeText below).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()

        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        expectStep("tour")
        for card in ["apps", "themes", "fast", "files"] {
            app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
            waitFor("tour card \(card)") { element("onboarding.tour.card.\(card)").isHittable }
        }
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        waitFor("back to the fast mode card") { element("onboarding.tour.card.fast").isHittable }
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        expectStep("personalize")
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        expectStep("apps")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        expectStep("personalize")
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        expectStep("apps")
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        expectStep("fastMode")
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        expectStep("keyboard")

        let tryIt = element("onboarding.keyboard.try")
        XCTAssertEqual(tryIt.value as? String, "waiting")
        app.typeKey("a", modifierFlags: [.control, .option])
        waitFor("the cheat card reacts to ⌃⌥A") { (tryIt.value as? String) == "done" }
        XCTAssertFalse(element("desktop.launcher").exists, "the launcher does not open behind onboarding")

        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        expectStep("finale")
        // Return is "Show Me".
        app.typeText("\r")
        waitFor("onboarding closed") { !onboarding.exists }
        for id in ["window:browser", "window:terminal", "window:files"] {
            XCTAssertTrue(element(id).waitForExistence(timeout: 8), "\(id) opens in the demo workspace")
        }
    }

    // MARK: Touch

    func testSkipKeepsChoicesSoFar() {
        launchToIntro()
        element("onboarding.next").tap()
        expectStep("tour")
        element("onboarding.skip").tap()
        // Skip from the tour; the desktop comes up with the defaults.
        waitFor("onboarding closed") { !onboarding.exists }
        XCTAssertTrue(app.buttons["desktop.panel.applications"].waitForExistence(timeout: 5))
    }

    func testPickStyleThenSkip() {
        launchToIntro()
        element("onboarding.next").tap()
        expectStep("tour")
        for _ in 0..<5 { element("onboarding.next").tap() }
        expectStep("personalize")
        element("onboarding.style.kylin").tap()
        // Applied live, behind the sheet.
        XCTAssertTrue(element("desktop.panel.search").waitForExistence(timeout: 5), "the Kylin panel is up already")
        element("onboarding.skip").tap()
        waitFor("onboarding closed") { !onboarding.exists }
        XCTAssertTrue(element("desktop.panel.search").exists, "the chosen style stays")
    }

    func testSkipFromIntro() {
        launchToIntro()
        element("onboarding.skip").tap()
        waitFor("onboarding closed") { !onboarding.exists }
        waitFor("boot splash gone", timeout: 15) { !element("desktop.bootSplash").exists }
    }

    func testReplayFromSettings() {
        app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "settings", "-desktop.tiling", "",
                               "-desktop.onboarded", "YES", "-desktop.style", "ish"]
        app.launch()
        let replay = element("settings.replayWelcome")
        XCTAssertTrue(element("window:settings").waitForExistence(timeout: 15))
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<12 where !replay.isHittable { scroll.swipeUp() }
        replay.tap()
        XCTAssertTrue(onboarding.waitForExistence(timeout: 5), "Replay Welcome opens onboarding")
        expectStep("intro")
        element("onboarding.skip").tap()
        waitFor("onboarding closed") { !onboarding.exists }
    }

    // MARK: Screenshots

    /// Every step in landscape (and two in portrait), when DESKTOP_SCREENSHOT_DIR is set.
    func testCaptureEveryStep() throws {
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["DESKTOP_SCREENSHOT_DIR"]
            .map { $0 }, "DESKTOP_SCREENSHOT_DIR not set")
        func shot(_ name: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("onboarding-\(name).png"))
        }
        launchToIntro()
        sleep(1)
        shot("01-intro-drawing")
        sleep(3)
        shot("02-intro")
        element("onboarding.next").tap()
        expectStep("tour")
        for (index, card) in ["desktop", "apps", "themes", "fast", "files"].enumerated() {
            if index > 0 { element("onboarding.next").tap() }
            waitFor("card \(card)") { element("onboarding.tour.card.\(card)").isHittable }
            sleep(2)
            shot("03-tour-\(index + 1)-\(card)")
        }
        element("onboarding.next").tap()
        expectStep("personalize")
        element("onboarding.style.macos").tap()
        sleep(1)
        shot("04-personalize")
        let tokyo = element("onboarding.theme.tokyo-night")
        if tokyo.exists {
            tokyo.tap()
            sleep(1)
            shot("05-personalize-tokyo-night")
            element("onboarding.theme.none").tap()
        }
        element("onboarding.style.ish").tap()
        element("onboarding.next").tap()
        expectStep("apps")
        sleep(1)
        shot("06-apps")
        element("onboarding.next").tap()
        expectStep("fastMode")
        shot("07-fast-mode")
        element("onboarding.next").tap()
        expectStep("keyboard")
        shot("08-keyboard")
        app.typeKey("a", modifierFlags: [.control, .option])
        sleep(1)
        shot("09-keyboard-tried")
        element("onboarding.next").tap()
        expectStep("finale")
        shot("10-finale")
        element("onboarding.showMe").tap()
        sleep(1)
        shot("11-demo-reveal")
        sleep(3)
        shot("12-demo")
        app.terminate()

        XCUIDevice.shared.orientation = .portrait
        launchToIntro()
        sleep(4)
        shot("13-portrait-intro")
        element("onboarding.next").tap()
        for _ in 0..<5 { element("onboarding.next").tap() }
        expectStep("personalize")
        sleep(1)
        shot("14-portrait-personalize")
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    /// Shell surfaces touched by the polish pass, tagged DESKTOP_SHOT_TAG (before/after).
    func testCapturePolishSurfaces() throws {
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["DESKTOP_SCREENSHOT_DIR"], "DESKTOP_SCREENSHOT_DIR not set")
        let tag = ProcessInfo.processInfo.environment["DESKTOP_SHOT_TAG"] ?? "current"
        func shot(_ name: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("polish-\(tag)-\(name).png"))
        }
        func launch(style: String, appearance: String, autostart: String = "") {
            app.terminate()
            app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", autostart, "-desktop.tiling", "",
                                   "-desktop.onboarded", "YES", "-desktop.style", style, "-desktop.appearance", appearance,
                                   "-desktop.colorTheme", "", "-desktop.wallpaper", "", "-wallhaven.mock", "YES"]
            app.launch()
            XCTAssertTrue(app.buttons["desktop.panel.applications"].waitForExistence(timeout: 15))
            waitFor("boot splash gone", timeout: 15) { !element("desktop.bootSplash").exists }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.7)).tap()
            sleep(1)
        }
        launch(style: "ubuntu", appearance: "light")
        shot("1-ubuntu-light-topbar")
        launch(style: "ish", appearance: "light", autostart: "files")
        shot("2-ish-light-panel")
        app.typeKey("o", modifierFlags: [.control, .option])
        sleep(1)
        app.typeKey("o", modifierFlags: [.control, .option])
        launch(style: "ish", appearance: "dark")
        app.typeKey("o", modifierFlags: [.control, .option])
        sleep(1)
        shot("3-overview-empty")
        app.typeKey("o", modifierFlags: [.control, .option])
        app.buttons["desktop.panel.applications"].tap()
        let search = app.textFields["desktop.launcher.search"]
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText("zzqx")
            sleep(1)
            shot("4-launcher-no-match")
        }
        launch(style: "macos", appearance: "light")
        app.buttons["desktop.panel.applications"].tap()
        sleep(1)
        shot("5-macos-light-launchpad")
        if app.textFields.firstMatch.waitForExistence(timeout: 3) {
            app.textFields.firstMatch.tap()
            app.textFields.firstMatch.typeText("zzqx")
            sleep(1)
            shot("6-launchpad-no-match")
        }
        launch(style: "ish", appearance: "dark", autostart: "themes")
        let favorites = app.segmentedControls["themes.filter"].buttons["Favorites"]
        if favorites.waitForExistence(timeout: 5) {
            favorites.tap()
            sleep(1)
            shot("7-themes-favorites-empty")
        }
    }
}
