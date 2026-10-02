import XCTest

/// The release walkthrough on the installed app, in landscape. test1 expects a fresh install
/// (cold first launch: unpacking progress, onboarding); test2 tours the desktop. Screenshots
/// go to RELEASE_SHOT_DIR; step timestamps to RELEASE_SHOT_DIR/steps.txt, so host-side
/// memory samples can be matched to what was open.
@MainActor
final class ReleaseUITests: XCTestCase {
    private var app: XCUIApplication!
    /// DebugAutomation's inbox is per simulator: /tmp/ish-automation/<SIMULATOR_UDID>.
    private static let automation = URL(fileURLWithPath: "/tmp/ish-automation")
        .appendingPathComponent(ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "")
    private var shotDir: String { ProcessInfo.processInfo.environment["RELEASE_SHOT_DIR"] ?? "/tmp/release-shots" }

    override func setUp() async throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .landscapeRight
    }

    // MARK: - Helpers

    private func launch(_ extra: [String] = [], reset: Bool = true, environment: [String: String] = [:]) {
        app = XCUIApplication(bundleIdentifier: "com.valentinneagu.ish.arm64")
        app.launchEnvironment = environment
        var arguments = ["-desktop.debugAutomation", "YES"]
        if reset { arguments += ["-desktop.resetSession", "YES"] }
        app.launchArguments = arguments + extra
        app.launch()
    }

    private func save(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: shotDir).appendingPathComponent("\(name).png"))
        step("screenshot \(name)")
    }

    private func step(_ text: String) {
        let url = URL(fileURLWithPath: shotDir).appendingPathComponent("steps.txt")
        let line = Data("\(Date().timeIntervalSince1970) \(text)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func automate(_ command: String, wait: TimeInterval = 2) -> String {
        let log = Self.automation.appendingPathComponent("log")
        let before = (try? String(contentsOf: log, encoding: .utf8))?.count ?? 0
        let inbox = Self.automation.appendingPathComponent("in")
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString).cmd")
        try? command.write(to: file.appendingPathExtension("tmp"), atomically: true, encoding: .utf8)
        try? FileManager.default.moveItem(at: file.appendingPathExtension("tmp"), to: file)
        pause(wait)
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let output = String(text.dropFirst(min(before, text.count)))
        step("automate \(command) -> \(output.prefix(400).replacingOccurrences(of: "\n", with: " ¶ "))")
        return output
    }

    /// Polls the automation `state` until a window title contains `needle`.
    @discardableResult
    private func waitForWindow(_ needle: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if automate("state", wait: 2).localizedCaseInsensitiveContains(needle) { return true }
            pause(2)
        }
        return false
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func dismissWelcome() {
        let welcome = app.buttons["Start Using the Desktop"]
        if welcome.waitForExistence(timeout: 3) { welcome.tap(); pause(1) }
    }

    private func key(_ key: String, _ flags: XCUIElement.KeyModifierFlags) {
        app.typeKey(key, modifierFlags: flags)
    }

    private func powerMenu(_ item: String) -> Bool {
        element("desktop.panel.power").tap()
        let button = app.buttons[item].firstMatch
        guard button.waitForExistence(timeout: 5) else { return false }
        button.tap()
        return true
    }

    // MARK: - Tests

    /// Fresh install: the boot splash shows unpacking progress, then onboarding, then the desktop.
    func test1ColdFirstLaunch() {
        let start = Date()
        launch([], reset: true)
        step("cold launch")
        var shots = 0
        let splash = element("desktop.bootSplash")
        while splash.exists || Date().timeIntervalSince(start) < 2 {
            if shots < 6 { save("01-boot-splash-\(shots)"); shots += 1 }
            pause(0.7)
            if Date().timeIntervalSince(start) > 240 { break }
        }
        let toDesktop = Date().timeIntervalSince(start)
        step(String(format: "time to desktop (splash gone): %.1f s", toDesktop))
        let welcome = app.buttons["Start Using the Desktop"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 30), "onboarding appears on first launch")
        save("02-onboarding")
        welcome.tap()
        pause(3)
        save("03-desktop-first")
    }

    func test2DesktopTour() {
        launch(["-desktop.onboarded", "YES", "-desktop.style", "ish", "-desktop.tiling", ""])
        XCTAssertTrue(element("desktop.surface").waitForExistence(timeout: 120))
        dismissWelcome()
        pause(8)
        save("10-desktop-ish")

        // foot + fastfetch
        automate("open|linux:ish-terminal sh -c 'fastfetch; exec sh -l'", wait: 2)
        XCTAssertTrue(waitForWindow("foot", timeout: 60) || waitForWindow("sh", timeout: 5), "foot window")
        pause(8)
        save("11-foot-fastfetch")

        // Thunar
        automate("open|linux:thunar /root", wait: 2)
        XCTAssertTrue(waitForWindow("Thunar", timeout: 60) || waitForWindow("root", timeout: 5), "Thunar window")
        pause(4)
        save("12-thunar")

        // Firefox on example.com
        automate("open|linux:firefox-esr https://example.com", wait: 2)
        let firefox = waitForWindow("Example Domain", timeout: 180)
        XCTAssertTrue(firefox, "Firefox shows example.com")
        pause(5)
        save("13-firefox-example")
        step("MEASURE firefox+thunar+foot open")
        pause(20)

        // Keyboard shortcuts need the hardware keyboard path. In a headless simulator a
        // focused Linux surface brings up the on-screen keyboard, which eats the chords, so
        // each step falls back to the panel control and records which path worked.
        let hideKeyboard = app.keyboards.buttons["Hide keyboard"].firstMatch
        if hideKeyboard.exists { hideKeyboard.tap(); pause(1) }
        let framesBefore = automate("state", wait: 2)
        key("t", [.control, .option])
        pause(4)
        if automate("state", wait: 2) == framesBefore {
            step("ctrl-opt-T did not reach the desktop; using the panel tiling menu")
            element("desktop.panel.tiling").tap()
            let toggle = app.buttons["Auto-Tile Workspace 1"].firstMatch
            if toggle.waitForExistence(timeout: 5) { toggle.tap() } else { XCTFail("no tiling menu") }
            pause(4)
        } else {
            step("ctrl-opt-T tiled the workspace")
        }
        save("14-tiling-3-windows")

        key("o", [.control, .option])
        pause(2)
        if element("desktop.overview").exists {
            step("ctrl-opt-O opened the overview")
        } else {
            step("ctrl-opt-O did not reach the desktop; using the panel overview button")
            element("desktop.panel.overview").tap()
            pause(2)
        }
        XCTAssertTrue(element("desktop.overview").exists, "overview opens")
        save("15-overview")
        element("desktop.overview").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
        pause(2)
        key(XCUIKeyboardKey.tab.rawValue, [.option])
        pause(0.3)
        step("switcher after opt-Tab: \(element("desktop.switcher").exists)")
        save("16-switcher")
        pause(2)

        // VLC with the bundled test clip (audio through ishaudio)
        automate("open|linux:ish-vlc /root/Videos/ish-test-720p.mp4", wait: 2)
        let vlc = waitForWindow("VLC", timeout: 90)
        if !vlc { automate("sh|grep -v frame /tmp/ishwl.log | tail -30", wait: 3) }
        XCTAssertTrue(vlc, "VLC window")
        pause(3)
        save("17-vlc")
        step("MEASURE vlc playing")
        pause(10)

        // Files: drag a file onto the Desktop place
        automate("sh|echo release > /root/release-dnd.txt; rm -f /root/Desktop/release-dnd.txt", wait: 3)
        automate("open|files|path=/root", wait: 4)
        let entry = element("files.entry.release-dnd.txt")
        let desktopPlace = element("files.place.Desktop")
        if entry.waitForExistence(timeout: 20) && desktopPlace.exists {
            entry.press(forDuration: 1.5, thenDragTo: desktopPlace, withVelocity: .slow, thenHoldForDuration: 1.0)
            pause(4)
            let moved = automate("sh|ls /root/Desktop/release-dnd.txt", wait: 3)
            XCTAssertTrue(moved.contains("/root/Desktop/release-dnd.txt"), "file dragged to Desktop")
        } else {
            XCTFail("Files entry or Desktop place missing")
        }
        save("18-files-dnd")

        // Lock and unlock
        if powerMenu("Lock Screen") {
            XCTAssertTrue(element("desktop.lockScreen").waitForExistence(timeout: 5), "lock screen")
            save("19-locked")
            element("desktop.lockScreen").tap()
            pause(2)
            XCTAssertFalse(element("desktop.lockScreen").exists, "unlocked")
        } else {
            XCTFail("no Lock Screen item")
        }

        // Restart the Linux session, then a Linux app again
        XCTAssertTrue(powerMenu("Restart Desktop Session"), "restart item")
        pause(12)
        save("20-session-restarted")
        automate("sh|cat /tmp/ishwl-session.pid; tr '\\0' ' ' < /proc/$(cat /tmp/ishwl-session.pid)/cmdline", wait: 3)
        automate("open|linux:thunar /root", wait: 2)
        XCTAssertTrue(waitForWindow("Thunar", timeout: 60) || waitForWindow("root", timeout: 5), "Thunar after restart")
        pause(3)
        save("21-thunar-after-restart")
    }

    /// Both CPU engines boot the desktop; quick settings shows which one runs, and the
    /// compatibility engine offers the fast-mode help.
    func test4CPUEngines() {
        for (mode, label) in [("1", "Native JIT"), ("0", "Compatibility mode")] {
            launch(["-desktop.onboarded", "YES", "-desktop.style", "ish", "-desktop.tiling", ""],
                   environment: ["ISH_JIT": mode])
            XCTAssertTrue(element("desktop.surface").waitForExistence(timeout: 120))
            dismissWelcome()
            pause(6)
            let loop = automate("sh|time sh -c 'i=0; while [ $i -lt 200000 ]; do i=$((i+1)); done'", wait: 25)
            step("ISH_JIT=\(mode) shell loop: \(loop)")
            element("desktop.panel.quickSettings").tap()
            let row = element("quickSettings.performanceMode")
            XCTAssertTrue(row.waitForExistence(timeout: 5), "performance row")
            XCTAssertTrue(row.label.contains(label), "engine label \(row.label)")
            save("41-quick-settings-jit\(mode)")
            if mode == "0" {
                let help = element("quickSettings.fastModeHelp")
                XCTAssertTrue(help.exists, "fast mode help button")
                help.tap()
                XCTAssertTrue(app.navigationBars["Enable fast mode"].waitForExistence(timeout: 5), "help sheet")
                save("42-fast-mode-help")
                app.buttons["Done"].firstMatch.tap()
            }
            app.terminate()
        }
    }

    /// Installed over an older root: the desktop offers the update, the next launch installs
    /// it with progress, and /root, /home survive (markers written beforehand by the runner).
    func test0SystemUpdate() {
        launch(["-desktop.onboarded", "YES"])
        let update = app.buttons["Update Linux system"].firstMatch
        XCTAssertTrue(update.waitForExistence(timeout: 90), "update offered")
        save("50-update-offered")
        update.tap()
        pause(2)
        app.terminate()
        let start = Date()
        launch(["-desktop.onboarded", "YES"])
        var shots = 0
        while element("desktop.bootSplash").exists || Date().timeIntervalSince(start) < 2 {
            if shots < 4 { save("51-updating-\(shots)"); shots += 1 }
            pause(1.5)
            if Date().timeIntervalSince(start) > 240 { break }
        }
        step(String(format: "update to desktop: %.1f s", Date().timeIntervalSince(start)))
        XCTAssertTrue(element("desktop.surface").waitForExistence(timeout: 60))
        pause(5)
        let check = automate("sh|cat /usr/share/ish/rootfs-version /root/update-marker.txt /home/alice/notes.txt /etc/ish/reinstall-packages", wait: 4)
        XCTAssertTrue(check.contains("kept-across-update"), "/root kept")
        XCTAssertTrue(check.contains("hi"), "/home kept")
        XCTAssertTrue(check.contains("htop"), "added package listed for reinstall")
        pause(10)
        save("52-after-update")
        app.terminate()
    }

    /// The styles ask the guest to switch themes (ish-apply-style, 12-23 s); open Linux apps
    /// are restored by session restore.
    func test3Styles() {
        for style in ["kylin", "windows"] {
            launch(["-desktop.onboarded", "YES", "-desktop.style", style, "-desktop.tiling", ""], reset: true)
            XCTAssertTrue(element("desktop.surface").waitForExistence(timeout: 120))
            dismissWelcome()
            pause(30)
            automate("open|linux:thunar /root", wait: 2)
            _ = waitForWindow("Thunar", timeout: 60)
            pause(4)
            save("30-style-\(style)")
            app.terminate()
        }
    }
}
