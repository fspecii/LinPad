import CoreGraphics
import XCTest
@testable import DesktopKit

@MainActor
final class WindowManagerTests: XCTestCase {
    private var manager: WindowManager!

    override func setUp() async throws {
        manager = WindowManager()
        manager.updateDesktopSize(CGSize(width: 1180, height: 786))
    }

    @discardableResult
    private func open(_ appID: String = "app", size: CGSize = CGSize(width: 600, height: 400)) -> DesktopWindow {
        let window = manager.makeWindow(appID: appID, symbol: "app", title: appID, preferredSize: size)
        manager.present(window)
        return window
    }

    func testNewWindowIsFocusedAndOnTop() {
        let first = open("a")
        let second = open("b")
        XCTAssertEqual(manager.focusedWindowID, second.id)
        XCTAssertEqual(manager.visibleStack().map(\.id), [second.id, first.id])
    }

    func testCloseAndMinimizeReturnFocusToPreviouslyFocusedWindow() {
        let a = open("a")
        let b = open("b")
        let c = open("c")
        manager.focus(a.id)
        manager.focus(c.id)
        manager.close(c.id)
        XCTAssertEqual(manager.focusedWindowID, a.id, "most recently focused, not topmost")
        manager.minimize(a.id)
        XCTAssertEqual(manager.focusedWindowID, b.id)
        manager.minimize(b.id)
        XCTAssertNil(manager.focusedWindowID)
    }

    func testSnapKeyboardCommandsAndToggleBack() {
        let window = open()
        manager.snap(window.id, to: .leftHalf)
        XCTAssertEqual(manager.displayFrame(for: window), CGRect(x: 0, y: 0, width: 590, height: 786))
        manager.snap(window.id, to: .topRight)
        XCTAssertEqual(manager.displayFrame(for: window), CGRect(x: 590, y: 0, width: 590, height: 393))
        manager.snap(window.id, to: .topRight)
        XCTAssertNil(window.snap, "snapping to the current zone restores the window")
        manager.snap(window.id, to: .maximize)
        XCTAssertTrue(window.isMaximized)
        manager.restoreOrMinimize(window.id)
        XCTAssertFalse(window.isTiled)
        manager.restoreOrMinimize(window.id)
        XCTAssertTrue(window.isMinimized)
    }

    func testDraggingTiledWindowRestoresFloatingSizeUnderPointer() {
        let window = open()
        let floating = window.frame
        manager.snap(window.id, to: .leftHalf)
        let origin = manager.beginMove(window.id, pointer: CGPoint(x: 295, y: 20))
        XCTAssertEqual(origin?.size, floating.size)
        XCTAssertFalse(window.isTiled)
        XCTAssertTrue(window.isInteracting)
        XCTAssertEqual(origin.map { ($0.minX + $0.width / 2).rounded() }, 295, "grab point keeps its relative position")
    }

    func testDragToEdgeSnapsAndShowsPreview() throws {
        let window = open()
        let origin = try XCTUnwrap(manager.beginMove(window.id, pointer: CGPoint(x: 400, y: 200)))
        manager.updateMove(window.id, from: origin, translation: CGSize(width: -398, height: 0), pointer: CGPoint(x: 2, y: 200))
        XCTAssertEqual(manager.snapPreview?.frame, WindowGeometry.frame(for: .leftHalf, in: manager.desktopSize))
        manager.endMove(window.id, from: origin, pointer: CGPoint(x: 2, y: 200))
        XCTAssertEqual(window.snap, .leftHalf)
        XCTAssertEqual(window.frame, origin, "the floating frame is kept for restore")
        XCTAssertNil(manager.snapPreview)
        XCTAssertFalse(window.isInteracting)
    }

    func testResizeFromLeftEdge() throws {
        let window = open()
        window.frame.origin.x = 200
        let origin = try XCTUnwrap(manager.beginResize(window.id))
        manager.updateResize(window.id, from: origin, edge: .left, translation: CGSize(width: -40, height: 0))
        manager.endResize(window.id)
        XCTAssertEqual(window.frame.minX, origin.minX - 40)
        XCTAssertEqual(window.frame.maxX, origin.maxX)
    }

    func testWorkspacesCanBeAddedUpToNineAndNamed() {
        XCTAssertEqual(manager.workspaceCount, WindowManager.defaultWorkspaceCount)
        while manager.addWorkspace() != nil {}
        XCTAssertEqual(manager.workspaceCount, WindowManager.maximumWorkspaces)
        XCTAssertEqual(manager.tiling.count, WindowManager.maximumWorkspaces, "every workspace has its tiling state")
        manager.renameWorkspace(8, to: "  Mail ")
        XCTAssertEqual(manager.title(ofWorkspace: 8), "Mail")
        XCTAssertEqual(manager.title(ofWorkspace: 7), "Workspace 8")
    }

    func testDeletingAWorkspaceMovesItsWindowsToTheNeighbour() {
        let a = open("a")
        let b = open("b")
        let c = open("c")
        manager.move(b.id, toWorkspace: 2)
        manager.move(c.id, toWorkspace: 3)
        manager.setTiling(true, workspace: 3)
        var remapped: [Int: Int]?
        manager.onWorkspacesRemapped = { remapped = $0 }
        manager.switchToWorkspace(2)
        manager.removeWorkspace(2)
        XCTAssertEqual(manager.workspaceCount, 3)
        XCTAssertEqual(b.workspace, 1, "the deleted workspace's windows go to the previous one")
        XCTAssertEqual(c.workspace, 2, "later workspaces shift down")
        XCTAssertTrue(manager.isTiling(workspace: 2), "tiling moves with its workspace")
        XCTAssertEqual(manager.currentWorkspace, 1)
        XCTAssertEqual(remapped, [0: 0, 1: 1, 3: 2])
        manager.removeWorkspace(0)
        XCTAssertEqual(a.workspace, 0, "deleting the first sends its windows to the next")
        manager.removeWorkspace(0)
        manager.removeWorkspace(0)
        XCTAssertEqual(manager.workspaceCount, 1, "the last workspace stays")
    }

    func testReorderingWorkspacesCarriesWindowsNamesAndTiling() {
        let a = open("a")
        let b = open("b")
        manager.move(b.id, toWorkspace: 3)
        manager.renameWorkspace(3, to: "Code")
        manager.setTiling(true, workspace: 3)
        manager.moveWorkspace(from: 3, to: 0)
        XCTAssertEqual(b.workspace, 0)
        XCTAssertEqual(a.workspace, 1)
        XCTAssertEqual(manager.title(ofWorkspace: 0), "Code")
        XCTAssertTrue(manager.isTiling(workspace: 0))
        XCTAssertFalse(manager.isTiling(workspace: 3))
        XCTAssertEqual(manager.currentWorkspace, 1, "the current workspace follows its content")
        manager.switchToWorkspace(0)
        XCTAssertEqual(manager.focusedWindowID, b.id, "⌃⌥1 now reaches the moved workspace")
    }

    func testWorkspacesRoundTripThroughTheSession() throws {
        manager.addWorkspace()
        manager.renameWorkspace(4, to: "Music")
        let snapshot = DesktopSessionSnapshot(manager: manager)
        let decoded = try JSONDecoder().decode(DesktopSessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        let restored = WindowManager()
        restored.restoreWorkspaces(names: try XCTUnwrap(decoded.workspaceNames))
        XCTAssertEqual(restored.workspaceCount, 5)
        XCTAssertEqual(restored.title(ofWorkspace: 4), "Music")
    }

    func testWorkspacesMoveAndSwitch() {
        let a = open("a")
        let b = open("b")
        manager.move(b.id, toWorkspace: 2)
        XCTAssertEqual(manager.focusedWindowID, a.id)
        XCTAssertFalse(manager.isVisible(b))
        manager.switchToWorkspace(2)
        XCTAssertEqual(manager.focusedWindowID, b.id)
        manager.switchWorkspace(by: 2)
        XCTAssertEqual(manager.currentWorkspace, 0)
        manager.switchWorkspace(by: -1)
        XCTAssertEqual(manager.currentWorkspace, 3)
        manager.focus(b.id)
        XCTAssertEqual(manager.currentWorkspace, 2, "focusing a window follows it to its workspace")
    }

    func testAlwaysOnTopStaysAboveRaisedWindows() {
        let pinned = open("pinned")
        manager.toggleAlwaysOnTop(pinned.id)
        let other = open("other")
        manager.focus(other.id)
        XCTAssertEqual(manager.visibleStack().first?.id, pinned.id)
    }

    func testSwitcherOrderIsMostRecentFirst() {
        let a = open("a")
        let b = open("b")
        let c = open("c")
        manager.focus(a.id)
        manager.minimize(b.id)
        XCTAssertEqual(manager.recentWindowsInCurrentWorkspace().map(\.id), [a.id, c.id, b.id])
    }

    func testKeyboardOverlapLiftsOnlyFocusedWindow() {
        let a = open("a", size: CGSize(width: 500, height: 300))
        let b = open("b", size: CGSize(width: 500, height: 300))
        b.frame = CGRect(x: 600, y: 450, width: 500, height: 300)
        a.frame = CGRect(x: 0, y: 450, width: 500, height: 300)
        manager.updateKeyboardOverlap(400)
        XCTAssertEqual(manager.displayFrame(for: b).maxY, 386)
        XCTAssertEqual(manager.displayFrame(for: a), a.frame)
        manager.updateKeyboardOverlap(0)
        XCTAssertEqual(manager.displayFrame(for: b), b.frame)
    }

    func testDesktopResizeKeepsWindowsReachable() {
        let window = open()
        window.frame = CGRect(x: 1000, y: 600, width: 600, height: 400)
        manager.updateDesktopSize(CGSize(width: 700, height: 500))
        XCTAssertLessThanOrEqual(window.frame.minX, 700 - WindowGeometry.Limits().minimumVisibleWidth)
        XCTAssertLessThanOrEqual(window.frame.minY, 500 - WindowManager.titleBarHeight)
    }

    func testRestoredPlacementIsAppliedToNextWindowOfThatApp() {
        let placement = WindowPlacement(frame: CGRect(x: 50, y: 60, width: 500, height: 350), workspace: 1,
                                        snap: .rightHalf, isMaximized: false, isMinimized: false, isAlwaysOnTop: true)
        manager.enqueuePlacement(placement, forAppID: "files")
        let restored = open("files")
        XCTAssertEqual(manager.placement(of: restored), placement)
        let fresh = open("files")
        XCTAssertEqual(fresh.workspace, 0)
        XCTAssertNil(fresh.snap)
    }

    func testSessionSnapshotRoundTripsAndDropsCommands() throws {
        let window = manager.makeWindow(appID: "terminal", symbol: "terminal", title: "Terminal",
                                        preferredSize: CGSize(width: 600, height: 400),
                                        arguments: [AppArgument.command: "make clean", AppArgument.cwd: "/root/app"])
        manager.present(window)
        manager.snap(window.id, to: .bottomLeft)
        let snapshot = DesktopSessionSnapshot(manager: manager)
        let decoded = try JSONDecoder().decode(DesktopSessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.windows.first?.arguments, [AppArgument.cwd: "/root/app"])
        XCTAssertEqual(decoded.windows.first?.placement.snap, .bottomLeft)
    }
}
