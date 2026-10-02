import Foundation

/// An XKB layout as ishwl compiles it (rules evdev, model pc105). Keys reach Linux as
/// physical evdev codes, so this keymap decides which characters and shortcuts they make.
struct LinuxXKBLayout: Hashable, Identifiable, Sendable {
    /// "de", "ch".
    let layout: String
    /// "mac", "de_mac", "" for the layout's default.
    let variant: String
    let title: String
    /// Non-Latin layouts get US as a second group, so Ctrl and Alt shortcuts still find
    /// Latin letters (GTK, Qt and Firefox look shortcuts up in every group).
    var addsLatin = false

    /// "layout" or "layout:variant", the value stored for a manual choice.
    var id: String { variant.isEmpty ? layout : "\(layout):\(variant)" }

    /// The `keymap` bridge message's layout and variant fields.
    var xkbLayout: String { addsLatin ? "\(layout),us" : layout }
    var xkbVariant: String { addsLatin ? "\(variant)," : variant }
}

/// What the Option keys are in the Linux keymap, i.e. outside the text the iPad types
/// itself (terminals, shortcuts, X11 apps, apps without a text field).
enum LinuxOptionKeyRole: String, CaseIterable, Identifiable, Sendable {
    /// Right Option is AltGr (third level: Option-L is @ on a German Mac layout), left
    /// Option is Alt, as on a PC keyboard.
    case rightAltGr
    /// Both Option keys are AltGr, so Option combinations type what the keycaps show.
    case altGr
    /// Both Option keys are Alt, for Alt shortcuts in every app.
    case alt

    static let storageKey = "desktop.linux.optionKeyRole"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightAltGr: "Right AltGr, Left Alt"
        case .altGr: "AltGr (Characters)"
        case .alt: "Alt (Shortcuts)"
        }
    }

    /// XKB options for the keymap. Every layout here that has a third level reaches it
    /// with Right Alt (level3(ralt_switch)); these move it.
    var xkbOptions: String {
        switch self {
        case .rightAltGr: ""
        case .altGr: "lv3:alt_switch"
        case .alt: "lv3:ralt_alt"
        }
    }

    static var current: LinuxOptionKeyRole {
        UserDefaults.standard.string(forKey: storageKey).flatMap(LinuxOptionKeyRole.init) ?? .rightAltGr
    }
}

enum LinuxKeyboardLayouts {
    /// UserDefaults: "automatic" (follow the iPad) or a catalog id.
    static let storageKey = "desktop.linux.keyboardLayout"
    static let automatic = "automatic"
    /// The title of the layout in use, for Settings.
    static let resolvedTitleKey = "desktop.linux.keyboardLayout.resolved"

    /// iPadOS uses Apple's layouts for hardware keyboards, so Automatic prefers the
    /// Macintosh variants: their Option (AltGr) level matches the keycaps and the iPad.
    static let catalog: [LinuxXKBLayout] = [
        .init(layout: "us", variant: "mac", title: "English (US, Macintosh)"),
        .init(layout: "us", variant: "", title: "English (US)"),
        .init(layout: "us", variant: "intl", title: "English (US, International)"),
        .init(layout: "us", variant: "dvorak", title: "English (Dvorak)"),
        .init(layout: "us", variant: "colemak", title: "English (Colemak)"),
        .init(layout: "gb", variant: "mac", title: "English (UK, Macintosh)"),
        .init(layout: "gb", variant: "", title: "English (UK)"),
        .init(layout: "de", variant: "mac", title: "German (Macintosh)"),
        .init(layout: "de", variant: "", title: "German"),
        .init(layout: "at", variant: "mac", title: "German (Austria, Macintosh)"),
        .init(layout: "ch", variant: "de_mac", title: "German (Switzerland, Macintosh)"),
        .init(layout: "ch", variant: "", title: "German (Switzerland)"),
        .init(layout: "ch", variant: "fr_mac", title: "French (Switzerland, Macintosh)"),
        .init(layout: "ch", variant: "fr", title: "French (Switzerland)"),
        .init(layout: "fr", variant: "mac", title: "French (Macintosh)"),
        .init(layout: "fr", variant: "", title: "French"),
        .init(layout: "be", variant: "", title: "Belgian"),
        .init(layout: "ca", variant: "", title: "French (Canada)"),
        .init(layout: "it", variant: "mac", title: "Italian (Macintosh)"),
        .init(layout: "it", variant: "", title: "Italian"),
        .init(layout: "es", variant: "", title: "Spanish"),
        .init(layout: "latam", variant: "", title: "Spanish (Latin American)"),
        .init(layout: "pt", variant: "mac", title: "Portuguese (Macintosh)"),
        .init(layout: "pt", variant: "", title: "Portuguese"),
        .init(layout: "br", variant: "", title: "Portuguese (Brazil)"),
        .init(layout: "nl", variant: "mac", title: "Dutch (Macintosh)"),
        .init(layout: "ro", variant: "std", title: "Romanian (Standard)"),
        .init(layout: "ro", variant: "", title: "Romanian (Programmers)"),
        .init(layout: "pl", variant: "", title: "Polish"),
        .init(layout: "cz", variant: "", title: "Czech"),
        .init(layout: "sk", variant: "", title: "Slovak"),
        .init(layout: "hu", variant: "", title: "Hungarian"),
        .init(layout: "hr", variant: "", title: "Croatian"),
        .init(layout: "si", variant: "", title: "Slovenian"),
        .init(layout: "se", variant: "mac", title: "Swedish (Macintosh)"),
        .init(layout: "se", variant: "", title: "Swedish"),
        .init(layout: "no", variant: "mac", title: "Norwegian (Macintosh)"),
        .init(layout: "no", variant: "", title: "Norwegian"),
        .init(layout: "dk", variant: "mac", title: "Danish (Macintosh)"),
        .init(layout: "dk", variant: "", title: "Danish"),
        .init(layout: "fi", variant: "mac", title: "Finnish (Macintosh)"),
        .init(layout: "fi", variant: "", title: "Finnish"),
        .init(layout: "is", variant: "mac", title: "Icelandic (Macintosh)"),
        .init(layout: "ee", variant: "", title: "Estonian"),
        .init(layout: "lv", variant: "", title: "Latvian"),
        .init(layout: "lt", variant: "", title: "Lithuanian"),
        .init(layout: "tr", variant: "", title: "Turkish"),
        .init(layout: "ru", variant: "mac", title: "Russian (Macintosh)", addsLatin: true),
        .init(layout: "ru", variant: "", title: "Russian", addsLatin: true),
        .init(layout: "ua", variant: "macOS", title: "Ukrainian (macOS)", addsLatin: true),
        .init(layout: "ua", variant: "", title: "Ukrainian", addsLatin: true),
        .init(layout: "bg", variant: "", title: "Bulgarian", addsLatin: true),
        .init(layout: "rs", variant: "", title: "Serbian", addsLatin: true),
        .init(layout: "gr", variant: "", title: "Greek", addsLatin: true),
        .init(layout: "il", variant: "", title: "Hebrew", addsLatin: true),
        .init(layout: "ara", variant: "mac", title: "Arabic (Macintosh)", addsLatin: true),
        .init(layout: "ir", variant: "", title: "Persian", addsLatin: true),
        .init(layout: "th", variant: "", title: "Thai", addsLatin: true),
        .init(layout: "jp", variant: "", title: "Japanese"),
        .init(layout: "kr", variant: "", title: "Korean"),
        .init(layout: "cn", variant: "", title: "Chinese"),
    ]

    static func layout(id: String) -> LinuxXKBLayout? {
        catalog.first { $0.id == id }
    }

    /// The layout iPadOS uses for a hardware keyboard with this input language
    /// (`UITextInputMode.primaryLanguage`, e.g. "de-CH", "pt-BR", "zh-Hans"). Chinese,
    /// Japanese and Korean keep their IME: only the physical layout is chosen here.
    static func forLanguage(_ primaryLanguage: String?) -> LinuxXKBLayout {
        layout(id: id(forLanguage: primaryLanguage)) ?? catalog[0]
    }

    static func id(forLanguage primaryLanguage: String?) -> String {
        let (language, region) = split(primaryLanguage ?? "")
        switch language {
        case "en": return ["GB", "IE"].contains(region) ? "gb:mac" : "us:mac"
        case "de": return ["CH", "LI"].contains(region) ? "ch:de_mac" : region == "AT" ? "at:mac" : "de:mac"
        case "fr": return region == "CA" ? "ca" : region == "CH" ? "ch:fr_mac" : region == "BE" ? "be" : "fr:mac"
        case "it": return "it:mac"
        case "es": return region == nil || region == "ES" ? "es" : "latam"
        case "ca", "eu", "gl": return "es"
        case "pt": return region == "PT" ? "pt:mac" : "br"
        case "nl": return region == "BE" ? "be" : "us:mac"
        case "ro": return "ro:std"
        case "pl": return "pl"
        case "cs": return "cz"
        case "sk": return "sk"
        case "hu": return "hu"
        case "hr", "bs": return "hr"
        case "sl": return "si"
        case "sv": return "se:mac"
        case "nb", "nn", "no": return "no:mac"
        case "da": return "dk:mac"
        case "fi": return "fi:mac"
        case "is": return "is:mac"
        case "et": return "ee"
        case "lv": return "lv"
        case "lt": return "lt"
        case "tr": return "tr"
        case "ru": return "ru:mac"
        case "uk": return "ua:macOS"  // Ukrainian; British English is en-GB
        case "bg": return "bg"
        case "sr": return "rs"
        case "el": return "gr"
        case "he", "iw": return "il"
        case "ar": return "ara:mac"
        case "fa": return "ir"
        case "th": return "th"
        case "ja": return "jp"
        case "ko": return "kr"
        case "zh", "yue": return "cn"
        default: return "us:mac"
        }
    }

    /// "de-CH" → ("de", "CH"); "zh-Hans-CN" → ("zh", "CN"); "es-419" → ("es", "419").
    private static func split(_ identifier: String) -> (String, String?) {
        let parts = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        let language = parts.first?.lowercased() ?? ""
        let region = parts.dropFirst().first { part in
            (part.count == 2 && part.allSatisfy(\.isLetter)) || (part.count == 3 && part.allSatisfy(\.isNumber))
        }
        return (language, region?.uppercased())
    }
}

/// Decides the Linux keymap from the iPad's input language, what the hardware keyboard
/// actually types, and the user's settings. Pure state, so it is unit-testable; the
/// UIKit side is LinuxKeyboardLayoutMonitor.
///
/// The input language says little about the hardware layout (English can be US,
/// British, Dvorak, Colemak; Japanese can be JIS or US), and iPadOS has no public API
/// for the hardware layout. So every unmodified key press is checked against the
/// layout in use: `UIKey.charactersIgnoringModifiers` is what the iPad's layout made of
/// that HID usage. When it contradicts the layout, the catalog layout that agrees with
/// everything typed so far takes over.
struct LinuxKeyboardLayoutResolver: Equatable {
    /// `LinuxKeyboardLayouts.automatic` or a catalog id.
    var setting = LinuxKeyboardLayouts.automatic
    var optionRole = LinuxOptionKeyRole.rightAltGr
    private(set) var language: String?
    private(set) var detected: LinuxXKBLayout?
    /// Apple ISO keyboards report the key left of 1 and the key right of left Shift
    /// swapped (HID 0x64 and 0x35); Linux's hid-apple driver swaps them back the same way.
    private(set) var swapsISOKeys = false
    /// HID usage → character, since the language last changed.
    private(set) var observations: [UInt16: Unicode.Scalar] = [:]

    static let isoGrave: UInt16 = 0x35
    static let isoNonUSBackslash: UInt16 = 0x64

    var layout: LinuxXKBLayout {
        if setting != LinuxKeyboardLayouts.automatic, let manual = LinuxKeyboardLayouts.layout(id: setting) {
            return manual
        }
        return detected ?? LinuxKeyboardLayouts.forLanguage(language)
    }

    /// `keymap LAYOUT VARIANT OPTIONS`, fields percent-escaped by the bridge ("-" when empty).
    var keymapFields: [String] {
        [layout.xkbLayout, layout.xkbVariant, optionRole.xkbOptions]
    }

    /// A new input language (Globe key, another keyboard): what was learned about the
    /// previous one no longer applies.
    @discardableResult
    mutating func setLanguage(_ primaryLanguage: String?) -> Bool {
        guard let primaryLanguage, !primaryLanguage.isEmpty, primaryLanguage != "dictation",
              primaryLanguage != "emoji", primaryLanguage != language else { return false }
        language = primaryLanguage
        forgetKeyboard()
        return true
    }

    /// A keyboard was attached or removed.
    mutating func forgetKeyboard() {
        detected = nil
        observations = [:]
        swapsISOKeys = false
    }

    /// One unmodified hardware key press: the HID usage and the character the iPad's
    /// layout gives it. Returns whether the layout or the ISO key swap changed.
    @discardableResult
    mutating func observe(usage: UInt16, characters: String) -> Bool {
        let scalars = Array(characters.lowercased().unicodeScalars)
        guard scalars.count == 1, let scalar = scalars.first, scalar.value > 0x20, scalar.value != 0x7F,
              !(0xF700...0xF8FF).contains(scalar.value), Self.fingerprintIndex(usage) != nil else { return false }
        observations[usage] = scalar
        let before = (layout, swapsISOKeys)
        if setting == LinuxKeyboardLayouts.automatic, !Self.agrees(layout, with: observations) {
            detected = Self.bestMatch(for: observations, preferring: LinuxKeyboardLayouts.forLanguage(language))
        }
        updateISOSwap()
        return before != (layout, swapsISOKeys)
    }

    private mutating func updateISOSwap() {
        guard let table = Self.fingerprint(layout) else { return }
        let grave = table[Self.fingerprintIndex(Self.isoGrave)!]
        let lsgt = table[Self.fingerprintIndex(Self.isoNonUSBackslash)!]
        guard grave != lsgt else { return }
        if let seen = observations[Self.isoGrave] {
            if seen == lsgt { swapsISOKeys = true } else if seen == grave { swapsISOKeys = false }
        } else if let seen = observations[Self.isoNonUSBackslash] {
            if seen == grave { swapsISOKeys = true } else if seen == lsgt { swapsISOKeys = false }
        }
    }

    // MARK: Fingerprints

    /// HID usages 0x04-0x38, then 0x64: the order of the fingerprint strings.
    static func fingerprintIndex(_ usage: UInt16) -> Int? {
        switch usage {
        case 0x04...0x38: Int(usage) - 0x04
        case 0x64: 0x38 - 0x04 + 1
        default: nil
        }
    }

    static func fingerprint(_ layout: LinuxXKBLayout) -> [Unicode.Scalar]? {
        LinuxKeyboardFingerprints.base[layout.id].map { Array($0.unicodeScalars) }
    }

    /// The layout's base character for each observed usage matches. The two ISO keys
    /// only count once the swap is known, so they never decide the layout.
    static func agrees(_ layout: LinuxXKBLayout, with observations: [UInt16: Unicode.Scalar]) -> Bool {
        guard let table = fingerprint(layout) else { return true }
        return mismatches(table, observations) == 0
    }

    private static func mismatches(_ table: [Unicode.Scalar], _ observations: [UInt16: Unicode.Scalar]) -> Int {
        var count = 0
        for (usage, scalar) in observations where usage != isoGrave && usage != isoNonUSBackslash {
            guard let index = fingerprintIndex(usage), index < table.count, table[index] != " " else { continue }
            if table[index] != scalar { count += 1 }
        }
        return count
    }

    /// The catalog layout with the fewest contradictions; ties go to the language's own
    /// layout, then to layouts of the same XKB layout code, then to catalog order.
    static func bestMatch(for observations: [UInt16: Unicode.Scalar], preferring preferred: LinuxXKBLayout) -> LinuxXKBLayout {
        var best = preferred
        var bestScore = fingerprint(preferred).map { mismatches($0, observations) } ?? Int.max
        for candidate in LinuxKeyboardLayouts.catalog where candidate != preferred {
            guard let table = fingerprint(candidate) else { continue }
            let score = mismatches(table, observations)
            let sameFamily = candidate.layout == preferred.layout
            let bestSameFamily = best.layout == preferred.layout
            if score < bestScore || (score == bestScore && sameFamily && !bestSameFamily) {
                best = candidate
                bestScore = score
            }
        }
        return best
    }
}
