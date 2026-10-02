import CoreGraphics
import Foundation

/// When the on-screen keyboard may push the focused window up, and when it must let go.
/// The window's own frame is never changed: the lift is applied only in
/// `WindowManager.displayFrame`, so clearing the state restores the exact original frame
/// (and the Linux surface gets a configure for its full size again).
struct KeyboardAvoidance: Equatable {
    /// Below this height the "keyboard" is iPadOS's shortcuts bar shown with a hardware keyboard.
    static let minimumKeyboardHeight: CGFloat = 100
    static let hardwareBarHeight: CGFloat = 200

    /// How far the docked keyboard reaches into the desktop; 0 when nothing avoids it.
    private(set) var overlap: CGFloat = 0
    /// The window that was focused when the keyboard came up; only it is lifted.
    private(set) var windowID: UUID?

    /// `keyboard` is the keyboard's end frame in desktop coordinates (nil or null: gone).
    mutating func keyboardChanged(to keyboard: CGRect?, desktop: CGRect, hardwareKeyboard: Bool, focusedWindow: UUID?) {
        // With a hardware keyboard iPadOS shows only the shortcuts bar (taller with
        // predictions); a full keyboard that does come up still covers the window.
        let minimumHeight = hardwareKeyboard ? Self.hardwareBarHeight : Self.minimumKeyboardHeight
        guard let keyboard, !keyboard.isNull, !keyboard.isEmpty, keyboard.height >= minimumHeight,
              // Floating, undocked and split keyboards do not sit on the bottom edge.
              keyboard.maxY >= desktop.maxY - 2,
              keyboard.minY < desktop.maxY else {
            reset()
            return
        }
        overlap = min(desktop.maxY - keyboard.minY, desktop.height)
        if windowID == nil { windowID = focusedWindow }
    }

    /// Keyboard hidden, focus moved to another window, window switch, app in background.
    mutating func reset() {
        overlap = 0
        windowID = nil
    }

    mutating func focusChanged(to id: UUID?) {
        if id != windowID { reset() }
    }

    func lifts(_ window: UUID) -> Bool {
        overlap > 0 && windowID == window
    }
}
