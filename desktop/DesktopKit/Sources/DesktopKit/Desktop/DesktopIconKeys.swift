import Foundation

/// Keys the desktop's icons respond to when the desktop has focus.
enum DesktopIconKey: Equatable {
    case move(dx: Int, dy: Int)
    case open
    case trash
    case rename
    case selectAll
}
