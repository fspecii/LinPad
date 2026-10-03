import SwiftUI

// The panels of the desktop themes' eras. DesktopRootView asks for "the style's taskbar",
// "menu bar", "top bar" and "Dock"; these pick the era's own when the style has a skin and
// the regular one otherwise, so the window manager and the desktop area never change.

struct StyleTaskbar: View {
    let controller: DesktopController
    @Environment(\.desktopStyle) private var style

    var body: some View {
        if let skin = style.spec.skin {
            EraTaskbar(controller: controller, skin: skin)
        } else {
            WindowsTaskbar(controller: controller)
        }
    }
}

struct StyleMenuBar: View {
    let controller: DesktopController
    @Environment(\.desktopStyle) private var style

    var body: some View {
        if let skin = style.spec.skin {
            EraMenuBar(controller: controller, skin: skin)
        } else {
            MenuBar(controller: controller)
        }
    }
}

struct StyleTopBar: View {
    let controller: DesktopController
    @Environment(\.desktopStyle) private var style

    var body: some View {
        if let skin = style.spec.skin {
            EraStatusBar(controller: controller, skin: skin)
        } else {
            TopBar(controller: controller)
        }
    }
}

struct StyleDock: View {
    let controller: DesktopController
    let axis: Dock.Axis
    @Environment(\.desktopStyle) private var style

    var body: some View {
        if let skin = style.spec.skin {
            EraDock(controller: controller, skin: skin)
        } else {
            Dock(controller: controller, axis: axis)
        }
    }
}

/// The LinPad mark the era panels use where their vendors put a logo.
struct EraMark: View {
    var size: CGFloat = 14
    var color: Color = .white

    var body: some View {
        Image(systemName: "circle.hexagongrid.fill")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
    }
}

// MARK: - Taskbars (Luna, Aero, Aero Night, Classic 98)

struct EraTaskbar: View {
    let controller: DesktopController
    let skin: EraSkin
    @Environment(\.desktopTheme) private var theme

    private var manager: WindowManager { controller.windowManager }

    static func height(_ skin: EraSkin) -> CGFloat {
        switch skin {
        case .luna: 34
        case .aero: 42
        case .aeroNight: 38
        default: 34
        }
    }

    /// The tray's glyphs read on the bar, whatever the windows' colour theme is.
    private var barTheme: DesktopTheme {
        var bar = theme
        bar.primaryText = skin == .classic ? .black : .white
        bar.secondaryText = skin == .classic ? Color(rgb: 0x404040) : Color.white.opacity(0.7)
        return bar
    }

    /// 7's superbar shows icons only; the other eras label their buttons.
    private var labelsButtons: Bool { skin != .aero }

    var body: some View {
        HStack(spacing: skin == .classic ? 3 : 4) {
            startButton
            if skin == .luna { Color(rgb: 0x1941A5).opacity(0.6).frame(width: 1).padding(.vertical, 4) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: skin == .aero ? 2 : 3) {
                    ForEach(manager.windowsInCurrentWorkspace()) { window in
                        EraTaskButton(window: window, controller: controller, skin: skin, labelled: labelsButtons)
                    }
                }
                .padding(.horizontal, 2)
            }
            Spacer(minLength: 0)
            tray
        }
        .padding(.leading, skin == .luna ? 0 : 4)
        .frame(height: Self.height(skin))
        .background(EraTaskbarBackground(skin: skin).ignoresSafeArea(edges: .bottom))
        .environment(\.desktopTheme, barTheme)
        .environment(\.colorScheme, skin == .classic ? .light : .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop.taskbar")
    }

    // MARK: Start

    private var startButton: some View {
        Button { controller.toggleLauncher() } label: {
            EraStartFace(skin: skin, isOpen: controller.isLauncherPresented, height: Self.height(skin))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Start")
        .accessibilityIdentifier("desktop.panel.applications")
    }

    // MARK: Tray

    @ViewBuilder
    private var tray: some View {
        let items = HStack(spacing: 2) {
            OverviewButton(isActive: controller.isOverviewPresented) { controller.toggleOverview() }
                .accessibilityIdentifier("desktop.panel.overview")
            WorkspaceSwitcher(manager: manager)
            SystemTrayButtons(controller: controller)
            EraClock(skin: skin)
        }
        switch skin {
        case .luna:
            items
                .padding(.horizontal, 8)
                .frame(height: Self.height(skin))
                .background(LinearGradient(colors: [Color(rgb: 0x16A3F2), Color(rgb: 0x0F8BE8), Color(rgb: 0x0C72D2)],
                                           startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .leading) { Color(rgb: 0x0B4FA6).frame(width: 1) }
                .foregroundStyle(.white)
        case .classic:
            items
                .padding(.horizontal, 4)
                .frame(height: Self.height(skin) - 8)
                .modifier(ClassicBox(sunken: true, thick: false))
                .padding(.trailing, 3)
                .foregroundStyle(.black)
        default:
            items.padding(.horizontal, 6).foregroundStyle(.white)
        }
    }
}

/// The taskbar's surface: Luna's blue, the glass eras' tinted glass, 98's grey.
struct EraTaskbarBackground: View {
    let skin: EraSkin

    var body: some View {
        switch skin {
        case .luna:
            LinearGradient(stops: [
                .init(color: Color(rgb: 0x3168D5), location: 0), .init(color: Color(rgb: 0x4993E6), location: 0.06),
                .init(color: Color(rgb: 0x2157D7), location: 0.18), .init(color: Color(rgb: 0x2663E0), location: 0.55),
                .init(color: Color(rgb: 0x2157D7), location: 0.9), .init(color: Color(rgb: 0x1941A5), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        case .aero, .aeroNight:
            let night = skin == .aeroNight
            ZStack(alignment: .top) {
                Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                LinearGradient(colors: night ? [Color.black.opacity(0.78), Color(white: 0.08).opacity(0.92)]
                                             : [Color(rgb: 0x9CC4EC).opacity(0.35), Color(rgb: 0x123458).opacity(0.62)],
                               startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [.white.opacity(night ? 0.12 : 0.22), .clear], startPoint: .top, endPoint: .center)
                Color.white.opacity(night ? 0.3 : 0.55).frame(height: 1)
            }
        default:
            ZStack(alignment: .top) {
                EraSkin.classicFace
                VStack(spacing: 0) {
                    Color(rgb: 0xDFDFDF).frame(height: 1.5)
                    Color.white.frame(height: 1.5)
                }
            }
        }
    }
}

/// The start button's face: Luna's green pill, the glass orb, 98's bevelled button.
struct EraStartFace: View {
    let skin: EraSkin
    var isOpen = false
    var height: CGFloat

    var body: some View {
        switch skin {
        case .luna:
            HStack(spacing: 6) {
                EraMark(size: 17).shadow(color: .black.opacity(0.4), radius: 1, x: 1, y: 1)
                Text("start")
                    .font(.custom("TrebuchetMS-BoldItalic", size: 19))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 0, x: 1, y: 1)
            }
            .padding(.leading, 12)
            .padding(.trailing, 22)
            .frame(height: height)
            .background(
                UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 0, bottomTrailing: 14, topTrailing: 14))
                    .fill(LinearGradient(stops: [
                        .init(color: Color(rgb: isOpen ? 0x2F7A2F : 0x5EB45A), location: 0),
                        .init(color: Color(rgb: isOpen ? 0x2A6E2A : 0x3E9B3E), location: 0.15),
                        .init(color: Color(rgb: isOpen ? 0x266426 : 0x328E32), location: 0.6),
                        .init(color: Color(rgb: 0x2B7A2B), location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.45), radius: 2, x: 2))
        case .aero, .aeroNight:
            EraOrb(size: skin == .aero ? 36 : 40, isPressed: isOpen)
                .frame(width: 54, height: height)
                .offset(y: skin == .aeroNight ? -2 : 0)
        default:
            HStack(spacing: 4) {
                EraMark(size: 13, color: Color(rgb: 0x000080))
                Text("Start").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
            }
            .padding(.horizontal, 6)
            .frame(height: height - 8)
            .modifier(ClassicBox(sunken: isOpen))
        }
    }
}

/// The glass orb of the Aero eras, with the LinPad mark instead of a vendor logo.
struct EraOrb: View {
    var size: CGFloat = 36
    var isPressed = false
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(rgb: 0x9AD8FF), Color(rgb: 0x2A7CD0), Color(rgb: 0x0B2F66)],
                                         center: UnitPoint(x: 0.5, y: 0.7), startRadius: 0, endRadius: size * 0.6))
            Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 1)
            Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1).padding(1)
            Ellipse().fill(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.78, height: size * 0.46)
                .offset(y: -size * 0.2)
            EraMark(size: size * 0.38).shadow(color: Color(rgb: 0x0B2F66), radius: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(rgb: 0x6FD0FF).opacity(isHovered || isPressed ? 0.9 : 0.25), radius: isHovered ? 8 : 4)
        .onHover { isHovered = $0 }
    }
}

private struct EraTaskButton: View {
    let window: DesktopWindow
    let controller: DesktopController
    let skin: EraSkin
    let labelled: Bool

    private var manager: WindowManager { controller.windowManager }
    private var isFocused: Bool { manager.focusedWindowID == window.id && !window.isMinimized }

    var body: some View {
        Button { manager.activateFromTaskbar(window.id) } label: {
            HStack(spacing: 6) {
                AppIcon(iconName: controller.iconName(forAppID: window.appID), url: controller.iconURL(forAppID: window.appID),
                        symbol: window.symbol, size: labelled ? 18 : 28)
                if labelled {
                    Text(window.title)
                        .font(skin == .classic ? .system(size: 12, weight: isFocused ? .bold : .regular)
                                               : .system(size: 12, weight: .regular))
                        .foregroundStyle(skin == .classic ? Color.black : Color.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, labelled ? 8 : 0)
            .frame(width: labelled ? 168 : 56, height: EraTaskbar.height(skin) - (skin == .classic ? 8 : 6))
            .background(face)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            WindowMenu(window: window, controller: controller).swiftUIItems
            Divider()
            AppContextMenu(appID: window.appID, controller: controller)
        }
        .windowPreview(for: { [window] }, controller: controller, arrowEdge: .bottom)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            manager.taskbarTargets[window.id] = frame
        }
        .accessibilityLabel(window.title)
        .accessibilityValue(window.isMinimized ? "Minimized" : isFocused ? "Active" : "")
        .accessibilityIdentifier("desktop.taskbar.item")
    }

    @ViewBuilder
    private var face: some View {
        switch skin {
        case .luna:
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LinearGradient(colors: isFocused ? [Color(rgb: 0x1E52B7), Color(rgb: 0x1A48A8)]
                                                       : [Color(rgb: 0x4C93F7), Color(rgb: 0x2C6BE0)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(isFocused ? Color.black.opacity(0.35) : Color.white.opacity(0.35), lineWidth: 1))
        case .classic:
            Rectangle().fill(isFocused ? Color(rgb: 0xE4E4E4) : EraSkin.classicFace)
                .overlay(ClassicBevel(raised: !isFocused, thick: true))
        default:
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(isFocused ? 0.38 : 0.16), .white.opacity(isFocused ? 0.14 : 0.04)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.white.opacity(isFocused ? 0.55 : 0.28), lineWidth: 1))
        }
    }
}

/// The eras' clocks: one line in Luna and 98, time over date in the glass eras.
struct EraClock: View {
    let skin: EraSkin

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 0) {
                Text(context.date.formatted(date: .omitted, time: .shortened))
                if skin == .aero {
                    Text(context.date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year()))
                }
            }
            .font(skin == .dotMatrix ? EraFonts.dot(size: 21) : .system(size: skin == .aero ? 11 : 12).monospacedDigit())
            .fontDesign(skin == .dotMatrix ? nil : .default)
            .padding(.horizontal, 6)
            .accessibilityLabel(context.date.formatted(date: .complete, time: .shortened))
            .accessibilityIdentifier("desktop.panel.clock")
        }
    }
}

// MARK: - Menu bars (Platinum, Aqua)

struct EraMenuBar: View {
    let controller: DesktopController
    let skin: EraSkin

    static let height: CGFloat = 26

    @Environment(\.desktopTheme) private var theme

    private var barTheme: DesktopTheme {
        var bar = theme
        bar.primaryText = .black
        bar.secondaryText = Color(rgb: 0x555555)
        return bar
    }

    private var manager: WindowManager { controller.windowManager }

    var body: some View {
        HStack(spacing: 16) {
            systemMenu
            Text(focusedAppName)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
            if let window = manager.focusedWindow {
                Menu("Window") { WindowMenu(window: window, controller: controller).swiftUIItems }
                    .menuStyle(.button).buttonStyle(.plain)
            }
            Menu("Go") {
                ForEach(0..<manager.workspaceCount, id: \.self) { index in
                    Button(manager.title(ofWorkspace: index)) {
                        withAnimation(DesktopMotion.standard) { manager.switchToWorkspace(index) }
                    }
                }
                Divider()
                Button("New Workspace", systemImage: "plus") { addAndSwitch(manager) }
                    .disabled(manager.workspaceCount >= WindowManager.maximumWorkspaces)
            }
            .menuStyle(.button).buttonStyle(.plain)
            Spacer(minLength: 12)
            OverviewButton(isActive: controller.isOverviewPresented) { controller.toggleOverview() }
                .accessibilityIdentifier("desktop.panel.overview")
            WorkspaceSwitcher(manager: manager)
            SystemTrayButtons(controller: controller)
            EraClock(skin: skin)
            if skin == .platinum { applicationMenu }
        }
        .font(.system(size: 13, weight: skin == .platinum ? .semibold : .regular))
        .foregroundStyle(.black)
        .environment(\.desktopTheme, barTheme)
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(background.ignoresSafeArea(edges: .top))
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private var background: some View {
        if skin == .platinum {
            ZStack(alignment: .bottom) {
                EraSkin.platinumFace
                Color.black.frame(height: 1)
            }
            .overlay(alignment: .top) { Color.white.frame(height: 1) }
        } else {
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color.white.opacity(0.97), Color(rgb: 0xE9E9E9).opacity(0.94)],
                               startPoint: .top, endPoint: .bottom)
                Color(rgb: 0x9A9A9A).frame(height: 1)
            }
        }
    }

    /// Platinum's system menu opens the launcher (apps listed as in the era's menu); Aqua's
    /// carries the system items and the Dock has the apps.
    @ViewBuilder
    private var systemMenu: some View {
        if skin == .platinum {
            Button { controller.toggleLauncher() } label: {
                EraMark(size: 15, color: Color(rgb: 0x6666CC))
                    .frame(width: 30, height: 22)
                    .background(controller.isLauncherPresented ? Color(rgb: 0x6666CC).opacity(0.25) : .clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("System menu")
            .accessibilityIdentifier("desktop.panel.applications")
        } else {
            Menu {
                Button { controller.open(appID: AppID.settings, arguments: [:]) } label: { ThemedLabel("About This Desktop", systemImage: "info.circle") }
                Divider()
                Button { controller.presentRunDialog() } label: { ThemedLabel("Run Command…", systemImage: "terminal") }
                Button { controller.open(appID: AppID.settings, arguments: [:]) } label: { ThemedLabel("Settings…", systemImage: "gearshape") }
                Divider()
                PowerMenuItems(controller: controller)
            } label: {
                EraMark(size: 15, color: Color(rgb: 0x3875D7))
                    .frame(width: 30, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain)
            .accessibilityLabel("System menu")
        }
    }

    /// The era's application menu at the right end: the windows, to switch between them.
    private var applicationMenu: some View {
        Menu {
            ForEach(manager.windowsInCurrentWorkspace()) { window in
                Button(window.title) { manager.activateFromTaskbar(window.id) }
            }
        } label: {
            HStack(spacing: 4) {
                if let window = manager.focusedWindow {
                    AppIcon(iconName: controller.iconName(forAppID: window.appID), url: controller.iconURL(forAppID: window.appID),
                            symbol: window.symbol, size: 16)
                }
                Text(focusedAppName).lineLimit(1)
            }
            .padding(.leading, 8)
            .overlay(alignment: .leading) { Color(rgb: 0x999999).frame(width: 1) }
        }
        .menuStyle(.button).buttonStyle(.plain)
        .accessibilityLabel("Application menu")
    }

    private var focusedAppName: String {
        guard let window = manager.focusedWindow else { return "Desktop" }
        return controller.launcherApps.first { $0.id == window.appID }?.name ?? window.title
    }
}

// MARK: - Status bars (Berry, Dot Matrix)

struct EraStatusBar: View {
    let controller: DesktopController
    let skin: EraSkin
    @Environment(\.desktopTheme) private var theme

    static let height: CGFloat = 32

    private var barTheme: DesktopTheme {
        guard skin == .berry else { return theme }
        var bar = theme
        bar.primaryText = .white
        bar.secondaryText = Color.white.opacity(0.65)
        return bar
    }

    private var manager: WindowManager { controller.windowManager }

    var body: some View {
        HStack(spacing: 10) {
            if skin == .berry {
                TimelineView(.everyMinute) { context in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(context.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 17, weight: .bold))
                        Text(context.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.65))
                    }
                    .accessibilityIdentifier("desktop.panel.clock")
                }
            } else {
                EraClock(skin: skin)
            }
            if let window = manager.focusedWindow, skin == .berry {
                Text(window.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(Color(rgb: 0x6CB4FF))
            }
            Spacer(minLength: 8)
            OverviewButton(isActive: controller.isOverviewPresented) { controller.toggleOverview() }
                .accessibilityIdentifier("desktop.panel.overview")
            WorkspaceSwitcher(manager: manager)
            SystemTrayButtons(controller: controller)
            PowerButton(controller: controller, size: 26)
        }
        .foregroundStyle(skin == .berry ? Color.white : theme.primaryText)
        .environment(\.desktopTheme, barTheme)
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(background.ignoresSafeArea(edges: .top))
        .environment(\.colorScheme, skin == .berry ? .dark : (theme.windowBackground.isDarkish ? .dark : .light))
    }

    @ViewBuilder
    private var background: some View {
        if skin == .berry {
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(rgb: 0x2B2F35), Color(rgb: 0x0B0C0E)], startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [Color(rgb: 0x9AA1AB), Color(rgb: 0xE6EAEE), Color(rgb: 0x9AA1AB)],
                               startPoint: .leading, endPoint: .trailing).frame(height: 1)
            }
        } else {
            theme.panelBackground
        }
    }
}

extension Color {
    /// Rough luminance test for picking light or dark controls on a flat panel.
    var isDarkish: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b < 0.5
    }
}

// MARK: - Docks (Aqua, Berry, Dot Matrix)

struct EraDock: View {
    let controller: DesktopController
    let skin: EraSkin
    @Environment(\.desktopTheme) private var theme

    private var manager: WindowManager { controller.windowManager }

    private var items: [DesktopAppDescriptor] {
        let pinned = controller.pinnedApps
        let pinnedIDs = Set(pinned.map(\.id))
        var running: [DesktopAppDescriptor] = []
        for window in manager.windows where !pinnedIDs.contains(window.appID)
            && !running.contains(where: { $0.id == window.appID }) {
            running.append(controller.launcherApps.first { $0.id == window.appID }
                ?? DesktopAppDescriptor(id: window.appID, name: window.title, symbol: window.symbol,
                                        category: .linux) { _ in AnyView(EmptyView()) })
        }
        return pinned + running
    }

    private var iconSize: CGFloat {
        switch skin {
        case .berry: 44
        case .dotMatrix: 42
        default: 48
        }
    }

    var body: some View {
        let row = HStack(alignment: .bottom, spacing: skin == .berry ? 14 : 10) {
            appsButton
            ForEach(items) { app in
                EraDockItem(app: app, controller: controller, skin: skin, size: iconSize)
            }
        }
        Group {
            switch skin {
            case .berry:
                row.padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 70)
                    .background {
                        ZStack(alignment: .top) {
                            LinearGradient(colors: [Color(rgb: 0x1C1F24), Color(rgb: 0x060708)], startPoint: .top, endPoint: .bottom)
                            LinearGradient(colors: [Color(rgb: 0x7D848E), Color(rgb: 0xE6EAEE), Color(rgb: 0x7D848E)],
                                           startPoint: .leading, endPoint: .trailing).frame(height: 1.5)
                        }
                        .ignoresSafeArea(edges: .bottom)
                    }
            case .dotMatrix:
                row.padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(theme.panelBackground))
                    .overlay(Capsule().strokeBorder(theme.primaryText.opacity(0.14), lineWidth: 1))
                    .frame(maxWidth: .infinity)
                    .frame(height: 76)
                    .padding(.bottom, 6)
            default:
                row.padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 10)
                    .background {
                        UnevenRoundedRectangle(cornerRadii: .init(topLeading: 12, bottomLeading: 0, bottomTrailing: 0, topTrailing: 12))
                            .fill(Color.white.opacity(0.32))
                            .background(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 12, bottomLeading: 0,
                                                                                  bottomTrailing: 0, topTrailing: 12))
                                .fill(.ultraThinMaterial))
                            .overlay(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 12, bottomLeading: 0,
                                                                               bottomTrailing: 0, topTrailing: 12))
                                .strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 72, alignment: .bottom)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dock")
        .accessibilityIdentifier("desktop.dock")
    }

    private var appsButton: some View {
        Button { controller.toggleLauncher() } label: {
            ZStack {
                switch skin {
                case .berry:
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Color(rgb: 0x3B4048), Color(rgb: 0x16191D)], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(rgb: 0x9AA1AB), lineWidth: 1))
                    ThemeGlyph(ThemeIconNames.launcher, symbol: "square.grid.3x3.fill", size: 18)
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                case .dotMatrix:
                    Circle().fill(theme.primaryText)
                    ThemeGlyph(ThemeIconNames.launcher, symbol: "circle.grid.3x3.fill", size: 16)
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(theme.panelBackground)
                default:
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Color(rgb: 0x7FB6FF), Color(rgb: 0x1F5FC9)], startPoint: .top, endPoint: .bottom))
                    ThemeGlyph(ThemeIconNames.launcher, symbol: "square.grid.3x3.fill", size: 20)
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: iconSize, height: iconSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityLabel("Applications")
        .accessibilityIdentifier("desktop.panel.applications")
    }
}

private struct EraDockItem: View {
    let app: DesktopAppDescriptor
    let controller: DesktopController
    let skin: EraSkin
    let size: CGFloat
    @Environment(\.desktopTheme) private var theme

    private var manager: WindowManager { controller.windowManager }
    private var windows: [DesktopWindow] { manager.windows.filter { $0.appID == app.id } }
    private var isFocused: Bool { windows.contains { $0.id == manager.focusedWindowID && !$0.isMinimized } }

    var body: some View {
        let isRunning = !windows.isEmpty
        Button(action: activate) {
            AppIcon(iconName: controller.iconName(forAppID: app.id), url: controller.iconURL(forAppID: app.id),
                    symbol: app.symbol, size: size)
                .grayscale(skin == .dotMatrix ? 1 : 0)
                .padding(skin == .berry ? 5 : 0)
                .background {
                    // The trackball era's focus: a blue glow behind the selected app.
                    if skin == .berry && isFocused {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [Color(rgb: 0x5FB0FF), Color(rgb: 0x0B5FD0)], startPoint: .top, endPoint: .bottom))
                            .shadow(color: Color(rgb: 0x1E8BFF), radius: 8)
                    }
                }
                .overlay(alignment: .bottom) {
                    if isRunning { indicator.offset(y: skin == .aqua ? 9 : 7) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .contextMenu { AppContextMenu(appID: app.id, controller: controller) }
        .windowPreview(for: { windows }, controller: controller, arrowEdge: .bottom)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            for window in windows { manager.taskbarTargets[window.id] = frame }
        }
        .help(app.name)
        .accessibilityLabel(app.name)
        .accessibilityValue(isRunning ? "Running" : "")
        .accessibilityIdentifier(isRunning ? "desktop.taskbar.item" : "desktop.dock.item")
    }

    @ViewBuilder
    private var indicator: some View {
        switch skin {
        case .aqua:
            Image(systemName: "triangle.fill").font(.system(size: 6)).foregroundStyle(.black.opacity(0.8))
        case .dotMatrix:
            Circle().fill(theme.accent).frame(width: 5, height: 5)
        default:
            Capsule().fill(Color(rgb: 0x1E8BFF)).frame(width: isFocused ? 18 : 6, height: 3)
        }
    }

    private func activate() {
        controller.activateApp(app.id)
    }
}
