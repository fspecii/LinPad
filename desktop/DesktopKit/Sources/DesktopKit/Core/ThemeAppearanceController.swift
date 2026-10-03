import SwiftUI

extension DesktopController {
    /// Themes app › Advanced styling: saves, retiles and passes fonts to Linux apps.
    func updateStyling(_ styling: DesktopStyling) {
        let fontsChanged = styling.linuxFontArguments != self.styling.linuxFontArguments
        self.styling = styling
        styling.save()
        windowManager.outerGapOverride = styling.outerGap.map { CGFloat($0) }
        if let inner = styling.innerGap {
            UserDefaults.standard.set(inner, forKey: DesktopSettings.tilingGapKey)
        }
        guard fontsChanged else { return }
        linuxFontsTask?.cancel()
        let arguments = styling.linuxFontArguments
        let host = host
        // Sliders change many times a second; the guest gets the value the user settles on.
        linuxFontsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            let command = "ish-apply-colors --fonts " + (arguments.map { $0.map(ShellQuote.quote).joined(separator: " ") } ?? "default")
            let result = await host.run(command, cwd: nil, stdin: nil)
            if !result.succeeded, result.exitCode != 127 {
                self?.notify("Couldn't set fonts for Linux apps: \(result.failureDescription)")
            }
        }
    }

    /// Themes app › Appearance: the mode and the light/dark pair.
    func updateThemeAppearance(_ appearance: ThemeAppearance) {
        themeAppearance = appearance
        appearance.save()
        evaluateThemeAppearance()
    }

    /// Applies the pair member the mode asks for now; called on mode changes, when iPadOS
    /// switches light/dark, and at the schedule's turning points.
    func evaluateThemeAppearance(now: Date = Date()) {
        scheduleTask?.cancel()
        let appearance = themeAppearance
        guard appearance.isEnabled else { return }
        let target = appearance.themeID(at: now, systemIsDark: systemIsDark)
        if target != colorThemes.currentID { applyColorTheme(target) }
        guard appearance.mode == .scheduled else { return }
        let next = appearance.schedule.nextChange(after: now)
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(next.timeIntervalSinceNow, 1) + 1))
            guard !Task.isCancelled else { return }
            self?.evaluateThemeAppearance()
        }
    }

    /// Applies a saved look: style, colour theme, styling, and optionally a wallpaper search.
    func applyLook(_ look: DesktopLook) {
        // A desktop theme's look goes through the preset, so it is applied exactly as from the
        // gallery (wallpaper, brushed metal, widgets, the dark member).
        if let id = look.presetID, let preset = DesktopThemePreset.preset(id) {
            applyDesktopThemePreset(preset, dark: look.presetDark)
            if look.styling != preset.styling { updateStyling(look.styling) }
            if let wallpaper = look.wallpaper { wallpapers.update { $0.light = wallpaper; $0.dark = wallpaper } }
            return
        }
        clearDesktopThemePreset()
        UserDefaults.standard.set(look.brushedMetal ?? false, forKey: EraSettings.brushedMetalKey)
        if let wallpaper = look.wallpaper {
            wallpapers.update { settings in
                settings.light = wallpaper
                settings.dark = wallpaper
                settings.perWorkspace = [:]
                settings.usesPerWorkspace = false
            }
        }
        UserDefaults.standard.set(look.style.rawValue, forKey: DesktopStyle.storageKey)
        if let appearance = look.appearanceID { UserDefaults.standard.set(appearance, forKey: DesktopAppearance.storageKey) }
        if themeAppearance.isEnabled {
            var appearance = themeAppearance
            appearance.isEnabled = false
            updateThemeAppearance(appearance)
        }
        // Switch the style now, so its own defaults (a style's colour theme, auto-tiling) run
        // before the look's colours instead of overriding them when the view catches up.
        let appearance = DesktopAppearance(rawValue: look.appearanceID ?? "") ?? .styleDefault
        applyStyle(look.style, dark: colorThemes.theme(look.colorThemeID)?.isDark
                   ?? appearance.isDark(style: look.style, system: systemIsDark ? .dark : .light))
        applyColorTheme(look.colorThemeID)
        updateStyling(look.styling)
        notify("Look: \(look.name)")
    }
}
