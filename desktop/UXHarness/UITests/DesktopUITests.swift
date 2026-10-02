import XCTest

/// Drives the desktop the way a user with a keyboard, trackpad or finger does, in landscape.
@MainActor
class DesktopUITests: XCTestCase {
    /// Subclasses rerun every test in another desktop style.
    var style: String { "ish" }
    private var app: XCUIApplication!
    private let windowKeys: XCUIElement.KeyModifierFlags = [.control, .option]

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        // An empty argument-domain value starts every workspace untiled, whatever a previous run saved.
        app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "", "-desktop.style", style,
                               "-desktop.tiling", "", "-desktop.onboarded", "YES", "-wallhaven.mock", "YES",
                               "-desktop.wallpaper", "", "-desktop.resetIcons", "YES", "-desktop.colorTheme", "", "-desktop.themeAppearance", "", "-desktop.styling", ""]
        app.launch()
        XCTAssertTrue(app.buttons["desktop.panel.applications"].waitForExistence(timeout: 10))
        waitFor("boot splash gone", timeout: 15) { !app.descendants(matching: .any)["desktop.bootSplash"].exists }
        // The simulator routes hardware key events to the app only after it has seen a touch.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.7)).tap()
    }

    // MARK: Helpers

    private var windows: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'window:'"))
    }

    private func window(_ appID: String) -> XCUIElement {
        app.descendants(matching: .any)["window:\(appID)"].firstMatch
    }

    /// The window area in screen coordinates, whatever panels the style puts around it.
    private var desktop: CGRect {
        app.descendants(matching: .any)["desktop.surface"].firstMatch.frame
    }

    /// A screenshot for diagnosing a failure, when DESKTOP_SCREENSHOT_DIR is set.
    private func debugShot(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["DESKTOP_SCREENSHOT_DIR"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("debug-\(name).png"))
    }

    private func openFromLauncher(_ appID: String, search: String) {
        let field = app.textFields["desktop.launcher.search"]
        waitFor("the previous launcher has closed") { !field.exists }
        app.buttons["desktop.panel.applications"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(search)
        let row = app.buttons["desktop.launcher.app.\(appID)"]
        waitFor("\(appID) is listed for “\(search)”") { row.exists && row.isHittable }
        row.tap()
    }

    private func openTerminal() {
        openFromLauncher("terminal", search: "Term")
    }

    private func value(of element: XCUIElement) -> String {
        element.value as? String ?? ""
    }

    private func waitFor(_ description: @autoclosure () -> String, timeout: TimeInterval = 5,
                         _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(condition(), description())
    }

    /// Waits out the tiling animation before comparing.
    private func assertFrame(_ actual: @autoclosure () -> CGRect, equals expected: CGRect, accuracy: CGFloat = 3,
                             file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        func matches(_ frame: CGRect) -> Bool {
            abs(frame.minX - expected.minX) <= accuracy && abs(frame.minY - expected.minY) <= accuracy
                && abs(frame.width - expected.width) <= accuracy && abs(frame.height - expected.height) <= accuracy
        }
        while !matches(actual()) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let actual = actual()
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, "minX of \(actual)", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, "minY of \(actual)", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, "width of \(actual)", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, "height of \(actual)", file: file, line: line)
    }

    // MARK: Tests

    func testLauncherOpensAppsAndTwoWindowsFitSideBySide() {
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "runs in landscape")
        openFromLauncher("files", search: "Files")
        let files = window("files")
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        openFromLauncher("settings", search: "Sett")
        let settings = window("settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(files.frame.intersection(settings.frame).width < 1, "\(files.frame) overlaps \(settings.frame)")
        XCTAssertTrue(value(of: settings).contains("focused"))
    }

    /// The launcher's own Settings control (footer gear, Start menu gear, Kylin side
    /// column), or the Settings tile where the launcher is a plain app grid.
    func testLauncherSettingsButtonOpensSettings() {
        app.buttons["desktop.panel.applications"].tap()
        let gear = app.buttons["desktop.launcher.settings"].firstMatch
        let tile = app.buttons["desktop.launcher.app.settings"].firstMatch
        waitFor("launcher open") { gear.exists || tile.exists }
        (gear.exists ? gear : tile).tap()
        XCTAssertTrue(window("settings").waitForExistence(timeout: 5), "Settings opened from the launcher")
        XCTAssertFalse(gear.exists, "the launcher closed")
    }

    func testKeyboardSettingsShowModifierKeyboardAndOptionKeyChoices() {
        openFromLauncher("settings", search: "Sett")
        let settings = window("settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let ids = ["settings.shortcutModifier", "settings.linuxKeyboard", "settings.linuxOptionKey"]
        for id in ids {
            let element = app.descendants(matching: .any)[id].firstMatch
            for _ in 0..<12 where !(element.exists && element.isHittable) { settings.swipeUp() }
            XCTAssertTrue(element.exists && element.isHittable, "\(id) renders in Settings")
        }
    }

    func testToastSwipesAwayAndWorkspacesAreAddedReorderedAndDeleted() {
        openFromLauncher("settings", search: "Sett")
        let aurora = app.buttons["wallpaper.gradient.aurora"]
        XCTAssertTrue(aurora.waitForExistence(timeout: 5))
        aurora.tap()
        let toast = app.descendants(matching: .any)["desktop.toast"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        let start = toast.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 220, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0)
        waitFor("toast swiped away") { !toast.exists }

        app.typeKey("n", modifierFlags: windowKeys)
        let fifth = app.buttons["desktop.workspace.5"]
        XCTAssertTrue(fifth.waitForExistence(timeout: 5), "⌃⌥N adds a workspace")
        XCTAssertTrue(fifth.isSelected, "and switches to it")
        app.buttons["desktop.workspace.add"].tap()
        XCTAssertTrue(app.buttons["desktop.workspace.6"].waitForExistence(timeout: 5), "the + pill adds one")
        app.buttons["desktop.workspace.6"].press(forDuration: 1.0)
        let delete = app.buttons["Delete Workspace"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        waitFor("empty workspace deleted without asking") { !app.buttons["desktop.workspace.6"].exists }
    }

    func testColorThemePickerPreviewsAndApplies() {
        app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [.control, .option, .shift])
        let title = app.staticTexts["themePicker.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "⌃⌥⇧Space opens the picker")
        XCTAssertEqual(title.label, "Style Colors")
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        waitFor("arrow previews the next theme") { title.label != "Style Colors" }
        let chosen = title.label
        app.buttons["themePicker.apply"].tap()
        waitFor("picker closed") { !title.exists }
        app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [.control, .option, .shift])
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, chosen, "the applied theme is the current one")
        XCTAssertTrue(app.buttons["themePicker.card.none"].exists)
        app.buttons["themePicker.card.none"].tap()
        app.buttons["themePicker.apply"].tap()
        waitFor("back to the style's colours") { !title.exists }
    }

    /// The user's bug: after the on-screen keyboard, the focused window stayed squashed.
    /// With a software keyboard: it lifts, and comes back to its exact frame when the
    /// keyboard hides. With a hardware keyboard: it never moves.
    func testWindowFrameIsRestoredAfterTheKeyboardHides() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFromLauncher("themes", search: "Them")
        let themes = window("themes")
        XCTAssertTrue(themes.waitForExistence(timeout: 5))
        app.buttons["themes.section.editor"].tap()
        let name = app.textFields["themes.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let original = themes.frame
        name.tap()
        let keyboard = app.keyboards.firstMatch
        if keyboard.waitForExistence(timeout: 3) {
            waitFor("lifted for the keyboard: window \(themes.frame), was \(original)") { themes.frame != original }
            let hide = keyboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'keyboard' OR label CONTAINS[c] 'dismiss'")).firstMatch
            if hide.exists { hide.tap() } else { app.buttons["themes.section.gallery"].tap() }
            waitFor("keyboard gone") { !keyboard.exists }
        } else {
            name.typeText("x")
        }
        waitFor("exact frame back: \(themes.frame) vs \(original)", timeout: 5) { themes.frame == original }
    }

    // MARK: Command Menu, cheatsheet, capture

    func testCommandMenuOpensAnAppAndCheatsheetShows() {
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["commandMenu.search"]
        if !search.waitForExistence(timeout: 5) { debugShot("cmdk-missing") }
        XCTAssertTrue(search.exists, "⌘K opens the Command Menu")
        debugShot("command-menu")
        search.typeText("files")
        search.typeText("\n")
        XCTAssertTrue(window("files").waitForExistence(timeout: 5), "Return runs the best match")
        XCTAssertFalse(search.exists)

        app.typeKey("/", modifierFlags: .command)
        let sheet = app.descendants(matching: .any)["shortcutSheet"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "⌘/ shows the cheatsheet")
        XCTAssertTrue(app.staticTexts["Command Menu"].exists, "generated from the binding table")
        debugShot("cheatsheet")
        app.typeKey("/", modifierFlags: .command)
        waitFor("cheatsheet closed") { !sheet.exists }
    }

    func testBrightnessCommandShowsTheOSD() {
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["commandMenu.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("brightness down\n")
        let osd = app.descendants(matching: .any)["desktop.osd"].firstMatch
        XCTAssertTrue(osd.waitForExistence(timeout: 3), "the OSD shows the new level")
        debugShot("osd")
        waitFor("the OSD fades", timeout: 4) { !osd.exists }
    }

    func testScreenshotIsSavedToPictures() {
        app.typeKey("s", modifierFlags: windowKeys)
        let toast = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Screenshot saved to ~/Pictures/Screenshots'")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 10), "the toast says where the screenshot went")
        XCTAssertTrue(app.buttons["Share"].exists, "the toast offers Share")
        debugShot("screenshot-toast")
    }

    // MARK: Themes app

    private func openThemes() -> XCUIElement {
        openFromLauncher("themes", search: "Them")
        let themes = window("themes")
        XCTAssertTrue(themes.waitForExistence(timeout: 5))
        // Landscape and maximized where the key gets through, so the sidebar stays on screen.
        waitFor("focused") { value(of: themes).contains("focused") }
        XCUIDevice.shared.orientation = .landscapeLeft
        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: windowKeys)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        return themes
    }

    func testThemesAppAppliesAThemeFromTheGallery() {
        let themes = openThemes()
        let search = themes.textFields["themes.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("nord")
        let apply = app.buttons["themes.apply.nord"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        apply.tap()
        waitFor("Nord applied") { apply.label == "Applied" }
    }

    func testThemeEditorSavesACustomTheme() {
        _ = openThemes()
        app.buttons["themes.section.editor"].tap()
        let name = app.textFields["themes.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "UI Test Theme")
        let accent = app.textFields["themes.editor.hex.accent"]
        accent.tap()
        accent.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "#ff8800")
        XCUIDevice.shared.orientation = .landscapeLeft
        app.buttons["themes.editor.save"].tap()
        let status = app.staticTexts["themes.editor.status"]
        if !status.waitForExistence(timeout: 10) { debugShot("editor-save") }
        XCTAssertTrue(status.exists)
        waitFor("saved: \(status.label)", timeout: 10) { status.label.hasPrefix("Saved UI Test Theme") }
        // The saved theme is the desktop's current one: the colour theme picker opens on it.
        app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [.control, .option, .shift])
        let title = app.staticTexts["themePicker.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "UI Test Theme")
        XCTAssertTrue(app.buttons["themePicker.card.ui-test-theme"].exists, "listed with the other themes")
    }

    func testLightAndDarkModesApplyThePairedTheme() {
        _ = openThemes()
        app.buttons["themes.section.appearance"].tap()
        let enabled = app.switches["themes.mode.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        enabled.tap()
        let now = app.staticTexts["themes.mode.current"]
        app.buttons["Light"].firstMatch.tap()
        let lightPicker = app.buttons["themes.lightTheme"]
        if lightPicker.exists {
            lightPicker.tap()
            app.buttons["Catppuccin Latte"].firstMatch.tap()
        }
        waitFor("light member applied: \(now.label)", timeout: 5) { now.label == "Now: Catppuccin Latte" }
        app.buttons["Dark"].firstMatch.tap()
        waitFor("dark partner applied: \(now.label)", timeout: 5) { now.label == "Now: Catppuccin" }
    }

    func testLauncherIsKeyboardNavigable() {
        app.typeKey("a", modifierFlags: windowKeys)
        let field = app.textFields["desktop.launcher.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("e")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'desktop.launcher.app.'"))
        let first = rows.matching(NSPredicate(format: "selected == true")).firstMatch.identifier
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        let highlighted = rows.matching(NSPredicate(format: "selected == true")).firstMatch.identifier
        XCTAssertNotEqual(first, highlighted, "the arrow key moves the highlight")
        field.typeText("\n")
        let opened = highlighted.replacingOccurrences(of: "desktop.launcher.app.", with: "")
        waitFor("the highlighted app (\(opened)) opened") { window(opened).exists }
        XCTAssertFalse(field.exists)

        app.typeKey("a", modifierFlags: windowKeys)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.typeKey("a", modifierFlags: windowKeys)
        waitFor("the shortcut toggles the launcher closed") { !field.exists }
    }

    func testKeyboardSnappingHalvesQuartersMaximizeAndCenter() {
        openTerminal()
        let terminal = window("terminal")
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        let floating = terminal.frame
        let area = desktop

        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: windowKeys)
        waitFor("left half") { value(of: terminal).contains("leftHalf") }
        assertFrame(terminal.frame, equals: CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height))

        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: windowKeys)
        waitFor("right half") { value(of: terminal).contains("rightHalf") }
        assertFrame(terminal.frame, equals: CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height))

        app.typeKey("k", modifierFlags: windowKeys)
        waitFor("bottom right quarter") { value(of: terminal).contains("bottomRight") }
        assertFrame(terminal.frame, equals: CGRect(x: area.midX, y: area.midY, width: area.width / 2, height: area.height / 2))

        app.typeKey("u", modifierFlags: windowKeys)
        waitFor("top left quarter") { value(of: terminal).contains("topLeft") }
        assertFrame(terminal.frame, equals: CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height / 2))

        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: windowKeys)
        waitFor("maximized") { value(of: terminal).contains("maximized") }
        assertFrame(terminal.frame, equals: area)

        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: windowKeys)
        waitFor("restored") { !value(of: terminal).contains("maximized") }
        assertFrame(terminal.frame, equals: floating)

        app.typeKey("c", modifierFlags: windowKeys)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(terminal.frame.midX, area.midX, accuracy: 2)
        XCTAssertEqual(terminal.frame.midY, area.midY, accuracy: 2)
    }

    func testDragTitleBarMovesAndSnapsToEdge() {
        openTerminal()
        let terminal = window("terminal")
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        let titleBar = terminal.descendants(matching: .any).matching(identifier: "desktop.window.titlebar").firstMatch
        let before = terminal.frame

        let start = titleBar.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 120, dy: 80)), withVelocity: .slow, thenHoldForDuration: 0.2)
        waitFor("window moved: \(terminal.frame) from \(before)") { abs(terminal.frame.minX - before.minX - 120) < 6 }
        XCTAssertEqual(terminal.frame.minY - before.minY, 80, accuracy: 6)
        XCTAssertEqual(terminal.frame.size, before.size)

        let grab = titleBar.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let leftEdge = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 2, dy: desktop.midY))
        grab.press(forDuration: 0.2, thenDragTo: leftEdge, withVelocity: .slow, thenHoldForDuration: 0.2)
        waitFor("snapped to the left half") { value(of: terminal).contains("leftHalf") }

        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        titleBar.doubleTap()
        waitFor("double-tap maximizes") { value(of: terminal).contains("maximized") }
    }

    func testResizeFromCornerAndLeftEdge() {
        openTerminal()
        let terminal = window("terminal")
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        let before = terminal.frame

        let corner = app.descendants(matching: .any).matching(identifier: "desktop.window.resize.bottomRight").firstMatch
        XCTAssertTrue(corner.exists)
        let grip = corner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.2, thenDragTo: grip.withOffset(CGVector(dx: -100, dy: -60)), withVelocity: .slow, thenHoldForDuration: 0.2)
        waitFor("corner resize: \(terminal.frame) from \(before)") { abs(terminal.frame.width - (before.width - 100)) < 6 }
        XCTAssertEqual(terminal.frame.height, before.height - 60, accuracy: 6)
        XCTAssertEqual(terminal.frame.minX, before.minX, accuracy: 1)

        let mid = terminal.frame
        let handle = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: mid.minX - 3, dy: mid.midY))
        handle.press(forDuration: 0.2, thenDragTo: handle.withOffset(CGVector(dx: 50, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
        waitFor("left edge resize: \(terminal.frame) from \(mid)") { abs(terminal.frame.minX - (mid.minX + 50)) < 6 }
        XCTAssertEqual(terminal.frame.maxX, mid.maxX, accuracy: 2)
    }

    func testWorkspacesWithKeyboard() {
        openTerminal()
        let terminal = window("terminal")
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))

        app.typeKey("2", modifierFlags: [.control, .option, .shift])
        waitFor("moved to workspace 2") { value(of: terminal).contains("workspace 2") }
        if style == "ish" || style == "windows" {
            XCTAssertFalse(app.buttons.matching(identifier: "desktop.taskbar.item").firstMatch.exists,
                           "the taskbar lists only the current workspace")
        }
        XCTAssertTrue(app.buttons["desktop.workspace.1"].isSelected)

        app.typeKey("2", modifierFlags: windowKeys)
        waitFor("switched to workspace 2") { app.buttons["desktop.workspace.2"].isSelected }
        waitFor("window visible again") { terminal.isHittable }

        app.typeKey("]", modifierFlags: windowKeys)
        waitFor("next workspace") { app.buttons["desktop.workspace.3"].isSelected }
        app.typeKey("[", modifierFlags: windowKeys)
        waitFor("previous workspace") { app.buttons["desktop.workspace.2"].isSelected }
    }

    func testWindowSwitcherGoesToPreviousWindow() {
        openFromLauncher("files", search: "Files")
        let files = window("files")
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        openTerminal()
        let terminal = window("terminal")
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        waitFor("terminal focused") { value(of: terminal).contains("focused") }

        app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: .option)
        let switcher = app.descendants(matching: .any).matching(identifier: "desktop.switcher").firstMatch
        // Released Option commits at once when GameController reports it; otherwise the
        // switcher stays up and Return commits.
        if switcher.waitForExistence(timeout: 1) {
            let items = switcher.descendants(matching: .any).matching(identifier: "desktop.switcher.item")
            XCTAssertEqual(items.count, 2)
            let selected = items.matching(NSPredicate(format: "selected == true")).firstMatch
            XCTAssertEqual(selected.label, files.label, "starts on the previously used window")
            selected.tap()
        }
        waitFor("files focused") { value(of: files).contains("focused") }
        XCTAssertFalse(switcher.exists)
    }

    func testOverviewOpensFromKeyboardAndPanelAndFocusesPickedWindow() {
        openFromLauncher("files", search: "Files")
        let files = window("files")
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        openTerminal()
        XCTAssertTrue(window("terminal").waitForExistence(timeout: 5))

        app.typeKey("o", modifierFlags: windowKeys)
        let tiles = app.descendants(matching: .any).matching(identifier: "desktop.overview.window")
        waitFor("overview shows both windows") { tiles.count == 2 }
        app.typeKey("o", modifierFlags: windowKeys)
        waitFor("the shortcut toggles the overview closed") { tiles.count == 0 }

        app.buttons["desktop.panel.overview"].tap()
        waitFor("panel button opens the overview") { tiles.count == 2 }
        tiles.matching(NSPredicate(format: "label == %@", files.label)).firstMatch.tap()
        waitFor("picked window focused") { tiles.count == 0 && value(of: files).contains("focused") }
    }

    func testOverviewDragMovesWindowToAnotherWorkspace() {
        openTerminal()
        let terminal = window("terminal")
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        app.typeKey("o", modifierFlags: windowKeys)
        let tile = app.descendants(matching: .any).matching(identifier: "desktop.overview.window").firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        let target = app.descendants(matching: .any).matching(identifier: "desktop.overview.workspace.3").firstMatch
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)), withVelocity: .slow, thenHoldForDuration: 0.2)
        waitFor("moved by drag") { value(of: terminal).contains("workspace 3") }
    }

    func testWindowMenuFromTitleBarIcon() {
        openTerminal()
        let terminal = window("terminal")
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        terminal.descendants(matching: .any).matching(identifier: "desktop.window.menu").firstMatch.tap()
        let pin = app.buttons["Always on Top"]
        XCTAssertTrue(pin.waitForExistence(timeout: 3))
        pin.tap()
        waitFor("pinned") { value(of: terminal).contains("always on top") }
    }

    func testCloseAndMinimizeMoveFocusToPreviousWindow() {
        openFromLauncher("files", search: "Files")
        let files = window("files")
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        openTerminal()
        let terminal = window("terminal")
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))

        terminal.descendants(matching: .any).matching(identifier: "desktop.window.minimize").firstMatch.tap()
        waitFor("minimized") { value(of: terminal).contains("minimized") }
        waitFor("focus moved to Files") { value(of: files).contains("focused") }

        app.buttons.matching(identifier: "desktop.taskbar.item")
            .matching(NSPredicate(format: "label == %@", "Terminal")).firstMatch.tap()
        waitFor("restored from taskbar") { value(of: terminal).contains("focused") }

        app.typeKey("w", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(terminal.exists, "⌘W belongs to the app (a tab in VS Code), not the desktop")
        app.typeKey("w", modifierFlags: windowKeys)
        waitFor("closed") { !terminal.exists }
        waitFor("focus back on Files") { value(of: files).contains("focused") }
    }

    /// With desktop shortcuts moved to ⌘, the terminal (like Linux apps) still keeps ⌘W.
    func testCommandShortcutsYieldToTerminal() {
        app.terminate()
        app.launchArguments += ["-desktop.keyboard.modifier", "command"]
        app.launch()
        XCTAssertTrue(app.buttons["desktop.panel.applications"].waitForExistence(timeout: 10))
        waitFor("boot splash gone", timeout: 15) { !app.descendants(matching: .any)["desktop.bootSplash"].exists }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.7)).tap()
        openFromLauncher("files", search: "Files")
        let files = window("files")
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        openTerminal()
        let terminal = window("terminal")
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        waitFor("terminal focused") { value(of: terminal).contains("focused") }

        app.typeKey("w", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(terminal.exists, "the terminal keeps ⌘W")
        XCTAssertTrue(files.exists, "and nothing else closes")

        files.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
        waitFor("files focused") { value(of: files).contains("focused") }
        app.typeKey("w", modifierFlags: .command)
        waitFor("⌘W closes a native window") { !files.exists }
    }

    func testAutoTilingToggleFromKeyboardAndPanel() {
        openFromLauncher("files", search: "Files")
        let files = window("files")
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        openTerminal()
        let terminal = window("terminal")
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        let floatingFiles = files.frame
        let area = desktop

        app.typeKey("t", modifierFlags: [.control, .option, .shift])
        waitFor("tiled side by side: \(files.frame) \(terminal.frame)") {
            files.frame.intersection(terminal.frame).width < 1
                && abs(files.frame.minY - (area.minY + 10)) < 2 && abs(terminal.frame.minY - (area.minY + 10)) < 2
                && abs(max(files.frame.maxX, terminal.frame.maxX) - (area.maxX - 10)) < 2
        }
        XCTAssertEqual(files.frame.maxY, area.maxY, accuracy: 10, "tiles fill the height, less the gap")

        app.typeKey("t", modifierFlags: [.control, .option, .shift])
        assertFrame(files.frame, equals: floatingFiles)

        let tiling = app.descendants(matching: .any)["desktop.panel.tiling"].firstMatch
        XCTAssertTrue(tiling.exists)
        tiling.tap()
        let toggle = app.buttons["Auto-Tile Workspace 1"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.tap()
        waitFor("the panel menu turns tiling on") { (tiling.value as? String ?? "").hasPrefix("On") }
        waitFor("tiled again") { files.frame.intersection(terminal.frame).width < 1 && files.frame != floatingFiles }
    }

    func testNotificationCenterKeepsHistoryAndDoNotDisturb() {
        app.terminate()
        app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "no-such-app", "-desktop.style", style,
                               "-desktop.tiling", "", "-desktop.onboarded", "YES", "-desktop.doNotDisturb", "NO"]
        app.launch()
        let bell = app.buttons["desktop.panel.notifications"]
        XCTAssertTrue(bell.waitForExistence(timeout: 10))
        waitFor("unread badge") { (bell.value as? String ?? "").contains("unread") }
        bell.tap()
        let center = app.descendants(matching: .any)["desktop.notificationCenter"]
        XCTAssertTrue(center.waitForExistence(timeout: 3))
        XCTAssertTrue(center.descendants(matching: .any)["desktop.notification"].firstMatch.exists, "history kept")
        let doNotDisturb = center.descendants(matching: .any)["notifications.doNotDisturb"].firstMatch
        let before = doNotDisturb.value as? String
        doNotDisturb.tap()
        waitFor("do not disturb toggled") { (doNotDisturb.value as? String) != before }
        bell.tap()
        waitFor("center closed") { !center.exists }
    }

    func testQuickSettingsTogglesAutoTiling() {
        app.buttons["desktop.panel.quickSettings"].tap()
        let panel = app.descendants(matching: .any)["desktop.quickSettings"]
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        let tiling = panel.buttons["Auto-Tiling"]
        XCTAssertFalse(tiling.isSelected)
        tiling.tap()
        waitFor("tiling on") { tiling.isSelected }
        let tilingButton = app.descendants(matching: .any)["desktop.panel.tiling"].firstMatch
        XCTAssertTrue((tilingButton.value as? String ?? "").hasPrefix("On"))
        tiling.tap()
        waitFor("tiling off") { !tiling.isSelected }
    }

    func testLockScreenFromPowerMenu() {
        app.buttons["desktop.panel.quickSettings"].tap()
        let power = app.descendants(matching: .any)["quickSettings.power"].firstMatch
        XCTAssertTrue(power.waitForExistence(timeout: 3))
        power.tap()
        let lock = app.buttons["Lock Screen"].firstMatch
        XCTAssertTrue(lock.waitForExistence(timeout: 3))
        lock.tap()
        let screen = app.descendants(matching: .any)["desktop.lockScreen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 3))
        screen.tap()
        waitFor("unlocked") { !screen.exists }
    }

    func testFirstRunOnboardingChoosesStyle() {
        app.terminate()
        // No -desktop.style here: the argument domain would override the style onboarding saves.
        app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "",
                               "-desktop.tiling", "", "-desktop.onboarded", "NO", "-desktop.onboarding.progress", ""]
        app.launch()
        let onboarding = app.descendants(matching: .any)["desktop.onboarding"]
        XCTAssertTrue(onboarding.waitForExistence(timeout: 15))
        let kylin = app.buttons["onboarding.style.kylin"]
        for _ in 0..<7 where !kylin.exists { app.buttons["onboarding.next"].tap() }
        kylin.tap()
        app.buttons["onboarding.skip"].tap()
        waitFor("onboarding closed") { !onboarding.exists }
        XCTAssertTrue(app.descendants(matching: .any)["desktop.panel.search"].firstMatch.waitForExistence(timeout: 5),
                      "the Kylin panel is up")
    }

    private var desktopWallpaper: XCUIElement {
        app.descendants(matching: .any)["desktop.wallpaper"].firstMatch
    }

    func testSetBuiltInWallpaperFromSettings() {
        openFromLauncher("settings", search: "Sett")
        let aurora = app.buttons["wallpaper.gradient.aurora"]
        XCTAssertTrue(aurora.waitForExistence(timeout: 5))
        aurora.tap()
        waitFor("gradient applied") { (desktopWallpaper.value as? String) == "gradient:aurora" }
        let dunes = app.buttons["wallpaper.item.builtin-dunes"]
        if !dunes.isHittable { window("settings").swipeUp() }
        XCTAssertTrue(dunes.waitForExistence(timeout: 5))
        dunes.tap()
        waitFor("built-in image applied") { (desktopWallpaper.value as? String) == "image:builtin-dunes" }
    }

    func testIconPackIsChosenIndependentlyOfStyle() {
        openFromLauncher("settings", search: "Sett")
        let papirus = app.buttons["iconPack.Papirus"]
        XCTAssertTrue(papirus.waitForExistence(timeout: 10), "installed packs are listed")
        XCTAssertTrue(app.buttons["iconPack.match"].isSelected, "Match Style is the default")
        papirus.tap()
        waitFor("Papirus applied", timeout: 10) { papirus.isSelected && !app.buttons["iconPack.match"].isSelected }

        let more = app.buttons["iconPacks.getMore"]
        if !more.isHittable { window("settings").swipeUp() }
        more.tap()
        let packages = window("packages")
        XCTAssertTrue(packages.waitForExistence(timeout: 5))
        let search = packages.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "icon-theme", "Packages opens filtered to icon themes")
    }

    /// "All Workspaces" is the default and replaces a workspace's own wallpaper; the toast
    /// undoes it.
    func testAllWorkspacesWallpaperClearsPerWorkspaceOneAndUndoes() {
        app.typeKey("2", modifierFlags: windowKeys)
        openFromLauncher("settings", search: "Sett")
        let target = app.descendants(matching: .any)["wallpaper.target"].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        app.buttons["This Workspace Only"].firstMatch.tap()
        app.buttons["wallpaper.gradient.aurora"].tap()
        waitFor("workspace 2's own wallpaper") { (desktopWallpaper.value as? String) == "gradient:aurora" }

        target.tap()
        app.buttons["All Workspaces"].firstMatch.tap()
        app.buttons["wallpaper.gradient.dusk"].tap()
        waitFor("all workspaces, workspace 2 included") { (desktopWallpaper.value as? String) == "gradient:dusk" }

        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        waitFor("undone: workspace 2 has its own wallpaper again") { (desktopWallpaper.value as? String) == "gradient:aurora" }
    }

    func testWallhavenMockedResponseSetsWallpaper() {
        openFromLauncher("wallpapers", search: "Wallp")
        let thumb = app.buttons["wallhaven.thumb.stub01"]
        XCTAssertTrue(thumb.waitForExistence(timeout: 10), "the mocked grid loads")
        XCTAssertTrue(app.buttons["wallhaven.thumb.stub06"].exists)
        thumb.tap()
        let set = app.descendants(matching: .any)["wallhaven.setWallpaper"].firstMatch
        XCTAssertTrue(set.waitForExistence(timeout: 5))
        set.tap()
        let both = app.buttons["All Workspaces"].firstMatch
        XCTAssertTrue(both.waitForExistence(timeout: 3))
        both.tap()
        waitFor("downloaded and applied", timeout: 10) {
            (desktopWallpaper.value as? String) == "image:wallhaven-stub01"
        }
    }

    // MARK: Desktop icons

    private func desktopIcon(_ name: String) -> XCUIElement {
        app.descendants(matching: .any)["desktop.icon.\(name)"].firstMatch
    }

    /// Presses briefly (no hold) and moves, the way a finger flicks an icon across.
    private func flick(_ element: XCUIElement, by offset: CGVector) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(offset), withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// Regression test for "I can't drag icons from the desktop": a press-and-move with no
    /// hold must move the icon, onto the grid.
    func testDraggingDesktopIconMovesIt() {
        let icon = desktopIcon("Terminal")
        XCTAssertTrue(icon.waitForExistence(timeout: 5))
        let before = icon.frame
        flick(icon, by: CGVector(dx: 300, dy: 220))
        waitFor("icon moved: \(icon.frame) from \(before)", timeout: 5) {
            icon.frame.minX > before.minX + 150 && icon.frame.minY > before.minY + 100
        }
        let dx = icon.frame.minX - before.minX, dy = icon.frame.minY - before.minY
        XCTAssertEqual(dx.truncatingRemainder(dividingBy: 96), 0, accuracy: 1, "snapped to a column (moved \(dx))")
        XCTAssertEqual(dy.truncatingRemainder(dividingBy: 100), 0, accuracy: 1, "snapped to a row (moved \(dy))")
    }

    func testDesktopIconPositionPersistsAcrossRelaunch() {
        let icon = desktopIcon("Terminal")
        XCTAssertTrue(icon.waitForExistence(timeout: 5))
        let before = icon.frame
        flick(icon, by: CGVector(dx: 400, dy: 120))
        waitFor("icon moved") { icon.frame.minX > before.minX + 200 }
        let moved = icon.frame
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.terminate()

        app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "", "-desktop.style", style,
                               "-desktop.tiling", "", "-desktop.onboarded", "YES", "-wallhaven.mock", "YES",
                               "-desktop.wallpaper", ""]
        app.launch()
        let restored = desktopIcon("Terminal")
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        waitFor("icon back where it was dropped: \(restored.frame) vs \(moved)", timeout: 10) {
            abs(restored.frame.minX - moved.minX) < 1 && abs(restored.frame.minY - moved.minY) < 1
        }
    }

    func testRubberBandSelectsTwoIconsThatMoveTogether() {
        let terminal = desktopIcon("Terminal"), files = desktopIcon("Files")
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        XCTAssertTrue(files.exists)
        let surface = app.descendants(matching: .any)["desktop.surface"].firstMatch
        let band = terminal.frame.union(files.frame)
        // From the empty margin beyond the two icons back across both of them.
        let origin = surface.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: band.maxX - surface.frame.minX + 70, dy: band.maxY - surface.frame.minY + 20))
        let to = origin.withOffset(CGVector(dx: band.minX - surface.frame.minX - 6, dy: band.minY - surface.frame.minY - 6))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
        waitFor("both selected") { terminal.isSelected && files.isSelected }
        XCTAssertFalse(desktopIcon("Trash").isSelected, "only the icons inside the rectangle")

        let terminalBefore = terminal.frame, filesBefore = files.frame
        flick(terminal, by: CGVector(dx: 96 * 4, dy: 0))
        waitFor("both moved: \(terminal.frame) \(files.frame)") {
            terminal.frame.minX > terminalBefore.minX + 200 && files.frame.minX > filesBefore.minX + 200
        }
        XCTAssertEqual(terminal.frame.minX - terminalBefore.minX, files.frame.minX - filesBefore.minX, accuracy: 1,
                       "the group keeps its shape")
    }

    func testSnapToGridCanBeTurnedOff() {
        let icon = desktopIcon("Terminal")
        XCTAssertTrue(icon.waitForExistence(timeout: 5))
        let surface = app.descendants(matching: .any)["desktop.surface"].firstMatch
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.6)).press(forDuration: 1.2)
        let arrange = app.buttons["Arrange Icons"].firstMatch
        XCTAssertTrue(arrange.waitForExistence(timeout: 5))
        arrange.tap()
        let snap = app.buttons["Snap to Grid"].firstMatch
        XCTAssertTrue(snap.waitForExistence(timeout: 5))
        snap.tap()
        waitFor("menu closed") { !snap.exists }

        let before = icon.frame
        flick(icon, by: CGVector(dx: 237, dy: 143))
        waitFor("icon moved freely: \(icon.frame) from \(before)") { icon.frame.minX > before.minX + 150 }
        XCTAssertEqual(icon.frame.minX - before.minX, 237, accuracy: 12, "kept where it was dropped, not snapped")
        XCTAssertEqual(icon.frame.minY - before.minY, 143, accuracy: 12)
    }

    func testDraggingDesktopIconAfterHoldMovesIt() {
        let icon = app.descendants(matching: .any)["desktop.icon.Terminal"].firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 5))
        let before = icon.frame
        let start = icon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 1.0, thenDragTo: start.withOffset(CGVector(dx: 300, dy: 220)),
                    withVelocity: .slow, thenHoldForDuration: 0.5)
        waitFor("icon moved after a hold: \(icon.frame) from \(before)", timeout: 5) {
            icon.frame.minX > before.minX + 150 && icon.frame.minY > before.minY + 100
        }
    }

    func testSessionIsRestoredOnRelaunch() {
        openFromLauncher("files", search: "Files")
        let files = window("files")
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: windowKeys)
        waitFor("snapped") { value(of: files).contains("rightHalf") }
        app.typeKey("3", modifierFlags: [.control, .option, .shift])
        waitFor("moved") { value(of: files).contains("workspace 3") }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        app.terminate()

        app.launchArguments = ["-desktop.autostart", "", "-desktop.style", style, "-desktop.tiling", "",
                               "-desktop.onboarded", "YES", "-wallhaven.mock", "YES",
                               "-desktop.wallpaper", ""]
        app.launch()
        let restored = window("files")
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertTrue(value(of: restored).contains("rightHalf"))
        XCTAssertTrue(value(of: restored).contains("workspace 3"))
    }
}

final class WindowsStyleUITests: DesktopUITests {
    override var style: String { "windows" }
}

final class MacStyleUITests: DesktopUITests {
    override var style: String { "macos" }
}

final class UbuntuStyleUITests: DesktopUITests {
    override var style: String { "ubuntu" }
}

final class KylinStyleUITests: DesktopUITests {
    override var style: String { "kylin" }
}
