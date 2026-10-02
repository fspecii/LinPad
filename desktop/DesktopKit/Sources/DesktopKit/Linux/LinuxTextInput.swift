import UIKit

/// What the focused Linux app reported through zwp_text_input_v3 (wl-bridge
/// src/textinput.c). While a toplevel has this, iPadOS text input goes to the app as
/// composed text: commits, a preedit with its cursor, and deletions around the caret.
struct LinuxTextInputState {
    /// zwp_text_input_v3 content purpose and hint bits.
    var purpose: UInt32 = 0
    var hint: UInt32 = 0
    var textBeforeCursor = ""
    var textAfterCursor = ""
    /// The app sends its surrounding text (terminals don't); without it, deletions are
    /// Backspace presses and the text is what this side typed.
    var appReportsText = false
    /// The app's cursor rectangle in the toplevel view's coordinates.
    var caret: CGRect = .null

    enum Purpose: UInt32 {
        case normal, alpha, digits, number, phone, url, email, name, password, pin, date, time, datetime, terminal
    }

    /// Chromium-based apps (VS Code, Electron): their surrounding text does not match the
    /// document and they ignore delete_surrounding_text, so they are treated like a
    /// terminal (Backspace presses, the host's own record of what it typed).
    static let unreliableSurroundingApps: Set<String> = [
        "code", "code-url-handler", "codium", "chromium", "chromium-browser", "google-chrome", "electron",
    ]

    static let hiddenTextHint: UInt32 = 0x40
    static let multilineHint: UInt32 = 0x200

    var isMultiline: Bool { hint & Self.multilineHint != 0 }

    var keyboardType: UIKeyboardType {
        switch Purpose(rawValue: purpose) {
        case .digits, .pin: .numberPad
        case .number: .decimalPad
        case .phone: .phonePad
        case .url: .URL
        case .email: .emailAddress
        default: .default
        }
    }

    var isSecret: Bool {
        Purpose(rawValue: purpose) == .password || Purpose(rawValue: purpose) == .pin || hint & Self.hiddenTextHint != 0
    }
}

final class LinuxTextPosition: UITextPosition {
    /// UTF-16 offset into the document: the app's text before the caret, the marked
    /// text, then the app's text after the caret.
    let offset: Int

    init(_ offset: Int) {
        self.offset = offset
    }
}

final class LinuxTextRange: UITextRange {
    let lower: Int
    let upper: Int

    init(_ a: Int, _ b: Int) {
        lower = min(a, b)
        upper = max(a, b)
    }

    override var start: UITextPosition { LinuxTextPosition(lower) }
    override var end: UITextPosition { LinuxTextPosition(upper) }
    override var isEmpty: Bool { lower == upper }
}

/// UITextInput over the app's surrounding text, so the iPad keyboard can compose:
/// accents (long press, Option dead keys), dictation, emoji and CJK marked text.
/// Without an enabled text input (an app that never asked for one, or a widget that
/// is not a text field), text is replayed as key presses as before.
extension LinuxSurfaceView: UITextInput {
    private var textInput: LinuxTextInputState? { surface?.textInput }
    private var before: String { textInput?.textBeforeCursor ?? "" }
    private var after: String { textInput?.textAfterCursor ?? "" }
    private var caretOffset: Int { before.utf16.count }
    private var document: NSString { (before + (markedText ?? "") + after) as NSString }

    /// The app's text input changed: new surrounding text, state or caret.
    func textInputDidChange(activationChanged: Bool) {
        if textInput == nil, markedText != nil {
            markedText = nil
        }
        // The app's own edits (and a different field) invalidate what the keyboard
        // assumes about the text; a composition in progress keeps going.
        if markedText == nil {
            inputDelegate?.selectionWillChange(self)
            inputDelegate?.textWillChange(self)
            inputDelegate?.textDidChange(self)
            inputDelegate?.selectionDidChange(self)
        }
        guard activationChanged else { return }
        // A text field gained or lost focus: with no hardware keyboard, that is when the
        // on-screen keyboard comes up or goes away (OnScreenKeyboard.inputView(for:)).
        if textInput != nil, !isFirstResponder, !HardwareKeyboardMonitor.isAttached, canBecomeFirstResponder {
            becomeFirstResponder()
        }
        if isFirstResponder {
            reloadInputViews()
        }
    }

    // MARK: Keys

    var hasText: Bool { true }

    var keyboardType: UIKeyboardType {
        get { textInput?.keyboardType ?? .default }
        set {}
    }

    var isSecureTextEntry: Bool {
        get { textInput?.isSecret ?? false }
        set {}
    }

    func insertText(_ text: String) {
        if let marked = markedText {
            markedText = nil
            commit(marked)
        }
        // A multi-line field takes line breaks and tabs as text, so they stay in order
        // with the text around them (toolkits queue key events behind committed text).
        // Elsewhere they are keys: Return submits a form, Tab moves focus.
        let multiline = textInput?.isMultiline == true
        switch text {
        case "\n", "\r": multiline ? commit("\n") : pressKey(LinuxKeyCodes.enter)
        case "\t": multiline ? commit("\t") : pressKey(LinuxKeyCodes.tab)
        case "": break
        default: commit(text)
        }
    }

    func deleteBackward() {
        if var marked = markedText {
            marked.removeLast()
            setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0))
            return
        }
        // Deleting through the text input keeps the order with typed text; at the start
        // of the app's text (joining lines, say) only a Backspace key can do it.
        if textInput?.appReportsText == true, let last = before.last {
            commit("", replacing: String(last))
            return
        }
        pressKey(LinuxKeyCodes.backspace)
        if var text = textInput?.textBeforeCursor, !text.isEmpty {
            text.removeLast()
            surface?.textInput?.textBeforeCursor = text
        }
    }

    /// What this side remembers typing when the app reports no text of its own.
    private static let typedContextLimit = 256

    private func pressKey(_ code: UInt32) {
        bridge?.key(code, pressed: true, focusedSurface: surfaceID)
        bridge?.key(code, pressed: false, focusedSurface: surfaceID)
    }

    /// Inserts at the app's caret, first removing `replacing`, the text just before it.
    private func commit(_ text: String, replacing removed: String = "") {
        guard let state = textInput else {
            bridge?.type(text)
            return
        }
        if state.appReportsText {
            bridge?.compose(surfaceID, deleteBefore: removed.utf8.count, commit: text)
        } else {
            for _ in removed.unicodeScalars { pressKey(LinuxKeyCodes.backspace) }
            bridge?.compose(surfaceID, commit: text)
        }
        var updated = String(before.dropLast(removed.count)) + text
        if !state.appReportsText, updated.count > Self.typedContextLimit {
            updated = String(updated.suffix(Self.typedContextLimit))
        }
        surface?.textInput?.textBeforeCursor = updated
    }

    private func sendPreedit() {
        guard textInput != nil else { return }
        let marked = markedText ?? ""
        let utf16 = marked as NSString
        let location = min(markedSelection.location, utf16.length)
        let end = min(location + markedSelection.length, utf16.length)
        let begin = utf16.substring(to: location).utf8.count
        let cursorEnd = utf16.substring(to: end).utf8.count
        bridge?.compose(surfaceID, preedit: marked, cursor: begin..<cursorEnd)
    }

    // MARK: Marked text

    var markedTextRange: UITextRange? {
        markedText.map { LinuxTextRange(caretOffset, caretOffset + ($0 as NSString).length) }
    }

    func setMarkedText(_ text: String?, selectedRange: NSRange) {
        let text = text ?? ""
        markedText = text.isEmpty ? nil : text
        markedSelection = selectedRange
        sendPreedit()
    }

    func unmarkText() {
        guard let marked = markedText else { return }
        markedText = nil
        commit(marked)
    }

    // MARK: Document

    var selectedTextRange: UITextRange? {
        get {
            guard markedText != nil else { return LinuxTextRange(caretOffset, caretOffset) }
            let start = caretOffset + markedSelection.location
            return LinuxTextRange(start, start + markedSelection.length)
        }
        set {
            // Only a selection inside the composition can be honoured; the app owns its caret.
            guard let range = newValue as? LinuxTextRange, let marked = markedText,
                  range.lower >= caretOffset, range.upper <= caretOffset + (marked as NSString).length else { return }
            markedSelection = NSRange(location: range.lower - caretOffset, length: range.upper - range.lower)
            sendPreedit()
        }
    }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? LinuxTextRange else { return nil }
        let document = document
        let lower = min(range.lower, document.length), upper = min(range.upper, document.length)
        return document.substring(with: NSRange(location: lower, length: upper - lower))
    }

    func replace(_ range: UITextRange, withText text: String) {
        guard let range = range as? LinuxTextRange else { return }
        // Corrections and accent replacements end at the caret: delete, then insert.
        if markedText == nil, range.upper == caretOffset {
            commit(text, replacing: (before as NSString).substring(from: min(range.lower, caretOffset)))
        } else {
            insertText(text)
        }
    }

    var beginningOfDocument: UITextPosition { LinuxTextPosition(0) }
    var endOfDocument: UITextPosition { LinuxTextPosition(document.length) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? LinuxTextPosition, let to = toPosition as? LinuxTextPosition else { return nil }
        return LinuxTextRange(from.offset, to.offset)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? LinuxTextPosition else { return nil }
        let target = position.offset + offset
        return (0...document.length).contains(target) ? LinuxTextPosition(target) : nil
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .left, .up: self.position(from: position, offset: -offset)
        default: self.position(from: position, offset: offset)
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = (position as? LinuxTextPosition)?.offset ?? 0
        let b = (other as? LinuxTextPosition)?.offset ?? 0
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        ((toPosition as? LinuxTextPosition)?.offset ?? 0) - ((from as? LinuxTextPosition)?.offset ?? 0)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        switch direction {
        case .left, .up: range.start
        default: range.end
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let position = position as? LinuxTextPosition else { return nil }
        switch direction {
        case .left, .up: return LinuxTextRange(0, position.offset)
        default: return LinuxTextRange(position.offset, document.length)
        }
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .natural
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    // MARK: Geometry (candidate bar, emoji and dictation popovers)

    private var caret: CGRect {
        guard let rect = textInput?.caret, !rect.isNull, rect.height > 0 else {
            return CGRect(x: 0, y: 0, width: 2, height: 20)
        }
        return CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, 2), height: rect.height)
    }

    func firstRect(for range: UITextRange) -> CGRect { caret }
    func caretRect(for position: UITextPosition) -> CGRect { caret }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { LinuxTextPosition(caretOffset) }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        range.start
    }

    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    // MARK: Hardware keys

    /// Whether a hardware key press should go to the iPad's text system (and arrive as
    /// insertText / marked text) instead of straight to the app as a key code. Only
    /// while the app has a text field to compose into, and never for shortcuts.
    private static let altOnlyKeys: Set<UIKeyboardHIDUsage> = [
        .keyboardUpArrow, .keyboardDownArrow, .keyboardLeftArrow, .keyboardRightArrow,
        .keyboardDeleteOrBackspace, .keyboardDeleteForward, .keyboardReturnOrEnter, .keypadEnter,
        .keyboardTab, .keyboardHome, .keyboardEnd, .keyboardPageUp, .keyboardPageDown,
    ]

    private static let textEditingKeys: Set<UIKeyboardHIDUsage> = [
        .keyboardReturnOrEnter, .keypadEnter, .keyboardTab, .keyboardDeleteOrBackspace,
    ]

    func routesToTextSystem(_ press: UIPress) -> Bool {
        guard textInput != nil || markedText != nil, let key = press.key else { return false }
        let modifiers = key.modifierFlags
        if modifiers.contains(.command) || modifiers.contains(.control) { return false }
        // While composing, Return, Delete and the arrows belong to the composition.
        if markedText != nil { return true }
        // Option types characters (dead keys: Option-E then E is é) or stays Alt for the
        // app's shortcuts, per LinuxOptionKeyMode; with editing and arrow keys it is Alt.
        if modifiers.contains(.alternate) {
            return !Self.altOnlyKeys.contains(key.keyCode)
                && LinuxOptionKeyMode.typesCharacters(appID: surface?.appID ?? "")
        }
        // UIKit delivers text later than raw key codes, so the keys that edit text go the
        // same way as the letters, or a fast Return would overtake the word before it.
        // They come back as insertText("\n" / "\t") and deleteBackward.
        // (Shift-Tab stays a key code: UIKit takes it for focus movement.)
        if Self.textEditingKeys.contains(key.keyCode) {
            return !(key.keyCode == .keyboardTab && modifiers.contains(.shift))
        }
        let scalars = key.characters.unicodeScalars
        return !scalars.isEmpty && scalars.allSatisfy { scalar in
            // Arrows and function keys come as private-use characters.
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }
}
