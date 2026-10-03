import XCTest
@testable import DesktopKit

@MainActor
final class ClipboardHistoryTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        UserDefaults.standard.removeObject(forKey: ClipboardHistory.pausedKey)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: ClipboardHistory.pausedKey)
    }

    func testNewestFirstAndDuplicatesMoveUp() {
        let history = ClipboardHistory(directory: directory)
        history.record(text: "one", source: .linpad)
        history.record(text: "two", source: .linux)
        history.record(text: "one", source: .linpad)
        XCTAssertEqual(history.entries.map(\.text), ["one", "two"])
    }

    func testPasswordsAndPausedCopiesAreNotKept() {
        let history = ClipboardHistory(directory: directory)
        history.record(text: "hunter2", source: .linux, isSecret: true)
        XCTAssertTrue(history.entries.isEmpty)
        var applied = false
        history.recordLinuxCopy("s3cret", isSecret: true) { applied = true }
        XCTAssertTrue(applied, "the copy still reaches the iPad clipboard")
        XCTAssertTrue(history.entries.isEmpty, "but not the history")
        history.isPaused = true
        history.record(text: "while paused", source: .linpad)
        XCTAssertTrue(history.entries.isEmpty)
        history.isPaused = false
        history.record(text: "visible", source: .linpad)
        XCTAssertEqual(history.entries.count, 1)
    }

    func testLimitKeepsPinnedEntries() {
        let history = ClipboardHistory(directory: directory)
        history.record(text: "keep me", source: .linpad)
        history.togglePin(history.entries[0].id)
        for index in 0..<(ClipboardHistory.limit + 10) { history.record(text: "item \(index)", source: .linpad) }
        XCTAssertEqual(history.entries.filter { !$0.isPinned }.count, ClipboardHistory.limit)
        XCTAssertTrue(history.entries.contains { $0.text == "keep me" && $0.isPinned })
        XCTAssertFalse(history.entries.contains { $0.text == "item 0" }, "the oldest unpinned entries go")
    }

    func testClearKeepsPinnedAndRemoveDeletes() {
        let history = ClipboardHistory(directory: directory)
        history.record(text: "a", source: .linpad)
        history.record(text: "b", source: .linpad)
        history.togglePin(history.entries[1].id)
        history.clear()
        XCTAssertEqual(history.entries.map(\.text), ["a"])
        history.remove(history.entries[0].id)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testImagesAreStoredAndPruned() {
        let history = ClipboardHistory(directory: directory)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3)).image { _ in }
        for _ in 0..<(ClipboardHistory.imageLimit + 2) { history.record(image: image, source: .linpad) }
        let images = history.entries.filter { $0.imageFile != nil }
        XCTAssertEqual(images.count, ClipboardHistory.imageLimit)
        XCTAssertNotNil(history.image(of: images[0]))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".png") }) ?? []
        XCTAssertEqual(files.count, ClipboardHistory.imageLimit, "pruned images are deleted from disk")
        XCTAssertTrue(images[0].title.hasPrefix("Image "))
    }

    func testPersistsAcrossLaunches() {
        let history = ClipboardHistory(directory: directory)
        history.record(text: "survives", source: .linux)
        history.togglePin(history.entries[0].id)
        let reloaded = ClipboardHistory(directory: directory)
        XCTAssertEqual(reloaded.entries.first?.text, "survives")
        XCTAssertEqual(reloaded.entries.first?.isPinned, true)
        XCTAssertEqual(reloaded.entries.first?.source, .linux)
    }

    func testTitleIsTheFirstLine() {
        XCTAssertEqual(ClipboardEntry(text: "first\nsecond", source: .linpad, date: Date()).title, "first")
    }
}

@MainActor
final class CommandMenuSectionsTests: XCTestCase {
    func testIndexLetterOpensASection() {
        let controller = DesktopController(host: MockLinuxHost(latency: .zero), apps: BuiltinApps.all())
        controller.toggleCommandMenu(.index)
        XCTAssertEqual(controller.commandMenuResults().first?.section, .sections)
        controller.setCommandMenuQuery("c")
        XCTAssertEqual(controller.commandMenu?.mode, .section(.capture))
        let sections = Set(controller.commandMenuResults().map(\.section))
        XCTAssertEqual(sections, [.capture, .sections], "only Capture's items and the way back")
        XCTAssertTrue(controller.commandMenuResults().contains { $0.id == "command:capture.full" })
    }

    func testEverySectionInTheIndexHasItems() {
        let controller = DesktopController(host: MockLinuxHost(latency: .zero), apps: BuiltinApps.all())
        controller.open(appID: AppID.files, arguments: [:])
        ClipboardHistory.shared.record(text: "menu test", source: .linpad)
        controller.toggleCommandMenu(.all)
        let present = Set(controller.commandMenuItems().map(\.section))
        for (section, _) in CommandMenuItem.Section.browsable {
            XCTAssertTrue(present.contains(section), "\(section.rawValue) has items")
        }
        ClipboardHistory.shared.remove(ClipboardHistory.shared.entries.first { $0.text == "menu test" }!.id)
    }

    func testFlatMenuLeavesTheClipboardOut() {
        let controller = DesktopController(host: MockLinuxHost(latency: .zero), apps: BuiltinApps.all())
        controller.toggleCommandMenu(.all)
        XCTAssertFalse(controller.commandMenuResults().contains { $0.section == .clipboard })
        controller.toggleCommandMenu(.section(.clipboard))
        XCTAssertEqual(controller.commandMenu?.mode, .section(.clipboard), "switching modes keeps the menu open")
        controller.toggleCommandMenu(.section(.clipboard))
        XCTAssertNil(controller.commandMenu, "the same shortcut closes it")
    }

    func testSectionIndexKeysAreUnique() {
        let letters = CommandMenuItem.Section.browsable.map(\.1)
        XCTAssertEqual(Set(letters).count, letters.count)
    }
}
