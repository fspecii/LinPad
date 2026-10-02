import SwiftUI

/// Where a style puts its quick-settings and notification panels.
extension DesktopStyle {
    var quickSettingsAlignment: Alignment {
        switch self {
        case .windows, .kylin: .bottomTrailing
        default: .topTrailing
        }
    }

    var notificationCenterAlignment: Alignment {
        switch self {
        case .ubuntu: .top
        case .ish: .topTrailing
        default: .trailing
        }
    }

    /// macOS, Windows and Kylin slide notifications in as a full-height column on the right.
    var notificationCenterIsColumn: Bool {
        self == .macos || self == .windows || self == .kylin
    }

    var quickSettingsTitle: String {
        switch self {
        case .macos: "Control Center"
        case .windows: "Quick Settings"
        case .ubuntu: "System Menu"
        case .kylin: "Quick Settings"
        case .ish: "Settings"
        }
    }
}

/// The tray buttons every shell shows near its clock: quick settings (network, volume and
/// battery at a glance) and the notification bell with an unread count.
struct SystemTrayButtons: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    private var status: SystemStatus { controller.systemStatus }

    var body: some View {
        HStack(spacing: 2) {
            if controller.showsKeyboardButton {
                let keyboard = OnScreenKeyboard.shared
                Button { keyboard.toggle(for: controller) } label: {
                    Image(systemName: keyboard.isVisible ? "keyboard.chevron.compact.down" : "keyboard")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 28)
                        .background(PanelItemBackground(isActive: keyboard.isVisible))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel(keyboard.isVisible ? "Hide Keyboard" : "Show Keyboard")
                .accessibilityIdentifier("desktop.panel.keyboard")
            }
            Button { controller.toggleQuickSettings() } label: {
                HStack(spacing: 6) {
                    Image(systemName: status.network.symbol)
                    if let volume = controller.systemControls?.volume {
                        Image(systemName: volumeSymbol(volume))
                    }
                    Image(systemName: status.batterySymbol)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(PanelItemBackground(isActive: controller.isQuickSettingsPresented))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(controller.style.quickSettingsTitle)
            .accessibilityIdentifier("desktop.panel.quickSettings")

            Button { controller.toggleNotificationCenter() } label: {
                Image(systemName: controller.notifications.doNotDisturb ? "moon.fill" : "bell")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 28)
                    .background(PanelItemBackground(isActive: controller.isNotificationCenterPresented))
                    .overlay(alignment: .topTrailing) {
                        if controller.notifications.unreadCount > 0 {
                            Circle().fill(Color(red: 0.96, green: 0.25, blue: 0.25)).frame(width: 7, height: 7)
                                .offset(x: -4, y: 4)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("Notifications")
            .accessibilityValue(controller.notifications.unreadCount > 0 ? "\(controller.notifications.unreadCount) unread" : "")
            .accessibilityIdentifier("desktop.panel.notifications")
        }
        .foregroundStyle(theme.primaryText)
        .onAppear { status.start() }
        .onDisappear { status.stop() }
    }

    private func volumeSymbol(_ volume: Float) -> String {
        if controller.systemControls?.isMuted == true || volume == 0 { return "speaker.slash.fill" }
        return volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
    }
}

struct QuickSettingsPanel: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopStyle) private var style
    @AppStorage(DesktopAppearance.storageKey) private var appearanceID = DesktopAppearance.styleDefault.rawValue
    @AppStorage(DesktopStyle.storageKey) private var styleID = DesktopStyle.defaultStyle.rawValue
    @AppStorage(DesktopSettings.performanceOverlayKey) private var showsPerformance = false
    @State private var volume: Float = 1

    private var status: SystemStatus { controller.systemStatus }
    private var manager: WindowManager { controller.windowManager }
    private var tileRadius: CGFloat { style == .kylin ? 8 : theme.cornerRadius }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: style == .kylin ? 4 : 3),
                      spacing: 8) {
                tile("Do Not Disturb", symbol: "moon.fill", isOn: controller.notifications.doNotDisturb) {
                    controller.notifications.doNotDisturb.toggle()
                }
                tile("Auto-Tiling", symbol: "rectangle.split.2x1", isOn: manager.isTiling(workspace: manager.currentWorkspace)) {
                    manager.setTiling(!manager.isTiling(workspace: manager.currentWorkspace))
                }
                tile(appearanceTitle, symbol: "circle.lefthalf.filled", isOn: appearanceID != DesktopAppearance.styleDefault.rawValue) {
                    cycleAppearance()
                }
                tile("Performance", symbol: "speedometer", isOn: showsPerformance) { showsPerformance.toggle() }
                tile(status.network.title, symbol: status.network.symbol, isOn: status.network != .offline) {}
                    .allowsHitTesting(false)
                if style == .kylin {
                    tile("Lock", symbol: "lock.fill", isOn: false) { controller.lockScreen() }
                }
            }
            if controller.systemControls?.volume != nil {
                sliderRow(symbol: "speaker.wave.2.fill", label: "Volume", value: Binding(
                    get: { Double(volume) },
                    set: { value in
                        volume = Float(value)
                        controller.systemControls?.volume = Float(value)
                        controller.systemControls?.isMuted = value == 0
                    }))
            }
            sliderRow(symbol: "sun.max.fill", label: "Brightness", value: Binding(
                get: { Double(status.brightness) },
                set: { status.brightness = CGFloat($0) }))
            Divider().overlay(theme.separator)
            infoRow(symbol: "paintpalette", title: "Style") {
                Picker("Style", selection: $styleID) {
                    ForEach(DesktopStyle.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("quickSettings.style")
            }
            PerformanceModeRow(controller: controller)
            infoRow(symbol: "keyboard", title: "Keyboard") {
                Button(status.keyboardLanguage ?? "Hardware keyboard") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
            }
            HStack {
                Label(batteryText, systemImage: status.batterySymbol)
                    .font(.system(size: 13))
                Spacer()
                Menu {
                    PowerMenuItems(controller: controller)
                } label: {
                    Image(systemName: "power").frame(width: 32, height: 32)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Power")
                .accessibilityIdentifier("quickSettings.power")
            }
        }
        .foregroundStyle(theme.primaryText)
        .padding(16)
        .frame(width: style == .kylin ? 396 : 340)
        .background {
            RoundedRectangle(cornerRadius: theme.cornerRadius + 2, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: theme.cornerRadius + 2, style: .continuous).fill(theme.panelBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: theme.cornerRadius + 2, style: .continuous).strokeBorder(theme.separator)
        }
        .shadow(color: .black.opacity(0.3), radius: 20, y: 6)
        .onAppear {
            volume = controller.systemControls?.volume ?? 1
            status.start()
        }
        .onDisappear { status.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop.quickSettings")
    }

    private var appearanceTitle: String {
        (DesktopAppearance(rawValue: appearanceID) ?? .styleDefault).title
    }

    private func cycleAppearance() {
        let all = DesktopAppearance.allCases
        let index = all.firstIndex { $0.rawValue == appearanceID } ?? 0
        appearanceID = all[(index + 1) % all.count].rawValue
    }

    private var batteryText: String {
        guard let level = status.batteryLevel else { return "Battery unavailable" }
        let charging = status.batteryState == .charging ? " · Charging" : ""
        return "\(Int((level * 100).rounded()))%\(charging)"
    }

    private func tile(_ title: String, symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(isOn ? Color.white : theme.primaryText)
            .frame(maxWidth: .infinity, minHeight: style == .kylin ? 72 : 64)
            .background(RoundedRectangle(cornerRadius: tileRadius, style: .continuous)
                .fill(isOn ? theme.accent : theme.primaryText.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func sliderRow(symbol: String, label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20)
            Slider(value: value, in: 0...1).tint(theme.accent)
                .accessibilityLabel(label)
        }
    }

    private func infoRow<Content: View>(symbol: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Label(title, systemImage: symbol).font(.system(size: 13))
            Spacer()
            content()
        }
    }
}

struct NotificationCenterPanel: View {
    let controller: DesktopController
    let isColumn: Bool
    @Environment(\.desktopTheme) private var theme

    private var notifications: NotificationCenterModel { controller.notifications }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Notifications").font(.system(size: 15, weight: .semibold))
                Spacer()
                Toggle(isOn: Binding(get: { notifications.doNotDisturb }, set: { notifications.doNotDisturb = $0 })) {
                    Label("Do Not Disturb", systemImage: "moon.fill").labelStyle(.iconOnly)
                }
                .toggleStyle(.button)
                .tint(theme.accent)
                .accessibilityIdentifier("notifications.doNotDisturb")
                if !notifications.notices.isEmpty {
                    Button("Clear All") { withAnimation(DesktopMotion.quick) { notifications.clear() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accent)
                        .font(.system(size: 13))
                }
            }
            if notifications.notices.isEmpty {
                Text("No notifications")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(notifications.notices) { notice in
                            noticeCard(notice)
                        }
                    }
                }
            }
            if isColumn { Spacer(minLength: 0) }
        }
        .foregroundStyle(theme.primaryText)
        .padding(16)
        .frame(width: 374)
        .frame(maxHeight: isColumn ? .infinity : 460)
        .background {
            RoundedRectangle(cornerRadius: theme.cornerRadius + 2, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: theme.cornerRadius + 2, style: .continuous).fill(theme.panelBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: theme.cornerRadius + 2, style: .continuous).strokeBorder(theme.separator)
        }
        .shadow(color: .black.opacity(0.3), radius: 20, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop.notificationCenter")
    }

    private func noticeCard(_ notice: DesktopNotice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.fill").foregroundStyle(theme.accent).font(.system(size: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Text(notice.date, style: .relative).font(.system(size: 11)).foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(DesktopMotion.quick) { notifications.remove(notice.id) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.primaryText.opacity(0.06)))
        .background(theme.panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("desktop.notification")
        .noticeSwipeToDismiss { withAnimation(DesktopMotion.quick) { notifications.remove(notice.id) } }
    }
}

/// Lock, session restart, reboot and quit, wherever a style keeps its power button.
struct PowerMenuItems: View {
    let controller: DesktopController

    var body: some View {
        Button("Lock Screen", systemImage: "lock") { controller.lockScreen() }
        Divider()
        if controller.linux != nil {
            Button("Restart Desktop Session", systemImage: "arrow.clockwise") {
                Task { await controller.restartDesktopSession() }
            }
        }
        if let controls = controller.systemControls {
            if controls.canRebootLinux {
                Button("Restart Linux", systemImage: "restart") {
                    controller.session.saveNow()
                    Task { await controls.rebootLinux() }
                }
            }
        }
        Button("Quit", systemImage: "power", role: .destructive) {
            controller.session.saveNow()
            // A desktop session ends by leaving; iPadOS has no API for it, so the app exits.
            exit(0)
        }
    }
}
