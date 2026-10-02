import SwiftUI

/// Whisker-menu style launcher: search on top, categories on the left, apps on the right.
struct LauncherView: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    @State private var query = ""
    @State private var category: AppCategory?
    /// The row Return launches; arrow keys move it.
    @State private var highlighted = 0
    @FocusState private var isSearchFocused: Bool

    private var categories: [AppCategory] {
        AppCategory.allCases.filter { category in controller.launcherApps.contains { $0.category == category } }
    }

    private var results: [DesktopAppDescriptor] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let scoped = trimmed.isEmpty
            ? controller.launcherApps.filter { category == nil || $0.category == category }
            : controller.launcherApps.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
                    || $0.id.localizedCaseInsensitiveContains(trimmed)
                    || $0.category.rawValue.localizedCaseInsensitiveContains(trimmed)
            }
        return scoped.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(12)
            theme.separator.frame(height: 1)
            HStack(spacing: 0) {
                categoryList
                    .frame(width: 168)
                theme.separator.frame(width: 1)
                appList
            }
            theme.separator.frame(height: 1)
            footer
        }
        .frame(width: 540, height: 440)
        .background {
            RoundedRectangle(cornerRadius: theme.cornerRadius + 2, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: theme.cornerRadius + 2, style: .continuous)
                .fill(theme.panelBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.cornerRadius + 2, style: .continuous)
                .strokeBorder(theme.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 28, y: 14)
        .onAppear {
            if HardwareKeyboardMonitor.isAttached { Task { isSearchFocused = true } }
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onChange(of: category) { _, _ in highlighted = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop.launcher")
    }

    private func moveHighlight(by step: Int) -> KeyPress.Result {
        let count = results.count
        guard count > 0 else { return .handled }
        highlighted = min(max(highlighted + step, 0), count - 1)
        return .handled
    }

    /// Tab walks the categories, so the whole menu works from the keyboard.
    private func cycleCategory(by step: Int) -> KeyPress.Result {
        let all: [AppCategory?] = [nil] + categories.map(Optional.some)
        let index = all.firstIndex(of: category) ?? 0
        category = all[((index + step) % all.count + all.count) % all.count]
        query = ""
        return .handled
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.secondaryText)
            TextField("Search applications", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(theme.primaryText)
                .focused($isSearchFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .onSubmit(launchHighlighted)
                .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                .onKeyPress(.tab, phases: .down) { press in
                    cycleCategory(by: press.modifiers.contains(.shift) ? -1 : 1)
                }
                .accessibilityIdentifier("desktop.launcher.search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(theme.primaryText.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var categoryList: some View {
        ScrollView {
            VStack(spacing: 2) {
                CategoryRow(title: "All Applications", symbol: "square.grid.2x2",
                            isSelected: category == nil && query.isEmpty) {
                    category = nil
                    query = ""
                }
                ForEach(categories, id: \.self) { item in
                    CategoryRow(title: item.rawValue, symbol: item.launcherSymbol,
                                isSelected: category == item && query.isEmpty) {
                        category = item
                        query = ""
                    }
                }
            }
            .padding(8)
        }
    }

    private var appList: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, app in
                        AppRow(app: app, iconName: controller.iconName(forAppID: app.id),
                               isHighlighted: index == highlighted) {
                            launch(app)
                        }
                        .contextMenu { AppContextMenu(appID: app.id, controller: controller) }
                        .id(app.id)
                    }
                }
                .padding(8)
                .onChange(of: highlighted) { _, index in
                    if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                }
            }
        }
        .overlay {
            if results.isEmpty {
                Text("No applications match “\(query)”")
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .padding()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(theme.accent)
            Text("root@\(controller.host.hostName)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.primaryText)
            Spacer()
            FooterButton(symbol: "terminal", label: "Run Command") { controller.presentRunDialog() }
            if controller.app(withID: AppID.settings) != nil {
                FooterButton(symbol: "gearshape", label: "Settings") {
                    controller.isLauncherPresented = false
                    controller.open(appID: AppID.settings, arguments: [:])
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    private func launchHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        launch(results[highlighted])
    }

    private func launch(_ app: DesktopAppDescriptor) {
        controller.isLauncherPresented = false
        controller.open(appID: app.id, arguments: [:])
    }
}

private struct CategoryRow: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                Text(title)
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(isSelected ? theme.accent.opacity(0.2) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AppRow: View {
    let app: DesktopAppDescriptor
    let iconName: String?
    let isHighlighted: Bool
    let action: () -> Void
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AppIcon(iconName: iconName, url: app.iconURL, symbol: app.symbol, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.primaryText)
                    Text(app.category.rawValue)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
                if isHighlighted {
                    Image(systemName: "return")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(isHighlighted ? theme.accent.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(app.name)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityIdentifier("desktop.launcher.app.\(app.id)")
    }
}

private struct FooterButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.primaryText)
                .frame(width: 32, height: 30)
                .background(theme.primaryText.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("desktop.launcher.\(label == "Settings" ? "settings" : symbol)")
    }
}

/// The rounded app tile shared by the launcher and the desktop.
struct DesktopAppTile: View {
    let symbol: String
    let size: CGFloat
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [theme.accent.opacity(0.95), theme.accent.opacity(0.55)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension AppCategory {
    var launcherSymbol: String {
        switch self {
        case .accessories: "wrench.and.screwdriver"
        case .development: "chevron.left.forwardslash.chevron.right"
        case .internet: "globe"
        case .system: "cpu"
        case .settings: "gearshape"
        case .linux: "macwindow.on.rectangle"
        }
    }
}
