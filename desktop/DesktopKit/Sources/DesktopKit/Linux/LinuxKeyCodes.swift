import UIKit

/// USB HID keyboard usages (what `UIKey.keyCode` holds) to Linux evdev key codes,
/// the same table Linux's hid-input uses. ishwl turns evdev codes into keysyms
/// with an XKB "us" keymap, so layout handling stays on the Linux side.
enum LinuxKeyCodes {
    static let backspace: UInt32 = 14
    static let enter: UInt32 = 28
    static let tab: UInt32 = 15
    static let leftControl: UInt32 = 29

    static func evdev(for usage: UIKeyboardHIDUsage) -> UInt32? {
        let raw = usage.rawValue
        // Left Command acts as Control, so Cmd-C / Cmd-V / Cmd-S do what an iPad user
        // expects; right Command stays Super for Linux shortcuts that need it.
        if raw == 0xE3 { return leftControl }
        if raw >= 0xE0 && raw <= 0xE7 {
            return modifierTable[raw - 0xE0]
        }
        guard raw < mainTable.count else { return nil }
        let code = mainTable[raw]
        return code == 0 ? nil : UInt32(code)
    }

    private static let modifierTable: [UInt32] = [29, 42, 56, 125, 97, 54, 100, 126]

    private static let mainTable: [UInt8] = [
        0, 0, 0, 0, 30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38,
        50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44, 2, 3,
        4, 5, 6, 7, 8, 9, 10, 11, 28, 1, 14, 15, 57, 12, 13, 26,
        27, 43, 43, 39, 40, 41, 51, 52, 53, 58, 59, 60, 61, 62, 63, 64,
        65, 66, 67, 68, 87, 88, 99, 70, 119, 110, 102, 104, 111, 107, 109, 106,
        105, 108, 103, 69, 98, 55, 74, 78, 96, 79, 80, 81, 75, 76, 77, 71,
        72, 73, 82, 83, 86, 127, 116, 117,
    ]
}
