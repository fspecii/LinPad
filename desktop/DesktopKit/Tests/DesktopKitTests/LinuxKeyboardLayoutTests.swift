import UIKit
import XCTest
@testable import DesktopKit

final class LinuxKeyboardLayoutTests: XCTestCase {
    private func id(_ language: String?) -> String {
        LinuxKeyboardLayouts.id(forLanguage: language)
    }

    func testLanguagesMapToTheIPadsHardwareLayouts() {
        let expected: [String: String] = [
            "en-US": "us:mac", "en": "us:mac", "en-AU": "us:mac", "en-GB": "gb:mac", "en-IE": "gb:mac",
            "de-DE": "de:mac", "de": "de:mac", "de-AT": "at:mac", "de-CH": "ch:de_mac",
            "fr-FR": "fr:mac", "fr-CA": "ca", "fr-CH": "ch:fr_mac", "fr-BE": "be",
            "es-ES": "es", "es": "es", "es-MX": "latam", "es-419": "latam",
            "it-IT": "it:mac", "pt-PT": "pt:mac", "pt-BR": "br", "pt": "br",
            "ro-RO": "ro:std", "pl-PL": "pl", "nl-NL": "us:mac", "nl-BE": "be",
            "sv-SE": "se:mac", "nb-NO": "no:mac", "da-DK": "dk:mac", "fi-FI": "fi:mac",
            "ru-RU": "ru:mac", "uk-UA": "ua:macOS", "tr-TR": "tr",
            "ja-JP": "jp", "ko-KR": "kr", "zh-Hans": "cn", "zh-Hant-TW": "cn", "yue-Hant": "cn",
            "cs-CZ": "cz", "el-GR": "gr", "he-IL": "il",
        ]
        for (language, layout) in expected {
            XCTAssertEqual(id(language), layout, language)
        }
    }

    func testUnknownOrMissingLanguageIsUS() {
        XCTAssertEqual(id(nil), "us:mac")
        XCTAssertEqual(id(""), "us:mac")
        XCTAssertEqual(id("tlh"), "us:mac")
        XCTAssertEqual(id("de_CH"), "ch:de_mac", "underscore identifiers too")
    }

    func testEveryMappedLayoutIsInTheCatalogWithAFingerprint() {
        let languages = ["en-US", "en-GB", "de", "de-AT", "de-CH", "fr", "fr-CA", "fr-CH", "fr-BE", "it", "es", "es-MX",
                         "pt-PT", "pt-BR", "nl", "ro", "pl", "cs", "sk", "hu", "hr", "sl", "sv", "nb", "da", "fi", "is",
                         "et", "lv", "lt", "tr", "ru", "uk", "bg", "sr", "el", "he", "ar", "fa", "th", "ja", "ko", "zh-Hans"]
        for language in languages {
            let layoutID = id(language)
            let layout = LinuxKeyboardLayouts.layout(id: layoutID)
            XCTAssertNotNil(layout, "\(language) → \(layoutID)")
            if let layout { XCTAssertNotNil(LinuxKeyboardLayoutResolver.fingerprint(layout), layoutID) }
        }
        for layout in LinuxKeyboardLayouts.catalog {
            XCTAssertEqual(LinuxKeyboardLayoutResolver.fingerprint(layout)?.count, 54, layout.id)
        }
        XCTAssertEqual(Set(LinuxKeyboardLayouts.catalog.map(\.id)).count, LinuxKeyboardLayouts.catalog.count, "unique ids")
    }

    func testNonLatinLayoutsGetUSForShortcuts() {
        let russian = LinuxKeyboardLayouts.forLanguage("ru-RU")
        XCTAssertEqual(russian.xkbLayout, "ru,us")
        XCTAssertEqual(russian.xkbVariant, "mac,")
        let german = LinuxKeyboardLayouts.forLanguage("de-DE")
        XCTAssertEqual(german.xkbLayout, "de")
        XCTAssertEqual(german.xkbVariant, "mac")
        for language in ["ja", "ko", "zh-Hans"] {
            XCTAssertFalse(LinuxKeyboardLayouts.forLanguage(language).addsLatin, "\(language) layouts are Latin already")
        }
    }

    func testOptionKeyRoles() {
        XCTAssertEqual(LinuxOptionKeyRole.rightAltGr.xkbOptions, "")
        XCTAssertEqual(LinuxOptionKeyRole.altGr.xkbOptions, "lv3:alt_switch")
        XCTAssertEqual(LinuxOptionKeyRole.alt.xkbOptions, "lv3:ralt_alt")
    }

    @MainActor
    func testKeymapFields() {
        var resolver = LinuxKeyboardLayoutResolver()
        resolver.setLanguage("de-DE")
        XCTAssertEqual(resolver.keymapFields, ["de", "mac", ""])
        resolver.optionRole = .altGr
        XCTAssertEqual(resolver.keymapFields, ["de", "mac", "lv3:alt_switch"])
        XCTAssertEqual(resolver.keymapFields.map(LinuxGUIBridge.escape), ["de", "mac", "lv3:alt_switch"])
        resolver.setting = "us"
        XCTAssertEqual(resolver.keymapFields.map(LinuxGUIBridge.escape), ["us", "-", "lv3:alt_switch"], "empty fields are '-'")
        resolver.setting = "no such layout"
        XCTAssertEqual(resolver.layout.id, "de:mac", "an unknown manual id falls back to automatic")
    }

    func testIgnoresDictationAndEmojiModes() {
        var resolver = LinuxKeyboardLayoutResolver()
        XCTAssertTrue(resolver.setLanguage("fr-FR"))
        XCTAssertFalse(resolver.setLanguage("dictation"))
        XCTAssertFalse(resolver.setLanguage("emoji"))
        XCTAssertFalse(resolver.setLanguage(nil))
        XCTAssertFalse(resolver.setLanguage("fr-FR"), "unchanged")
        XCTAssertEqual(resolver.layout.id, "fr:mac")
    }

    // MARK: Detection from what the keys type

    func testQWERTZKeyboardUnderEnglishBecomesGerman() {
        var resolver = LinuxKeyboardLayoutResolver()
        resolver.setLanguage("en-US")
        XCTAssertFalse(resolver.observe(usage: 0x04, characters: "a"), "agrees with US")
        XCTAssertTrue(resolver.observe(usage: 0x1C, characters: "z"), "the US Y key types z")
        XCTAssertEqual(resolver.layout.layout, "de")
        XCTAssertTrue(resolver.observe(usage: 0x2F, characters: "ü") == false)
        XCTAssertEqual(resolver.layout.id, "de:mac")
    }

    func testAZERTYAndDvorakAreFound() {
        var resolver = LinuxKeyboardLayoutResolver()
        resolver.setLanguage("en-US")
        resolver.observe(usage: 0x14, characters: "a")
        resolver.observe(usage: 0x1E, characters: "&")
        XCTAssertEqual(resolver.layout.layout, "fr")

        var dvorak = LinuxKeyboardLayoutResolver()
        dvorak.setLanguage("en-US")
        dvorak.observe(usage: 0x05, characters: "x")
        dvorak.observe(usage: 0x07, characters: "e")
        XCTAssertEqual(dvorak.layout.id, "us:dvorak")
    }

    func testUSKeyboardWithJapaneseStaysUSAfterASymbolKey() {
        var resolver = LinuxKeyboardLayoutResolver()
        resolver.setLanguage("ja-JP")
        XCTAssertEqual(resolver.layout.id, "jp")
        resolver.observe(usage: 0x2F, characters: "[")
        XCTAssertEqual(resolver.layout.layout, "us", "JIS has @ there")
    }

    func testShiftedOrModifiedCharactersAreLowercasedAndJunkIgnored() {
        var resolver = LinuxKeyboardLayoutResolver()
        resolver.setLanguage("de-DE")
        XCTAssertFalse(resolver.observe(usage: 0x1D, characters: "Y"))
        XCTAssertEqual(resolver.layout.id, "de:mac")
        XCTAssertFalse(resolver.observe(usage: 0x28, characters: "\r"), "Return")
        XCTAssertFalse(resolver.observe(usage: 0x52, characters: "\u{F700}"), "arrow")
        XCTAssertFalse(resolver.observe(usage: 0x2E, characters: ""), "dead key")
        XCTAssertFalse(resolver.observe(usage: 0x04, characters: "ab"))
        XCTAssertTrue(resolver.observations.count == 1)
    }

    func testManualLayoutIsNeverOverridden() {
        var resolver = LinuxKeyboardLayoutResolver()
        resolver.setting = "us:colemak"
        resolver.setLanguage("de-DE")
        resolver.observe(usage: 0x1C, characters: "z")
        XCTAssertEqual(resolver.layout.id, "us:colemak")
    }

    func testLanguageChangeForgetsDetection() {
        var resolver = LinuxKeyboardLayoutResolver()
        resolver.setLanguage("en-US")
        resolver.observe(usage: 0x1C, characters: "z")
        XCTAssertEqual(resolver.layout.layout, "de")
        resolver.setLanguage("fr-FR")
        XCTAssertEqual(resolver.layout.id, "fr:mac")
        XCTAssertTrue(resolver.observations.isEmpty)
    }

    func testCyrillicKeysKeepRussian() {
        var resolver = LinuxKeyboardLayoutResolver()
        resolver.setLanguage("ru-RU")
        XCTAssertFalse(resolver.observe(usage: 0x14, characters: "й"))
        XCTAssertFalse(resolver.observe(usage: 0x04, characters: "Ф"))
        XCTAssertEqual(resolver.layout.id, "ru:mac")
    }

    func testAppleISOKeySwap() {
        var resolver = LinuxKeyboardLayoutResolver()
        resolver.setLanguage("de-DE")
        // de(mac): the key right of left Shift is <, so seeing < from usage 0x35 means swapped.
        XCTAssertTrue(resolver.observe(usage: 0x35, characters: "<"))
        XCTAssertTrue(resolver.swapsISOKeys)
        XCTAssertEqual(resolver.layout.id, "de:mac", "the ISO keys never pick the layout")
        resolver.forgetKeyboard()
        XCTAssertFalse(resolver.swapsISOKeys)

        var gb = LinuxKeyboardLayoutResolver()
        gb.setLanguage("en-GB")
        XCTAssertFalse(gb.observe(usage: 0x35, characters: "§"), "gb(mac) has § left of 1: not swapped")
        XCTAssertFalse(gb.swapsISOKeys)
        var swapped = LinuxKeyboardLayoutResolver()
        swapped.setLanguage("en-GB")
        XCTAssertTrue(swapped.observe(usage: 0x64, characters: "§"), "§ from the usage of the key right of Shift")
        XCTAssertTrue(swapped.swapsISOKeys)
    }

    @MainActor
    func testISOSwapInEvdevTable() {
        defer { LinuxKeyCodes.swapsISOKeys = false }
        let grave = UIKeyboardHIDUsage(rawValue: 0x35)!, lsgt = UIKeyboardHIDUsage(rawValue: 0x64)!
        XCTAssertEqual(LinuxKeyCodes.evdev(for: grave), 41)
        XCTAssertEqual(LinuxKeyCodes.evdev(for: lsgt), 86)
        LinuxKeyCodes.swapsISOKeys = true
        XCTAssertEqual(LinuxKeyCodes.evdev(for: grave), 86)
        XCTAssertEqual(LinuxKeyCodes.evdev(for: lsgt), 41)
        XCTAssertEqual(LinuxKeyCodes.evdev(for: .keyboardA), 30)
        XCTAssertEqual(LinuxKeyCodes.evdev(for: UIKeyboardHIDUsage(rawValue: 0x89)!), 124, "JIS Yen")
    }
}
