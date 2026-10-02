import SwiftUI

/// The launchers of the desktop themes' eras: Luna's two-column start menu, the glass start
/// menu with its search field, 98's cascading list with a side band, and Platinum's
/// system menu. All of them list the same apps and launch the same way as the other styles.
struct EraLauncher: View {
    let controller: DesktopController
    let skin: EraSkin
    @State private var query = ""
    @State private var showsAll = false

    private var pinned: [DesktopAppDescriptor] {
        controller.launcherApps.filter { $0.category != .linux || $0.showsOnDesktop }
    }

    private var apps: [DesktopAppDescriptor] {
        if !query.isEmpty { return LauncherSearch.results(in: controller.launcherApps, query: query) }
        return showsAll ? LauncherSearch.results(in: controller.launcherApps, query: "") : pinned
    }

    private var maxHeight: CGFloat {
        max(300, controller.windowManager.desktopSize.height - 16 - controller.windowManager.keyboardOverlap)
    }

    var body: some View {
        Group {
            switch skin {
            case .luna: luna
            case .classic: classic
            case .platinum: platinum
            default: glass
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop.launcher")
        // The menu sits in the panel's corner whatever the overlay around it does.
        .padding(.leading, skin == .platinum ? 6 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: skin.launcherAlignment)
    }

    private func launch(_ app: DesktopAppDescriptor) {
        controller.isLauncherPresented = false
        controller.open(appID: app.id, arguments: [:])
    }

    private func openSystem(_ id: String) {
        controller.isLauncherPresented = false
        controller.open(appID: id, arguments: [:])
    }

    private func row(_ app: DesktopAppDescriptor, iconSize: CGFloat, font: Font, height: CGFloat,
                     text: Color, highlight: Color, highlightText: Color) -> some View {
        EraMenuRow(height: height, highlight: highlight) { hovered in
            HStack(spacing: 8) {
                AppIcon(iconName: controller.iconName(forAppID: app.id), url: app.iconURL, symbol: app.symbol, size: iconSize)
                Text(app.name).font(font).foregroundStyle(hovered ? highlightText : text).lineLimit(1)
                Spacer(minLength: 0)
            }
        } action: { launch(app) }
        .contextMenu { AppContextMenu(appID: app.id, controller: controller) }
        .accessibilityLabel(app.name)
        .accessibilityIdentifier("desktop.launcher.app.\(app.id)")
    }

    private func link(_ title: String, symbol: String, color: Color, font: Font, height: CGFloat,
                      highlight: Color, highlightText: Color, action: @escaping () -> Void) -> some View {
        EraMenuRow(height: height, highlight: highlight, content: { hovered in
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 22)
                Text(title).font(font).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovered ? highlightText : color)
        }, action: action)
    }

    // MARK: Luna

    private var luna: some View {
        let blue = LinearGradient(stops: [.init(color: Color(rgb: 0x1868CE), location: 0), .init(color: Color(rgb: 0x0E60CB), location: 0.1),
                                          .init(color: Color(rgb: 0x0E60CB), location: 0.6), .init(color: Color(rgb: 0x3A86E6), location: 1)],
                                  startPoint: .top, endPoint: .bottom)
        let highlight = Color(rgb: 0x316AC5)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.square.fill")
                    .font(.system(size: 34)).foregroundStyle(Color(rgb: 0xF4C25B))
                    .background(RoundedRectangle(cornerRadius: 4).fill(.white).padding(-2))
                Text("root").font(.custom("TrebuchetMS-Bold", size: 18)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 0, x: 1, y: 1)
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 60).background(blue)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(apps) { app in
                                row(app, iconSize: 28, font: .system(size: 13, weight: showsAll ? .regular : .semibold), height: 38,
                                    text: .black, highlight: highlight, highlightText: .white)
                            }
                        }
                        .padding(4)
                    }
                    Color(rgb: 0xD5D2C4).frame(height: 1).padding(.horizontal, 8)
                    Button { showsAll.toggle() } label: {
                        HStack(spacing: 6) {
                            Spacer()
                            Text(showsAll ? "Back" : "All Programs").font(.system(size: 13, weight: .bold))
                            Image(systemName: showsAll ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill")
                                .foregroundStyle(Color(rgb: 0x2C9B2C))
                        }
                        .foregroundStyle(.black).padding(.horizontal, 12).frame(height: 36).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("desktop.launcher.allApps")
                }
                .frame(width: 250).background(Color.white)
                VStack(spacing: 0) {
                    systemLinks(color: Color(rgb: 0x0A246A), font: .system(size: 13, weight: .bold), height: 34,
                                highlight: highlight, highlightText: .white)
                    Spacer()
                }
                .padding(6)
                .frame(width: 200)
                .background(Color(rgb: 0xD3E5FA))
                .overlay(alignment: .leading) { Color(rgb: 0x95BDEE).frame(width: 1) }
            }
            HStack(spacing: 4) {
                Spacer()
                PowerButton(controller: controller, size: 32)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(rgb: 0xE35B2B)))
                    .environment(\.desktopTheme, whiteText)
                Text("Turn Off").font(.system(size: 12)).foregroundStyle(.white).padding(.trailing, 10)
            }
            .frame(height: 44).background(blue)
        }
        .frame(width: 450, height: min(520, maxHeight))
        .clipShape(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 8, bottomLeading: 0, bottomTrailing: 0, topTrailing: 8)))
        .overlay(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 8, bottomLeading: 0, bottomTrailing: 0, topTrailing: 8))
            .strokeBorder(Color(rgb: 0x0831D9), lineWidth: 2))
        .shadow(color: .black.opacity(0.45), radius: 6, x: 3, y: 3)
        .environment(\.colorScheme, .light)
    }

    private var whiteText: DesktopTheme {
        var theme = DesktopTheme.dark
        theme.primaryText = .white
        return theme
    }

    @ViewBuilder
    private func systemLinks(color: Color, font: Font, height: CGFloat, highlight: Color, highlightText: Color) -> some View {
        link("Files", symbol: "folder.fill", color: color, font: font, height: height, highlight: highlight,
             highlightText: highlightText) { openSystem(AppID.files) }
        link("Terminal", symbol: "terminal.fill", color: color, font: font, height: height, highlight: highlight,
             highlightText: highlightText) { openSystem(AppID.terminal) }
        link("Themes", symbol: "paintpalette.fill", color: color, font: font, height: height, highlight: highlight,
             highlightText: highlightText) { openSystem(ThemesApp.id) }
        link("Settings", symbol: "gearshape.fill", color: color, font: font, height: height, highlight: highlight,
             highlightText: highlightText) { openSystem(AppID.settings) }
        link("Run…", symbol: "play.rectangle.fill", color: color, font: font, height: height, highlight: highlight,
             highlightText: highlightText) {
            controller.isLauncherPresented = false
            controller.presentRunDialog()
        }
    }

    // MARK: Glass (Aero, Aero Night)

    private var glass: some View {
        let night = skin == .aeroNight
        let highlight = Color(rgb: 0xCCE8FF)
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(apps) { app in
                            row(app, iconSize: 30, font: .system(size: 13), height: 40, text: Color(rgb: 0x1E1E1E),
                                highlight: highlight, highlightText: .black)
                        }
                    }
                    .padding(6)
                }
                Color(rgb: 0xD6E1EE).frame(height: 1)
                Button { showsAll.toggle() } label: {
                    HStack {
                        Image(systemName: showsAll ? "chevron.left" : "chevron.right")
                        Text(showsAll ? "Back" : "All Programs")
                        Spacer()
                    }
                    .font(.system(size: 13)).foregroundStyle(.black).padding(.horizontal, 12).frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("desktop.launcher.allApps")
                HStack(spacing: 6) {
                    TextField("Search programs and files", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.black)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onSubmit { if let first = apps.first { launch(first) } }
                        .accessibilityIdentifier("desktop.launcher.search")
                    Image(systemName: "magnifyingglass").foregroundStyle(Color(rgb: 0x4A6A90))
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 3).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(rgb: 0x9DB3CF), lineWidth: 1))
                .padding(10)
            }
            .frame(width: 280)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
            .padding(8)
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "person.crop.square.fill").font(.system(size: 52))
                    .foregroundStyle(LinearGradient(colors: [Color(rgb: 0x9AD8FF), Color(rgb: 0x2A7CD0)], startPoint: .top, endPoint: .bottom))
                    .padding(.vertical, 12).frame(maxWidth: .infinity)
                systemLinks(color: .white, font: .system(size: 13), height: 34, highlight: Color.white.opacity(0.25), highlightText: .white)
                Spacer()
                HStack {
                    Spacer()
                    PowerButton(controller: controller, size: 32)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color(rgb: 0xC0381F)))
                        .environment(\.desktopTheme, whiteText)
                }
                .padding(10)
            }
            .frame(width: 190)
            .padding(.vertical, 8)
        }
        .frame(height: min(540, maxHeight))
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: night ? [Color.black.opacity(0.7), Color(white: 0.1).opacity(0.85)]
                                                       : [Color(rgb: 0x2D5F8F).opacity(0.55), Color(rgb: 0x0F2A45).opacity(0.75)],
                                         startPoint: .top, endPoint: .bottom))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
        .environment(\.colorScheme, .light)
    }

    // MARK: Classic 98

    private var classic: some View {
        let navy = Color(rgb: 0x000080)
        return HStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [navy, Color(rgb: 0x1084D0)], startPoint: .bottom, endPoint: .top)
                HStack(spacing: 2) {
                    Text("LinPad").font(.system(size: 20, weight: .black))
                    Text("98").font(.system(size: 20, weight: .light))
                }
                .foregroundStyle(.white)
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .frame(width: 30, height: 110)
                .padding(.bottom, 6)
            }
            .frame(width: 30)
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(apps) { app in
                            row(app, iconSize: 24, font: .system(size: 13), height: 34, text: .black, highlight: navy, highlightText: .white)
                        }
                    }
                }
                ClassicSeparator()
                link(showsAll ? "Favorites" : "Programs", symbol: "folder.fill", color: .black, font: .system(size: 13),
                     height: 34, highlight: navy, highlightText: .white) { showsAll.toggle() }
                    .accessibilityIdentifier("desktop.launcher.allApps")
                link("Settings", symbol: "gearshape.fill", color: .black, font: .system(size: 13), height: 34,
                     highlight: navy, highlightText: .white) { openSystem(AppID.settings) }
                link("Run…", symbol: "play.rectangle.fill", color: .black, font: .system(size: 13), height: 34,
                     highlight: navy, highlightText: .white) {
                    controller.isLauncherPresented = false
                    controller.presentRunDialog()
                }
                ClassicSeparator()
                HStack {
                    Text("Shut Down…").font(.system(size: 13))
                    Spacer()
                    PowerButton(controller: controller, size: 30)
                }
                .padding(.horizontal, 8).frame(height: 36)
            }
            .padding(3)
        }
        .frame(width: 280, height: min(480, maxHeight))
        .modifier(ClassicBox())
        .environment(\.colorScheme, .light)
        .environment(\.desktopTheme, classicTheme)
    }

    private var classicTheme: DesktopTheme {
        var theme = DesktopTheme.dark
        theme.primaryText = .black
        return theme
    }

    // MARK: Platinum

    private var platinum: some View {
        let highlight = Color(rgb: 0x6666CC)
        return VStack(spacing: 0) {
            link("About This Desktop", symbol: "info.circle", color: .black, font: .system(size: 13), height: 26,
                 highlight: highlight, highlightText: .white) { openSystem(AppID.settings) }
            Color(rgb: 0x999999).frame(height: 1).padding(.vertical, 3)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(LauncherSearch.results(in: controller.launcherApps, query: "")) { app in
                        row(app, iconSize: 18, font: .system(size: 13), height: 26, text: .black, highlight: highlight, highlightText: .white)
                    }
                }
            }
            Color(rgb: 0x999999).frame(height: 1).padding(.vertical, 3)
            link("Run Command…", symbol: "terminal", color: .black, font: .system(size: 13), height: 26,
                 highlight: highlight, highlightText: .white) {
                controller.isLauncherPresented = false
                controller.presentRunDialog()
            }
            link("Control Panels", symbol: "slider.horizontal.3", color: .black, font: .system(size: 13), height: 26,
                 highlight: highlight, highlightText: .white) { openSystem(AppID.settings) }
        }
        .padding(.vertical, 4)
        .frame(width: 270)
        .frame(maxHeight: min(560, maxHeight))
        .fixedSize(horizontal: false, vertical: true)
        .background(EraSkin.platinumFace)
        .overlay(Rectangle().strokeBorder(Color.black, lineWidth: 1))
        .background(Color.black.opacity(0.35).offset(x: 2, y: 2))
        .environment(\.colorScheme, .light)
    }
}

/// A menu row whose content can recolour itself while highlighted.
private struct EraMenuRow<Content: View>: View {
    let height: CGFloat
    let highlight: Color
    @ViewBuilder let content: (Bool) -> Content
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content(isHovered)
                .padding(.horizontal, 8)
                .frame(height: height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isHovered ? highlight : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct ClassicSeparator: View {
    var body: some View {
        VStack(spacing: 0) {
            Color(rgb: 0x808080).frame(height: 1)
            Color.white.frame(height: 1)
        }
        .padding(.vertical, 3).padding(.horizontal, 2)
    }
}
