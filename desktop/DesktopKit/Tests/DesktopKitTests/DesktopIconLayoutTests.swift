import CoreGraphics
import XCTest
@testable import DesktopKit

final class DesktopIconLayoutTests: XCTestCase {
    private let size = CGSize(width: 1000, height: 16 * 2 + 300)
    private let keys = ["a", "b", "c", "d"]

    func testSnappedDragLandsOnTheCellUnderTheIcon() {
        var layout = DesktopIconLayout()
        layout.drag(["a"], by: CGSize(width: 96 * 3 + 20, height: 100 + 10), allKeys: keys, in: size)
        XCTAssertEqual(layout.resolved(keys, in: size)["a"], .init(column: 3, row: 1))
        XCTAssertEqual(layout.positions(keys, in: size)["a"], CGPoint(x: 16 + 96 * 3, y: 16 + 100))
    }

    func testGroupDragKeepsEveryIconAndSkipsOccupiedCells() {
        var layout = DesktopIconLayout()
        layout.drag(["a", "b"], by: CGSize(width: 96, height: 0), allKeys: keys, in: size)
        let cells = layout.resolved(keys, in: size)
        XCTAssertEqual(Set(cells.values).count, keys.count, "no two icons share a cell")
        XCTAssertEqual(cells["a"]?.column, 1)
        XCTAssertNotEqual(cells["b"], cells["d"])
    }

    func testFreePlacementKeepsTheDropPointAndNeverOverlaps() {
        var layout = DesktopIconLayout()
        layout.snapsToGrid = false
        layout.drag(["a"], by: CGSize(width: 333, height: 41), allKeys: keys, in: size)
        let positions = layout.positions(keys, in: size)
        XCTAssertEqual(positions["a"], CGPoint(x: 16 + 333, y: 16 + 41))

        let onB = CGSize(width: positions["b"]!.x - positions["a"]!.x, height: positions["b"]!.y - positions["a"]!.y)
        layout.drag(["a"], by: onB, allKeys: keys, in: size)
        let after = layout.positions(keys, in: size)
        let rects = keys.map { CGRect(origin: after[$0]!, size: layout.cellSize).insetBy(dx: 4, dy: 4) }
        for i in rects.indices {
            for j in rects.indices where i < j {
                XCTAssertFalse(rects[i].intersects(rects[j]), "\(keys[i]) overlaps \(keys[j])")
            }
        }
    }

    func testAlignToGridSnapsFreeIcons() {
        var layout = DesktopIconLayout()
        layout.snapsToGrid = false
        layout.drag(["a"], by: CGSize(width: 96 * 4 + 30, height: 100 + 20), allKeys: keys, in: size)
        layout.alignToGrid(keys, in: size)
        layout.snapsToGrid = true
        XCTAssertEqual(layout.resolved(keys, in: size)["a"], .init(column: 4, row: 1))
        XCTAssertTrue(layout.free.isEmpty)
    }

    func testIconsOffASmallerScreenFlowBackOn() {
        var layout = DesktopIconLayout()
        layout.move(["a"], to: .init(column: 9, row: 2), allKeys: keys, in: size)
        let portrait = CGSize(width: 16 * 2 + 96 * 3, height: 16 * 2 + 300)
        let cell = layout.resolved(keys, in: portrait)["a"]!
        XCTAssertLessThan(cell.column, 3)
    }

    func testLayoutsPersistPerContext() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DesktopIconLayoutTests"))
        defer { defaults.removePersistentDomain(forName: "DesktopIconLayoutTests") }
        var layout = DesktopIconLayout()
        layout.move(["a"], to: .init(column: 2, row: 2), allKeys: keys, in: size)
        layout.snapsToGrid = false
        layout.keepsArranged = .type
        layout.save(context: "macos.1000x332", to: defaults)

        let loaded = DesktopIconLayout.load(context: "macos.1000x332", from: defaults)
        XCTAssertEqual(loaded.cells["a"], .init(column: 2, row: 2))
        XCTAssertFalse(loaded.snapsToGrid)
        XCTAssertEqual(loaded.keepsArranged, .type)

        let other = DesktopIconLayout.load(context: "windows.1000x332", from: defaults)
        XCTAssertTrue(other.snapsToGrid, "another style starts from the default layout")

        DesktopIconLayout.reset(in: defaults)
        XCTAssertNil(DesktopIconLayout.load(context: "macos.1000x332", from: defaults).cells["a"])
    }

    func testIconSizeChangesTheGrid() {
        var layout = DesktopIconLayout()
        layout.iconSize = .large
        XCTAssertEqual(layout.origin(of: .init(column: 1, row: 1)), CGPoint(x: 16 + 120, y: 16 + 124))
        XCTAssertEqual(layout.rows(in: size), 2)
    }
}
