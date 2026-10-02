import GameController
import SwiftUI
import UIKit

extension Notification.Name {
    /// Posted when the Linux keymap changes during a session; `object` is the layout title.
    static let linuxKeyboardLayoutDidChange = Notification.Name("DesktopKit.linuxKeyboardLayoutDidChange")
}

/// Keeps ishwl's keymap in step with the iPad: the input language (Globe key), the
/// hardware keyboard coming and going, what its keys really type, and the Settings
/// choices. Sends `keymap LAYOUT VARIANT OPTIONS` on connect and on every change.
@MainActor
final class LinuxKeyboardLayoutMonitor {
    private var resolver = LinuxKeyboardLayoutResolver()
    private var send: ((String) -> Void)?
    private var sentLine: String?
    private var observers: [NSObjectProtocol] = []

    init() {
        resolver.setting = UserDefaults.standard.string(forKey: LinuxKeyboardLayouts.storageKey) ?? LinuxKeyboardLayouts.automatic
        resolver.optionRole = LinuxOptionKeyRole.current
        resolver.setLanguage(UITextInputMode.activeInputModes.first?.primaryLanguage ?? Locale.preferredLanguages.first)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UITextInputMode.currentInputModeDidChangeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let language = (note.object as? UITextInputMode)?.primaryLanguage
            MainActor.assumeIsolated { self?.languageChanged(language) }
        })
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.resolver.forgetKeyboard()
                    self?.update()
                }
            })
        }
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        })
    }

    /// A session connected (again): it starts with ishwl's default keymap, so send ours.
    func attach(send: @escaping (String) -> Void) {
        self.send = send
        sentLine = nil
        update()
    }

    /// Every hardware press in a Linux window, before it is turned into an evdev code.
    /// `inputMode` is the first responder's, which names the active input language even
    /// when no change notification came.
    func observe(_ presses: Set<UIPress>, inputMode: UITextInputMode?) {
        var changed = resolver.setLanguage(inputMode?.primaryLanguage)
        for press in presses {
            guard let key = press.key,
                  key.modifierFlags.subtracting([.alphaShift, .numericPad]).isEmpty else { continue }
            let characters = key.charactersIgnoringModifiers.isEmpty ? key.characters : key.charactersIgnoringModifiers
            if resolver.observe(usage: UInt16(key.keyCode.rawValue), characters: characters) { changed = true }
        }
        if changed { update() }
    }

    private func languageChanged(_ language: String?) {
        if resolver.setLanguage(language) { update() }
    }

    private func settingsChanged() {
        let setting = UserDefaults.standard.string(forKey: LinuxKeyboardLayouts.storageKey) ?? LinuxKeyboardLayouts.automatic
        let role = LinuxOptionKeyRole.current
        guard setting != resolver.setting || role != resolver.optionRole else { return }
        resolver.setting = setting
        resolver.optionRole = role
        update()
    }

    private func update() {
        LinuxKeyCodes.swapsISOKeys = resolver.swapsISOKeys
        let layout = resolver.layout
        if UserDefaults.standard.string(forKey: LinuxKeyboardLayouts.resolvedTitleKey) != layout.title {
            UserDefaults.standard.set(layout.title, forKey: LinuxKeyboardLayouts.resolvedTitleKey)
        }
        guard let send else { return }
        let line = "keymap " + resolver.keymapFields.map(LinuxGUIBridge.escape).joined(separator: " ")
        guard line != sentLine else { return }
        let isFirst = sentLine == nil
        sentLine = line
        send(line)
        // After the iPad's own layout OSD, which shows on the same input-mode change.
        if !isFirst {
            Task { @MainActor in
                NotificationCenter.default.post(name: .linuxKeyboardLayoutDidChange, object: layout.title)
            }
        }
    }
}

/// Settings → Keyboard: the Linux keymap and what the Option keys are in it.
struct LinuxKeyboardLayoutSettingsView: View {
    @Environment(\.desktopTheme) private var theme
    @AppStorage(LinuxKeyboardLayouts.storageKey) private var layout = LinuxKeyboardLayouts.automatic
    @AppStorage(LinuxKeyboardLayouts.resolvedTitleKey) private var resolvedTitle = ""
    @AppStorage(LinuxOptionKeyRole.storageKey) private var optionRole = LinuxOptionKeyRole.rightAltGr

    var body: some View {
        SettingsRow(title: "Linux keyboard layout") {
            Picker("Linux keyboard layout", selection: $layout) {
                Text("Automatic (follows iPad)").tag(LinuxKeyboardLayouts.automatic)
                ForEach(LinuxKeyboardLayouts.catalog) { Text($0.title).tag($0.id) }
            }
            .labelsHidden()
            .accessibilityIdentifier("settings.linuxKeyboardLayout")
        }
        SettingsRow(title: "Option key acts as") {
            Picker("Option key acts as", selection: $optionRole) {
                ForEach(LinuxOptionKeyRole.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .accessibilityIdentifier("settings.linuxOptionKeyRole")
        }
        Text(explanation)
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var explanation: String {
        let now = layout == LinuxKeyboardLayouts.automatic && !resolvedTitle.isEmpty ? " Now: \(resolvedTitle)." : ""
        return "Keys reach Linux apps by position and the Linux layout turns them into characters and shortcuts. "
            + "Automatic follows the iPad's keyboard language and checks it against what the keyboard types.\(now) "
            + "As AltGr, Option types the characters on the keycaps (Option-L is @ on a German Mac layout) in "
            + "terminals and other apps the iPad does not type into; as Alt it is for shortcuts."
    }
}
