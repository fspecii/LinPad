import SwiftUI

/// One row of the Command Menu: an app, an open window, a desktop command, a toggle, a
/// colour theme or a look, a clipboard entry, or a `linpad://` link typed in.
struct CommandMenuItem: Identifiable {
    /// Grouped like the Omarchy menu: Apps, Style, Setup, Capture, Toggles, System, Update.
    enum Section: String, CaseIterable {
        case links = "Links"
        case sections = "Menu"
        case clipboard = "Clipboard"
        case windows = "Windows"
        case apps = "Apps"
        case style = "Style"
        case setup = "Setup"
        case capture = "Capture"
        case toggles = "Toggles"
        case system = "System"
        case update = "Update"
        case commands = "Commands"

        /// The sections the menu's index offers, and the letter that opens each.
        static let browsable: [(Section, Character)] = [
            (.apps, "a"), (.style, "s"), (.setup, "e"), (.capture, "c"), (.toggles, "t"), (.system, "y"),
            (.update, "u"), (.windows, "w"), (.commands, "o"), (.clipboard, "v"),
        ]

        var symbol: String {
            switch self {
            case .apps: "square.grid.2x2"
            case .style: "paintpalette"
            case .setup: "gearshape"
            case .capture: "camera.viewfinder"
            case .toggles: "switch.2"
            case .system: "power"
            case .update: "arrow.down.circle"
            case .windows: "macwindow.on.rectangle"
            case .commands: "command"
            case .clipboard: "doc.on.clipboard"
            case .links: "link"
            case .sections: "list.bullet"
            }
        }
    }

    let id: String
    let title: String
    var subtitle: String?
    var section: Section
    var symbol: String
    var iconName: String?
    var iconURL: URL?
    var shortcut: String?
    var isOn: Bool?
    /// Extra words the search matches (ids, categories).
    var keywords = ""
    /// Opening a section keeps the menu up; everything else closes it first.
    var keepsMenuOpen = false
    /// Clipboard rows: the entry, for pinning and removing.
    var clipboardEntryID: UUID?
    let run: @MainActor () -> Void
}

/// Fuzzy matching for the Command Menu: the query's characters in order, scored so word
/// starts and runs of consecutive characters rank first ("tn" finds "Tokyo Night").
enum CommandMenuSearch {
    static func score(_ query: String, in text: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(text.lowercased())
        var score = 0
        var index = 0
        var previousMatch = -2
        for char in needle {
            guard let found = haystack[index...].firstIndex(of: char) else { return nil }
            let isWordStart = found == 0 || !haystack[found - 1].isLetter && !haystack[found - 1].isNumber
            score += 1
            if isWordStart { score += 8 }
            if found == previousMatch + 1 { score += 5 }
            if found == 0 { score += 6 }
            score -= min(found - index, 6)
            previousMatch = found
            index = found + 1
        }
        if text.lowercased().hasPrefix(query.lowercased()) { score += 20 }
        return score
    }

    /// The best matches first; without a query, every item in section order.
    static func rank(_ items: [CommandMenuItem], query: String, limit: Int = 80) -> [CommandMenuItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(items.prefix(limit)) }
        let scored: [(CommandMenuItem, Int)] = items.compactMap { item in
            let best = [score(trimmed, in: item.title), score(trimmed, in: item.keywords).map { $0 - 6 },
                        item.subtitle.flatMap { score(trimmed, in: $0) }.map { $0 - 10 }]
                .compactMap { $0 }.max()
            return best.map { (item, $0) }
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0.title < $1.0.title : $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Items in the menu's order: sections as `Section.allCases` lists them, stable within.
    static func ordered(_ items: [CommandMenuItem]) -> [CommandMenuItem] {
        let order = Dictionary(uniqueKeysWithValues: CommandMenuItem.Section.allCases.enumerated().map { ($1, $0) })
        return items.enumerated().sorted { lhs, rhs in
            let (l, r) = (order[lhs.element.section] ?? 0, order[rhs.element.section] ?? 0)
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
    }
}

/// What the Command Menu shows right now.
struct CommandMenuState: Equatable {
    enum Mode: Hashable {
        /// ⌘K: everything, searchable.
        case all
        /// ⌃⌥⇧M: the list of sections; a section's letter opens it.
        case index
        case section(CommandMenuItem.Section)
    }

    var query = ""
    var highlighted = 0
    var mode = Mode.all
}

extension DesktopController {
    /// ⌘K: opens the Command Menu, or closes it when it is open.
    func toggleCommandMenu() {
        toggleCommandMenu(.all)
    }

    /// Opens the menu in `mode`; the same shortcut again closes it.
    func toggleCommandMenu(_ mode: CommandMenuState.Mode) {
        if let state = commandMenu {
            commandMenu = state.mode == mode ? nil : CommandMenuState(mode: mode)
            return
        }
        dismissTransientOverlays()
        isLauncherPresented = false
        themePicker = nil
        commandMenu = CommandMenuState(mode: mode)
    }

    func moveCommandMenu(by offset: Int) {
        guard var state = commandMenu else { return }
        let count = commandMenuResults().count
        guard count > 0 else { return }
        state.highlighted = ((state.highlighted + offset) % count + count) % count
        commandMenu = state
    }

    func runHighlightedCommand() {
        guard let state = commandMenu else { return }
        let results = commandMenuResults()
        guard results.indices.contains(state.highlighted) else { return }
        run(results[state.highlighted])
    }

    func run(_ item: CommandMenuItem) {
        if !item.keepsMenuOpen { commandMenu = nil }
        item.run()
    }

    /// Typing in the menu. In the index, a section's letter opens that section.
    func setCommandMenuQuery(_ query: String) {
        guard var state = commandMenu else { return }
        if state.mode == .index, query.count == 1, let letter = query.lowercased().first,
           let section = CommandMenuItem.Section.browsable.first(where: { $0.1 == letter })?.0 {
            commandMenu = CommandMenuState(mode: .section(section))
            return
        }
        state.query = query
        state.highlighted = 0
        commandMenu = state
    }

    /// What the menu lists for its mode and query.
    func commandMenuResults() -> [CommandMenuItem] {
        guard let state = commandMenu else { return [] }
        let items: [CommandMenuItem]
        switch state.mode {
        case .all: items = commandMenuItems().filter { $0.section != .clipboard }
        case .index: items = sectionIndexItems()
        case .section(let section):
            items = commandMenuItems().filter { $0.section == section } + [backToIndexItem()]
        }
        return CommandMenuSearch.rank(items, query: state.query)
    }

    private func backToIndexItem() -> CommandMenuItem {
        CommandMenuItem(id: "menu:index", title: "All Sections", section: .sections, symbol: "chevron.left",
                        keywords: "back menu", keepsMenuOpen: true) { [weak self] in
            self?.commandMenu = CommandMenuState(mode: .index)
        }
    }

    private func sectionIndexItems() -> [CommandMenuItem] {
        CommandMenuItem.Section.browsable.map { section, letter in
            CommandMenuItem(id: "menu:\(section.rawValue)", title: section.rawValue, section: .sections, symbol: section.symbol,
                            shortcut: String(letter).uppercased(), keywords: "menu section", keepsMenuOpen: true) { [weak self] in
                self?.commandMenu = CommandMenuState(mode: .section(section))
            }
        }
    }

    /// Everything the menu can do, built when it is shown so it reflects the desktop now.
    func commandMenuItems() -> [CommandMenuItem] {
        var items: [CommandMenuItem] = []
        let query = commandMenu?.query.trimmingCharacters(in: .whitespaces) ?? ""
        if query.lowercased().hasPrefix("\(LinPadLink.scheme)://"), let url = URL(string: query) {
            items.append(CommandMenuItem(id: "link", title: "Open \(query)", subtitle: "Asks before doing anything",
                                         section: .links, symbol: "link", keywords: query) {
                LinPadLinkInbox.shared.receive(url)
            })
        }
        let manager = windowManager
        for window in manager.windows where manager.isVisible(window) || window.isMinimized {
            items.append(CommandMenuItem(id: "window:\(window.id)", title: window.title,
                                         subtitle: "Window · \(manager.title(ofWorkspace: window.workspace))",
                                         section: .windows, symbol: window.symbol,
                                         iconName: iconName(forAppID: window.appID), iconURL: iconURL(forAppID: window.appID),
                                         keywords: window.appID) { [weak self] in
                self?.windowManager.focus(window.id)
            })
        }
        for app in launcherApps {
            items.append(CommandMenuItem(id: "app:\(app.id)", title: app.name, subtitle: app.category.rawValue,
                                         section: .apps, symbol: app.symbol, iconName: iconName(forAppID: app.id),
                                         iconURL: app.iconURL, keywords: app.id) { [weak self] in
                self?.open(appID: app.id, arguments: [:])
            })
        }
        for command in DesktopCommand.all where !command.id.hasPrefix("workspace.move.") {
            items.append(CommandMenuItem(id: "command:\(command.id)", title: command.title, subtitle: command.group.rawValue,
                                         section: Self.menuSection(forCommand: command.id), symbol: "command",
                                         shortcut: command.shortcutLabel, keywords: command.id) { [weak self] in
                guard let self else { return }
                command.perform(self)
            })
        }
        items += styleItems()
        items += setupItems()
        items += toggleItems()
        items += systemItems()
        items += maintenanceCommandItems().map { item in
            var item = item
            item.section = .system
            return item
        }
        items += updateItems()
        items += clipboardItems()
        return CommandMenuSearch.ordered(items)
    }

    /// Desktop commands go under the section a user would look in.
    static func menuSection(forCommand id: String) -> CommandMenuItem.Section {
        if id.hasPrefix("capture.") { return .capture }
        if id.hasPrefix("theme.") || id.hasPrefix("background.") { return .style }
        if ["launcher", "run", "terminal"].contains(id) { return .apps }
        if ["shortcuts", "commandMenu", "commandMenu.sections", "clipboard"].contains(id) { return .system }
        return .commands
    }

    private func styleItems() -> [CommandMenuItem] {
        var items: [CommandMenuItem] = []
        for theme in [nil] + colorThemes.themes.map(Optional.some) {
            let id = theme?.id ?? ""
            items.append(CommandMenuItem(id: "theme:\(id)", title: "Theme: \(colorThemes.name(of: id))",
                                         subtitle: theme.map { $0.isDark ? "Dark colour theme" : "Light colour theme" } ?? "The style's own colours",
                                         section: .style, symbol: "paintpalette", isOn: colorThemes.currentID == id,
                                         keywords: "colour color theme \(id)") { [weak self] in
                self?.applyColorTheme(id)
            })
        }
        for look in DesktopLook.builtIn + DesktopLook.loadUserLooks() {
            items.append(CommandMenuItem(id: "look:\(look.id)", title: "Look: \(look.name)", subtitle: look.style.displayName,
                                         section: .style, symbol: "sparkles", keywords: "look preset") { [weak self] in
                self?.applyLook(look)
            })
        }
        return items
    }

    private func settingsItem(_ id: String, _ title: String, page: String?, symbol: String, keywords: String) -> CommandMenuItem {
        CommandMenuItem(id: "setup:\(id)", title: title, subtitle: "Settings", section: .setup, symbol: symbol,
                        keywords: keywords) { [weak self] in
            self?.open(appID: AppID.settings, arguments: page.map { [SettingsApp.pageArgument: $0] } ?? [:])
        }
    }

    private func setupItems() -> [CommandMenuItem] {
        [
            settingsItem("settings", "Settings", page: nil, symbol: "gearshape", keywords: "preferences"),
            settingsItem("wallpaper", "Wallpaper", page: SettingsApp.wallpaperPage, symbol: "photo", keywords: "background"),
            settingsItem("icons", "Icon Packs", page: SettingsApp.iconsPage, symbol: "square.grid.3x3", keywords: "icons"),
            settingsItem("apps", "Install Apps", page: SettingsApp.appsPage, symbol: "bag", keywords: "store packages install"),
            settingsItem("keyboard", "Keyboard & Shortcuts", page: SettingsApp.shortcutsPage, symbol: "keyboard",
                         keywords: "keys shortcuts modifier extra keys"),
            settingsItem("screensaver", "Screensaver & Lock", page: SettingsApp.idlePage, symbol: "sparkles.tv",
                         keywords: "idle screensaver lock timeout"),
            settingsItem("performance", "Performance", page: SettingsApp.performancePage, symbol: "speedometer",
                         keywords: "firefox video scale"),
            CommandMenuItem(id: "setup:onboarding", title: "Welcome Tour", subtitle: "Setup", section: .setup,
                            symbol: "hand.wave", keywords: "onboarding setup intro") { [weak self] in
                self?.presentOnboarding()
            },
        ]
    }

    private func systemItems() -> [CommandMenuItem] {
        var items = [
            CommandMenuItem(id: "system:clipboard", title: "Clipboard History", section: .system, symbol: "doc.on.clipboard",
                            shortcut: "⌃⌥V", keywords: "paste copy history", keepsMenuOpen: true) { [weak self] in
                self?.commandMenu = CommandMenuState(mode: .section(.clipboard))
            },
            CommandMenuItem(id: "system:screensaver", title: "Start Screensaver", section: .system, symbol: "sparkles.tv",
                            keywords: "idle saver") { [weak self] in
                self?.idle.showScreensaver()
            },
            CommandMenuItem(id: "system:lock", title: "Lock Screen", section: .system, symbol: "lock",
                            keywords: "lock away") { [weak self] in
                self?.lockScreen()
            },
        ]
        for (title, step) in [("Brightness Up", 0.1), ("Brightness Down", -0.1)] {
            items.append(CommandMenuItem(id: "brightness:\(step)", title: title, section: .system,
                                         symbol: step > 0 ? "sun.max" : "sun.min", keywords: "screen display") { [weak self] in
                let level = min(max(UIScreen.main.brightness + step, 0), 1)
                UIScreen.main.brightness = level
                self?.showOSD(.brightness(Double(level)))
            })
        }
        if let controls = systemControls, controls.volume != nil {
            for (title, step) in [("Volume Up", Float(0.1)), ("Volume Down", Float(-0.1))] {
                items.append(CommandMenuItem(id: "volume:\(step)", title: title, subtitle: "Linux audio", section: .system,
                                             symbol: step > 0 ? "speaker.wave.3" : "speaker.wave.1", keywords: "sound audio") { [weak self] in
                    let level = min(max((controls.volume ?? 0) + step, 0), 1)
                    controls.volume = level
                    self?.showOSD(.volume(Double(level)))
                })
            }
        }
        return items
    }

    private func updateItems() -> [CommandMenuItem] {
        [
            CommandMenuItem(id: "update:check", title: "Check for Updates", subtitle: "App and Linux system", section: .update,
                            symbol: "arrow.triangle.2.circlepath", keywords: "update upgrade release") { [weak self] in
                guard let self else { return }
                open(appID: AppID.settings, arguments: [SettingsApp.pageArgument: SettingsApp.updatesPage])
                let service = UpdateService.shared(for: host)
                Task { await service.checkNow() }
            },
            CommandMenuItem(id: "update:linpad", title: "Update Everything in a Terminal", subtitle: "linpad update",
                            section: .update, symbol: "terminal", keywords: "apk upgrade packages repair kit") { [weak self] in
                self?.open(appID: AppID.terminal, arguments: [AppArgument.command: "linpad update"])
            },
            settingsItem("updates", "Updates & Rollback", page: SettingsApp.updatesPage, symbol: "clock.arrow.circlepath",
                         keywords: "update version roll back rollback"),
        ].map { item in
            var item = item
            item.section = .update
            return item
        }
    }

    private func clipboardItems() -> [CommandMenuItem] {
        let history = ClipboardHistory.shared
        return history.entries.map { entry in
            let age = entry.date.formatted(.relative(presentation: .named))
            return CommandMenuItem(id: "clipboard:\(entry.id)", title: entry.title,
                                   subtitle: "\(entry.source.title) · \(age)\(entry.isPinned ? " · Pinned" : "")",
                                   section: .clipboard, symbol: entry.isPinned ? "pin.fill" : entry.imageFile != nil ? "photo" : "doc.on.clipboard",
                                   keywords: entry.text ?? "image", clipboardEntryID: entry.id) { [weak self] in
                history.restore(entry)
                self?.notify("Copied to the clipboard. Paste with ⌘V.")
            }
        }
    }

    private func toggleItems() -> [CommandMenuItem] {
        let manager = windowManager
        let defaults = UserDefaults.standard
        let showsIcons = defaults.object(forKey: DesktopFolderModel.showIconsKey) as? Bool ?? true
        let showsPerformance = defaults.bool(forKey: DesktopSettings.performanceOverlayKey)
        let keepAwake = defaults.bool(forKey: IdleSettings.keepAwakeKey)
        let history = ClipboardHistory.shared
        return [
            CommandMenuItem(id: "toggle:tiling", title: "Auto-Tiling", subtitle: manager.title(ofWorkspace: manager.currentWorkspace),
                            section: .toggles, symbol: "rectangle.split.2x1", isOn: manager.isTiling(workspace: manager.currentWorkspace),
                            keywords: "tile tiling") { [weak self] in
                guard let manager = self?.windowManager else { return }
                withAnimation(DesktopMotion.tile) { manager.setTiling(!manager.isTiling(workspace: manager.currentWorkspace)) }
            },
            CommandMenuItem(id: "toggle:zen", title: "Zen (no gaps, borders, rounding)", section: .toggles,
                            symbol: "square.dashed", isOn: manager.isZen, keywords: "gaps borders") { [weak self] in
                withAnimation(DesktopMotion.tile) { self?.windowManager.isZen.toggle() }
            },
            CommandMenuItem(id: "toggle:dnd", title: "Do Not Disturb", section: .toggles, symbol: "moon.fill",
                            isOn: notifications.doNotDisturb, keywords: "notifications quiet") { [weak self] in
                self?.notifications.doNotDisturb.toggle()
            },
            CommandMenuItem(id: "toggle:keepAwake", title: "Keep Awake", subtitle: "No screensaver or idle lock",
                            section: .toggles, symbol: "cup.and.saucer", isOn: keepAwake, keywords: "idle caffeine") {
                UserDefaults.standard.set(!keepAwake, forKey: IdleSettings.keepAwakeKey)
            },
            CommandMenuItem(id: "toggle:clipboardPause", title: "Pause Clipboard History", section: .toggles,
                            symbol: "pause.circle", isOn: history.isPaused, keywords: "privacy clipboard") {
                history.isPaused.toggle()
            },
            CommandMenuItem(id: "toggle:icons", title: "Desktop Icons", section: .toggles, symbol: "square.grid.2x2",
                            isOn: showsIcons, keywords: "desktop icons show hide") {
                UserDefaults.standard.set(!showsIcons, forKey: DesktopFolderModel.showIconsKey)
            },
            CommandMenuItem(id: "toggle:rice", title: "Rice Mode Screenshots", subtitle: "No panels, framed on the wallpaper",
                            section: .capture, symbol: "camera.aperture", isOn: DesktopCapture.riceMode,
                            keywords: "screenshot share frame") {
                UserDefaults.standard.set(!DesktopCapture.riceMode, forKey: DesktopCapture.riceModeKey)
            },
            CommandMenuItem(id: "toggle:mic", title: "Record the Microphone", subtitle: "With screen recordings",
                            section: .capture, symbol: "mic.fill",
                            isOn: UserDefaults.standard.bool(forKey: DesktopCapture.microphoneKey), keywords: "screen recording audio") {
                let key = DesktopCapture.microphoneKey
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
            },
            CommandMenuItem(id: "toggle:performance", title: "Performance Overlay", section: .toggles, symbol: "speedometer",
                            isOn: showsPerformance, keywords: "fps gpu") {
                UserDefaults.standard.set(!showsPerformance, forKey: DesktopSettings.performanceOverlayKey)
            },
        ]
    }
}

/// ⌘K: a centred, searchable, keyboard-first list over everything above.
struct CommandMenuView: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme
    @FocusState private var fieldFocused: Bool

    private var state: CommandMenuState { controller.commandMenu ?? CommandMenuState() }

    var body: some View {
        let results = controller.commandMenuResults()
        ZStack(alignment: .top) {
            theme.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { controller.commandMenu = nil }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ThemeGlyph(symbol: "magnifyingglass", size: 15).foregroundStyle(theme.secondaryText)
                    TextField(placeholder, text: Binding(
                        get: { state.query },
                        set: { controller.setCommandMenuQuery($0) }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($fieldFocused)
                        .onSubmit { controller.runHighlightedCommand() }
                        .accessibilityIdentifier("commandMenu.search")
                        // A section's letter switches mode and clears the query; a fresh
                        // field drops the letter the old one still shows.
                        .id(state.mode)
                        .onChange(of: state.mode) { fieldFocused = true }
                    Text(shortcutHint).font(.caption.monospaced()).foregroundStyle(theme.secondaryText)
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                theme.separator.frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if results.isEmpty || isClipboard && results.count == 1 && state.query.isEmpty {
                                Text(isClipboard && state.query.isEmpty
                                     ? (ClipboardHistory.shared.isPaused ? "History is paused." : "Nothing copied yet. Copies made in LinPad and in Linux apps show up here.")
                                     : "Nothing matches “\(state.query)”")
                                    .font(.callout).foregroundStyle(theme.secondaryText)
                                    .padding(16)
                            }
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                row(item, isHighlighted: index == state.highlighted, showsSection: index == 0
                                    || results[index - 1].section != item.section || !state.query.isEmpty && index == 0)
                                    .id(item.id)
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: state.highlighted) { _, index in
                        if results.indices.contains(index) { proxy.scrollTo(results[index].id, anchor: .center) }
                    }
                }
                .frame(maxHeight: listHeight)
                theme.separator.frame(height: 1)
                footer
            }
            .frame(width: 640)
            .background(RoundedRectangle(cornerRadius: theme.cornerRadius + 4, style: .continuous).fill(theme.windowBackground))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 4, style: .continuous)
                .strokeBorder((theme.borderActive ?? theme.accent).opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            .padding(.top, 70)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("commandMenu")
        }
        .onAppear { fieldFocused = true }
    }

    private var isClipboard: Bool { state.mode == .section(.clipboard) }

    /// The list shrinks above the on-screen keyboard so the footer stays reachable.
    private var listHeight: CGFloat {
        let manager = controller.windowManager
        let available = manager.desktopSize.height - manager.keyboard.overlap - 70 - 52 - 40 - 24
        return max(140, min(420, available))
    }

    private var placeholder: String {
        switch state.mode {
        case .all: "Apps, windows, commands, themes, linpad:// links"
        case .index: "Type a section's letter, or search"
        case .section(.clipboard): "Search the clipboard history"
        case .section(let section): "Search \(section.rawValue)"
        }
    }

    private var shortcutHint: String {
        switch state.mode {
        case .all: "⌘K"
        case .index: "⌃⌥⇧M"
        case .section(.clipboard): "⌃⌥V"
        case .section(let section): section.rawValue
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 14) {
            Text(isClipboard ? "Return copies · Esc closes" : "↑↓ choose · Return runs · Esc closes")
                .font(.caption).foregroundStyle(theme.secondaryText)
            Spacer()
            if isClipboard {
                let history = ClipboardHistory.shared
                Button(history.isPaused ? "Resume History" : "Pause History") { history.isPaused.toggle() }
                    .accessibilityIdentifier("clipboard.pause")
                Button("Clear", role: .destructive) { history.clear() }
                    .disabled(history.entries.allSatisfy(\.isPinned))
                    .accessibilityIdentifier("clipboard.clear")
            }
        }
        .font(.caption.weight(.medium))
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func pinButton(_ id: UUID, isHighlighted: Bool) -> some View {
        let pinned = ClipboardHistory.shared.entries.first { $0.id == id }?.isPinned == true
        return Button { ClipboardHistory.shared.togglePin(id) } label: {
            Image(systemName: pinned ? "pin.fill" : "pin").font(.system(size: 12))
                .foregroundStyle(isHighlighted ? theme.accent.readableLabel : theme.secondaryText)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 6)
        .accessibilityLabel(pinned ? "Unpin Entry" : "Pin Entry")
        .accessibilityIdentifier("clipboard.pin.\(id)")
    }

    private func row(_ item: CommandMenuItem, isHighlighted: Bool, showsSection: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsSection && state.query.isEmpty {
                Text(item.section.rawValue.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
            }
            Button { controller.run(item) } label: {
                HStack(spacing: 10) {
                    Group {
                        if item.iconName != nil || item.iconURL != nil {
                            AppIcon(iconName: item.iconName, url: item.iconURL, symbol: item.symbol, size: 22)
                        } else {
                            ThemeGlyph(symbol: item.symbol, size: 15).font(.system(size: 14)).frame(width: 22, height: 22)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        if let subtitle = item.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(isHighlighted ? theme.accent.readableLabel.opacity(0.75) : theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if let isOn = item.isOn {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isHighlighted ? theme.accent.readableLabel : (isOn ? theme.accent : theme.secondaryText))
                    }
                    if let shortcut = item.shortcut {
                        Text(shortcut).font(.caption.monospaced())
                            .foregroundStyle(isHighlighted ? theme.accent.readableLabel : theme.secondaryText)
                    }
                }
                .foregroundStyle(isHighlighted ? theme.accent.readableLabel : theme.primaryText)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isHighlighted ? theme.accent : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .contextMenu {
                if let id = item.clipboardEntryID {
                    let pinned = ClipboardHistory.shared.entries.first { $0.id == id }?.isPinned == true
                    Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") { ClipboardHistory.shared.togglePin(id) }
                    Button("Remove", systemImage: "trash", role: .destructive) { ClipboardHistory.shared.remove(id) }
                }
            }
            .accessibilityIdentifier("commandMenu.item.\(item.id)")
            .accessibilityAddTraits(isHighlighted ? .isSelected : [])
            .overlay(alignment: .trailing) {
                if let id = item.clipboardEntryID { pinButton(id, isHighlighted: isHighlighted) }
            }
        }
    }
}
