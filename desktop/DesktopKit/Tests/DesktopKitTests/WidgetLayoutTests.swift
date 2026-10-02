import CoreGraphics
import XCTest
@testable import DesktopKit

final class WidgetLayoutTests: XCTestCase {
    private let grid = WidgetGrid(columns: 24, rows: 16)

    func testAddedWidgetsFillFromTheRightWithoutOverlapping() {
        var board = WidgetBoard()
        let clock = board.add(.clock, workspace: 0, grid: grid)
        let weather = board.add(.weather, workspace: 0, grid: grid)
        XCTAssertEqual(clock.frame, WidgetFrame(x: 20, y: 0, width: 4, height: 4))
        XCTAssertFalse(clock.frame.intersects(weather.frame))
        XCTAssertEqual(board.widgets(workspace: 0).count, 2)
    }

    func testMoveClampsToTheGridAndBringsTheWidgetToTheFront() {
        var board = WidgetBoard()
        let first = board.add(.clock, workspace: 0, grid: grid)
        board.add(.notes, workspace: 0, grid: grid)
        board.move(first.id, toX: 30, y: -3, workspace: 0, grid: grid)
        let moved = board.widgets(workspace: 0).last
        XCTAssertEqual(moved?.id, first.id)
        XCTAssertEqual(moved?.frame, WidgetFrame(x: 20, y: 0, width: 4, height: 4))
    }

    func testResizeRespectsTheKindsLimits() {
        var board = WidgetBoard()
        let nowPlaying = board.add(.nowPlaying, workspace: 0, grid: grid)
        board.resize(nowPlaying.id, to: WidgetSize(width: 1, height: 40), workspace: 0, grid: grid)
        let frame = board.widgets(workspace: 0)[0].frame
        XCTAssertEqual(frame.size, WidgetSize(width: DesktopWidgetKind.nowPlaying.minimumSize.width,
                                              height: DesktopWidgetKind.nowPlaying.maximumSize.height))
    }

    func testSnapRoundsToTheNearestCell() {
        let cell = grid.cell(at: CGPoint(x: WidgetGrid.margin + WidgetGrid.cell * 3 + 25, y: WidgetGrid.margin + 10))
        XCTAssertEqual(cell.x, 4)
        XCTAssertEqual(cell.y, 0)
    }

    func testFramesSavedOnALargerScreenDrawInsideASmallerOne() {
        let small = WidgetGrid(columns: 10, rows: 8)
        let rect = small.rect(for: WidgetFrame(x: 20, y: 12, width: 4, height: 4))
        XCTAssertEqual(rect.maxX, WidgetGrid.margin + 10 * WidgetGrid.cell)
        XCTAssertEqual(rect.maxY, WidgetGrid.margin + 8 * WidgetGrid.cell)
    }

    func testPerWorkspaceScopeKeepsSeparateSetsAndSwitchingKeepsWhatIsOnScreen() {
        var board = WidgetBoard()
        board.add(.clock, workspace: 0, grid: grid)
        board.setScope(.perWorkspace, currentWorkspace: 1)
        XCTAssertEqual(board.widgets(workspace: 1).map(\.kind), [.clock])
        XCTAssertTrue(board.widgets(workspace: 0).isEmpty)
        board.add(.battery, workspace: 0, grid: grid)
        board.setScope(.global, currentWorkspace: 0)
        XCTAssertEqual(board.widgets(workspace: 5).map(\.kind), [.battery])
    }

    @MainActor
    func testStorePersistsAcrossInstances() throws {
        let suite = "widgets-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = DesktopWidgetStore(defaults: defaults)
        store.grid = grid
        let widget = store.add(.notes, workspace: 0)
        store.move(widget.id, toX: 3, y: 2, workspace: 0)
        store.setOption("text", "milk, eggs", for: widget.id, workspace: 0)

        let reloaded = DesktopWidgetStore(defaults: defaults).widgets(workspace: 0)
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded[0].frame.x, 3)
        XCTAssertEqual(reloaded[0].frame.y, 2)
        XCTAssertEqual(reloaded[0].options["text"], "milk, eggs")
    }

    @MainActor
    func testResetFlagStartsEmpty() throws {
        let suite = "widgets-reset-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        DesktopWidgetStore(defaults: defaults).add(.clock, workspace: 0)
        defaults.set(true, forKey: WidgetBoard.resetKey)
        XCTAssertTrue(DesktopWidgetStore(defaults: defaults).widgets(workspace: 0).isEmpty)
    }

    func testDiskUsageParsesPosixDf() {
        let output = """
            Filesystem     1024-blocks      Used Available Capacity Mounted on
            rootfs            61255492  20418496  40837000      34% /
            """
        let usage = DiskUsageMonitor.parse(output)
        XCTAssertEqual(usage?.totalBytes, 61_255_492 * 1024)
        XCTAssertEqual(usage?.fraction ?? 0, 20_418_496.0 / 61_255_492.0, accuracy: 0.0001)
        XCTAssertNil(DiskUsageMonitor.parse("df: /: No such file"))
    }
}
