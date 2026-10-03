import SwiftUI

/// One row of the Command Menu: an app, an open window, a desktop command, a toggle, a
/// colour theme or a look, or a `linpad://` link typed in.
struct CommandMenuItem: Identifiable {
    enum Section: String, CaseIterable {
        case windows = "Windows"
        case apps = "Apps"
        case commands = "Commands"
        case toggles = "Toggles"
        case themes = "Themes"
        case looks = "Looks"
        case links = "Links"
    }

    let id: String
    let title: String
    var subtitle: String?
    let section: Section
    var symbol: String
    var iconName: String?
    var iconURL: URL?
    var shortcut: String?
    var isOn: Bool?
    /// Extra words the search matches (ids, categories).
    var keywords = ""
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
    static func rank(_ items: [CommandMenuItem], query: String, limit: Int = 60) -> [CommandMenuItem] {
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
}

/// What the Command Menu shows right now.
struct CommandMenuState: Equatable {
    var query = ""
    var highlighted = 0
}

extension DesktopController {
    /// ⌘K: opens the Command Menu, or closes it when it is open.
    func toggleCommandMenu() {
        if commandMenu != nil {
            commandMenu = nil
            return
        }
        dismissTransientOverlays()
        isLauncherPresented = false
        themePicker = nil
        commandMenu = CommandMenuState()
    }

    func moveCommandMenu(by offset: Int) {
        guard var state = commandMenu else { return }
        let count = CommandMenuSearch.rank(commandMenuItems(), query: state.query).count
        guard count > 0 else { return }
        state.highlighted = ((state.highlighted + offset) % count + count) % count
        commandMenu = state
    }

    func runHighlightedCommand() {
        guard let state = commandMenu else { return }
        let results = CommandMenuSearch.rank(commandMenuItems(), query: state.query)
        guard results.indices.contains(state.highlighted) else { return }
        run(results[state.highlighted])
    }

    func run(_ item: CommandMenuItem) {
        commandMenu = nil
        item.run()
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
                                         section: .commands, symbol: "command", shortcut: command.shortcutLabel,
                                         keywords: command.id) { [weak self] in
                guard let self else { return }
                command.perform(self)
            })
        }
        items += maintenanceCommandItems()
        items += toggleItems()
        for (title, step) in [("Brightness Up", 0.1), ("Brightness Down", -0.1)] {
            items.append(CommandMenuItem(id: "brightness:\(step)", title: title, section: .commands,
                                         symbol: step > 0 ? "sun.max" : "sun.min", keywords: "screen display") { [weak self] in
                let level = min(max(UIScreen.main.brightness + step, 0), 1)
                UIScreen.main.brightness = level
                self?.showOSD(.brightness(Double(level)))
            })
        }
        if let controls = systemControls, controls.volume != nil {
            for (title, step) in [("Volume Up", Float(0.1)), ("Volume Down", Float(-0.1))] {
                items.append(CommandMenuItem(id: "volume:\(step)", title: title, subtitle: "Linux audio", section: .commands,
                                             symbol: step > 0 ? "speaker.wave.3" : "speaker.wave.1", keywords: "sound audio") { [weak self] in
                    let level = min(max((controls.volume ?? 0) + step, 0), 1)
                    controls.volume = level
                    self?.showOSD(.volume(Double(level)))
                })
            }
        }
        for theme in [nil] + colorThemes.themes.map(Optional.some) {
            let id = theme?.id ?? ""
            items.append(CommandMenuItem(id: "theme:\(id)", title: "Theme: \(colorThemes.name(of: id))",
                                         subtitle: theme.map { $0.isDark ? "Dark colour theme" : "Light colour theme" } ?? "The style's own colours",
                                         section: .themes, symbol: "paintpalette", isOn: colorThemes.currentID == id,
                                         keywords: "colour color theme \(id)") { [weak self] in
                self?.applyColorTheme(id)
            })
        }
        for look in DesktopLook.builtIn + DesktopLook.loadUserLooks() {
            items.append(CommandMenuItem(id: "look:\(look.id)", title: "Look: \(look.name)", subtitle: look.style.displayName,
                                         section: .looks, symbol: "sparkles", keywords: "look preset") { [weak self] in
                self?.applyLook(look)
            })
        }
        return items
    }

    private func toggleItems() -> [CommandMenuItem] {
        let manager = windowManager
        let defaults = UserDefaults.standard
        let showsIcons = defaults.object(forKey: DesktopFolderModel.showIconsKey) as? Bool ?? true
        let showsPerformance = defaults.bool(forKey: DesktopSettings.performanceOverlayKey)
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
            CommandMenuItem(id: "toggle:icons", title: "Desktop Icons", section: .toggles, symbol: "square.grid.2x2",
                            isOn: showsIcons, keywords: "desktop icons show hide") {
                UserDefaults.standard.set(!showsIcons, forKey: DesktopFolderModel.showIconsKey)
            },
            CommandMenuItem(id: "toggle:rice", title: "Rice Mode Screenshots", subtitle: "No panels, framed on the wallpaper",
                            section: .toggles, symbol: "camera.aperture", isOn: DesktopCapture.riceMode,
                            keywords: "screenshot share frame") {
                UserDefaults.standard.set(!DesktopCapture.riceMode, forKey: DesktopCapture.riceModeKey)
            },
            CommandMenuItem(id: "toggle:mic", title: "Record the Microphone", subtitle: "With screen recordings",
                            section: .toggles, symbol: "mic.fill",
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
        let results = CommandMenuSearch.rank(controller.commandMenuItems(), query: state.query)
        ZStack(alignment: .top) {
            theme.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { controller.commandMenu = nil }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ThemeGlyph(symbol: "magnifyingglass", size: 15).foregroundStyle(theme.secondaryText)
                    TextField("Apps, windows, commands, themes, linpad:// links", text: Binding(
                        get: { state.query },
                        set: { controller.commandMenu = CommandMenuState(query: $0, highlighted: 0) }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($fieldFocused)
                        .onSubmit { controller.runHighlightedCommand() }
                        .accessibilityIdentifier("commandMenu.search")
                    Text("⌘K").font(.caption.monospaced()).foregroundStyle(theme.secondaryText)
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                theme.separator.frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if results.isEmpty {
                                Text("Nothing matches “\(state.query)”")
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
                .frame(maxHeight: 420)
                theme.separator.frame(height: 1)
                Text("↑↓ choose · Return runs · Esc closes")
                    .font(.caption).foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
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
            .accessibilityIdentifier("commandMenu.item.\(item.id)")
            .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        }
    }
}
