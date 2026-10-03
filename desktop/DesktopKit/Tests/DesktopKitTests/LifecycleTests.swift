import XCTest
@testable import DesktopKit

/// A guest whose commands the test controls, recording the order of everything the
/// lifecycle asks of the host.
@MainActor
private final class LifecycleTestHost: LinuxHost, LinuxLifecycleHosting {
    let hostName = "test"
    let homeDirectory = "/root"
    var events: [String] = []
    var hangingCommands: Set<String> = []
    var files: [String: Data] = [:]
    var mode: BackgroundExecution?
    var inBackground: Bool?
    var resumed = 0

    func run(_ command: String, cwd: String?, stdin: Data?) async -> CommandResult {
        events.append(command == GuestLifecycleCommand.suspend ? "guest-suspend"
                      : command == GuestLifecycleCommand.resume ? "guest-resume" : "run")
        if hangingCommands.contains(command) {
            try? await Task.sleep(for: .seconds(3600))
        }
        return CommandResult(stdout: "")
    }

    func listDirectory(_ path: String) async throws -> [FileEntry] { [] }

    func readFile(_ path: String) async throws -> Data {
        guard let data = files[path] else { throw LinuxHostError.invalidPath(path) }
        return data
    }

    func writeFile(_ path: String, data: Data) async throws {
        events.append("write \(path)")
        files[path] = data
    }

    func makeTerminalViewController(command: String?, cwd: String?) -> UIViewController { UIViewController() }

    func flushFilesystem() async {
        events.append("flush")
    }

    func applyBackgroundExecution(_ mode: BackgroundExecution, inBackground: Bool) {
        self.mode = mode
        self.inBackground = inBackground
    }

    var backgroundLocationAccess: BackgroundLocationAccess { .unavailable }

    func requestBackgroundLocationAccess() async -> BackgroundLocationAccess { .unavailable }

    func resumeAfterBackground() {
        resumed += 1
    }
}

@MainActor
private final class FakeBackgroundTasks: BackgroundTaskRunning {
    var begun: [Int] = []
    var ended: [Int] = []
    var expirations: [Int: @MainActor () -> Void] = [:]
    private var next = 1

    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int {
        let token = next
        next += 1
        begun.append(token)
        expirations[token] = expiration
        return token
    }

    func end(_ token: Int) {
        ended.append(token)
    }
}

@MainActor
private final class RecordingSaver: LifecycleSaving {
    let host: LifecycleTestHost
    var hangs = false

    init(host: LifecycleTestHost) {
        self.host = host
    }

    func saveBeforeSuspension() async {
        host.events.append("app-save")
        if hangs { try? await Task.sleep(for: .seconds(3600)) }
    }
}

@MainActor
private final class TestWindowHandle: WindowHandle {
    let id = UUID()
    var title = ""
    var arguments: [String: String] = [:]
    func setTitle(_ title: String) { self.title = title }
    func close() {}
    func setArgument(_ value: String?, forKey key: String) { arguments[key] = value }
}

@MainActor
private final class NoDesktop: DesktopActions {
    func open(appID: String, arguments: [String: String]) {}
    func notify(_ message: String) {}
}

@MainActor
final class LifecycleTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var recoveryDirectory: URL!

    override func setUp() async throws {
        suiteName = "LifecycleTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        recoveryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: recoveryDirectory)
    }

    // MARK: Settings

    func testBackgroundExecutionDefaultsToWhileAudioPlays() {
        XCTAssertEqual(BackgroundExecution.stored(in: defaults), .whileAudioPlays)
        defaults.set("always", forKey: BackgroundExecution.storageKey)
        XCTAssertEqual(BackgroundExecution.stored(in: defaults), .always)
        defaults.set("bogus", forKey: BackgroundExecution.storageKey)
        XCTAssertEqual(BackgroundExecution.stored(in: defaults), .whileAudioPlays)
        for mode in BackgroundExecution.allCases {
            XCTAssertFalse(mode.explanation.isEmpty)
        }
        XCTAssertTrue(BackgroundExecution.always.explanation.contains("location"))
        XCTAssertTrue(BackgroundExecution.always.explanation.contains("battery"))
    }

    // MARK: How the last run ended

    func testPreviousExitFromTheSessionMarker() throws {
        let launched = Date(timeIntervalSince1970: 1_790_000_000)
        func marker(foreground: Bool, clean: Bool?) -> DiagnosticsSessionMarker {
            DiagnosticsSessionMarker(launchedAt: launched, appVersion: "1", inForeground: foreground,
                                     stallInProgressSince: nil, exitedCleanly: clean)
        }
        XCTAssertEqual(PreviousExit(marker: nil), .clean)
        XCTAssertEqual(PreviousExit(marker: marker(foreground: false, clean: nil)), .endedInBackground)
        XCTAssertEqual(PreviousExit(marker: marker(foreground: true, clean: nil)), .crashedInForeground)
        XCTAssertEqual(PreviousExit(marker: marker(foreground: false, clean: true)), .clean)
        XCTAssertEqual(PreviousExit(marker: marker(foreground: true, clean: true)), .clean)
        XCTAssertFalse(marker(foreground: true, clean: true).endedUncleanly, "Quit is not a crash")
        // Markers written before exitedCleanly existed still decode.
        let old = #"{"launchedAt":"2026-10-01T10:00:00Z","appVersion":"1.0","inForeground":false}"#
        let decoded = try JSONDecoder.diagnostics.decode(DiagnosticsSessionMarker.self, from: Data(old.utf8))
        XCTAssertNil(decoded.exitedCleanly)
        XCTAssertEqual(PreviousExit(marker: decoded), .endedInBackground)
    }

    func testQuitMarksTheExitClean() throws {
        let directory = recoveryDirectory.appendingPathComponent("diag", isDirectory: true)
        let first = DiagnosticsCenter(directory: directory, isInForeground: { true }, observesSystem: false)
        first.beginSession()
        first.markCleanExit()
        let second = DiagnosticsCenter(directory: directory, isInForeground: { true }, observesSystem: false)
        second.beginSession()
        XCTAssertEqual(second.previousExit, .clean)
        XCTAssertFalse(second.previousSessionEndedUncleanly)
        // Killed while in the background (the marker of `second` says foreground, then it
        // never wrote again): a third launch sees a crash in the foreground.
        let third = DiagnosticsCenter(directory: directory, isInForeground: { false }, observesSystem: false)
        third.beginSession()
        XCTAssertEqual(third.previousExit, .crashedInForeground)
        let fourth = DiagnosticsCenter(directory: directory, isInForeground: { false }, observesSystem: false)
        fourth.beginSession()
        XCTAssertEqual(fourth.previousExit, .endedInBackground)
    }

    // MARK: Linux windows in the session

    func testSelfRestoringLinuxAppsRelaunchOnce() {
        func window(_ id: String) -> DesktopSessionSnapshot.Window {
            DesktopSessionSnapshot.Window(appID: id, arguments: [:], placement: WindowPlacement(
                frame: .zero, workspace: 0, snap: nil, isMaximized: false, isMinimized: false, isAlwaysOnTop: false))
        }
        let saved = ["linux:firefox", "linux:foot", "linux:firefox", "linux:code", "linux:foot",
                     "linux:code", "linux:libreoffice-writer", "linux:org.xfce.mousepad"].map(window)
        XCTAssertEqual(LinuxSessionRelaunch.launches(for: saved).map(\.appID),
                       ["linux:firefox", "linux:foot", "linux:code", "linux:foot", "linux:libreoffice-writer",
                        "linux:org.xfce.mousepad"])
        XCTAssertTrue(LinuxSessionRelaunch.restoresOwnWindows("linux:firefox-esr"))
        XCTAssertTrue(LinuxSessionRelaunch.restoresOwnWindows("linux:org.mozilla.firefox"))
        XCTAssertFalse(LinuxSessionRelaunch.restoresOwnWindows("linux:foot"))
        XCTAssertFalse(LinuxSessionRelaunch.restoresOwnWindows("linux:codeblocks"))
    }

    func testSessionRestoreReopensWindowsAndDontRestoreClosesThem() throws {
        let key = DesktopSessionStore.storageKey
        let saved = UserDefaults.standard.data(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let first = DesktopController(host: MockLinuxHost(latency: .zero), apps: BuiltinApps.all())
        first.windowManager.updateDesktopSize(CGSize(width: 1180, height: 786))
        first.open(appID: AppID.editor, arguments: [AppArgument.path: "/root/notes.txt"])
        first.open(appID: AppID.terminal, arguments: [AppArgument.cwd: "/root/src", AppArgument.command: "make"])
        first.windowManager.move(try XCTUnwrap(first.windowManager.windows.last).id, toWorkspace: 2)
        first.session.saveNow()

        let second = DesktopController(host: MockLinuxHost(latency: .zero), apps: BuiltinApps.all())
        second.windowManager.updateDesktopSize(CGSize(width: 1180, height: 786))
        let reopened = second.session.restore()
        XCTAssertEqual(reopened, [AppID.editor, AppID.terminal])
        XCTAssertTrue(second.session.didRestoreWindows)
        XCTAssertEqual(second.windowManager.windows.count, 2)
        let terminal = try XCTUnwrap(second.windowManager.windows.first { $0.appID == AppID.terminal })
        XCTAssertEqual(terminal.arguments, [AppArgument.cwd: "/root/src"], "commands are never replayed")
        XCTAssertEqual(terminal.workspace, 2)
        XCTAssertEqual(second.windowManager.windows.first { $0.appID == AppID.editor }?.arguments[AppArgument.path],
                       "/root/notes.txt")

        second.session.discardRestoredWindows()
        XCTAssertTrue(second.windowManager.windows.isEmpty)
    }

    func testArgumentsSetByAnAppReachTheSession() throws {
        let manager = WindowManager()
        manager.updateDesktopSize(CGSize(width: 1180, height: 786))
        let window = manager.makeWindow(appID: AppID.editor, symbol: "doc", title: "Editor",
                                        preferredSize: CGSize(width: 400, height: 300))
        manager.present(window)
        var saves = 0
        manager.onLayoutChange = { saves += 1 }
        let handle = DesktopWindowHandle(window: window, manager: manager)
        handle.setArgument("abc-123", forKey: AppArgument.recovery)
        handle.setArgument("abc-123", forKey: AppArgument.recovery)
        XCTAssertEqual(saves, 1, "an unchanged value does not save again")
        XCTAssertEqual(DesktopSessionSnapshot(manager: manager).windows.first?.arguments[AppArgument.recovery], "abc-123")
    }

    // MARK: Leaving the screen

    func testBackgroundFlushRunsInOrderWithinTheGracePeriod() async throws {
        let host = LifecycleTestHost()
        let tasks = FakeBackgroundTasks()
        let savers = LifecycleSavers()
        let saver = RecordingSaver(host: host)
        savers.register(saver)
        let coordinator = LifecycleCoordinator(controller: nil, host: host, tasks: tasks, defaults: defaults,
                                               savers: savers, observesApplication: false)
        coordinator.didEnterBackground()
        XCTAssertEqual(tasks.begun.count, 1, "the grace period starts at once")
        XCTAssertEqual(host.inBackground, true)
        try await waitUntil { tasks.ended == tasks.begun }
        XCTAssertEqual(host.events, ["app-save", "guest-suspend", "flush"])
        let report = try XCTUnwrap(coordinator.lastFlush)
        XCTAssertEqual(report.appsSaved, 1)
        XCTAssertTrue(report.guestHookFinished)
        XCTAssertTrue(report.filesystemFlushed)

        coordinator.willEnterForeground()
        XCTAssertEqual(host.resumed, 1)
        XCTAssertEqual(host.inBackground, false)
        try await waitUntil { host.events.last == "guest-resume" }
    }

    func testAHungAppOrGuestDoesNotKeepTheFileSystemFromBeingFlushed() async throws {
        let host = LifecycleTestHost()
        host.hangingCommands = [GuestLifecycleCommand.suspend]
        let tasks = FakeBackgroundTasks()
        let savers = LifecycleSavers()
        let saver = RecordingSaver(host: host)
        saver.hangs = true
        savers.register(saver)
        let coordinator = LifecycleCoordinator(controller: nil, host: host, tasks: tasks, defaults: defaults,
                                               savers: savers, observesApplication: false)
        let start = Date()
        let report = await coordinator.flushForSuspension()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(host.events, ["app-save", "guest-suspend", "flush"])
        XCTAssertEqual(report.appsSaved, 0)
        XCTAssertFalse(report.guestHookFinished)
        XCTAssertTrue(report.filesystemFlushed)
        XCTAssertLessThan(elapsed, LifecycleCoordinator.saveTimeout + GuestLifecycleCommand.suspendTimeout + 3)
        XCTAssertLessThan(elapsed, 25, "well within iPadOS's ~30 s")
    }

    func testExpiredGracePeriodEndsTheTaskOnce() async throws {
        let host = LifecycleTestHost()
        host.hangingCommands = [GuestLifecycleCommand.suspend]
        let tasks = FakeBackgroundTasks()
        let coordinator = LifecycleCoordinator(controller: nil, host: host, tasks: tasks, defaults: defaults,
                                               savers: LifecycleSavers(), observesApplication: false)
        coordinator.didEnterBackground()
        let token = try XCTUnwrap(tasks.begun.first)
        tasks.expirations[token]?()
        XCTAssertEqual(tasks.ended, [token])
        coordinator.willEnterForeground()
        XCTAssertEqual(tasks.ended, [token], "ended exactly once")
    }

    func testTheSettingReachesTheHost() {
        let host = LifecycleTestHost()
        let coordinator = LifecycleCoordinator(controller: nil, host: host, tasks: FakeBackgroundTasks(),
                                               defaults: defaults, savers: LifecycleSavers(), observesApplication: false)
        coordinator.setBackgroundExecution(.off)
        XCTAssertEqual(host.mode, .off)
        XCTAssertEqual(host.inBackground, false)
        XCTAssertEqual(BackgroundExecution.stored(in: defaults), .off)
    }

    func testTimeoutReturnsWhileTheOperationHangs() async {
        let start = Date()
        let value: Bool? = await withLifecycleTimeout(0.2) {
            try? await Task.sleep(for: .seconds(3600))
            return true
        }
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let quick = await withLifecycleTimeout(5) { 42 }
        XCTAssertEqual(quick, 42)
    }

    // MARK: Text Editor

    private func makeDocument(host: LifecycleTestHost, window: TestWindowHandle, path: String?) -> EditorDocument {
        var arguments = window.arguments
        if let path { arguments[AppArgument.path] = path }
        let context = AppLaunchContext(host: host, arguments: arguments, window: window, desktop: NoDesktop())
        return EditorDocument(context: context, recovery: EditorRecoveryStore(directory: recoveryDirectory),
                              defaults: defaults)
    }

    private func edit(_ document: EditorDocument, to text: String) {
        document.editorView.textView.text = text
        document.editorView.textViewDidChange(document.editorView.textView)
    }

    func testEditorAutosavesToTheFileAndDropsTheRecoveryRecord() async throws {
        let host = LifecycleTestHost()
        host.files["/root/a.txt"] = Data("old\n".utf8)
        let window = TestWindowHandle()
        let document = makeDocument(host: host, window: window, path: "/root/a.txt")
        await document.loadIfNeeded()
        edit(document, to: "new text\n")
        XCTAssertTrue(document.isDirty)
        await document.saveBeforeSuspension()
        XCTAssertEqual(host.files["/root/a.txt"], Data("new text\n".utf8))
        XCTAssertFalse(document.isDirty)
        XCTAssertNil(EditorRecoveryStore(directory: recoveryDirectory).read(document.recoveryID),
                     "saved to the file, so nothing to recover")
    }

    func testUnsavedTextComesBackInTheRestoredWindow() async throws {
        defaults.set(false, forKey: LifecycleSettings.editorAutosaveKey)
        let host = LifecycleTestHost()
        host.files["/root/b.txt"] = Data("on disk\n".utf8)
        let window = TestWindowHandle()
        let document = makeDocument(host: host, window: window, path: "/root/b.txt")
        await document.loadIfNeeded()
        edit(document, to: "typed but never saved\n")
        await document.saveBeforeSuspension()
        XCTAssertEqual(host.files["/root/b.txt"], Data("on disk\n".utf8), "autosave off: the file is untouched")
        let id = try XCTUnwrap(window.arguments[AppArgument.recovery], "the window remembers its record")

        // iPadOS ends LinPad; the session reopens the window with the same arguments.
        let restoredWindow = TestWindowHandle()
        restoredWindow.arguments = window.arguments
        let restored = makeDocument(host: host, window: restoredWindow, path: "/root/b.txt")
        XCTAssertEqual(restored.recoveryID, id)
        await restored.loadIfNeeded()
        XCTAssertEqual(restored.editorView.text, "typed but never saved\n")
        XCTAssertTrue(restored.isDirty)
        XCTAssertTrue(restored.noticeMessage?.hasPrefix("Recovered unsaved changes") ?? false)
    }

    func testUntitledDocumentsAreRecovered() async throws {
        let host = LifecycleTestHost()
        let window = TestWindowHandle()
        let document = makeDocument(host: host, window: window, path: nil)
        await document.loadIfNeeded()
        edit(document, to: "draft")
        await document.saveBeforeSuspension()
        XCTAssertTrue(host.files.isEmpty, "an untitled document has no file to autosave to")
        let restoredWindow = TestWindowHandle()
        restoredWindow.arguments = window.arguments
        let restored = makeDocument(host: host, window: restoredWindow, path: nil)
        await restored.loadIfNeeded()
        XCTAssertEqual(restored.editorView.text, "draft")
    }

    func testRecoveryStoreRejectsUnsafeIDsAndPrunesOrphans() {
        let store = EditorRecoveryStore(directory: recoveryDirectory)
        let record = EditorRecoveryRecord(path: nil, text: "x", savedAt: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(store.write(record, id: "../escape"))
        XCTAssertTrue(store.write(record, id: "old-orphan"))
        XCTAssertTrue(store.write(record, id: "kept"))
        XCTAssertTrue(store.write(EditorRecoveryRecord(path: nil, text: "y", savedAt: Date()), id: "fresh"))
        store.prune(keeping: ["kept"])
        XCTAssertNil(store.read("old-orphan"))
        XCTAssertNotNil(store.read("kept"))
        XCTAssertNotNil(store.read("fresh"), "a recent record may still belong to a window being restored")
    }

    func testFilesAreReplacedAtomically() {
        let command = AtomicWrite.command(for: "/root/it's here.txt")
        XCTAssertTrue(command.contains(#"p='/root/it'\''s here.txt'"#))
        XCTAssertTrue(command.contains("mktemp"))
        XCTAssertTrue(command.contains(#"mv -f -- "$tmp" "$p""#))
        XCTAssertLessThan(command.range(of: "sync")!.lowerBound, command.range(of: "mv -f")!.lowerBound,
                          "flushed before it replaces the file")
    }

    // MARK: Helpers

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
