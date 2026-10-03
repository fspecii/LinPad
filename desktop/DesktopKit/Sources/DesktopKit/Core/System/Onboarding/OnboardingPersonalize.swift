import SwiftUI

/// "Make it yours": layout style, colour theme, light/dark and wallpaper, each applied to
/// the desktop behind the sheet the moment it is picked.
struct OnboardingPersonalize: View {
    @Bindable var flow: OnboardingFlow
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopStyleTheme) private var styleTheme
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let layout = sizeClass == .compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 26))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 32))
        ScrollView {
            layout {
                section("Layout", detail: "Where the panels, launcher and window buttons go.") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 200), spacing: 12)], spacing: 12) {
                        ForEach(DesktopStyle.groups) { group in
                            Section {
                                ForEach(group.styles) { style in styleTile(style) }
                            } header: {
                                Text(group.title)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(theme.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityAddTraits(.isHeader)
                            }
                        }
                    }
                }
                .frame(maxWidth: sizeClass == .compact ? .infinity : 430)
                VStack(alignment: .leading, spacing: 26) {
                    section("Color theme", detail: "Recolours the desktop and Linux apps.") { themeStrip }
                    section("Appearance", detail: appearanceDetail) {
                        Picker("Appearance", selection: $flow.choices.appearance) {
                            Text("Style").tag(DesktopAppearance.styleDefault.rawValue)
                            Text("Auto").tag(DesktopAppearance.system.rawValue)
                            Text("Light").tag(DesktopAppearance.light.rawValue)
                            Text("Dark").tag(DesktopAppearance.dark.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .disabled(!flow.choices.colorTheme.isEmpty)
                        .accessibilityIdentifier("onboarding.appearance")
                    }
                    section("Wallpaper", detail: nil) { wallpaperRow }
                    Toggle(isOn: $flow.choices.autoTiling) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tile windows automatically").font(.system(.callout, weight: .medium))
                            Text("New windows share the screen instead of overlapping.")
                                .font(.footnote)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .tint(theme.accent)
                    .accessibilityIdentifier("onboarding.autoTiling")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: flow.choices, initial: true) { _, choices in
            withAnimation(DesktopMotion.standard) { controller.previewOnboardingChoices(choices) }
        }
    }

    private var appearanceDetail: String {
        flow.choices.colorTheme.isEmpty ? "Style follows each layout's own default."
                                        : "\(controller.colorThemes.name(of: flow.choices.colorTheme)) sets its own."
    }

    private func section<Content: View>(_ title: String, detail: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.headline)).accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(theme.secondaryText)
                }
            }
            content()
        }
    }

    // MARK: Layout

    private func styleTile(_ style: DesktopStyle) -> some View {
        let selected = flow.choices.style == style.rawValue
        return Button {
            flow.choices.style = style.rawValue
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                StyleThumbnail(spec: style.spec, accent: theme.accent)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? theme.accent : theme.separator, lineWidth: selected ? 2.5 : 1))
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(theme.accent.readableLabel, theme.accent)
                                .padding(6)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                Text(style.displayName)
                    .font(.system(.subheadline, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? theme.primaryText : theme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .animation(DesktopMotion.quick, value: selected)
        .accessibilityLabel("\(style.displayName) layout")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("onboarding.style.\(style.rawValue)")
    }

    // MARK: Colour theme

    private var themeStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(controller.colorThemes.orderedIDs, id: \.self) { id in themeCard(id) }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
            }
            .frame(height: 104)
            .onAppear { proxy.scrollTo(flow.choices.colorTheme, anchor: .center) }
        }
    }

    private func themeCard(_ id: String) -> some View {
        let selected = flow.choices.colorTheme == id
        let name = controller.colorThemes.name(of: id)
        return Button {
            flow.choices.colorTheme = id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ThemePreviewCard(theme: controller.colorThemes.theme(id), fallback: styleTheme)
                    .frame(width: 112, height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? theme.accent : theme.separator, lineWidth: selected ? 2.5 : 1))
                Text(id.isEmpty ? "Layout colors" : name)
                    .font(.system(.caption, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)
                    .frame(width: 112, alignment: .leading)
            }
        }
        .buttonStyle(PressableStyle())
        .id(id)
        .accessibilityLabel(id.isEmpty ? "Layout colors" : "\(name) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("onboarding.theme.\(id.isEmpty ? "none" : id)")
    }

    // MARK: Wallpaper

    private var wallpaperRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(DesktopWallpaper.allCases, id: \.self) { gradient in
                    wallpaperTile(WallpaperSource.gradient(gradient.rawValue), label: gradient.rawValue.capitalized) {
                        gradient.view
                    }
                }
                ForEach(controller.wallpapers.library.filter { $0.origin == .builtIn }) { item in
                    wallpaperTile(.image(item.id), label: item.id.replacingOccurrences(of: BuiltInWallpapers.prefix, with: "").capitalized) {
                        WallpaperThumbnail(store: controller.wallpapers, item: item)
                    }
                }
                wallhavenTile
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
        }
    }

    private var currentWallpaper: String {
        flow.choices.wallpaper ?? controller.wallpapers.settings.light.identifier
    }

    private func wallpaperTile<Content: View>(_ source: WallpaperSource, label: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        let selected = currentWallpaper == source.identifier
        return Button {
            flow.choices.wallpaper = source.identifier
        } label: {
            content()
                .frame(width: 92, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? theme.accent : theme.separator, lineWidth: selected ? 2.5 : 1))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(label) wallpaper")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("onboarding.wallpaper.\(source.identifier)")
    }

    private var wallhavenTile: some View {
        let on = flow.choices.browseWallhaven
        return Button {
            flow.choices.browseWallhaven.toggle()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: on ? "checkmark" : "sparkle.magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                Text(on ? "After setup" : "Wallhaven")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(on ? theme.accent : theme.secondaryText)
            .frame(width: 92, height: 62)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.primaryText.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(on ? theme.accent : theme.separator, style: StrokeStyle(lineWidth: on ? 2 : 1, dash: on ? [] : [4, 3])))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Browse Wallhaven after setup")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityIdentifier("onboarding.wallhaven")
    }
}

/// A style's arrangement in miniature: where its bars, dock and launcher sit, with two
/// windows, drawn from the style's spec rather than a screenshot.
struct StyleThumbnail: View {
    let spec: DesktopStyleSpec
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let bar = max(7, size.height * 0.075)
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.22), Color(red: 0.24, green: 0.16, blue: 0.36)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                windows(in: windowArea(size: size, bar: bar), corner: min(spec.cornerRadius, 8) * 0.5)
                chrome(size: size, bar: bar)
            }
        }
        .accessibilityHidden(true)
    }

    private func windowArea(size: CGSize, bar: CGFloat) -> CGRect {
        var area = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.06, dy: 0)
        switch spec.shell {
        case .panel, .menuBarAndDock:
            area.origin.y = bar + 6
            area.size.height = size.height - bar - (spec.dockEdge == .bottom ? bar * 2.4 : 6) - 6
        case .topBarAndDock:
            area.origin.y = bar + 6
            area.origin.x = bar * 1.9 + 6
            area.size.width = size.width - area.origin.x - 8
            area.size.height = size.height - bar - 12
        case .taskbar, .kylinPanel:
            area.origin.y = 7
            area.size.height = size.height - bar * 1.3 - 14
        @unknown default:
            area.origin.y = bar + 6
            area.size.height = size.height - bar - 12
        }
        return area
    }

    private func windows(in area: CGRect, corner: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            thumbWindow(focused: false, corner: corner)
                .frame(width: area.width * 0.58, height: area.height * 0.66)
                .offset(x: area.minX + area.width * 0.38, y: area.minY + area.height * 0.04)
            thumbWindow(focused: true, corner: corner)
                .frame(width: area.width * 0.6, height: area.height * 0.72)
                .offset(x: area.minX, y: area.minY + area.height * 0.26)
        }
    }

    private func thumbWindow(focused: Bool, corner: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                if spec.buttonPlacement == .leading { buttons }
                Spacer(minLength: 0)
                if spec.buttonPlacement == .trailing { buttons }
            }
            .padding(.horizontal, 3)
            .frame(height: 7)
            .background(Color.white.opacity(focused ? 0.22 : 0.14))
            Color(white: 0.12, opacity: 0.92)
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
            .strokeBorder(focused ? accent.opacity(0.9) : .white.opacity(0.12), lineWidth: focused ? 1 : 0.5))
    }

    @ViewBuilder
    private var buttons: some View {
        let colors: [Color] = spec.buttonShape == .trafficLight ? [.red, .yellow, .green] : [.white, .white, .white]
        HStack(spacing: 1.5) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(colors[index].opacity(spec.buttonShape == .trafficLight ? 0.9 : 0.45)).frame(width: 3, height: 3)
            }
        }
    }

    @ViewBuilder
    private func chrome(size: CGSize, bar: CGFloat) -> some View {
        let barFill = Color.black.opacity(0.55)
        switch spec.shell {
        case .panel:
            HStack(spacing: 3) {
                Capsule().fill(accent).frame(width: bar * 1.6, height: bar * 0.5)
                ForEach(0..<2, id: \.self) { _ in Capsule().fill(.white.opacity(0.3)).frame(width: bar * 2.4, height: bar * 0.4) }
                Spacer()
                Capsule().fill(.white.opacity(0.5)).frame(width: bar * 2, height: bar * 0.4)
            }
            .padding(.horizontal, 4)
            .frame(width: size.width, height: bar)
            .background(barFill)
        case .menuBarAndDock:
            ZStack(alignment: .top) {
                HStack(spacing: 4) {
                    Circle().fill(.white.opacity(0.8)).frame(width: bar * 0.45)
                    ForEach(0..<3, id: \.self) { _ in Capsule().fill(.white.opacity(0.35)).frame(width: bar * 1.4, height: bar * 0.35) }
                    Spacer()
                }
                .padding(.horizontal, 5)
                .frame(width: size.width, height: bar)
                .background(barFill.opacity(0.6))
                dock(count: 6, size: bar)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 4)
            }
            .frame(width: size.width, height: size.height)
        case .topBarAndDock:
            ZStack(alignment: .topLeading) {
                HStack {
                    Capsule().fill(.white.opacity(0.5)).frame(width: bar * 2.6, height: bar * 0.4)
                    Spacer()
                    Capsule().fill(.white.opacity(0.7)).frame(width: bar * 1.8, height: bar * 0.4)
                    Spacer()
                }
                .padding(.horizontal, 5)
                .frame(width: size.width, height: bar)
                .background(Color.black)
                VStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2).fill(index == 0 ? accent : .white.opacity(0.35))
                            .frame(width: bar * 1.1, height: bar * 1.1)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .frame(width: bar * 1.9, height: size.height - bar)
                .background(barFill)
                .offset(y: bar)
            }
        case .taskbar:
            VStack {
                Spacer()
                HStack(spacing: 3) {
                    Spacer()
                    RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: bar * 0.9, height: bar * 0.9)
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.35)).frame(width: bar * 0.9, height: bar * 0.9)
                    }
                    Spacer()
                }
                .frame(width: size.width, height: bar * 1.3)
                .background(barFill)
            }
            .frame(width: size.width, height: size.height)
        case .kylinPanel:
            VStack {
                Spacer()
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: bar * 0.9, height: bar * 0.9)
                    Capsule().fill(.white.opacity(0.25)).frame(width: bar * 3, height: bar * 0.7)
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.35)).frame(width: bar * 0.9, height: bar * 0.9)
                    }
                    Spacer()
                    Capsule().fill(.white.opacity(0.5)).frame(width: bar * 1.8, height: bar * 0.4)
                }
                .padding(.horizontal, 4)
                .frame(width: size.width, height: bar * 1.3)
                .background(Color.white.opacity(0.18))
            }
            .frame(width: size.width, height: size.height)
        @unknown default:
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule().fill(index == 0 ? accent : .white.opacity(0.3)).frame(width: bar * 0.9, height: bar * 0.4)
                }
                Spacer()
            }
            .padding(.horizontal, 4)
            .frame(width: size.width, height: bar)
            .background(barFill)
        }
    }

    private func dock(count: Int, size: CGFloat) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2).fill(index == 0 ? accent : .white.opacity(0.4))
                    .frame(width: size * 1.1, height: size * 1.1)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.18)))
    }
}

/// Plain buttons that dip slightly while pressed and highlight under the pointer.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(DesktopMotion.quick, value: configuration.isPressed)
            .hoverEffect(.lift)
    }
}
