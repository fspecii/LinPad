import SwiftUI

extension ThemeAppearance {
    /// Fills an empty pair from the current colour theme and its partner, as the Themes app
    /// does when Light & Dark is first switched on.
    mutating func seedPairIfEmpty(currentID: String, themes: [ColorTheme], currentIsDark: Bool) {
        guard lightThemeID.isEmpty, darkThemeID.isEmpty else { return }
        let partner = ThemePairing.partner(of: currentID, in: themes, overrides: pairs)
        if currentIsDark {
            darkThemeID = currentID
            lightThemeID = partner == currentID ? "" : partner
        } else {
            lightThemeID = currentID
            darkThemeID = partner
        }
    }
}

extension DesktopController {
    /// Quick Settings' Dark Mode tile: picks the light or dark member of the Themes app's
    /// pair, which re-themes the desktop natively and Linux apps through ish-apply-colors.
    func setDarkMode(_ dark: Bool) {
        var appearance = themeAppearance
        let current = colorThemes.currentID
        appearance.seedPairIfEmpty(currentID: current, themes: colorThemes.themes,
                                   currentIsDark: colorThemes.theme(current)?.isDark ?? isDarkAppearance)
        appearance.mode = dark ? .dark : .light
        appearance.isEnabled = true
        // Style colours ("") have no theme to carry the mode, so the style's appearance does.
        if (dark ? appearance.darkThemeID : appearance.lightThemeID).isEmpty {
            UserDefaults.standard.set((dark ? DesktopAppearance.dark : .light).rawValue, forKey: DesktopAppearance.storageKey)
        }
        updateThemeAppearance(appearance)
    }

    func openLightAndDarkSettings() {
        dismissAllOverlays()
        open(appID: ThemesApp.id, arguments: [ThemesApp.sectionArgument: ThemesSection.appearance.rawValue])
    }
}
