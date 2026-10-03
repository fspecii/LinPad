import SwiftUI

/// UserDefaults keys (via @AppStorage) the Settings app writes and the shell may read.
public enum DesktopSettings {
    public static let accentColorKey = "desktop.accentColor"
    public static let monospacedFontSizeKey = "desktop.monospacedFontSize"
    /// Comma-separated app ids opened when the desktop starts, like XFCE session autostart.
    public static let autostartKey = "desktop.autostart"
    /// Reopen the windows that were open when the app last quit (default on).
    public static let restoreSessionKey = "desktop.restoreSession"
    /// Show the frame-rate, frame-time and memory overlay.
    public static let performanceOverlayKey = "desktop.performanceOverlay"
    /// Launch argument (`-desktop.resetSession YES`) that starts with no saved windows.
    public static let resetSessionArgument = "desktop.resetSession"
    /// Windows style: taskbar icons centered (Windows 11) or left-aligned.
    public static let taskbarCenteredKey = "desktop.taskbarCentered"
    /// Ubuntu style: the Dock hides until the pointer reaches the left edge.
    public static let dockAutoHideKey = "desktop.dockAutoHide"
    /// Per-workspace auto-tiling settings (JSON).
    public static let tilingKey = "desktop.tiling"
    /// Space between tiles and around them, in points.
    public static let tilingGapKey = "desktop.tilingGap"
    public static let defaultTilingGap: Double = 5
    /// Window chrome metrics: "" follows the input devices, "touch" or "pointer" forces one.
    public static let windowMetricsKey = "desktop.windowMetrics"
    /// Kylin: the start menu opens full screen.
    public static let kylinMenuFullScreenKey = "desktop.kylinMenuFullScreen"
    /// macOS: icons grow under the pointer.
    public static let dockMagnificationKey = "desktop.dockMagnification"

    public static let defaultAccentColor = "blue"
    public static let defaultMonospacedFontSize: Double = 14
    public static let monospacedFontSizeRange: ClosedRange<Double> = 10...24

    public struct AccentPreset: Identifiable {
        public let id: String
        public let name: String
        public let color: Color
    }

    public static let accentPresets: [AccentPreset] = [
        AccentPreset(id: "blue", name: "Blue", color: Color(red: 0.36, green: 0.62, blue: 1.0)),
        AccentPreset(id: "purple", name: "Purple", color: Color(red: 0.66, green: 0.48, blue: 1.0)),
        AccentPreset(id: "pink", name: "Pink", color: Color(red: 1.0, green: 0.45, blue: 0.68)),
        AccentPreset(id: "orange", name: "Orange", color: Color(red: 1.0, green: 0.6, blue: 0.25)),
        AccentPreset(id: "green", name: "Green", color: Color(red: 0.36, green: 0.82, blue: 0.5)),
        AccentPreset(id: "graphite", name: "Graphite", color: Color(white: 0.62)),
    ]

    /// The color for a stored preset id; unknown ids fall back to the default preset.
    public static func accentColor(for id: String) -> Color {
        (accentPresets.first { $0.id == id } ?? accentPresets[0]).color
    }
}

enum SettingsApp {
    /// Launch argument naming the section to show first.
    static let pageArgument = "page"
    static let wallpaperPage = "wallpaper"
    static let iconsPage = "icons"
    static let appsPage = "apps"
    static let updatesPage = "updates"
    static let maintenancePage = "maintenance"

    static func descriptor() -> DesktopAppDescriptor {
        DesktopAppDescriptor(
            id: AppID.settings, name: "Settings", symbol: "gearshape", category: .settings,
            defaultSize: CGSize(width: 620, height: 560), allowsMultipleWindows: false
        ) { context in
            AnyView(SettingsAppView(context: context))
        }
    }
}

// MARK: - About model

@MainActor
@Observable
final class SystemAboutModel {
    private static let separator = "__DK_SECTION__"
    private static let command = """
        uname -a
        echo \(separator)
        cat /etc/alpine-release 2>/dev/null
        echo \(separator)
        node -v 2>/dev/null
        echo \(separator)
        npm -v 2>/dev/null
        """

    @ObservationIgnored private let host: any LinuxHost
    let hostName: String
    private(set) var kernel: String?
    private(set) var alpineRelease: String?
    private(set) var nodeVersion: String?
    private(set) var npmVersion: String?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var errorMessage: String?

    init(host: any LinuxHost) {
        self.host = host
        hostName = host.hostName
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let result = await host.run(Self.command, cwd: nil, stdin: nil)
        let sections = result.stdout.outputSections(separatedBy: Self.separator)
        func value(_ index: Int) -> String? {
            guard index < sections.count else { return nil }
            let text = sections[index].trimmedWhitespace
            return text.isEmpty ? nil : text
        }
        kernel = value(0)
        alpineRelease = value(1)
        nodeVersion = value(2)
        npmVersion = value(3)
        errorMessage = kernel == nil ? "Couldn't query the Linux system: \(result.failureDescription)" : nil
        hasLoaded = true
    }
}

// MARK: - Views

struct SettingsAppView: View {
    @Environment(\.desktopTheme) private var theme
    @AppStorage(DesktopSettings.accentColorKey) private var accentID = DesktopSettings.defaultAccentColor
    @AppStorage(DesktopSettings.monospacedFontSizeKey) private var fontSize = DesktopSettings.defaultMonospacedFontSize
    @AppStorage(DesktopSettings.restoreSessionKey) private var restoresSession = true
    @AppStorage(DesktopSettings.performanceOverlayKey) private var showsPerformance = false
    @AppStorage(DesktopShortcutModifier.storageKey) private var shortcutModifier = DesktopShortcutModifier.controlOption
    @AppStorage(LinuxKeyboardMode.storageKey) private var linuxKeyboardMode = LinuxKeyboardMode.onDemand
    @AppStorage(ExtraKeysRow.storageKey) private var showsExtraKeys = true
    @AppStorage(DesktopStyle.storageKey) private var styleID = DesktopStyle.defaultStyle.rawValue
    @AppStorage(DesktopSettings.taskbarCenteredKey) private var taskbarCentered = true
    @AppStorage(DesktopSettings.dockAutoHideKey) private var dockAutoHides = false
    @AppStorage(DesktopAppearance.storageKey) private var appearanceID = DesktopAppearance.styleDefault.rawValue
    @AppStorage(DesktopSettings.windowMetricsKey) private var metricsID = ""
    @AppStorage(DesktopSettings.dockMagnificationKey) private var dockMagnifies = true
    @AppStorage(DesktopSettings.kylinMenuFullScreenKey) private var kylinMenuFullScreen = false
    @AppStorage(DesktopSettings.tilingKey) private var tilingJSON = ""
    @AppStorage(DesktopSettings.tilingGapKey) private var tilingGap = DesktopSettings.defaultTilingGap
    @State private var about: SystemAboutModel
    @Environment(\.desktopWallpapers) private var wallpapers
    @Environment(\.desktopIcons) private var icons
    @Environment(\.desktopColorThemes) private var colorThemes
    @Environment(\.desktopController) private var desktopController
    private let fastMode: FastModeModel?
    private let window: any WindowHandle
    private let desktop: any DesktopActions
    private let host: any LinuxHost
    private let initialPage: String?

    init(context: AppLaunchContext) {
        _about = State(initialValue: SystemAboutModel(host: context.host))
        host = context.host
        initialPage = context.arguments[SettingsApp.pageArgument]
        fastMode = (context.host as? FastModeControlling)?.fastMode
        window = context.window
        desktop = context.desktop
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let fastMode { FastModeSettingsSection(fastMode: fastMode) }
                    appearanceSection
                    StoreSettingsSection(store: StoreModel.shared(for: host), desktop: desktop)
                        .id(SettingsApp.appsPage)
                    if let icons {
                        IconPackSettingsSection(store: icons.packs, icons: icons, host: host, desktop: desktop)
                            .id(SettingsApp.iconsPage)
                    }
                    if let wallpapers {
                        WallpaperSettingsSection(store: wallpapers, host: host)
                            .id(SettingsApp.wallpaperPage)
                        if let desktopController { WallpaperAutoMatchToggle(model: desktopController.wallpaperMatch).padding(.horizontal, 4) }
                    }
                    desktopSection
                    tilingSection
                    shortcutsSection
                    UpdatesSettingsSection(service: UpdateService.shared(for: host))
                        .id(SettingsApp.updatesPage)
                    MaintenanceSettingsSection(service: SystemMaintenanceService.shared(for: host))
                        .id(SettingsApp.maintenancePage)
                    aboutSection
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                if let initialPage { Task { proxy.scrollTo(initialPage, anchor: .top) } }
            }
            .onChange(of: wallpapers?.pageRequest) { _, page in
                guard let page else { return }
                withAnimation { proxy.scrollTo(page, anchor: .top) }
                wallpapers?.pageRequest = nil
            }
        }
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .onAppear { window.setTitle("Settings") }
        .task {
            if !about.hasLoaded { await about.refresh() }
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        SettingsSection(title: "Appearance", symbol: "paintpalette") {
            if let colorThemes {
                colorThemeRows(colorThemes)
                ThemedSeparator()
            }
            SettingsRow(title: "Accent color") {
                HStack(spacing: 10) {
                    ForEach(DesktopSettings.accentPresets) { preset in
                        accentSwatch(preset)
                    }
                }
            }
            ThemedSeparator()
            SettingsRow(title: "Terminal & editor font size") {
                Stepper(value: $fontSize, in: DesktopSettings.monospacedFontSizeRange, step: 1) {
                    Text("\(Int(fontSize)) pt")
                        .font(.body.monospacedDigit())
                        .frame(minWidth: 44, alignment: .trailing)
                }
                .fixedSize()
            }
            Text("const greeting = \"Hello from Alpine\";")
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.3)))
                .accessibilityLabel("Font preview")
        }
    }

    @ViewBuilder
    private func colorThemeRows(_ store: ColorThemeStore) -> some View {
        SettingsRow(title: "Color theme") {
            Picker("Color theme", selection: Binding(get: { store.currentID }, set: { store.onApplyRequest?($0) })) {
                ForEach(store.orderedIDs, id: \.self) { id in Text(store.name(of: id)).tag(id) }
            }
            .labelsHidden()
            .accessibilityIdentifier("settings.colorTheme")
        }
        HStack(spacing: 12) {
            Button("Open Themes…") { desktop.open(appID: ThemesApp.id, arguments: [:]) }
                .accessibilityIdentifier("settings.openThemes")
            Button("Browse Themes…") { store.onPickerRequest?() }
                .accessibilityIdentifier("settings.browseThemes")
            if let current = store.current {
                Button("Find Wallpapers for This Theme") { store.onFindWallpapersRequest?(current) }
            }
            Spacer()
        }
        .font(.callout)
        Text("A color theme recolors every style and, in the background, Linux apps (terminal, GTK, Qt, VS Code). ⌃⌥⇧Space opens the picker, ⌃⌥⇧C goes to the next theme, ⌃⌥⇧B to the next wallpaper. Each theme remembers its wallpaper.")
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func accentSwatch(_ preset: DesktopSettings.AccentPreset) -> some View {
        let isSelected = accentID == preset.id
        return Button {
            accentID = preset.id
        } label: {
            Circle()
                .fill(preset.color)
                .frame(width: 24, height: 24)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(preset.color.readableLabel)
                    }
                }
                .padding(3)
                .overlay(Circle().stroke(isSelected ? preset.color : Color.clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .help(preset.name)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Desktop

    private var desktopSection: some View {
        SettingsSection(title: "Desktop", symbol: "macwindow.on.rectangle") {
            Text("Style").font(.callout)
            DesktopStyleChooser(selection: $styleID)
            Text("Changes the panels, window buttons, launcher and the Linux apps' GTK, Qt and icon themes. Shortcuts and window management stay the same.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            SettingsRow(title: "Appearance") {
                Picker("Appearance", selection: $appearanceID) {
                    ForEach(DesktopAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("settings.appearance")
            }
            SettingsRow(title: "Window controls") {
                Picker("Window controls", selection: $metricsID) {
                    Text("Automatic").tag("")
                    Text("Touch").tag("touch")
                    Text("Pointer").tag("pointer")
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            if styleID == DesktopStyle.windows.rawValue {
                SettingsRow(title: "Center taskbar icons") {
                    Toggle("Center taskbar icons", isOn: $taskbarCentered).labelsHidden().tint(theme.accent)
                }
            }
            if styleID == DesktopStyle.macos.rawValue {
                SettingsRow(title: "Magnify the Dock") {
                    Toggle("Magnify the Dock", isOn: $dockMagnifies).labelsHidden().tint(theme.accent)
                }
            }
            if styleID == DesktopStyle.kylin.rawValue {
                SettingsRow(title: "Full-screen start menu") {
                    Toggle("Full-screen start menu", isOn: $kylinMenuFullScreen).labelsHidden().tint(theme.accent)
                }
            }
            if styleID == DesktopStyle.ubuntu.rawValue || styleID == DesktopStyle.macos.rawValue {
                SettingsRow(title: "Auto-hide the Dock") {
                    Toggle("Auto-hide the Dock", isOn: $dockAutoHides).labelsHidden().tint(theme.accent)
                }
            }
            ThemedSeparator()
            SettingsRow(title: "Reopen windows at launch") {
                Toggle("Reopen windows at launch", isOn: $restoresSession)
                    .labelsHidden()
                    .tint(theme.accent)
                    .accessibilityIdentifier("settings.restoreSession")
            }
            Text("Brings back open apps, their positions and workspaces. Linux apps are started again; terminals reopen as a fresh shell in the same folder.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ThemedSeparator()
            SettingsRow(title: "Performance overlay") {
                Toggle("Performance overlay", isOn: $showsPerformance)
                    .labelsHidden()
                    .tint(theme.accent)
                    .accessibilityIdentifier("settings.performanceOverlay")
            }
        }
    }

    // MARK: Tiling

    private var tilingStates: [TilingState] {
        TilingSettings.decode(tilingJSON) ?? Array(repeating: TilingState(), count: WindowManager.defaultWorkspaceCount)
    }

    private func tilingBinding(_ index: Int) -> Binding<Bool> {
        Binding(get: { tilingStates[index].isEnabled }, set: { enabled in
            var states = tilingStates
            states[index].isEnabled = enabled
            tilingJSON = TilingSettings.encode(states)
        })
    }

    private var tilingSection: some View {
        SettingsSection(title: "Auto-Tiling", symbol: "rectangle.split.2x1") {
            ForEach(tilingStates.indices, id: \.self) { index in
                SettingsRow(title: "Workspace \(index + 1)") {
                    Toggle("Tile workspace \(index + 1)", isOn: tilingBinding(index))
                        .labelsHidden()
                        .tint(theme.accent)
                        .accessibilityIdentifier("settings.tiling.\(index + 1)")
                }
            }
            ThemedSeparator()
            SettingsRow(title: "Gaps") {
                Stepper(value: $tilingGap, in: 0...32, step: 2) {
                    Text("\(Int(tilingGap)) pt").font(.body.monospacedDigit())
                }
                .fixedSize()
            }
            Text("New windows take a tile; drag a window onto another to swap them, drag the split to resize. Float a window from its menu or with ⌃⌥F. Layouts are in the panel's tiling menu (⌃⌥\\ cycles them).")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Keyboard shortcuts

    private var shortcutsSection: some View {
        SettingsSection(title: "Keyboard Shortcuts", symbol: "keyboard") {
            SettingsRow(title: "Desktop shortcuts use") {
                Picker("Desktop shortcuts use", selection: $shortcutModifier) {
                    ForEach(DesktopShortcutModifier.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .accessibilityIdentifier("settings.shortcutModifier")
            }
            Text(shortcutModifier == .command
                 ? "Applications, Run, New Terminal and Close Window are on ⌘. While a Linux app or the Terminal has focus they give ⌘ back to it, so ⌘W closes an editor tab there (⌘ arrives as Ctrl). Window commands stay on ⌃⌥ (Control-Option)."
                 : "Every desktop shortcut is on ⌃⌥ (Control-Option), so ⌘ always reaches the app: ⌘W, ⌘R and ⌘↩ in VS Code or a terminal do what they do on Linux (⌘ arrives as Ctrl). Hold ⌘ in any window to see these too.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            SettingsRow(title: "On-screen keyboard in Linux apps") {
                Picker("On-screen keyboard in Linux apps", selection: $linuxKeyboardMode) {
                    ForEach(LinuxKeyboardMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .accessibilityIdentifier("settings.linuxKeyboard")
            }
            Text("Without a hardware keyboard, the panel's keyboard button brings the on-screen keyboard up for the focused Linux window; dismiss it with its own key. With a hardware keyboard attached it never appears.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            SettingsRow(title: "Show extra keys row") {
                Toggle("Show extra keys row", isOn: $showsExtraKeys)
                    .labelsHidden()
                    .accessibilityIdentifier("settings.extraKeysRow")
            }
            Text("Esc, Tab, Ctrl and arrow keys above the on-screen keyboard in the Terminal. Hidden with a hardware keyboard and in Linux apps.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            LinuxOptionKeySettingsView()
            LinuxKeyboardLayoutSettingsView()
            ForEach(DesktopCommand.Group.allCases, id: \.self) { group in
                Text(group.rawValue)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.top, 4)
                ForEach(DesktopCommand.all.filter { $0.group == group }) { command in
                    HStack {
                        Text(command.title)
                            .font(.callout)
                        Spacer(minLength: 12)
                        Text(command.shortcutLabel)
                            .font(.callout.monospaced())
                            .foregroundStyle(theme.primaryText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(theme.primaryText.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text("Escape closes the launcher, switcher, overview and Run dialog. In the launcher, ↑↓ pick an app, Tab changes category and Return opens it.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    // MARK: About

    private var aboutSection: some View {
        SettingsSection(title: "About", symbol: "info.circle", trailing: {
            if about.isLoading {
                ProgressView().controlSize(.small)
            } else {
                ToolbarIconButton("arrow.clockwise", help: "Refresh") {
                    Task { await about.refresh() }
                }
            }
        }) {
            if let message = about.errorMessage {
                InlineBanner(kind: .error, message: message)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            aboutRow("System", Self.systemName)
            ThemedSeparator()
            aboutRow("Host name", about.hostName)
            ThemedSeparator()
            aboutRow("Alpine Linux", about.alpineRelease ?? placeholder)
            ThemedSeparator()
            aboutRow("Kernel", about.kernel ?? placeholder, monospaced: true)
            ThemedSeparator()
            SettingsRow(title: "Node.js") {
                if let node = about.nodeVersion {
                    Text(node + (about.npmVersion.map { "  ·  npm \($0)" } ?? ""))
                        .font(.callout.monospaced())
                        .foregroundStyle(theme.secondaryText)
                        .textSelection(.enabled)
                } else if about.hasLoaded {
                    ToolbarTextButton(title: "Not installed — Get Node.js", symbol: "shippingbox") {
                        desktop.open(appID: AppID.packages, arguments: [:])
                    }
                } else {
                    Text(placeholder).foregroundStyle(theme.secondaryText)
                }
            }
            if let desktopController {
                ThemedSeparator()
                SettingsRow(title: "Welcome") {
                    ToolbarTextButton(title: "Replay Welcome", symbol: "sparkles") {
                        desktopController.presentOnboarding()
                    }
                    .accessibilityIdentifier("settings.replayWelcome")
                }
            }
        }
    }

    private var placeholder: String {
        about.hasLoaded ? "Not detected" : "…"
    }

    /// The app's own name and version, with the credit to iSH (the emulator it is built on).
    private static var systemName: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = info["CFBundleDisplayName"] as? String ?? "Linux for iPad"
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        return "\(name) \(version), powered by iSH".replacingOccurrences(of: "  ", with: " ")
    }

    private func aboutRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        SettingsRow(title: title) {
            Text(value)
                .font(monospaced ? .caption.monospaced() : .callout)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }
}

/// Fast mode: the setting, what happened at this launch, a retry and the setup steps.
private struct FastModeSettingsSection: View {
    @Bindable var fastMode: FastModeModel
    @Environment(\.desktopTheme) private var theme
    @State private var showsHelp = false
    @State private var showsSetup = false

    var body: some View {
        SettingsSection(title: "Fast Mode", symbol: "bolt") {
            SettingsRow(title: "Fast mode") {
                Picker("Fast mode", selection: $fastMode.setting) {
                    ForEach(FastModeModel.Setting.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("settings.fastMode")
            }
            SettingsRow(title: "Code cache") {
                Picker("Code cache", selection: $fastMode.codeCacheMB) {
                    ForEach(FastModeModel.codeCacheChoices, id: \.self) { mb in
                        Text(mb == 0 ? "Automatic" : "\(mb) MB").tag(mb)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("settings.fastModeCodeCache")
            }
            SettingsRow(title: "Status") {
                // A green mark carries the state; green text read at under 2:1 on light themes.
                Label {
                    Text(fastMode.statusText)
                } icon: {
                    if fastModeIsOn { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green) }
                }
                    .font(.callout)
                    .foregroundStyle(fastModeIsOn ? theme.primaryText : theme.secondaryText)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.fastModeStatus")
            }
            HStack {
                Button(fastMode.status == .enabling ? "Enabling…" : "Retry fast mode") { fastMode.retry() }
                    .disabled(!fastMode.canRetry)
                    .accessibilityIdentifier("settings.fastModeRetry")
                Spacer()
                Button(showsHelp ? "Hide setup" : "How to set up") { showsHelp.toggle() }
                Button("Set Up…") { showsSetup = true }
                    .accessibilityIdentifier("settings.fastModeSetup")
            }
            .sheet(isPresented: $showsSetup) { FastModeSetupSheet(fastMode: fastMode) }
            .buttonStyle(.bordered)
            .tint(theme.accent)
            .controlSize(.small)
            Text("Automatic asks StikDebug for the native JIT each time the app starts, before Linux boots. It needs StikDebug and LocalDevVPN installed, connected and paired with this iPad. The code cache holds translated programs; Firefox wants 256 MB or more, and a larger cache uses more memory. It applies at the next launch.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if showsHelp {
                FastModeHelpText()
                    .font(.callout)
            }
        }
    }

    private var fastModeIsOn: Bool {
        if case .on = fastMode.status { return true }
        return false
    }
}

struct SettingsSection<Trailing: View, Content: View>: View {
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopStyle) private var style
    let title: String
    let symbol: String
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    init(title: String, symbol: String,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ThemedLabel(title, systemImage: symbol, points: 20)
                    .font(.headline)
                Spacer()
                trailing()
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .background {
                if let skin = style.spec.skin {
                    EraGroupBox(skin: skin)
                } else {
                    RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).fill(theme.titleBarInactive)
                    RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).stroke(theme.separator, lineWidth: 1)
                }
            }
        }
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.callout)
            Spacer(minLength: 12)
            content()
        }
        .frame(minHeight: 28)
    }
}

#Preview("Settings") {
    SettingsAppView(context: AppsPreview.context())
        .frame(width: 620, height: 560)
}
