import CoreGraphics
import XCTest
@testable import DesktopKit

final class TilingLayoutTests: XCTestCase {
    private let bounds = CGSize(width: 1180, height: 786)
    private let gap: CGFloat = 8

    private func assertNoOverlap(_ frames: [CGRect], file: StaticString = #filePath, line: UInt = #line) {
        for (index, frame) in frames.enumerated() {
            XCTAssertTrue(CGRect(origin: .zero, size: bounds).contains(frame), "\(frame) leaves the desktop",
                          file: file, line: line)
            for other in frames[(index + 1)...] {
                XCTAssertTrue(frame.intersection(other).isNull || frame.intersection(other).width * frame.intersection(other).height == 0,
                              "\(frame) overlaps \(other)", file: file, line: line)
            }
        }
    }

    func testMasterStackProgression() {
        let one = WindowGeometry.tileFrames(count: 1, layout: .masterStack, in: bounds, gap: gap)
        XCTAssertEqual(one, [CGRect(x: 8, y: 8, width: 1164, height: 770)])

        let two = WindowGeometry.tileFrames(count: 2, layout: .masterStack, in: bounds, gap: gap)
        XCTAssertEqual(two[0].minX, 8)
        XCTAssertEqual(two[1].maxX, 1172)
        XCTAssertEqual(two[1].minX - two[0].maxX, gap, accuracy: 1)
        XCTAssertEqual(two[0].width, two[1].width, accuracy: 1, "two windows split 50/50")
        XCTAssertEqual(two[0].height, two[1].height)

        let four = WindowGeometry.tileFrames(count: 4, layout: .masterStack, in: bounds, gap: gap)
        XCTAssertEqual(four[0].height, 770, "the master keeps the full height")
        XCTAssertEqual(Set(four[1...].map(\.minX)).count, 1, "the rest stack in one column")
        XCTAssertEqual(four[3].maxY, 778, accuracy: 1)
        assertNoOverlap(four)
    }

    func testMasterRatioMovesTheSplitAndIsClamped() {
        let wide = WindowGeometry.tileFrames(count: 2, layout: .masterStack, in: bounds, gap: gap, masterRatio: 0.7)
        XCTAssertGreaterThan(wide[0].width, wide[1].width * 2)
        let extreme = WindowGeometry.tileFrames(count: 2, layout: .masterStack, in: bounds, gap: gap, masterRatio: 0.99)
        let clamped = WindowGeometry.tileFrames(count: 2, layout: .masterStack, in: bounds, gap: gap, masterRatio: 0.8)
        XCTAssertEqual(extreme, clamped)

        let ratio = WindowGeometry.masterRatio(forSplitAt: wide[0].maxX, in: bounds, gap: gap)
        XCTAssertEqual(ratio, 0.7, accuracy: 0.01, "the split position maps back to the ratio")
    }

    func testColumnsGridAndMonocle() {
        let columns = WindowGeometry.tileFrames(count: 3, layout: .columns, in: bounds, gap: gap)
        let widths = columns.map(\.width)
        XCTAssertLessThanOrEqual(widths.max()! - widths.min()!, 1, "columns share the width")
        assertNoOverlap(columns)

        let grid = WindowGeometry.tileFrames(count: 5, layout: .grid, in: bounds, gap: gap)
        XCTAssertEqual(grid.count, 5)
        XCTAssertEqual(grid[3].width, grid[4].width, "a short last row stretches evenly")
        XCTAssertGreaterThan(grid[3].width, grid[0].width)
        assertNoOverlap(grid)

        let monocle = WindowGeometry.tileFrames(count: 3, layout: .monocle, in: bounds, gap: gap)
        XCTAssertEqual(Set(monocle).count, 1)
        XCTAssertTrue(WindowGeometry.tileFrames(count: 0, layout: .grid, in: bounds, gap: gap).isEmpty)
    }

    func testNeighborFinding() {
        let tiles = WindowGeometry.tileFrames(count: 3, layout: .masterStack, in: bounds, gap: gap)
        XCTAssertEqual(WindowGeometry.neighbor(of: tiles[0], in: tiles, dx: 1, dy: 0), 1)
        XCTAssertEqual(WindowGeometry.neighbor(of: tiles[1], in: tiles, dx: 0, dy: 1), 2)
        XCTAssertEqual(WindowGeometry.neighbor(of: tiles[2], in: tiles, dx: -1, dy: 0), 0)
        XCTAssertNil(WindowGeometry.neighbor(of: tiles[0], in: tiles, dx: -1, dy: 0))
    }
}

@MainActor
final class TilingManagerTests: XCTestCase {
    private var manager: WindowManager!

    override func setUp() async throws {
        manager = WindowManager()
        manager.updateDesktopSize(CGSize(width: 1180, height: 786))
    }

    @discardableResult
    private func open(_ appID: String) -> DesktopWindow {
        let window = manager.makeWindow(appID: appID, symbol: "app", title: appID,
                                        preferredSize: CGSize(width: 600, height: 400))
        manager.present(window)
        return window
    }

    func testOpeningClosingAndMinimizingRetiles() {
        manager.setTiling(true)
        let a = open("a")
        XCTAssertEqual(manager.displayFrame(for: a).width, 1160, "10 pt from each screen edge")
        let b = open("b")
        XCTAssertEqual(manager.displayFrame(for: a).width, manager.displayFrame(for: b).width, accuracy: 1)
        let c = open("c")
        XCTAssertEqual(manager.displayFrame(for: b).minX, manager.displayFrame(for: c).minX)
        manager.minimize(b.id)
        XCTAssertEqual(manager.displayFrame(for: c).height, 766, "c takes the whole stack")
        manager.close(c.id)
        XCTAssertEqual(manager.displayFrame(for: a).width, 1160, "10 pt from each screen edge")
    }

    func testTurningTilingOffRestoresFloatingFrames() {
        let a = open("a")
        let floating = a.frame
        manager.setTiling(true)
        XCTAssertNotEqual(manager.displayFrame(for: a), floating)
        manager.setTiling(false)
        XCTAssertEqual(manager.displayFrame(for: a), floating)
    }

    func testFloatingWindowLeavesLayoutAndStaysOnTop() {
        manager.setTiling(true)
        let a = open("a")
        let b = open("b")
        manager.toggleFloating(b.id)
        XCTAssertFalse(manager.isTiledByLayout(b))
        XCTAssertEqual(manager.displayFrame(for: a).width, 1160, "10 pt from each screen edge")
        manager.focus(a.id)
        XCTAssertEqual(manager.visibleStack().first?.id, b.id, "floats stay above tiles")
    }

    func testDragOntoAnotherTileSwaps() throws {
        manager.setTiling(true)
        let a = open("a")
        let b = open("b")
        let aTile = manager.displayFrame(for: a)
        let bTile = manager.displayFrame(for: b)
        let origin = try XCTUnwrap(manager.beginMove(a.id, pointer: CGPoint(x: aTile.midX, y: 20)))
        let target = CGPoint(x: bTile.midX, y: bTile.midY)
        manager.updateMove(a.id, from: origin, translation: CGSize(width: target.x - aTile.midX, height: 0), pointer: target)
        XCTAssertEqual(manager.snapPreview?.frame, bTile, "the drop target is previewed")
        manager.endMove(a.id, from: origin, pointer: target)
        XCTAssertEqual(manager.displayFrame(for: a), bTile)
        XCTAssertEqual(manager.displayFrame(for: b), aTile)
    }

    func testResizingMasterEdgeChangesRatio() throws {
        manager.setTiling(true)
        let a = open("a")
        _ = open("b")
        let origin = try XCTUnwrap(manager.beginResize(a.id))
        manager.updateResize(a.id, from: origin, edge: .right, translation: CGSize(width: 200, height: 0))
        manager.endResize(a.id)
        XCTAssertGreaterThan(manager.tiling[0].masterRatio, 0.6)
        XCTAssertEqual(manager.displayFrame(for: a).maxX, origin.maxX + 200, accuracy: 2)
    }

    func testKeyboardTileNavigationAndMove() {
        manager.setTiling(true)
        let a = open("a")
        let b = open("b")
        let c = open("c")
        manager.focus(a.id)
        manager.focusTile(dx: 1, dy: 0)
        XCTAssertNotEqual(manager.focusedWindowID, a.id)
        manager.focus(b.id)
        manager.focusTile(dx: 0, dy: 1)
        XCTAssertEqual(manager.focusedWindowID, c.id)
        let cTile = manager.displayFrame(for: c)
        manager.moveTile(dx: -1, dy: 0)
        XCTAssertEqual(manager.displayFrame(for: a), cTile)
        XCTAssertEqual(manager.focusedWindowID, c.id)
    }

    func testTilingIsPerWorkspace() {
        manager.setTiling(true)
        let a = open("a")
        manager.switchToWorkspace(1)
        let b = open("b")
        XCTAssertTrue(manager.isTiledByLayout(a))
        XCTAssertFalse(manager.isTiledByLayout(b))
        manager.setTilingLayout(.columns)
        XCTAssertTrue(manager.isTiling(workspace: 1))
        XCTAssertEqual(manager.tiling[0].layout, .masterStack)
    }
}
