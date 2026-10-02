import SwiftUI

/// What the Option key does in a Linux text field: Alt, for the shortcuts of terminals and
/// editors (readline's Alt-B, VS Code's Alt-Up), or characters, for dead keys and accents
/// (Option-E then E is é). Outside text fields, and for Option with arrows, Backspace,
/// Delete, Return and Tab, it is always Alt.
enum LinuxOptionKeyMode: String, CaseIterable, Identifiable {
    case automatic
    case alt
    case characters

    static let storageKey = "desktop.linux.optionKey"
    /// Comma-separated Wayland app ids that get Alt in `automatic`.
    static let altAppsKey = "desktop.linux.optionKeyAltApps"
    static let defaultAltApps = "foot,code,code-url-handler,codium,kitty,xterm,emacs"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Alt in Terminals and Editors"
        case .alt: "Always Alt (Shortcuts)"
        case .characters: "Always Characters (Accents)"
        }
    }

    static var current: LinuxOptionKeyMode {
        UserDefaults.standard.string(forKey: storageKey).flatMap(LinuxOptionKeyMode.init) ?? .automatic
    }

    static var altApps: Set<String> {
        let list = UserDefaults.standard.string(forKey: altAppsKey) ?? defaultAltApps
        return Set(parse(list))
    }

    static func parse(_ list: String) -> [String] {
        list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    /// Whether Option combinations in this app's text fields type characters.
    static func typesCharacters(appID: String) -> Bool {
        switch current {
        case .alt: false
        case .characters: true
        case .automatic: !altApps.contains(appID.lowercased())
        }
    }
}

/// Settings → Keyboard: the Option key in Linux apps. Self-contained, so the Settings app
/// can place it anywhere.
struct LinuxOptionKeySettingsView: View {
    @Environment(\.desktopTheme) private var theme
    @AppStorage(LinuxOptionKeyMode.storageKey) private var mode = LinuxOptionKeyMode.automatic
    @AppStorage(LinuxOptionKeyMode.altAppsKey) private var altApps = LinuxOptionKeyMode.defaultAltApps

    var body: some View {
        SettingsRow(title: "Option key in Linux apps") {
            Picker("Option key in Linux apps", selection: $mode) {
                ForEach(LinuxOptionKeyMode.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .accessibilityIdentifier("settings.linuxOptionKey")
        }
        if mode == .automatic {
            SettingsRow(title: "Apps where Option is Alt") {
                TextField("App ids", text: $altApps)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .font(.callout.monospaced())
                    .accessibilityIdentifier("settings.linuxOptionKeyAltApps")
            }
        }
        Text("In a Linux text field, Option either types characters (Option-E then E is é, Option-S is ß) or reaches the app as Alt, for shortcuts such as Alt-B in a terminal or Alt-↑ in VS Code. Option with an arrow, Delete, Return or Tab is always Alt. App ids are Wayland app ids, separated by commas.")
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
