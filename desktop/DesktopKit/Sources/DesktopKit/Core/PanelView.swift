import UniformTypeIdentifiers
import SwiftUI

struct PanelView: View {
    static let height: CGFloat = 34

    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            ApplicationsButton(isActive: controller.isLauncherPresented) {
                controller.toggleLauncher()
            }
            PanelSeparator()
            Taskbar(controller: controller)
            PanelSeparator()
            OverviewButton(isActive: controller.isOverviewPresented) {
                controller.toggleOverview()
            }
            TilingButton(manager: controller.windowManager)
            WorkspaceSwitcher(manager: controller.windowManager)
            PanelSeparator()
            SystemMeters(monitor: controller.systemMonitor)
            SystemTrayButtons(controller: controller)
            PanelClock()
            PowerButton(controller: controller, size: 28)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background {
            ZStack {
                Rectangle().fill(theme.panelBlur ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.clear))
                theme.panelBackground
            }
            .ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .bottom) {
            theme.separator.frame(height: 1)
        }
        .task(id: ObjectIdentifier(controller.host)) {
            await controller.systemMonitor.poll(controller.host)
        }
    }
}

struct PanelSeparator: View {
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        theme.separator.frame(width: 1, height: 18)
    }
}

private struct ApplicationsButton: View {
    let isActive: Bool
    let action: () -> Void
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text("Applications")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(PanelItemBackground(isActive: isActive))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityHint("Shows the application menu")
        .accessibilityIdentifier("desktop.panel.applications")
    }
}

struct OverviewButton: View {
    let isActive: Bool
    let action: () -> Void
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? theme.accent : theme.secondaryText)
                .frame(width: 32, height: 26)
                .background(PanelItemBackground(isActive: isActive))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .help("Overview (⌃⌥O)")
        .accessibilityLabel("Overview")
        .accessibilityIdentifier("desktop.panel.overview")
    }
}

struct PanelItemBackground: View {
    let isActive: Bool
    var isDimmed = false
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isActive ? theme.accent.opacity(0.28) : theme.primaryText.opacity(isDimmed ? 0.03 : 0.07))
    }
}

private struct Taskbar: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(controller.windowManager.windowsInCurrentWorkspace()) { window in
                    TaskbarButton(window: window, controller: controller)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TaskbarButton: View {
    let window: DesktopWindow
    let controller: DesktopController
    private var manager: WindowManager { controller.windowManager }
    @Environment(\.desktopTheme) private var theme

    private var isFocused: Bool { manager.focusedWindowID == window.id && !window.isMinimized }

    var body: some View {
        Button {
            manager.activateFromTaskbar(window.id)
        } label: {
            HStack(spacing: 6) {
                AppGlyph(iconName: controller.iconName(forAppID: window.appID), url: controller.iconURL(forAppID: window.appID), symbol: window.symbol,
                         size: 12, tint: isFocused ? theme.accent : theme.secondaryText)
                Text(window.title)
                    .font(.system(size: 12, weight: isFocused ? .semibold : .regular))
                    .italic(window.isMinimized)
                    .foregroundStyle(window.isMinimized ? theme.secondaryText : theme.primaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 72, maxWidth: 190, alignment: .leading)
            .frame(height: 26)
            .background(PanelItemBackground(isActive: isFocused, isDimmed: window.isMinimized))
            .overlay(alignment: .bottom) {
                if isFocused {
                    Capsule().fill(theme.accent).frame(width: 18, height: 2).offset(y: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .contextMenu {
            WindowMenu(window: window, controller: controller).swiftUIItems
            Divider()
            AppContextMenu(appID: window.appID, controller: controller)
        }
        .windowPreview(for: { [window] }, controller: controller, arrowEdge: .top)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            manager.taskbarTargets[window.id] = frame
        }
        .accessibilityLabel(window.title)
        .accessibilityValue(window.isMinimized ? "Minimized" : isFocused ? "Active" : "")
        .accessibilityIdentifier("desktop.taskbar.item")
    }
}

struct WorkspaceSwitcher: View {
    let manager: WindowManager
    @Environment(\.desktopTheme) private var theme
    @State private var dropHover: Int?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<manager.workspaceCount, id: \.self) { index in
                let isCurrent = index == manager.currentWorkspace
                Button {
                    withAnimation(.snappy(duration: 0.2)) { manager.switchToWorkspace(index) }
                } label: {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isCurrent ? Color.white : theme.secondaryText)
                        .frame(width: 22, height: 20)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isCurrent ? theme.accent : theme.primaryText.opacity(0.08))
                        }
                        .overlay {
                            if dropHover == index {
                                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(theme.accent, lineWidth: 2)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if !isCurrent && manager.hasWindows(inWorkspace: index) {
                                Circle().fill(theme.accent).frame(width: 3, height: 3).offset(y: -2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .help(manager.title(ofWorkspace: index))
                .onDrag { WorkspaceDrag.provider(for: index) }
                .onDrop(of: [.plainText], delegate: WorkspaceReorderDropDelegate(manager: manager, index: index, hovered: $dropHover))
                .workspaceMenu(manager: manager, index: index)
                .accessibilityLabel(manager.title(ofWorkspace: index))
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .accessibilityIdentifier("desktop.workspace.\(index + 1)")
            }
            if manager.workspaceCount < WindowManager.maximumWorkspaces {
                Button { addAndSwitch(manager) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .help("New Workspace (⌃⌥N)")
                .accessibilityLabel("New Workspace")
                .accessibilityIdentifier("desktop.workspace.add")
            }
        }
    }
}

struct SystemMeters: View {
    let monitor: PanelSystemMonitor

    var body: some View {
        HStack(spacing: 8) {
            Meter(label: "CPU", value: monitor.cpuUsage,
                  detail: monitor.cpuUsage.map { String(format: "%.0f%%", $0 * 100) })
            Meter(label: "MEM", value: monitor.memoryUsage, detail: nil)
        }
    }
}

private struct Meter: View {
    let label: String
    let value: Double?
    let detail: String?
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.secondaryText)
            ZStack(alignment: .leading) {
                Capsule().fill(theme.primaryText.opacity(0.1))
                Capsule()
                    .fill(fillColor)
                    .frame(width: 34 * (value ?? 0))
            }
            .frame(width: 34, height: 5)
            .animation(.easeOut(duration: 0.5), value: value)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value.map { "\(Int($0 * 100)) percent" } ?? "Unavailable")
        .help(detail ?? value.map { "\(Int($0 * 100))%" } ?? "")
    }

    private var fillColor: Color {
        guard let value else { return .clear }
        if value > 0.85 { return Color(red: 0.95, green: 0.35, blue: 0.35) }
        if value > 0.6 { return Color(red: 0.98, green: 0.72, blue: 0.3) }
        return theme.accent
    }
}

struct PanelClock: View {
    @Environment(\.desktopTheme) private var theme
    @State private var isShowingDate = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        TimelineView(.everyMinute) { context in
            Button {
                isShowingDate.toggle()
            } label: {
                Text(Self.timeFormatter.string(from: context.date))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .popover(isPresented: $isShowingDate, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.date.formatted(.dateTime.weekday(.wide)))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.accent)
                    Text(context.date.formatted(.dateTime.day().month(.wide).year()))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                }
                .padding(16)
                .presentationCompactAdaptation(.popover)
            }
            .accessibilityLabel(context.date.formatted(date: .complete, time: .shortened))
        }
    }
}
