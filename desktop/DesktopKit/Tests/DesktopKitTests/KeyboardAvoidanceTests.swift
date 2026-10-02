import CoreGraphics
import XCTest
@testable import DesktopKit

final class KeyboardAvoidanceTests: XCTestCase {
    private let desktop = CGRect(x: 0, y: 0, width: 1180, height: 760)
    private let window = UUID()

    private func docked(_ height: CGFloat) -> CGRect {
        CGRect(x: 0, y: desktop.maxY - height, width: desktop.width, height: height)
    }

    func testDockedKeyboardLiftsTheFocusedWindowAndHidingRestoresIt() {
        var state = KeyboardAvoidance()
        state.keyboardChanged(to: docked(340), desktop: desktop, hardwareKeyboard: false, focusedWindow: window)
        XCTAssertEqual(state.overlap, 340)
        XCTAssertTrue(state.lifts(window))
        state.keyboardChanged(to: nil, desktop: desktop, hardwareKeyboard: false, focusedWindow: window)
        XCTAssertEqual(state, KeyboardAvoidance(), "keyboard gone: nothing lifted")
        state.keyboardChanged(to: docked(340), desktop: desktop, hardwareKeyboard: false, focusedWindow: window)
        state.reset()
        XCTAssertFalse(state.lifts(window), "will-hide or background resets")
    }

    func testHardwareKeyboardAndShortcutBarNeverMoveWindows() {
        var state = KeyboardAvoidance()
        state.keyboardChanged(to: docked(120), desktop: desktop, hardwareKeyboard: true, focusedWindow: window)
        XCTAssertEqual(state.overlap, 0, "the shortcuts bar with predictions")
        state.keyboardChanged(to: docked(340), desktop: desktop, hardwareKeyboard: true, focusedWindow: window)
        XCTAssertEqual(state.overlap, 340, "a full keyboard on screen still covers the window")
        state.reset()
        state.keyboardChanged(to: docked(55), desktop: desktop, hardwareKeyboard: false, focusedWindow: window)
        XCTAssertEqual(state.overlap, 0, "the shortcuts bar is not a keyboard")
    }

    func testFloatingAndUndockedKeyboardsAreIgnored() {
        var state = KeyboardAvoidance()
        let floating = CGRect(x: 400, y: 300, width: 320, height: 260)
        state.keyboardChanged(to: floating, desktop: desktop, hardwareKeyboard: false, focusedWindow: window)
        XCTAssertEqual(state.overlap, 0)
        state.keyboardChanged(to: docked(340), desktop: desktop, hardwareKeyboard: false, focusedWindow: window)
        state.keyboardChanged(to: floating, desktop: desktop, hardwareKeyboard: false, focusedWindow: window)
        XCTAssertEqual(state.overlap, 0, "undocking releases the window")
        let offscreen = CGRect(x: 0, y: desktop.maxY, width: desktop.width, height: 340)
        state.keyboardChanged(to: offscreen, desktop: desktop, hardwareKeyboard: false, focusedWindow: window)
        XCTAssertEqual(state.overlap, 0, "an end frame below the screen means hidden")
    }

    func testFocusChangeReleasesTheLiftedWindow() {
        var state = KeyboardAvoidance()
        state.keyboardChanged(to: docked(340), desktop: desktop, hardwareKeyboard: false, focusedWindow: window)
        state.focusChanged(to: window)
        XCTAssertTrue(state.lifts(window))
        let other = UUID()
        state.focusChanged(to: other)
        XCTAssertFalse(state.lifts(window))
        XCTAssertFalse(state.lifts(other))
        XCTAssertEqual(state.overlap, 0)
    }

    func testWindowsMoveUpBeforeTheyShrinkAndNeverBelowTheMinimum() {
        let small = CGRect(x: 100, y: 400, width: 600, height: 300)
        let moved = WindowGeometry.avoidingKeyboard(small, availableHeight: 420, minimumHeight: 200)
        XCTAssertEqual(moved, CGRect(x: 100, y: 120, width: 600, height: 300), "moved up, same size")
        let tall = CGRect(x: 0, y: 0, width: 1180, height: 760)
        XCTAssertEqual(WindowGeometry.avoidingKeyboard(tall, availableHeight: 420, minimumHeight: 200).height, 420)
        let squeezed = WindowGeometry.avoidingKeyboard(tall, availableHeight: 150, minimumHeight: 200)
        XCTAssertEqual(squeezed.height, WindowGeometry.keyboardMinimumHeight, "no smaller than the floor")
        XCTAssertEqual(squeezed.minY, 0)
    }

    @MainActor
    func testWindowManagerRestoresTheExactFrame() {
        let manager = WindowManager()
        manager.updateDesktopSize(desktop.size)
        let window = manager.makeWindow(appID: "firefox", symbol: "globe", title: "Firefox", preferredSize: CGSize(width: 900, height: 700))
        manager.present(window)
        let original = manager.displayFrame(for: window)
        manager.updateKeyboard(docked(380), hardwareKeyboard: false)
        XCTAssertLessThan(manager.displayFrame(for: window).maxY, original.maxY)
        XCTAssertEqual(window.frame, original, "the window's own frame is untouched")
        manager.resetKeyboard()
        XCTAssertEqual(manager.displayFrame(for: window), original)

        manager.updateKeyboard(docked(380), hardwareKeyboard: false)
        let other = manager.makeWindow(appID: "files", symbol: "folder", title: "Files", preferredSize: CGSize(width: 400, height: 300))
        manager.present(other)
        XCTAssertEqual(manager.displayFrame(for: window), original, "switching windows releases the lift")
    }
}

final class WindowRotationTests: XCTestCase {
    func testWindowsThatFitComeBackOnScreen() {
        let frame = CGRect(x: -130, y: 137, width: 952, height: 680)
        XCTAssertEqual(WindowGeometry.keptOnScreen(frame, in: CGSize(width: 1366, height: 990)),
                       CGRect(x: 0, y: 137, width: 952, height: 680))
        let wide = CGRect(x: -50, y: 0, width: 1400, height: 300)
        XCTAssertEqual(WindowGeometry.keptOnScreen(wide, in: CGSize(width: 1366, height: 990)).minX, -50,
                       "too wide to fit: left as clamped")
    }
}
