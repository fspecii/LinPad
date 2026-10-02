import SwiftUI

extension DesktopController {
    /// ⌃⌥⇧Space: opens the picker on the current theme; pressed again while open, moves on.
    func presentThemePicker() {
        if themePicker != nil {
            moveThemePicker(by: 1)
            return
        }
        dismissTransientOverlays()
        isLauncherPresented = false
        themePicker = ColorThemePicker(ids: colorThemes.orderedIDs, currentID: colorThemes.currentID)
        colorThemes.previewID = colorThemes.currentID
    }

    /// Arrows: the desktop redraws with the candidate at once; the guest is not touched.
    func moveThemePicker(by offset: Int) {
        themePicker?.move(by: offset)
        if let picker = themePicker { colorThemes.previewID = picker.selectedID }
    }

    func previewTheme(_ id: String) {
        themePicker?.select(id)
        colorThemes.previewID = id
    }

    func commitThemePicker() {
        guard let picker = themePicker else { return }
        themePicker = nil
        colorThemes.previewID = nil
        applyColorTheme(picker.selectedID)
    }

    func cancelThemePicker() {
        themePicker = nil
        colorThemes.previewID = nil
    }

    /// ⌃⌥⇧C: the next theme, no picker.
    func cycleColorTheme() {
        let ids = colorThemes.orderedIDs
        let index = ids.firstIndex(of: colorThemes.currentID) ?? 0
        let next = ids[(index + 1) % ids.count]
        applyColorTheme(next)
        notify("Theme: \(colorThemes.name(of: next))")
    }

    /// Switches the native colours now, brings back the theme's wallpaper, then renders the
    /// theme for Linux apps in the background.
    func applyColorTheme(_ id: String) {
        let old = colorThemes.currentID
        guard id != old else { return }
        wallpapers.switchTheme(from: old, to: id)
        colorThemes.select(id)
        guard colorThemes.guestSupportsThemes else { return }
        let progress = notify("Applying \(colorThemes.name(of: id)) to Linux apps…", action: nil,
                              showsProgress: true, lifetime: .seconds(90))
        colorThemes.applyToGuest(id, host: host) { [weak self] succeeded, error in
            guard let self else { return }
            dismissToast(progress)
            if !succeeded, let error { notify("Couldn't theme Linux apps: \(error)") }
        }
    }

    /// ⌃⌥⇧B.
    func cycleWallpaper() {
        wallpapers.cycleWallpaper(themeID: colorThemes.currentID)
    }

    /// Opens the Wallpapers app searching Wallhaven for the theme's look.
    func findWallpapers(for theme: ColorTheme) {
        var arguments = [WallpapersApp.queryArgument: theme.wallhaven?.q ?? theme.name]
        if let color = theme.wallhaven?.colors?.last { arguments[WallpapersApp.colorArgument] = color }
        themePicker = nil
        colorThemes.previewID = nil
        open(appID: WallpapersApp.id, arguments: arguments)
        NotificationCenter.default.post(name: WallpapersApp.searchRequested, object: nil, userInfo: arguments)
    }
}
