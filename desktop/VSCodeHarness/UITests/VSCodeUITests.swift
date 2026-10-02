import XCTest

/// VS Code on the iSH desktop, end to end: the installed iSH app with the devtools rootfs,
/// driven the way a user with a hardware keyboard would. Screenshots go to
/// VSCODE_SHOT_DIR (default /tmp/vscode-shots); every step is logged with a timestamp to
/// step-log.txt there, so a host-side memory sampler can be lined up with it.
///
/// Guest checks use the app's test-only automation hook (DragDrop/DebugAutomation.swift),
/// so the app must be built with AUTOMATION=1.
@MainActor
final class VSCodeUITests: XCTestCase {
    private var app: XCUIApplication!
    private static let automation = URL(fileURLWithPath: "/tmp/ish-automation")
    private var shotDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["VSCODE_SHOT_DIR"] ?? "/tmp/vscode-shots")
    }

    override func setUp() async throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        try? FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
    }

    // MARK: - Helpers

    private func launch(reset: Bool) {
        app = XCUIApplication(bundleIdentifier: "com.valentinneagu.ish.arm64")
        app.launchArguments = ["-desktop.style", "ish", "-desktop.tiling", "", "-desktop.onboarded", "YES",
                               "-desktop.debugAutomation", "YES"]
        if reset { app.launchArguments += ["-desktop.resetSession", "YES"] }
        app.launch()
        XCTAssertTrue(element("desktop.surface").waitForExistence(timeout: 90), "the desktop is up")
        let welcome = app.buttons["Start Using the Desktop"]
        if welcome.waitForExistence(timeout: 3) { welcome.tap() }
        sleep(3)
    }

    private func step(_ text: String) {
        let line = "\(Int(Date().timeIntervalSince1970)) \(text)\n"
        let url = shotDir.appendingPathComponent("step-log.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Sends a command to the automation hook and returns the log lines it produced.
    @discardableResult
    private func automate(_ command: String, wait: TimeInterval = 2) -> String {
        let log = Self.automation.appendingPathComponent("log")
        let before = (try? String(contentsOf: log, encoding: .utf8))?.count ?? 0
        let inbox = Self.automation.appendingPathComponent("in")
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString).cmd")
        try? command.write(to: file.appendingPathExtension("tmp"), atomically: true, encoding: .utf8)
        try? FileManager.default.moveItem(at: file.appendingPathExtension("tmp"), to: file)
        RunLoop.current.run(until: Date().addingTimeInterval(wait))
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return String(text.dropFirst(min(before, text.count)))
    }

    private func guest(_ command: String, wait: TimeInterval = 3) -> String {
        automate("sh|" + command, wait: wait)
    }

    /// Repeats a guest command until its output contains `needle`.
    @discardableResult
    private func waitForGuest(_ command: String, contains needle: String, timeout: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if guest(command, wait: 2).contains(needle) { return true }
            sleep(2)
        }
        return false
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func vscodeWindow() -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'window:linux:code'")).firstMatch
    }

    private func save(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: shotDir.appendingPathComponent("\(name).png"))
        step("shot \(name)")
    }

    private func key(_ key: String, _ flags: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(key, modifierFlags: flags)
        usleep(400_000)
    }

    private func key(_ key: XCUIKeyboardKey, _ flags: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(key, modifierFlags: flags)
        usleep(400_000)
    }

    /// Types text as hardware key presses.
    private func type(_ text: String) {
        for character in text {
            let s = String(character)
            if s == "\n" { app.typeKey(.return, modifierFlags: []) } else { app.typeKey(s, modifierFlags: []) }
            usleep(60_000)
        }
        usleep(300_000)
    }

    private func pause(_ seconds: UInt32) { sleep(seconds) }

    /// The simulator has no hardware keyboard as far as iPadOS knows, so focusing a Linux
    /// window brings up the on-screen one, which squeezes the window. Typing goes through
    /// XCUITest key events either way.
    private func hideKeyboard() {
        let hide = app.keyboards.buttons["Hide keyboard"]
        if hide.exists { hide.tap(); usleep(500_000) }
    }

    /// Window titles as the desktop sees them.
    private func titles() -> String { automate("state", wait: 1.5) }

    @discardableResult
    private func waitForTitle(_ needle: String, timeout: TimeInterval = 120) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if titles().contains(needle) { return true }
            sleep(2)
        }
        return false
    }

    /// Waits until VS Code's extension host (in a log folder created after `before`) has
    /// activated its start-up extensions.
    @discardableResult
    private func waitForExtensionHost(after before: String, timeout: TimeInterval = 300) -> Bool {
        waitForGuest("d=$(ls -td /root/.config/Code/logs/*/ | head -1); [ \"$d\" != \"\(before)\" ] && grep -h 'Eager extensions activated' $d/window*/exthost/exthost.log | head -1",
                     contains: "Eager", timeout: timeout)
    }

    private func newestLogDir() -> String {
        let out = guest("ls -td /root/.config/Code/logs/*/ | head -1", wait: 2)
        return out.split(separator: "\n").first { $0.hasPrefix("/root") }.map(String.init) ?? ""
    }

    private var demo: String { "/root/projects/demo" }

    private var newestLogs: String { "$(ls -td /root/.config/Code/logs/*/ | head -1)" }

    // MARK: - The tour

    func testVSCodeEndToEnd() {
        guest("cd \(demo) && git checkout -q -- . && git clean -qfd src && rm -f notes.txt; true", wait: 4)
        launch(reset: true)
        step("desktop up")
        save("00-desktop")

        // Launch from the desktop icon (one tap, as the desktop opens apps).
        let before = newestLogDir()
        let icon = element("desktop.icon.Visual Studio Code")
        XCTAssertTrue(icon.waitForExistence(timeout: 20), "the desktop has a VS Code icon")
        let launched = Date()
        icon.tap()
        step("icon tapped")
        XCTAssertTrue(vscodeWindow().waitForExistence(timeout: 120), "a VS Code window appeared")
        step("window after \(Int(Date().timeIntervalSince(launched))) s")
        XCTAssertTrue(waitForExtensionHost(after: before), "the extension host started")
        step("extension host ready after \(Int(Date().timeIntervalSince(launched))) s")
        save("01-launched")
        // A second tap on the icon must not open a second window.
        icon.tap()
        pause(30)
        step("windows after second tap: " + titles())
        save("01b-second-tap")

        // Open the demo folder from a shell, as `code -r DIR` in any terminal would.
        guest("code -r \(demo) </dev/null >/dev/null 2>&1", wait: 3)
        XCTAssertTrue(waitForTitle("demo", timeout: 240), "the folder opened")
        pause(5)
        XCTAssertTrue(waitForGuest("grep -h 'vscode.git' $(ls -td /root/.config/Code/logs/*/ | head -1)window*/exthost/exthost.log | tail -1",
                                   contains: "vscode.git", timeout: 240), "the extension host serves the folder")
        pause(10)
        step("folder open")
        save("03-folder")

        automate("frame|Visual Studio Code|0|0|1032|1300", wait: 2)
        vscodeWindow().tap()
        hideKeyboard()

        // Cmd-P quick open (file search under emulation takes a while).
        key("p", .command)
        pause(3)
        type("README")
        pause(25)
        save("04-cmd-p")
        key(.return)
        XCTAssertTrue(waitForTitle("README.md", timeout: 60), "Cmd-P opened README.md")
        pause(5)

        // Cmd-K Cmd-O, the simple open-folder dialog (looked at, then cancelled).
        key("k", .command); key("o", .command)
        pause(8)
        save("02-open-folder-dialog")
        key(.escape)
        pause(2)

        // App.tsx at line 8 from a shell, as `code -g` in any terminal would.
        guest("cd \(demo) && code -r -g src/App.tsx:8 </dev/null >/dev/null 2>&1", wait: 3)
        XCTAssertTrue(waitForTitle("App.tsx", timeout: 60), "code -g opened App.tsx")
        pause(15)
        vscodeWindow().tap()
        hideKeyboard()

        // Cmd-G go to line, member completion from TypeScript 7.
        key(.end)
        key(.return)
        type("console.log(count.")
        pause(20)
        save("05-member-completion")
        key(.escape)
        type("toFixed(1")
        key(.end)
        pause(1)

        // Cmd-S.
        key("s", .command)
        XCTAssertTrue(waitForGuest("grep -c 'console.log(count.toFixed(1))' \(demo)/src/App.tsx", contains: "1", timeout: 30),
                      "Cmd-S saved the edit")

        // Hover (Cmd-K Cmd-I) on `count`.
        key(.leftArrow); key(.leftArrow); key(.leftArrow); key(.leftArrow); key(.leftArrow)
        key(.leftArrow); key(.leftArrow); key(.leftArrow); key(.leftArrow); key(.leftArrow); key(.leftArrow); key(.leftArrow)
        key("k", .command); key("i", .command)
        pause(6)
        save("06-hover")
        key(.escape)

        // Cmd-/ comments the line.
        key("/", .command)
        key("s", .command)
        XCTAssertTrue(waitForGuest("grep -c '// *console.log(count' \(demo)/src/App.tsx", contains: "1", timeout: 30),
                      "Cmd-/ commented the line")
        save("07-cmd-slash")
        key("/", .command)

        // Option-Up moves the line up (above `const [count...`).
        key(.upArrow, .option)
        key("s", .command)
        XCTAssertTrue(waitForGuest("grep -n 'console.log(count\\|useState(0)' \(demo)/src/App.tsx | head -1", contains: "console.log",
                                   timeout: 30), "Option-Up moved the line")
        save("08-option-up")
        key(.downArrow, .option)
        key("s", .command)

        // Cmd-B toggles the side bar.
        key("b", .command)
        pause(3)
        save("09-cmd-b-hidden")
        key("b", .command)
        pause(2)

        // Cmd-Shift-P command palette.
        key("p", [.command, .shift])
        pause(3)
        type("toggle word wrap")
        pause(3)
        save("10-cmd-shift-p")
        key(.escape)

        // Cmd-` opens the terminal: npm run dev, then claude --version.
        key("`", .command)
        pause(12)
        save("11-cmd-backtick")
        type("cd \(demo) && npm run dev -- --host 127.0.0.1\n")
        XCTAssertTrue(waitForGuest("wget -qO- http://127.0.0.1:5173/ | grep -o '<title>[^<]*</title>'", contains: "<title>",
                                   timeout: 120), "the Vite dev server answers")
        pause(3)
        save("12-npm-run-dev")
        key("c", .control)
        pause(3)
        type("claude --version\n")
        pause(25)
        save("13-claude-version")

        // Commit from the SCM view: Cmd-Shift-G, message, then Git: Commit from the palette
        // (Cmd-Return is the desktop's new-terminal shortcut).
        key("g", [.command, .shift])
        pause(4)
        type("Log the count from the iPad")
        pause(1)
        save("14-scm")
        key("p", [.command, .shift])
        pause(2)
        type("Git: Commit")
        pause(3)
        key(.return)
        XCTAssertTrue(waitForGuest("git -C \(demo) log -1 --format=%s", contains: "Log the count from the iPad", timeout: 60),
                      "the commit landed")
        pause(3)
        save("15-committed")

        // System shortcut probes: does iPadOS (or the desktop) take these first?
        key(.return, .command)
        pause(5)
        save("16-probe-cmd-return")
        step("probe cmd-return state \(app.state.rawValue)")
        automate("state", wait: 2)
        key("h", .command)
        pause(4)
        step("probe cmd-h app state \(app.state.rawValue)")
        if app.state != .runningForeground { app.activate(); pause(5) }
        save("17-probe-cmd-h")
        key(.escape)
        key(" ", .control)
        pause(4)
        save("18-probe-ctrl-space")
        key(.escape)

        // `code FILE` from foot opens it in the running window.
        guest("echo 'notes from foot' > \(demo)/notes.txt")
        automate("open|linux:foot", wait: 8)
        pause(8)
        type("code \(demo)/notes.txt\n")
        XCTAssertTrue(waitForTitle("notes.txt", timeout: 120), "code FILE opened it in the running window")
        pause(20)
        save("19-code-from-foot")
        step("main processes: " + guest("ps -o pid,args | grep '/opt/vscode/code' | grep -vc 'type=\\|grep'", wait: 3))

        // Quit (Cmd-Q) and reopen from the desktop: the session comes back.
        automate("focus|Visual Studio Code", wait: 2)
        key("q", .command)
        XCTAssertTrue(waitForGuest("pgrep -f /opt/vscode/code >/dev/null || echo gone", contains: "gone", timeout: 90),
                      "VS Code quit")
        pause(3)
        save("20-quit")
        icon.tap()
        XCTAssertTrue(vscodeWindow().waitForExistence(timeout: 120), "VS Code reopened")
        pause(60)
        save("21-reopened")
        step("done")
    }

    /// iOS memory with VS Code, Firefox and Thunar open. The host samples the app's
    /// footprint; this test only arranges the windows and logs when each is up.
    func testMemoryWithFirefoxAndThunar() {
        launch(reset: false)
        step("mem: desktop up")
        if !vscodeWindow().waitForExistence(timeout: 10) {
            let icon = element("desktop.icon.Visual Studio Code")
            if icon.waitForExistence(timeout: 20) { icon.tap() }
        }
        XCTAssertTrue(vscodeWindow().waitForExistence(timeout: 120))
        pause(120)
        step("mem: vscode idle")
        save("30-mem-vscode")
        automate("open|linux:firefox", wait: 5)
        pause(90)
        step("mem: firefox up")
        automate("open|linux:thunar", wait: 5)
        pause(45)
        step("mem: thunar up")
        save("31-mem-all-three")
        pause(60)
        step("mem: idle all three")
    }
}
