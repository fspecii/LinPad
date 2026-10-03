import SwiftUI

/// The wallpaper with a small desktop drawn in a theme's colours on it: "before" with the
/// current theme, "after" with the match.
struct WallpaperMatchPreview: View {
    let store: WallpaperStore
    let source: WallpaperSource
    let theme: ColorTheme?
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                WallpaperView(store: store, source: source, accessibilityID: "wallmatch.preview.wallpaper")
                ThemePreviewCard(theme: theme, fallback: nil)
                    .scaleEffect(0.62, anchor: .bottomTrailing)
                    .padding(8)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(label).font(.caption).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// The palette as swatches: background, foreground, accent, then ANSI red…cyan.
struct WallpaperPaletteStrip: View {
    let theme: ColorTheme

    var body: some View {
        let colors = [theme.backgroundRGB, theme.foregroundRGB, theme.accentRGB]
            + Array(theme.terminalColors.dropFirst().prefix(6))
        HStack(spacing: 3) {
            ForEach(colors.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(colors[index].color)
                    .frame(height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.gray.opacity(0.35), lineWidth: 0.5))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Palette: background \(theme.background), foreground \(theme.foreground), accent \(theme.accent)")
        .accessibilityIdentifier("wallmatch.palette")
    }
}

/// Before/after, the generated-or-closest choice and the optional icon pack and layout,
/// shared by the post-change card and the Themes app's Wallpaper section.
struct WallpaperMatchPanel: View {
    let controller: DesktopController
    @Binding var proposal: WallpaperMatchProposal
    var compact = false
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                WallpaperMatchPreview(store: controller.wallpapers, source: proposal.source,
                                      theme: controller.colorThemes.current,
                                      label: "Now: \(controller.colorThemes.name(of: controller.colorThemes.currentID))")
                Image(systemName: "arrow.right").foregroundStyle(theme.secondaryText).padding(.top, compact ? 34 : 60)
                WallpaperMatchPreview(store: controller.wallpapers, source: proposal.source, theme: proposal.chosenTheme,
                                      label: "Matched: \(proposal.chosenTheme.name)")
                    .accessibilityIdentifier("wallmatch.after")
            }
            WallpaperPaletteStrip(theme: proposal.chosenTheme)
            if let closest = proposal.closest {
                Picker("Colors", selection: $proposal.usesClosest) {
                    Text("Generate from wallpaper").tag(false)
                    Text("Closest: \(closest.theme.name)").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("wallmatch.source")
                if !compact {
                    Text(closest.distance < WallpaperMatching.closeDistance
                         ? "\(closest.theme.name) is a close match (ΔE \(String(format: "%.3f", closest.distance)))."
                         : "Nearest existing theme: \(closest.theme.name) (ΔE \(String(format: "%.3f", closest.distance))).")
                        .font(.caption).foregroundStyle(theme.secondaryText)
                }
            }
            if !proposal.usesClosest {
                Toggle(isOn: $proposal.includesIconPack) {
                    Text("Icon pack: \(proposal.iconPack)").font(.callout)
                }
                .tint(theme.accent)
                .accessibilityIdentifier("wallmatch.icons")
            }
            if let style = proposal.style, style.style != controller.style {
                Toggle(isOn: $proposal.includesStyle) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Layout: \(style.style.displayName)").font(.callout)
                        Text(style.reason.prefix(1).uppercased() + style.reason.dropFirst()).font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .tint(theme.accent)
                .accessibilityIdentifier("wallmatch.style")
            }
        }
    }
}

/// The non-blocking card after a wallpaper change: Apply, Customize or Not now.
struct WallpaperMatchPrompt: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        if let proposal = controller.wallpaperMatch.prompt {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Match the desktop to this wallpaper?", systemImage: "wand.and.stars")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button { controller.wallpaperMatch.dismissPrompt() } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                WallpaperMatchPanel(controller: controller, proposal: Binding(
                    get: { controller.wallpaperMatch.prompt ?? proposal },
                    set: { controller.wallpaperMatch.prompt = $0 }), compact: true)
                HStack(spacing: 10) {
                    Button("Not now") { controller.wallpaperMatch.dismissPrompt() }
                        .accessibilityIdentifier("wallmatch.notNow")
                    Spacer()
                    Button("Customize…") { controller.customizeWallpaperMatch(controller.wallpaperMatch.prompt ?? proposal) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("wallmatch.customize")
                    Button("Apply") { controller.applyWallpaperMatch(controller.wallpaperMatch.prompt ?? proposal) }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("wallmatch.apply")
                }
                .font(.system(size: 13))
            }
            .padding(16)
            .frame(width: 440)
            .foregroundStyle(theme.primaryText)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.windowBackground.opacity(0.88))
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.separator, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
            .padding(16)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wallmatch.prompt")
        }
    }
}

/// "Auto-match theme to new wallpapers", for Settings › Wallpaper and Themes › Wallpaper.
struct WallpaperAutoMatchToggle: View {
    let model: WallpaperMatchModel
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Auto-match theme to new wallpapers", isOn: Binding(get: { model.autoMatch }, set: { model.autoMatch = $0 }))
                .tint(theme.accent)
                .accessibilityIdentifier("wallmatch.auto")
            Text("Colors and accent follow each wallpaper you set. The layout style never changes without asking.")
                .font(.caption).foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
