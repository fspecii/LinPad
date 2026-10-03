import XCTest
@testable import DesktopKit

@MainActor
final class DockTapTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    private func window(_ id: UUID, minimized: Bool = false) -> DockTapAction.Window {
        .init(id: id, isMinimized: minimized)
    }

    func testNotRunningLaunches() {
        XCTAssertEqual(DockTapAction.resolve([], focused: nil), .launch)
        XCTAssertEqual(DockTapAction.resolve([], focused: a), .launch)
    }

    func testRunningBehindOthersComesForward() {
        XCTAssertEqual(DockTapAction.resolve([window(a)], focused: b), .focus(a))
        XCTAssertEqual(DockTapAction.resolve([window(a)], focused: nil), .focus(a))
    }

    func testFrontmostSingleWindowMinimizes() {
        XCTAssertEqual(DockTapAction.resolve([window(a)], focused: a), .minimize(a))
    }

    func testMinimizedRestores() {
        XCTAssertEqual(DockTapAction.resolve([window(a, minimized: true)], focused: nil), .focus(a))
        // A minimized window is never "in front", even if focus still names it.
        XCTAssertEqual(DockTapAction.resolve([window(a, minimized: true)], focused: a), .focus(a))
    }

    func testSeveralWindowsPreferTheMostRecentVisibleOne() {
        XCTAssertEqual(DockTapAction.resolve([window(a, minimized: true), window(b), window(c)], focused: nil), .focus(b))
    }

    func testSeveralWindowsCycleInsteadOfMinimizing() {
        XCTAssertEqual(DockTapAction.resolve([window(a), window(b), window(c)], focused: a), .focus(c))
    }

    // MARK: Through the window manager

    private func makeController() -> DesktopController {
        DesktopController(host: MockLinuxHost(latency: .zero), apps: BuiltinApps.all())
    }

    private func present(_ appID: String, in controller: DesktopController) -> DesktopWindow {
        let window = controller.windowManager.makeWindow(appID: appID, symbol: "macwindow", title: appID,
                                                         preferredSize: CGSize(width: 400, height: 300))
        controller.windowManager.present(window)
        return window
    }

    func testTapFocusMinimizeRestoreForALinuxWindow() {
        let controller = makeController()
        let manager = controller.windowManager
        let firefox = present("linux:firefox", in: controller)
        let other = present("files", in: controller)
        XCTAssertEqual(manager.focusedWindowID, other.id)

        controller.activateApp("linux:firefox")
        XCTAssertEqual(manager.focusedWindowID, firefox.id, "behind another window: comes forward")
        controller.activateApp("linux:firefox")
        XCTAssertTrue(firefox.isMinimized, "in front: minimizes")
        controller.activateApp("linux:firefox")
        XCTAssertFalse(firefox.isMinimized, "minimized: restores")
        XCTAssertEqual(manager.focusedWindowID, firefox.id)
    }

    func testTapSwitchesToTheWindowsWorkspace() {
        let controller = makeController()
        let manager = controller.windowManager
        let firefox = present("linux:firefox", in: controller)
        manager.move(firefox.id, toWorkspace: 1)
        manager.switchToWorkspace(0)
        controller.activateApp("linux:firefox")
        XCTAssertEqual(manager.currentWorkspace, 1)
        XCTAssertEqual(manager.focusedWindowID, firefox.id)
    }

    func testRepeatedTapsVisitEveryWindowOfTheApp() {
        let controller = makeController()
        let manager = controller.windowManager
        let windows = (0..<3).map { _ in present("terminal", in: controller) }
        var visited = Set<UUID>()
        for _ in 0..<3 {
            controller.activateApp("terminal")
            visited.insert(manager.focusedWindowID!)
        }
        XCTAssertEqual(visited, Set(windows.map(\.id)))
        XCTAssertFalse(windows.contains(where: \.isMinimized), "several windows never minimize")
    }
}
