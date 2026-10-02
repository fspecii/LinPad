import SwiftUI

/// What onboarding does to the desktop: live previews of the choices while it is open,
/// then saving them, installing apps and (on "Show me") arranging a demo workspace.
extension DesktopController {
    /// Opens onboarding: at first launch (even while Linux is still unpacking) or again from
    /// Settings › About.
    func presentOnboarding() {
        dismissAllOverlays()
        withAnimation(DesktopMotion.standard) { isOnboardingPresented = true }
    }

    /// Shows a choice on the desktop at once. Style and appearance go through their
    /// settings (the root view follows them); the colour theme is a preview until the end,
    /// because applying it to Linux apps needs the guest.
    func previewOnboardingChoices(_ choices: OnboardingChoices) {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: DesktopStyle.storageKey) != choices.style {
            defaults.set(choices.style, forKey: DesktopStyle.storageKey)
        }
        if defaults.string(forKey: DesktopAppearance.storageKey) ?? "" != choices.appearance {
            defaults.set(choices.appearance, forKey: DesktopAppearance.storageKey)
        }
        if colorThemes.previewID != choices.colorTheme {
            colorThemes.previewID = choices.colorTheme
        }
        if let identifier = choices.wallpaper, let source = WallpaperSource(identifier: identifier),
           wallpapers.settings.light != source || wallpapers.settings.dark != source {
            wallpapers.update { settings in
                settings.light = source
                settings.dark = source
                settings.perWorkspace = [:]
                settings.usesPerWorkspace = false
                settings.slideshow.isEnabled = false
            }
        }
    }

    /// Closes onboarding and makes its choices permanent. The parts that need Linux
    /// (theming Linux apps, firstrun.json, installs) wait for it to be up.
    func completeOnboarding(_ flow: OnboardingFlow, catalog: AppCatalogModel, skipped: Bool, showDemo: Bool = false) {
        let installed = catalog.packs.filter(\.isInstalled).map(\.id)
        if skipped { flow.skip(installed: installed) } else { flow.finish(installed: installed) }
        let choices = flow.choices
        let replaySkip = flow.isReplay && skipped
        let json = flow.firstRunJSON(installed: installed)
        colorThemes.previewID = nil
        withAnimation(.easeOut(duration: 0.35)) { isOnboardingPresented = false }
        guard !replaySkip else {
            if colorThemes.currentID != choices.colorTheme { applyColorTheme(choices.colorTheme) }
            return
        }
        windowManager.setTiling(choices.autoTiling || showDemo, workspace: windowManager.currentWorkspace)
        Task { [weak self] in
            guard let self else { return }
            await waitForBoot()
            if colorThemes.currentID != choices.colorTheme { applyColorTheme(choices.colorTheme) }
            if let json {
                _ = await host.run("mkdir -p /etc/ish")
                try? await host.writeFile(OnboardingFlow.firstRunPath, data: json)
            }
            if showDemo { await arrangeDemoWorkspace() }
            let packs = choices.packs.filter { !installed.contains($0) }
            if catalog.unavailableReason == nil, !packs.isEmpty {
                catalog.install(packs)
                notify("Installing \(packs.count == 1 ? "1 app" : "\(packs.count) apps") in the background. Settings › Apps shows the progress.")
            }
            if choices.browseWallhaven {
                open(appID: WallpapersApp.id, arguments: [WallpapersApp.queryArgument: colorThemes.current?.wallhaven?.q ?? "minimal dark"])
            }
        }
    }

    func waitForBoot() async {
        while !boot.isFinished {
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Whether the guest has the app (its .desktop file), once the list has been read.
    func hasLinuxApplication(_ desktopID: String) -> Bool {
        linux?.applications.contains { $0.id == desktopID } ?? false
    }

    /// "Show me": Firefox (or the built-in browser), a terminal running the system summary,
    /// Files and, when installed, VS Code, tiled on the current workspace one after another
    /// so the tiling animation reveals them.
    func arrangeDemoWorkspace() async {
        windowManager.setTiling(true, workspace: windowManager.currentWorkspace)
        var steps: [() -> Void] = []
        if linux != nil, hasLinuxApplication("firefox-esr") {
            steps.append { [weak self] in self?.open(appID: LinuxAppID.prefix + "firefox", arguments: [:]) }
        } else {
            steps.append { [weak self] in
                self?.open(appID: AppID.browser, arguments: [AppArgument.url: "https://github.com/fspecii/LinPad"])
            }
        }
        steps.append { [weak self] in
            self?.open(appID: AppID.terminal, arguments: [AppArgument.command: Self.demoFetchCommand])
        }
        steps.append { [weak self] in self?.open(appID: AppID.files, arguments: [:]) }
        if linux != nil, hasLinuxApplication("code") {
            steps.append { [weak self] in self?.open(appID: LinuxAppID.prefix + "code", arguments: [:]) }
        }
        for (index, step) in steps.enumerated() {
            if index > 0 { try? await Task.sleep(for: .milliseconds(320)) }
            withAnimation(DesktopMotion.tile) { step() }
        }
    }

    /// The guest's own summary, LinPad's when it has one.
    static let demoFetchCommand = "clear; if command -v linpad-fetch >/dev/null 2>&1; then linpad-fetch; else fastfetch; fi"
}

extension WallpaperSource {
    /// The inverse of `identifier`.
    init?(identifier: String) {
        let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "gradient": self = .gradient(parts[1])
        case "image": self = .image(parts[1])
        case "color":
            guard let rgb = UInt32(parts[1], radix: 16) else { return nil }
            self = .color(rgb)
        default: return nil
        }
    }
}
