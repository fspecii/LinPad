import XCTest

/// LinPad Store on the harness's mock guest (StoreMockGuest): browse, search, the detail
/// page, an install with progress and cancel, Installed and Updates, in several desktop
/// styles. Screenshots go to DESKTOP_SCREENSHOT_DIR when it is set.
///   TEST_RUNNER_DESKTOP_SCREENSHOT_DIR=…  TEST_RUNNER_DESKTOP_STYLES="ish,macos,windows,aero"
@MainActor
final class StoreUITests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var directory: String? { environment["DESKTOP_SCREENSHOT_DIR"] }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func launch(style: String, installSeconds: Int = 8) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "store", "-desktop.style", style,
                               "-desktop.onboarded", "YES", "-store.mockInstallSeconds", "\(installSeconds)"]
        app.launch()
        XCTAssertTrue(app.textFields["Search apps"].firstMatch.waitForExistence(timeout: 20), "the Store opens")
        return app
    }

    /// New windows open at half the screen in landscape; the Store's compact layout is
    /// captured there, then the window is maximized for the sidebar layout.
    private func maximize(_ app: XCUIApplication, compactShot: String? = nil) {
        sleep(2)
        if let compactShot { save(compactShot) }
        let titleBar = app.descendants(matching: .any)["desktop.window.titlebar"].firstMatch
        XCTAssertTrue(titleBar.waitForExistence(timeout: 5))
        titleBar.doubleTap()
        let sidebar = app.buttons["store.tab.home"].waitForExistence(timeout: 5)
        if !sidebar, let directory {
            save("debug-after-maximize")
            try? app.debugDescription.write(toFile: directory + "/debug-tree.txt", atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(sidebar, "the sidebar appears when the window is wide")
    }

    func testBrowseSearchInstallAndOpen() throws {
        let app = launch(style: "ish")
        maximize(app, compactShot: "ish-00-half-width")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["store.hero.apk:filezilla"].waitForExistence(timeout: 5))
        XCTAssertTrue(any["store.card.apk:geany"].exists)
        sleep(2)
        save("ish-01-home")

        app.buttons["store.tab.categories"].tap()
        XCTAssertTrue(any["store.categories"].waitForExistence(timeout: 5))
        save("ish-02-categories")
        any["store.category.Graphics"].firstMatch.tap()
        XCTAssertTrue(any["store.grid"].waitForExistence(timeout: 5))
        sleep(1)
        save("ish-03-category-graphics")

        let search = app.textFields["Search apps"].firstMatch
        search.tap()
        search.typeText("filezila")
        XCTAssertTrue(any["store.row.apk:filezilla"].waitForExistence(timeout: 5), "typo-tolerant search finds FileZilla")
        sleep(1)
        save("ish-04-search")
        any["store.row.apk:filezilla"].buttons.firstMatch.tap()
        XCTAssertTrue(any["store.detail.apk:filezilla"].waitForExistence(timeout: 5))
        XCTAssertTrue(any["store.detail.compat"].exists)
        sleep(2)
        save("ish-05-detail-filezilla")

        app.buttons["store.detail.install"].tap()
        XCTAssertTrue(any["store.progress.apk:filezilla"].waitForExistence(timeout: 5), "progress replaces the button")
        sleep(3)
        save("ish-06-installing")
        XCTAssertTrue(app.buttons["store.open.apk:filezilla"].waitForExistence(timeout: 30), "Open appears once installed")
        save("ish-07-installed")

        app.buttons["store.tab.installed"].tap()
        XCTAssertTrue(any["store.row.apk:filezilla"].waitForExistence(timeout: 5))
        save("ish-08-installed-tab")
        app.buttons["store.tab.updates"].tap()
        XCTAssertTrue(any["store.updates"].waitForExistence(timeout: 5))
        sleep(2)
        save("ish-09-updates")
        app.terminate()
    }

    func testQueueCancelAndSizeWarning() throws {
        let app = launch(style: "ish", installSeconds: 20)
        maximize(app)
        let any = app.descendants(matching: .any)
        // Two installs queue behind each other; the second can be cancelled while it waits.
        let search = app.textFields["Search apps"].firstMatch
        search.tap()
        search.typeText("inkscape")
        XCTAssertTrue(app.buttons["store.install.apk:inkscape"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["store.install.apk:inkscape"].firstMatch.tap()
        app.buttons["Clear"].firstMatch.tap()
        search.tap()
        search.typeText("krita")
        XCTAssertTrue(app.buttons["store.install.apk:krita"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["store.install.apk:krita"].firstMatch.tap()
        XCTAssertTrue(any["store.queue.waiting"].waitForExistence(timeout: 5))
        sleep(1)
        save("ish-10-queue")
        app.buttons["store.queue.cancel"].tap()
        sleep(2)
        save("ish-11-cancelled")

        app.buttons["Clear"].firstMatch.tap()
        search.tap()
        search.typeText("libreoffice")
        XCTAssertTrue(any["store.row.office"].waitForExistence(timeout: 5))
        any["store.row.office"].buttons.firstMatch.tap()
        XCTAssertTrue(any["store.detail.sizeWarning"].waitForExistence(timeout: 5), "LibreOffice warns about its size")
        sleep(2)
        save("ish-12-detail-libreoffice")
        app.terminate()
    }

    func testStylesAndThemes() throws {
        let styles = environment["DESKTOP_STYLES"]?.split(separator: ",").map(String.init) ?? ["macos", "windows", "aero", "ubuntu"]
        for style in styles {
            let app = launch(style: style)
            maximize(app, compactShot: "style-\(style)-half")
            sleep(1)
            save("style-\(style)-home")
            let card = app.descendants(matching: .any)["store.card.apk:audacity"].firstMatch
            if card.waitForExistence(timeout: 5) {
                card.tap()
                sleep(2)
                save("style-\(style)-detail-audacity")
            }
            app.terminate()
        }
    }

    private func save(_ name: String) {
        guard let directory else { return }
        let shot = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: shot.size, format: format).image { _ in
            shot.draw(in: CGRect(origin: .zero, size: shot.size))
        }
        try? upright.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
