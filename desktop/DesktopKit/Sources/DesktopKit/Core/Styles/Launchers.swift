import SwiftUI

/// Search and keyboard selection shared by every launcher presentation.
@MainActor
struct LauncherSearch {
    static func results(in apps: [DesktopAppDescriptor], query: String,
                        category: AppCategory? = nil) -> [DesktopAppDescriptor] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let scoped = trimmed.isEmpty
            ? apps.filter { category == nil || $0.category == category }
            : apps.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
                    || $0.id.localizedCaseInsensitiveContains(trimmed)
                    || $0.category.rawValue.localizedCaseInsensitiveContains(trimmed)
            }
        return scoped.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// The search field every launcher puts on top: type to filter, arrows to move, Return to open.
private struct LauncherSearchField: View {
    @Binding var query: String
    let placeholder: String
    let onMove: (_ dx: Int, _ dy: Int) -> Void
    let onSubmit: () -> Void
    @Environment(\.desktopTheme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.secondaryText)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(theme.primaryText)
                .focused($isFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .onSubmit(onSubmit)
                .onKeyPress(.upArrow) { onMove(0, -1); return .handled }
                .onKeyPress(.downArrow) { onMove(0, 1); return .handled }
                .onKeyPress(.leftArrow) {
                    // With text typed, left and right move the caret instead.
                    guard query.isEmpty else { return .ignored }
                    onMove(-1, 0)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    guard query.isEmpty else { return .ignored }
                    onMove(1, 0)
                    return .handled
                }
                .accessibilityIdentifier("desktop.launcher.search")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(theme.primaryText.opacity(0.1), in: Capsule())
        .onAppear { if HardwareKeyboardMonitor.isAttached { Task { isFocused = true } } }
    }
}

/// One app as an icon with its name under it (Start menu, Launchpad, Ubuntu app grid).
private struct AppGridCell: View {
    let app: DesktopAppDescriptor
    let iconName: String?
    let iconSize: CGFloat
    let isHighlighted: Bool
    let action: () -> Void
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                AppIcon(iconName: iconName, url: app.iconURL, symbol: app.symbol, size: iconSize)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 30, alignment: .top)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHighlighted ? theme.primaryText.opacity(0.14) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(app.name)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityIdentifier("desktop.launcher.app.\(app.id)")
    }
}

/// Launchpad (macOS) and the application grid (Ubuntu): every app in a grid over the
/// dimmed desktop, search on top.
struct AppGridLauncher: View {
    let controller: DesktopController
    /// Kylin's full-screen menu offers a way back to the window-mode menu.
    var onExitFullScreen: (() -> Void)?
    @Environment(\.desktopTheme) private var theme
    @State private var query = ""
    @State private var highlighted = 0
    @State private var columns = 6

    private static let cellWidth: CGFloat = 132

    private var results: [DesktopAppDescriptor] {
        LauncherSearch.results(in: controller.launcherApps, query: query)
    }

    /// The grid sits on a darkened desktop in every appearance, so its labels are light;
    /// a light theme's dark text read at under 3:1 there.
    private var gridTheme: DesktopTheme {
        var grid = theme
        grid.primaryText = .white
        grid.secondaryText = Color.white.opacity(0.75)
        return grid
    }

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(Color.black.opacity(0.35))
                .contentShape(Rectangle())
                .onTapGesture { controller.isLauncherPresented = false }
                .accessibilityLabel("Close applications")
            if let onExitFullScreen {
                Button(action: onExitFullScreen) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(gridTheme.primaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Exit Full Screen")
                .accessibilityIdentifier("desktop.launcher.exitFullScreen")
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(16)
            }
            VStack(spacing: 28) {
                LauncherSearchField(query: $query, placeholder: "Search", onMove: move, onSubmit: launchHighlighted)
                    .frame(width: 300)
                    .padding(.top, 28)
                GeometryReader { proxy in
                    let count = max(3, Int((proxy.size.width - 80) / Self.cellWidth))
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cellWidth - 12), spacing: 12),
                                                 count: count), spacing: 18) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, app in
                                AppGridCell(app: app, iconName: controller.iconName(forAppID: app.id),
                                            iconSize: 64, isHighlighted: index == highlighted) {
                                    launch(app)
                                }
                                .contextMenu { AppContextMenu(appID: app.id, controller: controller) }
                            }
                        }
                        .padding(.horizontal, 40)
                    }
                    .onAppear { columns = count }
                    .onChange(of: count) { _, value in columns = value }
                }
                .overlay(alignment: .top) {
                    if results.isEmpty {
                        VStack(spacing: 6) {
                            Text("No applications match “\(query)”")
                                .font(.system(size: 17, weight: .semibold))
                            Text("Install more with Packages, or check the spelling.")
                                .font(.system(size: 14))
                                .foregroundStyle(gridTheme.secondaryText)
                        }
                        .padding(.top, 60)
                    }
                }
            }
        }
        .environment(\.desktopTheme, gridTheme)
        .foregroundStyle(Color.white)
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onAppear {
            query = controller.launcherInitialQuery
            controller.launcherInitialQuery = ""
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop.launcher")
    }

    private func move(_ dx: Int, _ dy: Int) {
        guard !results.isEmpty else { return }
        highlighted = min(max(highlighted + dx + dy * columns, 0), results.count - 1)
    }

    private func launchHighlighted() {
        if results.indices.contains(highlighted) { launch(results[highlighted]) }
    }

    private func launch(_ app: DesktopAppDescriptor) {
        controller.isLauncherPresented = false
        controller.open(appID: app.id, arguments: [:])
    }
}

/// The Windows 11 Start menu: search, a grid of pinned apps, and an alphabetical list of
/// everything else.
struct StartMenu: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme
    @State private var query = ""
    @State private var showsAllApps = false
    @State private var highlighted = 0

    private static let columns = 6

    private var pinned: [DesktopAppDescriptor] {
        controller.launcherApps.filter { $0.category != .linux || $0.showsOnDesktop }
    }

    private var results: [DesktopAppDescriptor] {
        query.isEmpty && !showsAllApps
            ? pinned
            : LauncherSearch.results(in: controller.launcherApps, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            LauncherSearchField(query: $query, placeholder: "Search for apps", onMove: move, onSubmit: launchHighlighted)
                .padding(20)
            HStack {
                Text(query.isEmpty ? (showsAllApps ? "All apps" : "Pinned") : "Best matches")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Spacer()
                if query.isEmpty {
                    Button {
                        showsAllApps.toggle()
                        highlighted = 0
                    } label: {
                        Label(showsAllApps ? "Back" : "All apps",
                              systemImage: showsAllApps ? "chevron.left" : "chevron.right")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(theme.primaryText.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                }
            }
            .padding(.horizontal, 28)
            ScrollView {
                if query.isEmpty && !showsAllApps {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: Self.columns),
                              spacing: 6) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, app in
                            AppGridCell(app: app, iconName: controller.iconName(forAppID: app.id),
                                        iconSize: 40, isHighlighted: index == highlighted) { launch(app) }
                                .contextMenu { AppContextMenu(appID: app.id, controller: controller) }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, app in
                            StartListRow(app: app, iconName: controller.iconName(forAppID: app.id),
                                         isHighlighted: index == highlighted) { launch(app) }
                                .contextMenu { AppContextMenu(appID: app.id, controller: controller) }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
            }
            theme.separator.frame(height: 1)
            HStack {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.accent)
                Text("root@\(controller.host.hostName)")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button {
                    controller.presentRunDialog()
                } label: {
                    Image(systemName: "terminal").frame(width: 36, height: 32)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Run Command")
                Button {
                    controller.isLauncherPresented = false
                    controller.open(appID: AppID.settings, arguments: [:])
                } label: {
                    Image(systemName: "gearshape").frame(width: 36, height: 32)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("desktop.launcher.settings")
                PowerButton(controller: controller, size: 36)
            }
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, 24)
            .frame(height: 58)
        }
        .frame(width: 620, height: min(600, max(300, controller.windowManager.desktopSize.height - 24
                                                     - controller.windowManager.keyboardOverlap)))
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.panelBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.separator, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 28, y: 10)
        .onChange(of: query) { _, _ in highlighted = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop.launcher")
    }

    private func move(_ dx: Int, _ dy: Int) {
        guard !results.isEmpty else { return }
        let rowStep = query.isEmpty && !showsAllApps ? Self.columns : 1
        highlighted = min(max(highlighted + dx + dy * rowStep, 0), results.count - 1)
    }

    private func launchHighlighted() {
        if results.indices.contains(highlighted) { launch(results[highlighted]) }
    }

    private func launch(_ app: DesktopAppDescriptor) {
        controller.isLauncherPresented = false
        controller.open(appID: app.id, arguments: [:])
    }
}

private struct StartListRow: View {
    let app: DesktopAppDescriptor
    let iconName: String?
    let isHighlighted: Bool
    let action: () -> Void
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AppIcon(iconName: iconName, url: app.iconURL, symbol: app.symbol, size: 28)
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Text(app.category.rawValue)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHighlighted ? theme.primaryText.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(app.name)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityIdentifier("desktop.launcher.app.\(app.id)")
    }
}
