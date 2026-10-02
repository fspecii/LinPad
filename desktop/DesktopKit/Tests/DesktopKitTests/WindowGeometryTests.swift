import CoreGraphics
import XCTest
@testable import DesktopKit

final class WindowGeometryTests: XCTestCase {
    /// iPad Air 11" landscape below a 34 pt panel.
    private let air11 = CGSize(width: 1180, height: 786)
    private let air13 = CGSize(width: 1366, height: 990)

    func testHalvesAndQuartersTileTheDesktopExactly() {
        let bounds = CGSize(width: 1181, height: 787)
        let left = WindowGeometry.frame(for: .leftHalf, in: bounds)
        let right = WindowGeometry.frame(for: .rightHalf, in: bounds)
        XCTAssertEqual(left.maxX, right.minX)
        XCTAssertEqual(left.width + right.width, bounds.width)

        let quarters = [SnapZone.topLeft, .topRight, .bottomLeft, .bottomRight]
            .map { WindowGeometry.frame(for: $0, in: bounds) }
        XCTAssertEqual(quarters.map { $0.width * $0.height }.reduce(0, +), bounds.width * bounds.height)
        for (index, quarter) in quarters.enumerated() {
            for other in quarters[(index + 1)...] {
                XCTAssertTrue(quarter.intersection(other).isEmpty || quarter.intersection(other).width * quarter.intersection(other).height == 0)
            }
        }
        XCTAssertEqual(WindowGeometry.frame(for: .maximize, in: bounds), CGRect(origin: .zero, size: bounds))
    }

    func testSnapZonesFromPointer() {
        let zone = { (x: CGFloat, y: CGFloat) in WindowGeometry.snapZone(at: CGPoint(x: x, y: y), in: self.air11) }
        XCTAssertEqual(zone(600, 4), .maximize)
        XCTAssertEqual(zone(4, 400), .leftHalf)
        XCTAssertEqual(zone(1178, 400), .rightHalf)
        XCTAssertEqual(zone(4, 20), .topLeft)
        XCTAssertEqual(zone(30, 2), .topLeft)
        XCTAssertEqual(zone(1176, 10), .topRight)
        XCTAssertEqual(zone(5, 780), .bottomLeft)
        XCTAssertEqual(zone(1179, 770), .bottomRight)
        XCTAssertNil(zone(600, 400))
        XCTAssertNil(zone(40, 400))
        XCTAssertNil(WindowGeometry.snapZone(at: .zero, in: .zero))
    }

    func testClampKeepsTitleBarReachable() {
        let limits = WindowGeometry.Limits()
        let offLeft = WindowGeometry.clamped(CGRect(x: -2000, y: 100, width: 600, height: 400), in: air11)
        XCTAssertEqual(offLeft.maxX, limits.minimumVisibleWidth)
        let offRight = WindowGeometry.clamped(CGRect(x: 5000, y: 100, width: 600, height: 400), in: air11)
        XCTAssertEqual(offRight.minX, air11.width - limits.minimumVisibleWidth)
        let tooLow = WindowGeometry.clamped(CGRect(x: 100, y: 5000, width: 600, height: 400), in: air11)
        XCTAssertEqual(tooLow.minY, air11.height - limits.titleBarHeight - limits.bottomGestureInset)
        let aboveTop = WindowGeometry.clamped(CGRect(x: 100, y: -50, width: 600, height: 400), in: air11)
        XCTAssertEqual(aboveTop.minY, 0)
        let huge = WindowGeometry.clamped(CGRect(x: 0, y: 0, width: 5000, height: 5000), in: air11)
        XCTAssertEqual(huge.size, air11)
        let tiny = WindowGeometry.clamped(CGRect(x: 10, y: 10, width: 10, height: 10), in: air11)
        XCTAssertEqual(tiny.size, limits.minimumSize)
    }

    func testResizeFromEveryEdgeKeepsOppositeEdgesAndMinimums() {
        let origin = CGRect(x: 200, y: 150, width: 600, height: 400)
        let grow = CGSize(width: 50, height: 30)
        let shrink = CGSize(width: -50, height: -30)

        let right = WindowGeometry.resized(origin, edge: .right, translation: grow, in: air11)
        XCTAssertEqual(right, CGRect(x: 200, y: 150, width: 650, height: 400))
        let left = WindowGeometry.resized(origin, edge: .left, translation: shrink, in: air11)
        XCTAssertEqual(left, CGRect(x: 150, y: 150, width: 650, height: 400))
        let top = WindowGeometry.resized(origin, edge: .top, translation: shrink, in: air11)
        XCTAssertEqual(top, CGRect(x: 200, y: 120, width: 600, height: 430))
        let bottomRight = WindowGeometry.resized(origin, edge: .bottomRight, translation: grow, in: air11)
        XCTAssertEqual(bottomRight, CGRect(x: 200, y: 150, width: 650, height: 430))
        let topLeft = WindowGeometry.resized(origin, edge: .topLeft, translation: grow, in: air11)
        XCTAssertEqual(topLeft.maxX, origin.maxX)
        XCTAssertEqual(topLeft.maxY, origin.maxY)

        let collapsed = WindowGeometry.resized(origin, edge: .topLeft, translation: CGSize(width: 2000, height: 2000), in: air11)
        XCTAssertEqual(collapsed.size, WindowGeometry.Limits().minimumSize)
        XCTAssertEqual(collapsed.maxX, origin.maxX)
        XCTAssertEqual(collapsed.maxY, origin.maxY)

        let pastEdges = WindowGeometry.resized(origin, edge: .bottomRight, translation: CGSize(width: 5000, height: 5000), in: air11)
        XCTAssertEqual(pastEdges.maxX, air11.width)
        XCTAssertEqual(pastEdges.maxY, air11.height)
        let pastOrigin = WindowGeometry.resized(origin, edge: .topLeft, translation: CGSize(width: -5000, height: -5000), in: air11)
        XCTAssertEqual(pastOrigin.origin, .zero)
    }

    func testKeyboardAvoidanceLiftsThenShortens() {
        let frame = CGRect(x: 100, y: 400, width: 500, height: 300)
        let lifted = WindowGeometry.avoidingKeyboard(frame, availableHeight: 500, minimumHeight: 200)
        XCTAssertEqual(lifted, CGRect(x: 100, y: 200, width: 500, height: 300))
        let tall = CGRect(x: 0, y: 0, width: 500, height: 700)
        let shortened = WindowGeometry.avoidingKeyboard(tall, availableHeight: 450, minimumHeight: 200)
        XCTAssertEqual(shortened, CGRect(x: 0, y: 0, width: 500, height: 450))
        let clear = CGRect(x: 0, y: 0, width: 500, height: 300)
        XCTAssertEqual(WindowGeometry.avoidingKeyboard(clear, availableHeight: 450, minimumHeight: 200), clear)
    }

    func testTwoDefaultWindowsFitSideBySideInLandscape() {
        for bounds in [air11, air13] {
            let size = WindowGeometry.initialSize(preferred: CGSize(width: 760, height: 480), in: bounds)
            let first = WindowGeometry.placement(for: size, avoiding: [], in: bounds)
            let second = WindowGeometry.placement(for: size, avoiding: [first], in: bounds)
            XCTAssertTrue(first.intersection(second).isNull || first.intersection(second).width == 0,
                          "windows overlap in \(bounds)")
            XCTAssertGreaterThanOrEqual(first.minX, 0)
            XCTAssertLessThanOrEqual(second.maxX, bounds.width)
            XCTAssertGreaterThan(size.width, 520)
        }
    }

    func testThirdWindowCascades() {
        let size = WindowGeometry.initialSize(preferred: CGSize(width: 760, height: 480), in: air11)
        let first = WindowGeometry.placement(for: size, avoiding: [], in: air11)
        let second = WindowGeometry.placement(for: size, avoiding: [first], in: air11)
        let third = WindowGeometry.placement(for: size, avoiding: [first, second], in: air11)
        XCTAssertNotEqual(third.origin, first.origin)
        XCTAssertNotEqual(third.origin, second.origin)
        XCTAssertEqual(WindowGeometry.clamped(third, in: air11), third)
    }

    func testPortraitUsesFullWidthPreference() {
        let portrait = CGSize(width: 820, height: 1146)
        let size = WindowGeometry.initialSize(preferred: CGSize(width: 760, height: 480), in: portrait)
        XCTAssertEqual(size, CGSize(width: 760, height: 480))
    }

    func testOverviewLayoutFitsAreaAndKeepsAspect() {
        let frames = (0..<5).map { CGRect(x: CGFloat($0) * 50, y: 0, width: 600, height: 400) }
        let area = CGRect(x: 40, y: 140, width: 1100, height: 600)
        let layout = WindowGeometry.overviewLayout(for: frames, in: area)
        XCTAssertEqual(layout.count, frames.count)
        for (frame, tile) in zip(frames, layout) {
            XCTAssertTrue(area.insetBy(dx: -0.5, dy: -0.5).contains(tile))
            XCTAssertEqual(tile.width / tile.height, frame.width / frame.height, accuracy: 0.01)
        }
        for (index, tile) in layout.enumerated() {
            for other in layout[(index + 1)...] {
                XCTAssertLessThan(tile.intersection(other).width, 0.5)
            }
        }
        let single = WindowGeometry.overviewLayout(for: [CGRect(x: 0, y: 0, width: 300, height: 200)], in: area)
        XCTAssertEqual(single.first?.size, CGSize(width: 300, height: 200), "never scaled up")
    }
}
