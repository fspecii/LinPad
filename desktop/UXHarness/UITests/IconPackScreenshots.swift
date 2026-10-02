import XCTest

/// The desktop drawn from different icon packs' caches, in landscape. The harness has no
/// guest, so each pack's cache is rendered beforehand by the guest's ish-apply-style and
/// passed as `-desktop.iconCacheRoot` (a directory laid out like the guest's "/").
///   TEST_RUNNER_DESKTOP_SCREENSHOT_DIR=…  TEST_RUNNER_DESKTOP_ICON_ROOTS="Papirus=/path,Qogir=/path"
///   TEST_RUNNER_DESKTOP_STYLES="ish,windows" (default ish)
@MainActor
final class IconPackScreenshots: XCTestCase {
    func testCaptureIconPacks() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["DESKTOP_SCREENSHOT_DIR"]
        let roots = environment["DESKTOP_ICON_ROOTS"]
        try XCTSkipIf(directory == nil || roots == nil, "DESKTOP_SCREENSHOT_DIR or DESKTOP_ICON_ROOTS not set")
        let styles = environment["DESKTOP_STYLES"]?.split(separator: ",").map(String.init) ?? ["ish"]
        XCUIDevice.shared.orientation = .landscapeLeft
        for pair in roots!.split(separator: ",") {
            let fields = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let (pack, root) = fields.count == 2 ? (fields[0], fields[1]) : ("none", "")
            for style in styles {
                let app = XCUIApplication()
                app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", "files,terminal",
                                       "-desktop.style", style, "-desktop.onboarded", "YES",
                                       "-desktop.iconCacheRoot", root]
                app.launch()
                XCTAssertTrue(app.buttons["desktop.panel.applications"].waitForExistence(timeout: 15))
                sleep(2)
                save(to: directory!, name: "\(pack)-\(style)-desktop")
                let iconView = app.buttons["Icon View"].firstMatch
                if iconView.exists {
                    iconView.tap()
                    sleep(1)
                    save(to: directory!, name: "\(pack)-\(style)-files-grid")
                }
                app.terminate()
            }
        }
    }

    private func save(to directory: String, name: String) {
        let shot = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: shot.size, format: format).image { _ in
            shot.draw(in: CGRect(origin: .zero, size: shot.size))
        }
        try? upright.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
