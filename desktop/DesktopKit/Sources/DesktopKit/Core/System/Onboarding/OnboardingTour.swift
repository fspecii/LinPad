import SwiftUI

/// The feature reel: five cards, each with a small live preview drawn natively.
struct OnboardingTour: View {
    @Binding var page: Int
    @Environment(\.desktopTheme) private var theme

    static let cards: [(id: String, title: String, body: String)] = [
        ("desktop", "A real desktop",
         "Windows you can move, snap and tile, workspaces, a launcher and a window switcher. Five layouts, from macOS to Ubuntu."),
        ("apps", "Real Linux apps",
         "Firefox, VS Code and the foot terminal are the Linux programs themselves, each in its own window. Install more with apk."),
        ("themes", "Themes in one keystroke",
         "Tokyo Night, Catppuccin, Gruvbox and more recolour the desktop and the Linux apps together."),
        ("fast", "Fast mode",
         "With StikDebug, LinPad runs Linux programs as native ARM64 code, about 5× faster than plain emulation."),
        ("files", "Your files",
         "Open iPad folders and Photos from Files, and keep Linux's /root and /home on the iPad."),
    ]

    var body: some View {
        VStack(spacing: 18) {
            TabView(selection: $page) {
                ForEach(Array(Self.cards.enumerated()), id: \.offset) { index, card in
                    TourCard(index: index, title: card.title, message: card.body, isCurrent: page == index)
                        .tag(index)
                        .accessibilityIdentifier("onboarding.tour.card.\(card.id)")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            HStack(spacing: 8) {
                ForEach(0..<Self.cards.count, id: \.self) { index in
                    Button {
                        withAnimation(DesktopMotion.standard) { page = index }
                    } label: {
                        Capsule()
                            .fill(index == page ? theme.accent : theme.primaryText.opacity(0.22))
                            .frame(width: index == page ? 22 : 8, height: 8)
                            .frame(minWidth: 24, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Self.cards[index].title), \(index + 1) of \(Self.cards.count)")
                    .accessibilityAddTraits(index == page ? .isSelected : [])
                }
            }
            .animation(DesktopMotion.standard, value: page)
        }
    }
}

private struct TourCard: View {
    let index: Int
    let title: String
    let message: String
    let isCurrent: Bool
    @Environment(\.desktopTheme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let layout = sizeClass == .compact
            ? AnyLayout(VStackLayout(spacing: 22)) : AnyLayout(HStackLayout(alignment: .center, spacing: 40))
        layout {
            preview
                .frame(maxWidth: 460, maxHeight: 300)
                .aspectRatio(1.5, contentMode: .fit)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(.title, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.system(.title3))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 340, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var preview: some View {
        MiniScreen {
            switch index {
            case 0: TilingPreview(isActive: isCurrent)
            case 1: LinuxAppsPreview(isActive: isCurrent)
            case 2: ThemesPreview(isActive: isCurrent)
            case 3: FastModePreview(isActive: isCurrent)
            default: FilesPreview()
            }
        }
    }
}

/// A small screen with the desktop's accent glow behind its content.
struct MiniScreen<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.13), Color(red: 0.12, green: 0.10, blue: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [theme.accent.opacity(0.35), .clear], center: .topTrailing, startRadius: 0, endRadius: 320)
            content()
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .environment(\.colorScheme, .dark)
    }
}

/// A drawn window: title bar with three dots and a title, then content.
struct MockWindow<Content: View>: View {
    var title: String
    var focused = false
    var accent: Color = .blue
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(.white.opacity(0.28)).frame(width: 5, height: 5) }
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                Color.clear.frame(width: 23, height: 5)
            }
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Color.white.opacity(focused ? 0.12 : 0.07))
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(red: 0.09, green: 0.10, blue: 0.13))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(focused ? accent : .white.opacity(0.1), lineWidth: focused ? 1.5 : 1))
    }
}

/// Three windows that float, then tile master-stack, then into columns.
private struct TilingPreview: View {
    let isActive: Bool
    @Environment(\.desktopTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var layout = 0

    var body: some View {
        GeometryReader { proxy in
            let area = CGRect(x: 10, y: 26, width: proxy.size.width - 20, height: proxy.size.height - 36)
            ZStack(alignment: .topLeading) {
                panel.frame(width: proxy.size.width, height: 18)
                ForEach(0..<3, id: \.self) { index in
                    let frame = frames(in: area)[index]
                    MockWindow(title: ["Terminal", "Files", "Firefox"][index], focused: index == 0, accent: theme.accent) {
                        lines(index)
                    }
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .task(id: isActive) {
            guard isActive, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.snappy(duration: 0.45)) { layout = (layout + 1) % 3 }
            }
        }
    }

    private var panel: some View {
        HStack(spacing: 6) {
            Circle().fill(theme.accent).frame(width: 7, height: 7)
            ForEach(0..<3, id: \.self) { index in
                Capsule().fill(.white.opacity(index == 0 ? 0.5 : 0.25)).frame(width: 22, height: 4)
            }
            Spacer()
            Text("9:41").font(.system(size: 8, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .background(Color.black.opacity(0.35))
    }

    private func frames(in area: CGRect) -> [CGRect] {
        let gap: CGFloat = 6
        switch layout {
        case 1:
            let half = (area.width - gap) / 2
            let stack = (area.height - gap) / 2
            return [CGRect(x: area.minX, y: area.minY, width: half, height: area.height),
                    CGRect(x: area.minX + half + gap, y: area.minY, width: half, height: stack),
                    CGRect(x: area.minX + half + gap, y: area.minY + stack + gap, width: half, height: stack)]
        case 2:
            let third = (area.width - 2 * gap) / 3
            return (0..<3).map { CGRect(x: area.minX + CGFloat($0) * (third + gap), y: area.minY, width: third, height: area.height) }
        default:
            return [CGRect(x: area.minX + area.width * 0.06, y: area.minY + area.height * 0.10,
                           width: area.width * 0.5, height: area.height * 0.55),
                    CGRect(x: area.minX + area.width * 0.42, y: area.minY + area.height * 0.02,
                           width: area.width * 0.48, height: area.height * 0.48),
                    CGRect(x: area.minX + area.width * 0.30, y: area.minY + area.height * 0.42,
                           width: area.width * 0.55, height: area.height * 0.52)]
        }
    }

    private func lines(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<5, id: \.self) { line in
                Capsule()
                    .fill(index == 0 && line == 0 ? theme.accent.opacity(0.8) : .white.opacity(0.16))
                    .frame(width: CGFloat(28 + (line * 17 + index * 11) % 46), height: 3)
            }
        }
        .padding(7)
    }
}

/// Firefox, VS Code and foot side by side; foot types a command.
private struct LinuxAppsPreview: View {
    let isActive: Bool
    @Environment(\.desktopTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var typed = 0
    private let command = "apk add nodejs git"

    var body: some View {
        HStack(spacing: 6) {
            MockWindow(title: "Firefox", accent: theme.accent) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Capsule().fill(Color.orange.opacity(0.85)).frame(width: 30, height: 8)
                        Capsule().fill(.white.opacity(0.12)).frame(width: 24, height: 8)
                    }
                    Text("wikipedia.org")
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Capsule().fill(.white.opacity(0.08)))
                    Text("Linux").font(.system(size: 11, weight: .bold, design: .serif)).foregroundStyle(.white.opacity(0.85))
                    ForEach(0..<5, id: \.self) { line in
                        Capsule().fill(.white.opacity(0.14)).frame(width: CGFloat(54 - line * 5), height: 3)
                    }
                }
                .padding(6)
            }
            MockWindow(title: "Visual Studio Code", accent: theme.accent) {
                HStack(spacing: 0) {
                    VStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 1.5).fill(.white.opacity(0.22)).frame(width: 7, height: 7) }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .frame(width: 14)
                    .background(Color.black.opacity(0.25))
                    VStack(alignment: .leading, spacing: 4) {
                        code([("const", .purple), ("app", .white), ("=", .gray)])
                        code([("import", .purple), ("{ serve }", .cyan)])
                        code([("app.get", .yellow), ("('/')", .orange)])
                        code([("  return", .purple), ("ok", .green)])
                        code([("}", .gray)])
                    }
                    .padding(6)
                }
            }
            MockWindow(title: "foot", focused: true, accent: theme.accent) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 3) {
                        Text("~ ❯").foregroundStyle(theme.accent)
                        Text(String(command.prefix(typed))).foregroundStyle(.white.opacity(0.9))
                        if typed < command.count { BlinkingCursor(color: .white, animates: !reduceMotion).scaleEffect(0.6) }
                    }
                    if typed >= command.count {
                        Text("(1/2) Installing nodejs").foregroundStyle(.white.opacity(0.55))
                        Text("(2/2) Installing git").foregroundStyle(.white.opacity(0.55))
                        Text("OK: 412 MiB in 98 packages").foregroundStyle(Color.green.opacity(0.8))
                    }
                }
                .font(.system(size: 7.5, design: .monospaced))
                .padding(6)
            }
        }
        .padding(12)
        .task(id: isActive) {
            guard isActive else { return }
            if reduceMotion {
                typed = command.count
                return
            }
            typed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(70))
                if typed < command.count {
                    typed += 1
                } else {
                    try? await Task.sleep(for: .seconds(2.2))
                    typed = 0
                }
            }
        }
    }

    private func code(_ tokens: [(String, Color)]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                Text(token.0).foregroundStyle(token.1.opacity(0.85))
            }
        }
        .font(.system(size: 7.5, design: .monospaced))
        .lineLimit(1)
    }
}

/// The built-in colour themes, one after another.
private struct ThemesPreview: View {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    private let themes = Array(ColorTheme.builtIn.prefix(6))

    var body: some View {
        let theme = themes.isEmpty ? nil : themes[index % themes.count]
        ZStack(alignment: .bottomLeading) {
            ThemePreviewCard(theme: theme, showsNotification: true)
                .id(theme?.id ?? "")
                .transition(.opacity)
                .padding(14)
            if let theme {
                Text(theme.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(22)
                    .id("label-\(theme.id)")
                    .transition(.opacity)
            }
        }
        .task(id: isActive) {
            guard isActive, !reduceMotion, !themes.isEmpty else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.easeInOut(duration: 0.45)) { index += 1 }
            }
        }
    }
}

/// Compatibility mode against fast mode, as bars.
private struct FastModePreview: View {
    let isActive: Bool
    @Environment(\.desktopTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(.yellow)
                Text("Native ARM64 JIT").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            bar(label: "Compatibility", value: "1×", fraction: 0.18, color: .white.opacity(0.35))
            bar(label: "Fast mode", value: "≈5×", fraction: 0.9, color: theme.accent)
            Text("Relative speed of Linux programs, average")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .task(id: isActive) {
            guard isActive else { return }
            filled = false
            if reduceMotion {
                filled = true
            } else {
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation(.easeOut(duration: 1.1)) { filled = true }
            }
        }
    }

    private func bar(label: String, value: String, fraction: CGFloat, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text(value).font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(.white)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(color).frame(width: proxy.size.width * (filled ? fraction : 0.02))
                }
            }
            .frame(height: 10)
        }
    }
}

/// A Files window with iPad locations next to Linux ones.
private struct FilesPreview: View {
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        MockWindow(title: "Files", focused: true, accent: theme.accent) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    sidebarRow("house", "Home", selected: false)
                    sidebarRow("ipad.landscape", "On My iPad", selected: true)
                    sidebarRow("icloud", "iCloud Drive", selected: false)
                    sidebarRow("photo.on.rectangle", "Photos", selected: false)
                    sidebarRow("externaldrive", "Linux /", selected: false)
                    Spacer()
                }
                .padding(8)
                .frame(width: 112)
                .background(Color.black.opacity(0.22))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(spacing: 3) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 20))
                                .foregroundStyle(item.color)
                                .frame(height: 24)
                            Text(item.name)
                                .font(.system(size: 7.5))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(10)
            }
        }
        .padding(14)
    }

    private var items: [(symbol: String, name: String, color: Color)] {
        [("folder.fill", "Projects", theme.accent), ("folder.fill", "Downloads", theme.accent),
         ("photo.fill", "beach.heic", .orange), ("doc.text.fill", "notes.md", .white.opacity(0.8)),
         ("film.fill", "demo.mov", .pink), ("folder.fill", "Shared", theme.accent),
         ("doc.richtext.fill", "report.pdf", .red.opacity(0.85)), ("terminal.fill", "build.sh", .green)]
    }

    private func sidebarRow(_ symbol: String, _ title: String, selected: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9)).frame(width: 12)
            Text(title).font(.system(size: 8.5, weight: selected ? .semibold : .regular)).lineLimit(1)
        }
        .foregroundStyle(selected ? Color.white : .white.opacity(0.7))
        .padding(.horizontal, 5).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? theme.accent.opacity(0.45) : .clear))
    }
}
