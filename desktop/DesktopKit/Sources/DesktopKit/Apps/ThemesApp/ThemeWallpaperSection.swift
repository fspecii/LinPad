import SwiftUI

/// Themes › Wallpaper: Match to Wallpaper for the current wallpaper, the library (built-ins,
/// downloads in Application Support/Wallpapers, Photos, Files, Linux pictures, per-workspace
/// or all workspaces) and the Wallhaven browser.
struct ThemeWallpaperView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case library = "Library", wallhaven = "Wallhaven"
        var id: String { rawValue }
    }

    let controller: DesktopController
    let context: AppLaunchContext
    let onEdit: () -> Void
    @Environment(\.desktopTheme) private var theme
    @State private var pane = Pane.library
    @State private var proposal: WallpaperMatchProposal?

    private var source: WallpaperSource {
        controller.wallpapers.activeSource(workspace: controller.wallpapers.currentWorkspace, isDark: controller.wallpapers.isDark)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .padding(.vertical, 10)
            .accessibilityIdentifier("themes.wallpaper.pane")
            theme.separator.frame(height: 1)
            switch pane {
            case .library:
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        matchSection
                        WallpaperSettingsSection(store: controller.wallpapers, host: context.host)
                    }
                    .padding(20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            case .wallhaven:
                WallpapersAppView(context: AppLaunchContext(host: context.host, arguments: [:],
                                                            window: FixedTitleWindow(base: context.window),
                                                            desktop: context.desktop))
            }
        }
        .task(id: source.identifier) {
            proposal = await controller.makeWallpaperMatch(for: source)
        }
    }

    private var matchSection: some View {
        SettingsSection(title: "Match to Wallpaper", symbol: "wand.and.stars") {
            if let current = proposal {
                WallpaperMatchPanel(controller: controller, proposal: Binding(get: { proposal ?? current }, set: { proposal = $0 }))
                HStack(spacing: 10) {
                    Button("Edit in Theme Editor") {
                        ThemeEditorView.pendingEdit = (proposal ?? current).chosenTheme
                        onEdit()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("themes.wallpaper.edit")
                    Spacer()
                    Button("Apply Match") { controller.applyWallpaperMatch(proposal ?? current) }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("themes.wallpaper.apply")
                }
                .font(.system(size: 13))
            } else if controller.wallpaperMatch.isAnalyzing {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text("Pick a wallpaper below to derive a matching theme from it.")
                    .font(.callout).foregroundStyle(theme.secondaryText)
            }
            ThemedSeparator()
            WallpaperAutoMatchToggle(model: controller.wallpaperMatch)
        }
    }
}

/// The embedded Wallhaven browser titles its window "Wallpapers"; inside Themes the window
/// keeps its own title.
private final class FixedTitleWindow: WindowHandle {
    let base: any WindowHandle

    init(base: any WindowHandle) {
        self.base = base
    }

    var id: UUID { base.id }
    func setTitle(_ title: String) {}
    func close() { base.close() }
}
