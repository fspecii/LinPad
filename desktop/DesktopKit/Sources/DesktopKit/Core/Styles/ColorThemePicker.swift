import SwiftUI

/// ⌃⌥⇧Space: a carousel of live previews drawn with each candidate's own colours. The
/// desktop behind retints as the selection moves; Return keeps it, Esc goes back.
struct ColorThemePickerView: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopStyleTheme) private var styleTheme
    @State private var installURL = ""
    @State private var isInstallPromptPresented = false
    @State private var installError: String?

    private var store: ColorThemeStore { controller.colorThemes }

    var body: some View {
        let picker = controller.themePicker
        ZStack {
            theme.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { controller.cancelThemePicker() }
                .accessibilityHidden(true)
            VStack(spacing: 14) {
                Text(store.name(of: picker?.selectedID ?? ""))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .accessibilityIdentifier("themePicker.title")
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 14) {
                            ForEach(picker?.ids ?? [], id: \.self) { id in
                                card(id, isSelected: picker?.selectedID == id)
                                    .id(id)
                            }
                        }
                        .padding(.horizontal, 40)
                        .padding(.vertical, 6)
                    }
                    .onChange(of: picker?.selectedID, initial: true) { _, id in
                        guard let id else { return }
                        withAnimation(DesktopMotion.quick) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .frame(height: 210)
                footer(selected: picker?.selectedID ?? "")
            }
            .padding(.vertical, 22)
            .background(RoundedRectangle(cornerRadius: theme.cornerRadius + 4, style: .continuous).fill(theme.windowBackground))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 4, style: .continuous)
                .strokeBorder((theme.borderActive ?? theme.accent).opacity(0.25), lineWidth: 1))
            .padding(.horizontal, 40)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("themePicker")
        }
        .task { await store.load(host: controller.host) }
        .alert("Install Theme from Git", isPresented: $isInstallPromptPresented) {
            TextField("https://github.com/…/omarchy-…-theme", text: $installURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Install") { install() }
        } message: {
            Text("Only colours, icons choice and images are taken from the repository.")
        }
    }

    private func footer(selected: String) -> some View {
        HStack(spacing: 14) {
            Text("← → preview · Return applies · Esc goes back")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            Spacer()
            if store.isInstalling {
                ProgressView().controlSize(.small)
            }
            if let installError {
                Text(installError).font(.caption).foregroundStyle(theme.urgent).lineLimit(1)
            }
            if let candidate = store.theme(selected) {
                Button("Find Wallpapers") { controller.findWallpapers(for: candidate) }
                    .accessibilityIdentifier("themePicker.findWallpapers")
            }
            if store.guestSupportsThemes {
                Button("Install from URL…") {
                    installURL = ""
                    installError = nil
                    isInstallPromptPresented = true
                }
                .disabled(store.isInstalling)
                .accessibilityIdentifier("themePicker.install")
            }
            Button("Apply") { controller.commitThemePicker() }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .accessibilityIdentifier("themePicker.apply")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 40)
    }

    private func install() {
        let url = installURL
        Task {
            installError = await store.install(url: url, host: controller.host)
            if installError == nil, let picker = controller.themePicker {
                controller.themePicker = ColorThemePicker(ids: store.orderedIDs, currentID: picker.selectedID)
            }
        }
    }

    private func card(_ id: String, isSelected: Bool) -> some View {
        let candidate = store.theme(id)
        return Button {
            if isSelected { controller.commitThemePicker() } else { controller.previewTheme(id) }
        } label: {
            VStack(spacing: 6) {
                ThemePreviewCard(theme: candidate, fallback: styleTheme)
                    .frame(width: 236, height: 160)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? theme.accent : theme.primaryText.opacity(0.28),
                                      lineWidth: isSelected ? 3 : 1))
                HStack(spacing: 4) {
                    if id == store.currentID { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                    Text(store.name(of: id)).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                }
                .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
            }
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityLabel(store.name(of: id))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("themePicker.card.\(id.isEmpty ? "none" : id)")
    }
}

/// A miniature desktop in a theme's colours: a panel strip, two tiled windows (the left one
/// focused, with the focus ring), and a terminal showing the 16 ANSI colours.
struct ThemePreviewCard: View {
    let theme: ColorTheme?
    /// For "Style Colors", which has no palette of its own: draw with the style's theme.
    var fallback: DesktopTheme?
    /// Adds a notification bubble in the corner (the Themes gallery's larger cards).
    var showsNotification = false
    @Environment(\.desktopTheme) private var desktopTheme
    @Environment(\.desktopStyleTheme) private var styleTheme

    var body: some View {
        let colors = palette
        ZStack(alignment: .topLeading) {
            colors.background
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Circle().fill(colors.accent).frame(width: 6, height: 6)
                    Capsule().fill(colors.foreground.opacity(0.5)).frame(width: 28, height: 4)
                    Spacer()
                    Capsule().fill(colors.accent).frame(width: 14, height: 5)
                    Capsule().fill(colors.foreground.opacity(0.35)).frame(width: 10, height: 5)
                }
                .padding(.horizontal, 6)
                .frame(height: 12)
                .background(colors.darker)
                HStack(spacing: 5) {
                    window(focused: true, colors: colors) { terminal(colors) }
                    window(focused: false, colors: colors) { editor(colors) }
                }
                .padding(.horizontal, 7)
                .padding(.bottom, 7)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsNotification {
                HStack(spacing: 5) {
                    Circle().fill(colors.accent).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Capsule().fill(colors.foreground).frame(width: 46, height: 3)
                        Capsule().fill(colors.muted).frame(width: 32, height: 3)
                    }
                }
                .padding(6)
                .background(colors.background)
                .overlay(Rectangle().strokeBorder(colors.accent, lineWidth: 1.5))
                .padding(.top, 18)
                .padding(.trailing, 10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private struct Colors {
        var background, darker, foreground, muted, accent, selection, title: Color
        var ansi: [Color]
    }

    private var palette: Colors {
        if let theme {
            let bg = theme.backgroundRGB, fg = theme.foregroundRGB
            return Colors(background: bg.color, darker: bg.mix(RGB(red: 0, green: 0, blue: 0), 0.25).color,
                          foreground: fg.color, muted: fg.mix(bg, 0.34).color, accent: theme.accentRGB.color,
                          selection: theme.selectionRGB.color, title: bg.mix(fg, 0.08).color,
                          ansi: theme.terminalColors.map(\.color))
        }
        let base = fallback ?? styleTheme
        return Colors(background: base.windowBackground, darker: base.panelBackground, foreground: base.primaryText,
                      muted: base.secondaryText, accent: base.accent, selection: base.accent.opacity(0.3),
                      title: base.titleBarActive, ansi: [])
    }

    private func window<Content: View>(focused: Bool, colors: Colors, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            colors.title.frame(height: 9)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(5)
        }
        .background(colors.background)
        .overlay(Rectangle().strokeBorder(focused ? colors.accent : Color.gray.opacity(0.5), lineWidth: focused ? 1.5 : 0.75))
    }

    private func terminal(_ colors: Colors) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text("$").foregroundStyle(colors.accent)
                Text("ls").foregroundStyle(colors.foreground)
            }
            .font(.system(size: 7, design: .monospaced))
            let ansi = colors.ansi.isEmpty ? [colors.accent, colors.foreground, colors.muted] : colors.ansi
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(9), spacing: 2), count: 8), spacing: 2) {
                ForEach(ansi.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5).fill(ansi[index]).frame(width: 9, height: 9)
                }
            }
        }
    }

    private func editor(_ colors: Colors) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Capsule().fill(colors.accent).frame(width: 30, height: 3)
            Capsule().fill(colors.foreground.opacity(0.7)).frame(width: 44, height: 3)
            Capsule().fill(colors.selection).frame(width: 52, height: 6)
            Capsule().fill(colors.muted).frame(width: 36, height: 3)
            RoundedRectangle(cornerRadius: 3).fill(colors.accent).frame(width: 26, height: 9)
        }
    }
}

private struct DesktopStyleThemeKey: EnvironmentKey {
    static let defaultValue = DesktopTheme.dark
}

extension EnvironmentValues {
    /// The style's own colours, without a colour theme (the "Style Colors" preview).
    var desktopStyleTheme: DesktopTheme {
        get { self[DesktopStyleThemeKey.self] }
        set { self[DesktopStyleThemeKey.self] = newValue }
    }
}
