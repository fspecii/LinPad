import UIKit

/// USB HID keyboard usages (what `UIKey.keyCode` holds) to Linux evdev key codes,
/// the same table Linux's hid-input uses. ishwl turns evdev codes into keysyms with
/// the XKB layout LinuxKeyboardLayoutMonitor picks, so keys travel by position and the
/// layout is applied on the Linux side.
enum LinuxKeyCodes {
    static let backspace: UInt32 = 14
    static let enter: UInt32 = 28
    static let tab: UInt32 = 15
    static let leftControl: UInt32 = 29
    /// Apple ISO keyboards report the key left of 1 as 0x64 and the key right of left
    /// Shift as 0x35; set by LinuxKeyboardLayoutMonitor when it sees that (on the main actor).
    nonisolated(unsafe) static var swapsISOKeys = false

    static func evdev(for usage: UIKeyboardHIDUsage) -> UInt32? {
        let raw = usage.rawValue
        if swapsISOKeys && (raw == 0x35 || raw == 0x64) { return raw == 0x35 ? 86 : 41 }
        // Left Command acts as Control, so Cmd-C / Cmd-V / Cmd-S do what an iPad user
        // expects; right Command stays Super for Linux shortcuts that need it.
        if raw == 0xE3 { return leftControl }
        if raw >= 0xE0 && raw <= 0xE7 {
            return modifierTable[raw - 0xE0]
        }
        if let code = internationalTable[raw] { return code }
        guard raw < mainTable.count else { return nil }
        let code = mainTable[raw]
        return code == 0 ? nil : UInt32(code)
    }

    private static let modifierTable: [UInt32] = [29, 42, 56, 125, 97, 54, 100, 126]

    /// JIS and Korean keys: Ro, Katakana/Hiragana, Yen, Henkan, Muhenkan, Hangul, Hanja.
    private static let internationalTable: [Int: UInt32] = [
        0x87: 89, 0x88: 93, 0x89: 124, 0x8A: 92, 0x8B: 94, 0x90: 122, 0x91: 123,
    ]

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
