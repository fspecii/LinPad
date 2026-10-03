import XCTest

/// Match to Wallpaper, in landscape: for each wallpaper, the prompt with its before/after
/// preview, then the desktop after Apply; plus the Themes › Wallpaper section and Customize.
///   TEST_RUNNER_DESKTOP_SCREENSHOT_DIR=…  TEST_RUNNER_DESKTOP_WALLPAPERS="dunes,aurora-night,meadow"
@MainActor
final class WallpaperMatchScreenshots: XCTestCase {
    func testCaptureWallpaperMatches() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = try XCTUnwrap(environment["DESKTOP_SCREENSHOT_DIR"], "DESKTOP_SCREENSHOT_DIR not set")
        let names = environment["DESKTOP_WALLPAPERS"]?.split(separator: ",").map(String.init)
            ?? ["dunes", "aurora-night", "meadow", "berry"]
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "themes", "-desktop.style", "ish",
                               "-desktop.onboarded", "YES", "-desktop.colorTheme", "", "-desktop.wallpaperMatch.auto", "NO"]
        app.launch()
        let section = app.buttons["themes.section.wallpaper"].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 20))
        section.tap()
        sleep(2)
        save(directory, "00-themes-wallpaper-section")

        for (index, name) in names.enumerated() {
            let tile = app.buttons["wallpaper.item.builtin-\(name)"].firstMatch
            var scrolls = 0
            while !(tile.exists && tile.isHittable), scrolls < 8 {
                app.swipeUp(velocity: .slow)
                scrolls += 1
            }
            XCTAssertTrue(tile.isHittable, "no tile for \(name)")
            tile.tap()
            let prompt = app.otherElements["wallmatch.prompt"].firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: 10), "no prompt for \(name)")
            sleep(2)
            save(directory, String(format: "%02d-%@-1-before-prompt", index + 1, name))
            app.buttons["wallmatch.apply"].firstMatch.tap()
            sleep(3)
            save(directory, String(format: "%02d-%@-2-after", index + 1, name))
        }

        // The section's own panel for the current wallpaper, then Customize from a prompt.
        for _ in 0..<8 { app.swipeDown(velocity: .fast) }
        sleep(2)
        save(directory, "90-themes-match-panel")
        let tile = app.buttons["wallpaper.item.builtin-\(names[0])"].firstMatch
        for _ in 0..<8 where !(tile.exists && tile.isHittable) { app.swipeUp(velocity: .slow) }
        if tile.isHittable {
            tile.tap()
            let customize = app.buttons["wallmatch.customize"].firstMatch
            if customize.waitForExistence(timeout: 10) {
                customize.tap()
                sleep(2)
                save(directory, "91-customize-editor")
            }
        }
    }

    private func save(_ directory: String, _ name: String) {
        let shot = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: shot.size, format: format).image { _ in
            shot.draw(in: CGRect(origin: .zero, size: shot.size))
        }
        try? upright.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
