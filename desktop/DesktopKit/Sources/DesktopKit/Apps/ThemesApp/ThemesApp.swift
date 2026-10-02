import SwiftUI

/// Colour themes, light/dark pairing, a theme editor, styling knobs and saved looks.
enum ThemesApp {
    static let id = "themes"
    /// Launch argument: the section to open ("gallery", "appearance", "editor", "styling", "icons", "looks").
    static let sectionArgument = "section"

    static func descriptor() -> DesktopAppDescriptor {
        DesktopAppDescriptor(
            id: id, name: "Themes", symbol: "paintpalette", category: .system,
            defaultSize: CGSize(width: 1020, height: 680), allowsMultipleWindows: false, showsOnDesktop: true
        ) { context in
            AnyView(ThemesAppView(context: context))
        }
    }
}

enum ThemesSection: String, CaseIterable, Identifiable {
    case gallery, appearance, editor, styling, icons, looks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gallery: "Gallery"
        case .appearance: "Light & Dark"
        case .editor: "Theme Editor"
        case .styling: "Styling"
        case .icons: "Icons"
        case .looks: "Looks"
        }
    }

    var symbol: String {
        switch self {
        case .gallery: "square.grid.2x2"
        case .appearance: "circle.lefthalf.filled"
        case .editor: "eyedropper.halffull"
        case .styling: "slider.horizontal.3"
        case .icons: "app.badge"
        case .looks: "sparkles"
        }
    }
}

struct ThemesAppView: View {
    let context: AppLaunchContext
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopController) private var controller
    @State private var section: ThemesSection

    init(context: AppLaunchContext) {
        self.context = context
        _section = State(initialValue: context.arguments[ThemesApp.sectionArgument].flatMap(ThemesSection.init) ?? .gallery)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            theme.separator.frame(width: 1)
            Group {
                if let controller {
                    content(controller)
                } else {
                    Text("Themes needs the desktop.").foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .onAppear { context.window.setTitle("Themes") }
        .onDisappear { controller?.colorThemes.previewID = nil }
        .onChange(of: section) { _, _ in controller?.colorThemes.previewID = nil }
        .task { if let controller { await controller.colorThemes.load(host: context.host) } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ThemesSection.allCases) { item in
                Button { section = item } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.system(size: 13, weight: section == item ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(section == item ? theme.accent.opacity(0.18) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityAddTraits(section == item ? .isSelected : [])
                .accessibilityIdentifier("themes.section.\(item.rawValue)")
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 190)
    }

    @ViewBuilder
    private func content(_ controller: DesktopController) -> some View {
        switch section {
        case .gallery: ThemeGalleryView(controller: controller, host: context.host, onEdit: { _ in section = .editor })
        case .appearance: ThemeAppearanceView(controller: controller)
        case .editor: ThemeEditorView(controller: controller, host: context.host)
        case .styling: ThemeStylingView(controller: controller)
        case .icons:
            ScrollView {
                IconPackSettingsSection(store: controller.icons.packs, icons: controller.icons, host: context.host,
                                        desktop: context.desktop)
                    .padding(20)
                    .frame(maxWidth: 700, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
        case .looks: ThemeLooksView(controller: controller)
        }
    }
}

private struct DesktopControllerKey: EnvironmentKey {
    static let defaultValue: DesktopController? = nil
}

extension EnvironmentValues {
    /// The desktop, for built-in apps that change the shell itself (Themes).
    var desktopController: DesktopController? {
        get { self[DesktopControllerKey.self] }
        set { self[DesktopControllerKey.self] = newValue }
    }
}

// MARK: - Gallery

struct ThemeGalleryView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", dark = "Dark", light = "Light", favorites = "Favorites"
        var id: String { rawValue }
    }

    let controller: DesktopController
    let host: any LinuxHost
    let onEdit: (ColorTheme) -> Void
    @Environment(\.desktopTheme) private var theme
    @AppStorage("themes.favorites") private var favoritesText = ""
    @State private var filter = Filter.all
    @State private var search = ""
    @State private var installURL = ""
    @State private var isInstallPromptPresented = false
    @State private var message: String?
    @State private var pendingRemoval: ColorTheme?

    private var store: ColorThemeStore { controller.colorThemes }
    private var favorites: Set<String> { Set(favoritesText.split(separator: ",").map(String.init)) }

    private var visible: [ColorTheme] {
        store.themes.filter { candidate in
            switch filter {
            case .all: true
            case .dark: candidate.isDark
            case .light: !candidate.isDark
            case .favorites: favorites.contains(candidate.id)
            }
        }
        .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.contains(search.lowercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            theme.separator.frame(height: 1)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 16)], spacing: 18) {
                    if filter == .all && search.isEmpty {
                        card(nil)
                    }
                    ForEach(visible) { card($0) }
                }
                .padding(18)
            }
        }
        .alert("Install Theme from Git", isPresented: $isInstallPromptPresented) {
            TextField("https://github.com/…/omarchy-…-theme", text: $installURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Install") { install() }
        } message: {
            Text("Only colors.toml, icons.theme, light.mode and background images are taken from the repository.")
        }
        .confirmationDialog("Remove \(pendingRemoval?.name ?? "")?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("Remove Theme", role: .destructive) { if let pendingRemoval { remove(pendingRemoval) } }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            .accessibilityIdentifier("themes.filter")
            TextField("Search themes", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .accessibilityIdentifier("themes.search")
            Spacer()
            if let message { Text(message).font(.caption).foregroundStyle(theme.secondaryText).lineLimit(1) }
            if store.isInstalling { ProgressView().controlSize(.small) }
            if store.guestSupportsThemes {
                Button("Install from URL…") {
                    installURL = ""
                    isInstallPromptPresented = true
                }
                .disabled(store.isInstalling)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func card(_ candidate: ColorTheme?) -> some View {
        let id = candidate?.id ?? ""
        let isCurrent = store.currentID == id
        let isPreviewing = store.previewID == id
        return VStack(alignment: .leading, spacing: 8) {
            ThemePreviewCard(theme: candidate, fallback: nil, showsNotification: true)
                .frame(height: 190)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isCurrent ? theme.accent : theme.separator, lineWidth: isCurrent ? 3 : 1))
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.name(of: id)).font(.system(size: 14, weight: .semibold))
                    Text(candidate.map { ($0.isDark ? "Dark" : "Light") + ($0.isUserTheme ? " · Yours" : "") } ?? "The style's own colours")
                        .font(.caption).foregroundStyle(theme.secondaryText)
                }
                Spacer()
                if let candidate {
                    Button { toggleFavorite(candidate.id) } label: {
                        Image(systemName: favorites.contains(candidate.id) ? "star.fill" : "star")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(favorites.contains(candidate.id) ? "Remove from Favorites" : "Add to Favorites")
                    .accessibilityIdentifier("themes.favorite.\(candidate.id)")
                    Menu {
                        Button("Find Wallpapers", systemImage: "photo.on.rectangle") { controller.findWallpapers(for: candidate) }
                        Button("Duplicate & Edit", systemImage: "square.on.square") {
                            ThemeEditorView.pendingDuplicate = candidate
                            onEdit(candidate)
                        }
                        if candidate.isUserTheme {
                            Button("Remove", systemImage: "trash", role: .destructive) { pendingRemoval = candidate }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("themes.more.\(candidate.id)")
                }
                Button(isPreviewing ? "Stop Preview" : "Preview") {
                    store.previewID = isPreviewing ? nil : id
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("themes.preview.\(id.isEmpty ? "none" : id)")
                Button(isCurrent ? "Applied" : "Apply") { apply(id) }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .disabled(isCurrent && store.previewID == nil)
                    .accessibilityIdentifier("themes.apply.\(id.isEmpty ? "none" : id)")
            }
            .font(.system(size: 13))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("themes.card.\(id.isEmpty ? "none" : id)")
    }

    private func apply(_ id: String) {
        store.previewID = nil
        if controller.themeAppearance.isEnabled {
            var appearance = controller.themeAppearance
            if store.theme(id)?.isDark ?? true { appearance.darkThemeID = id } else { appearance.lightThemeID = id }
            controller.updateThemeAppearance(appearance)
        }
        controller.applyColorTheme(id)
    }

    private func toggleFavorite(_ id: String) {
        var set = favorites
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        favoritesText = set.sorted().joined(separator: ",")
    }

    private func install() {
        let url = installURL
        Task {
            message = await store.install(url: url, host: host) ?? "Installed."
        }
    }

    private func remove(_ candidate: ColorTheme) {
        Task {
            let result = await host.run("ish-colors remove \(ShellQuote.quote(candidate.id))", cwd: nil, stdin: nil)
            if !result.succeeded {
                _ = await host.run("rm -rf -- \(ShellQuote.quote(ThemeFiles.userDirectory(host: host, id: candidate.id)))",
                                   cwd: nil, stdin: nil)
            }
            store.removeLocal(candidate.id)
            await store.load(host: host)
            message = "Removed \(candidate.name)."
        }
    }
}

// MARK: - Light & Dark

struct ThemeAppearanceView: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    private var store: ColorThemeStore { controller.colorThemes }
    private var appearance: ThemeAppearance { controller.themeAppearance }

    private func binding<Value>(_ keyPath: WritableKeyPath<ThemeAppearance, Value>) -> Binding<Value> {
        Binding(get: { controller.themeAppearance[keyPath: keyPath] }, set: { value in
            var copy = controller.themeAppearance
            copy[keyPath: keyPath] = value
            copy.isEnabled = true
            controller.updateThemeAppearance(copy)
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSection(title: "Mode", symbol: "circle.lefthalf.filled") {
                    Toggle("Switch themes by light and dark", isOn: Binding(get: { appearance.isEnabled }, set: { enabled in
                        var copy = appearance
                        copy.isEnabled = enabled
                        if enabled, copy.lightThemeID.isEmpty, copy.darkThemeID.isEmpty { seedPair(&copy) }
                        controller.updateThemeAppearance(copy)
                    }))
                    .accessibilityIdentifier("themes.mode.enabled")
                    Picker("Mode", selection: binding(\.mode)) {
                        ForEach(ThemeAppearanceMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("themes.mode")
                    Text("Now: \(store.name(of: store.currentID))")
                        .font(.callout.weight(.medium))
                        .accessibilityIdentifier("themes.mode.current")
                    if appearance.mode == .scheduled {
                        HStack(spacing: 16) {
                            DatePicker("Light from", selection: timeBinding(\.schedule.lightStart), displayedComponents: .hourAndMinute)
                            DatePicker("Dark from", selection: timeBinding(\.schedule.darkStart), displayedComponents: .hourAndMinute)
                        }
                        Text("Fixed times stand in for sunrise and sunset, so no location is needed.")
                            .font(.caption).foregroundStyle(theme.secondaryText)
                    }
                    if appearance.mode == .automatic {
                        Text("Follows iPadOS: the light theme in Light Mode, the dark one in Dark Mode.")
                            .font(.caption).foregroundStyle(theme.secondaryText)
                    }
                }
                SettingsSection(title: "Pair", symbol: "rectangle.on.rectangle") {
                    SettingsRow(title: "Light theme") {
                        Picker("Light theme", selection: binding(\.lightThemeID)) {
                            Text("Style Colors").tag("")
                            ForEach(store.themes.filter { !$0.isDark }) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("themes.lightTheme")
                    }
                    SettingsRow(title: "Dark theme") {
                        Picker("Dark theme", selection: binding(\.darkThemeID)) {
                            Text("Style Colors").tag("")
                            ForEach(store.themes.filter(\.isDark)) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("themes.darkTheme")
                    }
                    HStack(spacing: 14) {
                        previewTile(appearance.lightThemeID, label: "Light")
                        previewTile(appearance.darkThemeID, label: "Dark")
                    }
                }
                SettingsSection(title: "Pairing table", symbol: "arrow.left.arrow.right") {
                    Text("Choosing a light theme above picks its partner below as the dark one. Edit any pair.")
                        .font(.caption).foregroundStyle(theme.secondaryText)
                    let table = ThemePairing.table(for: store.themes, overrides: appearance.pairs)
                    ForEach(table.keys.sorted(), id: \.self) { light in
                        SettingsRow(title: store.name(of: light)) {
                            Picker("Pair for \(light)", selection: Binding(get: { table[light] ?? "" }, set: { dark in
                                var copy = controller.themeAppearance
                                copy.pairs[light] = dark
                                controller.updateThemeAppearance(copy)
                            })) {
                                ForEach(store.themes.filter(\.isDark)) { Text($0.name).tag($0.id) }
                            }
                            .labelsHidden()
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: appearance.lightThemeID) { _, light in
            guard !light.isEmpty else { return }
            let partner = ThemePairing.partner(of: light, in: store.themes, overrides: appearance.pairs)
            if partner != appearance.darkThemeID {
                var copy = appearance
                copy.darkThemeID = partner
                controller.updateThemeAppearance(copy)
            }
        }
    }

    private func seedPair(_ appearance: inout ThemeAppearance) {
        let current = store.currentID
        let partner = ThemePairing.partner(of: current, in: store.themes, overrides: appearance.pairs)
        if store.theme(current)?.isDark ?? true {
            appearance.darkThemeID = current
            appearance.lightThemeID = partner == current ? "" : partner
        } else {
            appearance.lightThemeID = current
            appearance.darkThemeID = partner
        }
    }

    private func timeBinding(_ keyPath: WritableKeyPath<ThemeAppearance, Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(byAdding: .minute, value: controller.themeAppearance[keyPath: keyPath],
                                  to: Calendar.current.startOfDay(for: Date())) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            var copy = controller.themeAppearance
            copy[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            controller.updateThemeAppearance(copy)
        })
    }

    private func previewTile(_ id: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ThemePreviewCard(theme: store.theme(id), fallback: nil)
                .frame(width: 220, height: 140)
            Text("\(label): \(store.name(of: id))").font(.caption).foregroundStyle(theme.secondaryText)
        }
    }
}

// MARK: - Styling

struct ThemeStylingView: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme
    @AppStorage(DesktopSettings.tilingGapKey) private var innerGap = DesktopSettings.defaultTilingGap
    @AppStorage(DesktopSettings.monospacedFontSizeKey) private var monoSize = DesktopSettings.defaultMonospacedFontSize

    private func binding<Value>(_ keyPath: WritableKeyPath<DesktopStyling, Value>) -> Binding<Value> {
        Binding(get: { controller.styling[keyPath: keyPath] }, set: { value in
            var copy = controller.styling
            copy[keyPath: keyPath] = value
            controller.updateStyling(copy)
        })
    }

    /// An optional knob as a slider; the toggle hands it back to the style.
    private func optionalSlider(_ title: String, _ keyPath: WritableKeyPath<DesktopStyling, Double?>,
                                range: ClosedRange<Double>, step: Double, styleValue: Double, unit: String = " pt",
                                id: String) -> some View {
        let value = controller.styling[keyPath: keyPath]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value.map { "\(Int($0))\(unit)" } ?? "Style default").font(.callout.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
                Toggle("Custom \(title)", isOn: Binding(get: { value != nil }, set: { on in
                    var copy = controller.styling
                    copy[keyPath: keyPath] = on ? styleValue : nil
                    controller.updateStyling(copy)
                }))
                .labelsHidden()
                .accessibilityIdentifier("themes.styling.\(id).custom")
            }
            if value != nil {
                Slider(value: Binding(get: { controller.styling[keyPath: keyPath] ?? styleValue }, set: { new in
                    var copy = controller.styling
                    copy[keyPath: keyPath] = (new / step).rounded() * step
                    controller.updateStyling(copy)
                }), in: range)
                .tint(theme.accent)
                .accessibilityIdentifier("themes.styling.\(id)")
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSection(title: "Windows", symbol: "macwindow") {
                    optionalSlider("Corner radius", \.cornerRadius, range: 0...16, step: 1, styleValue: theme.cornerRadius, id: "radius")
                    optionalSlider("Border width", \.borderWidth, range: 0...4, step: 1, styleValue: 2, id: "border")
                    SettingsRow(title: "Focus ring") {
                        Picker("Focus ring", selection: binding(\.focusRing)) {
                            ForEach(DesktopStyling.FocusRing.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                        .accessibilityIdentifier("themes.styling.focusRing")
                    }
                    SettingsRow(title: "Window shadows") {
                        Toggle("Window shadows", isOn: binding(\.windowShadows)).labelsHidden()
                    }
                }
                SettingsSection(title: "Tiling", symbol: "rectangle.split.2x1") {
                    SettingsRow(title: "Inner gap") {
                        Stepper("\(Int(innerGap)) pt", value: $innerGap, in: 0...24, step: 1).fixedSize()
                    }
                    optionalSlider("Outer gap", \.outerGap, range: 0...32, step: 1, styleValue: innerGap * 2, id: "outerGap")
                    SettingsRow(title: "Zen (no gaps, borders, rounding) ⌃⌥⇧⌫") {
                        Toggle("Zen", isOn: Binding(get: { controller.windowManager.isZen }, set: { on in
                            withAnimation(DesktopMotion.tile) { controller.windowManager.isZen = on }
                        }))
                        .labelsHidden()
                        .accessibilityIdentifier("themes.styling.zen")
                    }
                }
                SettingsSection(title: "Panels", symbol: "menubar.rectangle") {
                    optionalSlider("Panel & dock opacity", \.panelOpacity, range: 0.3...1, step: 0.05, styleValue: 0.85, unit: "", id: "panelOpacity")
                    SettingsRow(title: "Blur behind panels") {
                        Toggle("Blur behind panels", isOn: binding(\.panelBlur)).labelsHidden()
                    }
                    Text("Panel position follows the layout style (Windows and Kylin at the bottom, macOS and Ubuntu at the top); change the style in Looks or Settings.")
                        .font(.caption).foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SettingsSection(title: "Fonts", symbol: "textformat") {
                    SettingsRow(title: "Desktop font") {
                        Picker("Desktop font", selection: binding(\.uiFont)) {
                            ForEach(DesktopStyling.UIFontDesign.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                    }
                    SettingsRow(title: "Linux apps font") {
                        Picker("Linux apps font", selection: binding(\.linuxUIFont)) {
                            Text("Style default").tag(String?.none)
                            ForEach(DesktopStyling.linuxUIFonts, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .labelsHidden()
                    }
                    SettingsRow(title: "Terminal font") {
                        Picker("Terminal font", selection: binding(\.linuxMonoFont)) {
                            Text("Style default").tag(String?.none)
                            ForEach(DesktopStyling.linuxMonoFonts, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .labelsHidden()
                    }
                    SettingsRow(title: "Monospaced size") {
                        Stepper("\(Int(monoSize)) pt", value: $monoSize, in: DesktopSettings.monospacedFontSizeRange, step: 1)
                            .fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Text size for Linux apps and terminals: \(Int(controller.styling.fontScale * 100)) %").font(.callout)
                        Slider(value: Binding(get: { controller.styling.fontScale }, set: { value in
                            var copy = controller.styling
                            copy.fontScale = (value * 20).rounded() / 20
                            controller.updateStyling(copy)
                        }), in: 0.9...1.2)
                        .tint(theme.accent)
                    }
                    Text("The desktop's own text uses the iPad's fonts in the chosen design; Linux apps get the font, size and cursor size through GTK and foot (new windows).")
                        .font(.caption).foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SettingsSection(title: "Motion & pointer", symbol: "cursorarrow.motionlines") {
                    SettingsRow(title: "Animations") {
                        Picker("Animations", selection: binding(\.animation)) {
                            ForEach(DesktopStyling.AnimationSpeed.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                    SettingsRow(title: "Cursor size in Linux apps") {
                        Picker("Cursor size", selection: binding(\.cursorSize)) {
                            Text("Style default").tag(Int?.none)
                            ForEach(DesktopStyling.cursorSizes, id: \.self) { Text("\($0) px").tag(Int?.some($0)) }
                        }
                        .labelsHidden()
                    }
                    Text("Reduce Motion in iPadOS settings always wins over the animation choice.")
                        .font(.caption).foregroundStyle(theme.secondaryText)
                }
                Button("Reset Styling to Style Defaults") { controller.updateStyling(DesktopStyling()) }
                    .accessibilityIdentifier("themes.styling.reset")
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Looks

struct ThemeLooksView: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme
    @AppStorage(DesktopStyle.storageKey) private var styleID = DesktopStyle.defaultStyle.rawValue
    @State private var userLooks = DesktopLook.loadUserLooks()
    @State private var isNaming = false
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("A look sets the layout style, colour theme, fonts, corners and gaps in one tap.")
                        .font(.callout).foregroundStyle(theme.secondaryText)
                    Spacer()
                    Button("Save Current Look…") {
                        name = ""
                        isNaming = true
                    }
                    .accessibilityIdentifier("themes.looks.save")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 16)], spacing: 18) {
                    ForEach(DesktopLook.builtIn + userLooks) { look in lookCard(look) }
                }
            }
            .padding(20)
        }
        .alert("Save Look", isPresented: $isNaming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") { save() }
        }
    }

    private func lookCard(_ look: DesktopLook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemePreviewCard(theme: controller.colorThemes.theme(look.colorThemeID), fallback: nil)
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: CGFloat(look.styling.cornerRadius ?? 10), style: .continuous))
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(look.name).font(.system(size: 14, weight: .semibold))
                    Text("\(look.style.displayName) · \(controller.colorThemes.name(of: look.colorThemeID))")
                        .font(.caption).foregroundStyle(theme.secondaryText)
                }
                Spacer()
                if !look.isBuiltIn {
                    Button(role: .destructive) {
                        userLooks.removeAll { $0.id == look.id }
                        DesktopLook.saveUserLooks(userLooks)
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete \(look.name)")
                }
                if let query = look.wallpaperQuery {
                    Button("Wallpapers") {
                        controller.open(appID: WallpapersApp.id, arguments: [WallpapersApp.queryArgument: query])
                        NotificationCenter.default.post(name: WallpapersApp.searchRequested, object: nil,
                                                        userInfo: [WallpapersApp.queryArgument: query])
                    }
                    .buttonStyle(.bordered)
                }
                Button("Apply") { controller.applyLook(look) }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .accessibilityIdentifier("themes.looks.apply.\(look.id)")
            }
            .font(.system(size: 13))
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let look = DesktopLook(id: "user-\(UUID().uuidString.prefix(8).lowercased())", name: trimmed, styleID: styleID,
                               colorThemeID: controller.colorThemes.currentID, styling: controller.styling,
                               wallpaperQuery: controller.colorThemes.current?.wallhaven?.q)
        userLooks.append(look)
        DesktopLook.saveUserLooks(userLooks)
    }
}
