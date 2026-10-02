import Foundation
import Observation
import SwiftUI

/// The colour theme axis: which theme is active (empty: the style's own colours), the
/// list the guest knows about, and applying a theme to Linux apps (`ish-apply-colors`).
@Observable @MainActor
final class ColorThemeStore {
    static let storageKey = "desktop.colorTheme"

    private(set) var themes: [ColorTheme] = ColorTheme.builtIn
    private(set) var currentID: String
    /// The theme the picker is showing; the desktop draws with it until Return or Esc.
    var previewID: String?
    /// Set while the guest renders a theme for Linux apps.
    private(set) var applyingID: String?
    private(set) var isInstalling = false
    /// False on guests whose image predates colour themes; native colours still work.
    private(set) var guestSupportsThemes = true

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    /// The desktop's handlers, for Settings (which has no controller).
    @ObservationIgnored var onApplyRequest: ((String) -> Void)?
    @ObservationIgnored var onPickerRequest: (() -> Void)?
    @ObservationIgnored var onFindWallpapersRequest: ((ColorTheme) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        currentID = defaults.string(forKey: Self.storageKey) ?? ""
    }

    var activeID: String { previewID ?? currentID }
    var active: ColorTheme? { theme(activeID) }
    var current: ColorTheme? { theme(currentID) }

    func theme(_ id: String) -> ColorTheme? {
        id.isEmpty ? nil : themes.first { $0.id == id }
    }

    /// "" (style colours) followed by dark themes, light themes, then user themes.
    var orderedIDs: [String] {
        let builtIn = themes.filter { !$0.isUserTheme }
        return [""] + builtIn.filter(\.isDark).map(\.id) + builtIn.filter { !$0.isDark }.map(\.id)
            + themes.filter(\.isUserTheme).map(\.id)
    }

    func name(of id: String) -> String {
        theme(id)?.name ?? "Style Colors"
    }

    /// The native side switches at once; nothing reaches the guest here.
    func select(_ id: String) {
        guard id != currentID else { return }
        currentID = id
        defaults.set(id, forKey: Self.storageKey)
        if id.isEmpty {
            defaults.removeObject(forKey: LinuxDeviceInfo.colorThemeNameKey)
        } else {
            defaults.set(theme(id)?.name ?? id, forKey: LinuxDeviceInfo.colorThemeNameKey)
        }
    }

    /// A theme saved or imported by the Themes app shows at once, before the guest's list
    /// is read again (or on guests without `ish-colors`).
    func upsertLocal(_ theme: ColorTheme) {
        themes.removeAll { $0.id == theme.id }
        themes.append(theme)
        themes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func removeLocal(_ id: String) {
        themes.removeAll { $0.id == id && $0.isUserTheme }
        if let builtIn = ColorTheme.builtIn.first(where: { $0.id == id }) { upsertLocal(builtIn) }
        if currentID == id { select("") }
    }

    /// Reads the guest's list (built-in plus user and git themes).
    func load(host: any LinuxHost) async {
        let result = await host.run("ish-colors list --json", cwd: nil, stdin: nil)
        guard result.succeeded else {
            guestSupportsThemes = false
            return
        }
        guestSupportsThemes = true
        let listed = ColorTheme.decodeList(Data(result.stdout.utf8))
        guard !listed.isEmpty else { return }
        var merged = listed
        for theme in themes where theme.isUserTheme && !merged.contains(where: { $0.id == theme.id }) { merged.append(theme) }
        for theme in ColorTheme.builtIn where !merged.contains(where: { $0.id == theme.id }) { merged.append(theme) }
        themes = merged.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Renders the theme for foot, GTK, Qt, VS Code and the rest in the guest. Calls queue
    /// behind each other, as the guest's own lock would.
    func applyToGuest(_ id: String, host: any LinuxHost, completion: @escaping @MainActor (Bool, String?) -> Void) {
        guard guestSupportsThemes else { return }
        let previous = applyTask
        applyTask = Task { [weak self] in
            await previous?.value
            self?.applyingID = id
            let result = await host.run("ish-apply-colors \(ShellQuote.quote(id.isEmpty ? "none" : id))", cwd: nil, stdin: nil)
            self?.applyingID = nil
            completion(result.succeeded, result.succeeded ? nil : result.failureDescription)
        }
    }

    func install(url: String, host: any LinuxHost) async -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isAcceptableGitURL(trimmed) else { return "That is not an https:// or git@ repository URL." }
        isInstalling = true
        defer { isInstalling = false }
        let result = await host.run("ish-colors install \(ShellQuote.quote(trimmed))", cwd: nil, stdin: nil)
        guard result.succeeded else { return result.failureDescription }
        await load(host: host)
        return nil
    }

    /// The same filter as Omarchy's installer: no option injection, no exotic transports.
    nonisolated static func isAcceptableGitURL(_ url: String) -> Bool {
        guard !url.isEmpty, !url.hasPrefix("-"), !url.contains(" "), !url.contains("::") else { return false }
        return url.hasPrefix("https://") || (url.hasPrefix("git@") && url.contains(":"))
    }
}

/// The theme picker's state, apart from the view: arrows preview, Return keeps, Esc goes
/// back to the theme that was active when the picker opened.
struct ColorThemePicker: Equatable {
    let ids: [String]
    let originalID: String
    private(set) var index: Int

    init(ids: [String], currentID: String) {
        self.ids = ids.isEmpty ? [""] : ids
        originalID = currentID
        index = self.ids.firstIndex(of: currentID) ?? 0
    }

    var selectedID: String { ids[index] }

    mutating func move(by offset: Int) {
        index = ((index + offset) % ids.count + ids.count) % ids.count
    }

    mutating func select(_ id: String) {
        if let position = ids.firstIndex(of: id) { index = position }
    }
}

private struct ColorThemeStoreKey: EnvironmentKey {
    static let defaultValue: ColorThemeStore? = nil
}

extension EnvironmentValues {
    var desktopColorThemes: ColorThemeStore? {
        get { self[ColorThemeStoreKey.self] }
        set { self[ColorThemeStoreKey.self] = newValue }
    }
}
