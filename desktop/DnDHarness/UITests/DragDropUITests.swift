import XCTest

/// Drag and drop and context menus in the real iSH app, in landscape, by touch.
/// Screenshots go to DND_SCREENSHOT_DIR when it is set.
@MainActor
final class DragDropUITests: XCTestCase {
    private var app: XCUIApplication!
    private let stamp = String(Int(Date().timeIntervalSince1970) % 100_000)

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeRight
    }

    override func record(_ issue: XCTIssue) {
        if app != nil { save("fail-\(name.split(separator: " ").last.map(String.init) ?? "test")") }
        super.record(issue)
    }

    private func launch(autostart: String) {
        app = XCUIApplication(bundleIdentifier: "com.valentinneagu.ish.arm64")
        app.launchArguments = ["-desktop.resetSession", "YES", "-desktop.autostart", autostart, "-desktop.style", "ish",
                               "-desktop.tiling", "", "-desktop.onboarded", "YES",
                               "-desktop.debugAutomation", "YES"]
        app.launch()
    }

    private static let automation = URL(fileURLWithPath: "/tmp/ish-automation")
        .appendingPathComponent(ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "device")

    /// Sends a command to the app's test-only automation hook (DragDrop/DebugAutomation.swift)
    /// and returns the log lines it produced. Needs a build with AUTOMATION=1.
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

    /// Opens Files on a new empty folder, so menus on the empty area and new names are
    /// unaffected by earlier runs.
    @discardableResult
    private func openFilesInFreshFolder() -> String {
        XCTAssertTrue(element("desktop.surface").waitForExistence(timeout: 60))
        sleep(3)
        let folder = "/root/uitest-\(stamp)"
        automate("sh|mkdir -p \(folder)", wait: 3)
        automate("open|files|path=\(folder)", wait: 1)
        requireWindow("files")
        automate("frame|app:files|20|40|640|520", wait: 2)
        return folder
    }

    private func lastComponent(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }

    /// Repeats a guest command until its output contains `needle`.
    private func waitForGuest(_ command: String, contains needle: String, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if automate("sh|" + command, wait: 2).contains(needle) { return true }
        }
        return false
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func requireWindow(_ appID: String) {
        let window = element("window:\(appID)")
        if !window.waitForExistence(timeout: 90) {
            save("debug-no-\(appID)-window")
            XCTFail("no \(appID) window; state \(app.state.rawValue)")
        }
        let welcome = app.buttons["Start Using the Desktop"]
        if welcome.waitForExistence(timeout: 3) { welcome.tap(); sleep(1) }
        // The first touch after launch only focuses the window.
        sleep(2)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
    }

    private func entry(_ name: String) -> XCUIElement { element("files.entry.\(name)") }

    private func waitFor(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    private func save(_ name: String) {
        let directory = ProcessInfo.processInfo.environment["DND_SCREENSHOT_DIR"] ?? "/tmp/dnd-shots"
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    /// An item of the open context menu (UIKit shows menus as collection views).
    private func menuItem(_ title: String) -> XCUIElement {
        app.collectionViews.buttons[title].firstMatch
    }

    /// New File from the toolbar, through the name prompt.
    private func createFile(_ name: String) {
        // Through the background menu: UIKit menu items have exact frames, while SwiftUI
        // toolbar buttons inside a moved window can report stale ones.
        let field = app.alerts.textFields.firstMatch
        for _ in 0..<3 where !field.exists {
            element("files.content").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).press(forDuration: 1.2)
            if menuItem("New File").waitForExistence(timeout: 4) { menuItem("New File").tap() }
            _ = field.waitForExistence(timeout: 4)
        }
        if !field.exists { save("debug-new-file") }
        XCTAssertTrue(field.exists)
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + name)
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(entry(name).waitForExistence(timeout: 20), "\(name) was created")
    }

    // MARK: - Tests

    func testFilesContextMenuDuplicateTrashAndRestore() {
        launch(autostart: "")
        let folder = openFilesInFreshFolder()
        let name = "menu-\(stamp).txt"
        createFile(name)

        entry(name).press(forDuration: 1.2)
        XCTAssertTrue(menuItem("Duplicate").waitForExistence(timeout: 5), "the item menu opened")
        for title in ["Open With", "Cut", "Copy", "Copy Path", "Rename…", "Compress", "Share…", "Move to Trash",
                      "Delete Permanently…", "Properties"] {
            XCTAssertTrue(menuItem(title).exists, "menu has \(title)")
        }
        save("dnd-files-item-menu")
        menuItem("Duplicate").tap()
        let copy = "menu-\(stamp) (copy).txt"
        XCTAssertTrue(entry(copy).waitForExistence(timeout: 20), "Duplicate made a copy")

        entry(copy).press(forDuration: 1.2)
        XCTAssertTrue(menuItem("Move to Trash").waitForExistence(timeout: 5))
        menuItem("Move to Trash").tap()
        waitFor("the copy left the folder") { !entry(copy).exists }

        element("files.place.Trash").tap()
        XCTAssertTrue(entry(copy).waitForExistence(timeout: 20), "the copy is in the Trash")
        save("dnd-files-trash")
        entry(copy).press(forDuration: 1.2)
        XCTAssertTrue(menuItem("Restore").waitForExistence(timeout: 5))
        menuItem("Restore").tap()
        waitFor("the copy left the Trash") { !entry(copy).exists }
        XCTAssertTrue(waitForGuest("ls \(folder)", contains: copy), "Restore put it back")
        element("files.place.Home").tap()
        XCTAssertTrue(entry(lastComponent(folder)).waitForExistence(timeout: 20))
        entry(lastComponent(folder)).doubleTap()
        XCTAssertTrue(entry(copy).waitForExistence(timeout: 20), "and Files shows it there")

        // The background menu.
        let content = element("files.content")
        content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).press(forDuration: 1.2)
        XCTAssertTrue(menuItem("Open Terminal Here").waitForExistence(timeout: 5))
        XCTAssertTrue(menuItem("Paste").exists && menuItem("Select All").exists && menuItem("Sort By").exists)
        save("dnd-files-background-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.05)).tap()
    }

    func testDragBetweenFilesDesktopAndPlaces() {
        launch(autostart: "")
        openFilesInFreshFolder()
        automate("sh|rm -f /root/Desktop/*.txt", wait: 3)
        let name = "drag-\(stamp).txt"
        createFile(name)

        // Onto the Desktop place: moves into ~/Desktop, which the desktop shows as an icon.
        entry(name).press(forDuration: 0.8, thenDragTo: element("files.place.Desktop"))
        waitFor("the file left the folder") { !entry(name).exists }
        let icon = element("desktop.icon.\(name)")
        XCTAssertTrue(icon.waitForExistence(timeout: 20), "the file shows on the desktop")
        save("dnd-desktop-icon")

        // From the desktop back into the Files window, moved aside so the icon is visible.
        automate("frame|app:files|640|120|640|480", wait: 2)
        icon.press(forDuration: 0.8, thenDragTo: element("files.content"))
        XCTAssertTrue(entry(name).waitForExistence(timeout: 20), "dropped back into the folder")
        waitFor("the desktop icon went away") { !icon.exists }

        // The desktop's own menu.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.85)).press(forDuration: 1.2)
        XCTAssertTrue(menuItem("Arrange Icons").waitForExistence(timeout: 5))
        XCTAssertTrue(menuItem("Show Desktop Icons").exists && menuItem("Open Terminal Here").exists
                      && menuItem("Change Wallpaper").exists)
        save("dnd-desktop-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.95)).tap()
    }

    /// A native drag into a Linux app: Files → Thunar, checked in the guest.
    func testDragFromFilesIntoThunar() {
        launch(autostart: "")
        XCTAssertTrue(element("desktop.surface").waitForExistence(timeout: 60))
        sleep(3)
        let name = "to-thunar-\(stamp).txt"
        let source = "/root/dnd-src-\(stamp)", target = "/root/dnd-dst-\(stamp)"
        automate("sh|mkdir -p \(source) \(target) && echo from-files > \(source)/\(name)", wait: 4)
        automate("open|files|path=\(source)", wait: 1)
        requireWindow("files")
        automate("open|linux:thunar \(target)", wait: 1)
        let thunar = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'window:linux:'")).firstMatch
        XCTAssertTrue(thunar.waitForExistence(timeout: 120), "Thunar opened")
        sleep(4)
        automate("frame|app:files|20|40|600|460", wait: 1)
        automate("frame|Thunar|660|40|640|460", wait: 3)
        XCTAssertTrue(entry(name).waitForExistence(timeout: 20))
        save("dnd-thunar-before")

        entry(name).coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1.0,
            thenDragTo: thunar.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7)))
        XCTAssertTrue(waitForGuest("ls \(target)", contains: name, timeout: 40), "Thunar took the file into \(target)")
        XCTAssertTrue(automate("sh|cat \(target)/\(name)").contains("from-files"))
        sleep(2)
        save("dnd-thunar-after")
    }

    /// Drags that start in Thunar, driven through the automation hook (pointer events into the
    /// Linux window, the same bridge calls a trackpad makes): Thunar → Files, Thunar → the
    /// desktop, and Thunar → Mousepad (GTK to GTK, which opens the file).
    func testDragsFromThunar() {
        launch(autostart: "")
        XCTAssertTrue(element("desktop.surface").waitForExistence(timeout: 60))
        sleep(3)
        let dir = "/root/thunar-\(stamp)"
        // Thunar sorts by name: a-…, b-…, c-… are the first three icons.
        automate("sh|mkdir -p \(dir) && echo one > \(dir)/a-files.txt && echo two > \(dir)/b-desktop.txt && echo three > \(dir)/c-mousepad.txt", wait: 4)
        automate("open|files|path=/root", wait: 1)
        requireWindow("files")
        automate("open|linux:thunar \(dir)", wait: 1)
        let linux = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'window:linux:'"))
        XCTAssertTrue(linux.firstMatch.waitForExistence(timeout: 120), "Thunar opened")
        sleep(4)
        automate("frame|app:files|20|40|600|460", wait: 1)
        automate("frame|Thunar|660|40|640|460", wait: 4)
        save("dnd-thunar-source")

        // The first icon sits at (224, 150) in Thunar's content.
        let toFiles = automate("drag|Thunar|224|150|app:files|300|300", wait: 10)
        XCTAssertTrue(toFiles.contains("dnd_end host"), toFiles)
        XCTAssertTrue(waitForGuest("ls /root", contains: "a-files.txt"), "Thunar → Files moved the file into /root")
        XCTAssertTrue(entry("a-files.txt").waitForExistence(timeout: 20), "Files shows it")
        save("dnd-thunar-to-files")

        // The desktop shows through between the two windows.
        // Reload Thunar (F5) so the next file is first, whether or not it noticed the move.
        automate("key|Thunar|63", wait: 4)
        let toDesktop = automate("drag|Thunar|224|150|desktop|640|560", wait: 10)
        XCTAssertTrue(toDesktop.contains("dnd_end host"), toDesktop)
        XCTAssertTrue(waitForGuest("ls /root/Desktop", contains: "b-desktop.txt"), "Thunar → desktop moved it into ~/Desktop")
        XCTAssertTrue(element("desktop.icon.b-desktop.txt").waitForExistence(timeout: 20), "the desktop shows it")

        automate("open|linux:mousepad", wait: 1)
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline && !automate("state", wait: 2).contains("Mousepad") {}
        automate("frame|Mousepad|20|40|600|460", wait: 4)
        automate("key|Thunar|63", wait: 4)
        let toMousepad = automate("drag|Thunar|224|150|Mousepad|300|250", wait: 10)
        XCTAssertTrue(toMousepad.contains("dnd_end dropped"), toMousepad)
        var state = ""
        let opened = Date().addingTimeInterval(30)
        while Date() < opened {
            state = automate("state", wait: 2)
            if state.contains("c-mousepad.txt - Mousepad") { break }
        }
        save("dnd-thunar-to-mousepad")
        XCTAssertTrue(state.contains("c-mousepad.txt - Mousepad"), "Mousepad opened the dropped file: \(state)")
    }

    /// macOS-style Quick Look from the hardware keyboard: Space opens it on the selected file,
    /// the arrow keys move to the next file while it is open, Esc closes it.
    func testSpaceQuickLookWithArrowsAndEscape() {
        launch(autostart: "")
        XCTAssertTrue(element("desktop.surface").waitForExistence(timeout: 60))
        sleep(3)
        let folder = "/root/quicklook-\(stamp)"
        automate("sh|mkdir -p \(folder) && echo alpha > \(folder)/a.txt && echo bravo > \(folder)/b.txt", wait: 4)
        automate("open|files|path=\(folder)", wait: 1)
        requireWindow("files")
        automate("frame|app:files|20|40|640|520", wait: 2)
        XCTAssertTrue(entry("a.txt").waitForExistence(timeout: 20))
        entry("a.txt").tap()
        sleep(1)

        app.typeKey(" ", modifierFlags: [])
        // Quick Look titles the file without its extension on iPadOS 26.
        func preview(_ name: String) -> XCUIElement {
            app.navigationBars.matching(NSPredicate(format: "identifier == %@ OR identifier == %@", name, name + ".txt")).firstMatch
        }
        let first = preview("a")
        XCTAssertTrue(first.waitForExistence(timeout: 30), "Space opened Quick Look on a.txt")
        save("dnd-quicklook-a")

        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(preview("b").waitForExistence(timeout: 30), "↓ moved the preview to b.txt")
        save("dnd-quicklook-b")

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        waitFor("Esc closed Quick Look", timeout: 10) { !preview("b").exists }
        XCTAssertTrue(entry("b.txt").exists, "back in Files, with b.txt selected")
    }

    /// An iPad folder mounted into the guest (the picker is bypassed through the automation
    /// hook; the mount is the real iOSFS one): Linux sees its files, writes reach the iPad
    /// side, the sidebar lists it under iPad, and Eject unmounts it. Also checks the Photos
    /// place is there.
    func testIPadFolderMountAndPhotosPlace() throws {
        launch(autostart: "")
        XCTAssertTrue(element("desktop.surface").waitForExistence(timeout: 60))
        sleep(3)
        let hostFolder = URL(fileURLWithPath: "/tmp/ipad-folder-\(stamp)")
        try FileManager.default.createDirectory(at: hostFolder, withIntermediateDirectories: true)
        try Data("from the iPad".utf8).write(to: hostFolder.appendingPathComponent("ipad-note.txt"))

        let mounted = automate("mount|\(hostFolder.path)", wait: 6)
        XCTAssertTrue(mounted.contains("mounted /mnt/ipad/"), mounted)
        let point = "/mnt/ipad/ipad-folder-\(stamp)"
        XCTAssertTrue(waitForGuest("cat \(point)/ipad-note.txt", contains: "from the iPad"), "Linux reads the iPad folder")
        automate("sh|echo from-linux > \(point)/linux-note.txt; ls -l ~/iPad", wait: 3)
        XCTAssertEqual(try? String(contentsOf: hostFolder.appendingPathComponent("linux-note.txt"), encoding: .utf8),
                       "from-linux\n", "Linux writes reach the iPad folder")

        automate("open|files|path=\(point)", wait: 1)
        requireWindow("files")
        automate("frame|app:files|20|40|700|560", wait: 2)
        let place = element("files.place.ipad.ipad-folder-\(stamp)")
        XCTAssertTrue(place.waitForExistence(timeout: 20), "the sidebar lists the iPad folder")
        XCTAssertTrue(entry("ipad-note.txt").waitForExistence(timeout: 20))
        XCTAssertTrue(element("files.place.Photos").exists && element("files.add-ipad-folder").exists)
        save("dnd-ipad-folder")

        place.press(forDuration: 1.2)
        XCTAssertTrue(menuItem("Eject").waitForExistence(timeout: 10))
        menuItem("Eject").tap()
        waitFor("the place went away", timeout: 20) { !place.exists }
        XCTAssertFalse(automate("sh|ls \(point) 2>&1; echo done", wait: 3).contains("ipad-note.txt"), "unmounted")

        element("files.place.Photos").tap()
        XCTAssertTrue(app.buttons["photos.allow"].waitForExistence(timeout: 10) || element("photos.album").waitForExistence(timeout: 5),
                      "the Photos place asks for access or shows the library")
        save("dnd-photos-place")
    }

    /// Text dragged from the Text Editor into Mousepad.
    func testTextFromEditorToMousepad() {
        launch(autostart: "editor")
        requireWindow("editor")
        automate("open|linux:mousepad", wait: 1)
        let mousepad = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'window:linux:'")).firstMatch
        XCTAssertTrue(mousepad.waitForExistence(timeout: 120), "Mousepad opened")
        sleep(3)
        automate("frame|app:editor|20|40|600|460", wait: 1)
        automate("frame|Mousepad|660|40|640|460", wait: 3)
        let text = element("window:editor").textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        text.typeText("draggable\n")
        // The first line: 8 pt inset, about 17 pt per line.
        let word = text.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 17))
        word.doubleTap()
        sleep(1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
        word.doubleTap()
        sleep(1)
        word.press(forDuration: 1.5,
            thenDragTo: mousepad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        var title = ""
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            title = automate("state", wait: 2)
            if title.contains("*Untitled") { break }
        }
        save("dnd-editor-to-mousepad")
        XCTAssertTrue(title.contains("*Untitled"), "Mousepad's document changed: \(title)")
    }

    func testTextEditorAndPreviewMenus() {
        launch(autostart: "editor")
        let editor = element("window:editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        let text = editor.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        text.typeText("hello drag and drop")
        text.press(forDuration: 1.2)
        let undo = menuItem("Undo")
        XCTAssertTrue(undo.waitForExistence(timeout: 5) || app.menuItems["Undo"].exists, "the editor menu has Undo")
        save("dnd-editor-menu")
    }
}
