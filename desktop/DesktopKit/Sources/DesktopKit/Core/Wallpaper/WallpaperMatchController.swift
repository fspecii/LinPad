import SwiftUI

extension DesktopController {
    /// A wallpaper was set by the user (Settings, Themes, Wallhaven, Photos): offer to match
    /// the desktop to it, or with auto-match on, apply the palette and accent at once.
    func wallpaperDidChange() {
        guard !isOnboardingPresented else { return }
        let source = wallpapers.activeSource(workspace: wallpapers.currentWorkspace, isDark: isDarkAppearance)
        Task {
            // A newer wallpaper change supersedes this one.
            guard let proposal = await makeWallpaperMatch(for: source),
                  wallpapers.activeSource(workspace: wallpapers.currentWorkspace, isDark: isDarkAppearance) == source
            else { return }
            if wallpaperMatch.autoMatch {
                var automatic = proposal
                automatic.includesIconPack = false
                automatic.includesStyle = false
                applyWallpaperMatch(automatic, automatic: true)
            } else {
                wallpaperMatch.showPrompt(proposal)
            }
        }
    }

    func makeWallpaperMatch(for source: WallpaperSource) async -> WallpaperMatchProposal? {
        guard let analyzed = await wallpaperMatch.analyze(source, store: wallpapers) else { return nil }
        return WallpaperMatchProposal.make(analysis: analyzed.0, source: source, wallpaperID: analyzed.1,
                                           themes: colorThemes.themes, installedPacks: icons.packs.packs.map(\.id))
    }

    /// Saves the generated theme as a user theme (or takes the closest existing one), applies
    /// it to the desktop and Linux apps, and the layout style if the user ticked it.
    func applyWallpaperMatch(_ proposal: WallpaperMatchProposal, automatic: Bool = false) {
        wallpaperMatch.dismissPrompt()
        let previousThemeID = colorThemes.currentID
        let previousStyle = style
        let theme = proposal.chosenTheme
        Task {
            if !proposal.usesClosest {
                do {
                    try await ThemeFiles.save(theme, host: host)
                } catch {
                    notify("Couldn't save \(theme.name) for Linux apps: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                }
                colorThemes.upsertLocal(theme)
                await colorThemes.load(host: host)
            }
            keepWallpaper(forTheme: theme.id)
            if themeAppearance.isEnabled {
                var appearance = themeAppearance
                if theme.isDark { appearance.darkThemeID = theme.id } else { appearance.lightThemeID = theme.id }
                updateThemeAppearance(appearance)
            }
            applyColorTheme(theme.id)
            if proposal.includesStyle, let suggested = proposal.style?.style, suggested != style {
                UserDefaults.standard.set(suggested.rawValue, forKey: DesktopStyle.storageKey)
            }
            let message = automatic ? "Colors matched to the wallpaper (\(theme.name))." : "Desktop matched to the wallpaper: \(theme.name)."
            notify(message, action: DesktopToast.Action(title: "Undo") { [weak self] in
                self?.undoWallpaperMatch(themeID: previousThemeID, style: previousStyle)
            })
        }
    }

    /// Opens the generated palette in the Themes app's editor.
    func customizeWallpaperMatch(_ proposal: WallpaperMatchProposal) {
        wallpaperMatch.dismissPrompt()
        ThemeEditorView.pendingEdit = proposal.chosenTheme
        open(appID: ThemesApp.id, arguments: [ThemesApp.sectionArgument: ThemesSection.editor.rawValue])
        NotificationCenter.default.post(name: ThemesApp.sectionRequested, object: nil,
                                        userInfo: [ThemesApp.sectionArgument: ThemesSection.editor.rawValue])
    }

    private func undoWallpaperMatch(themeID: String, style previous: DesktopStyle) {
        keepWallpaper(forTheme: themeID)
        applyColorTheme(themeID)
        if previous != style { UserDefaults.standard.set(previous.rawValue, forKey: DesktopStyle.storageKey) }
    }

    /// A theme switch restores the wallpaper last used with that theme; a match must keep the
    /// wallpaper it was made from.
    private func keepWallpaper(forTheme id: String) {
        wallpapers.update { settings in
            var memory = settings.perTheme ?? [:]
            memory[id] = settings.light
            settings.perTheme = memory
        }
    }
}

extension ThemesApp {
    /// Posted with `sectionArgument` in `userInfo` to switch an open Themes window.
    static let sectionRequested = Notification.Name("DesktopKit.themesSectionRequested")
}
