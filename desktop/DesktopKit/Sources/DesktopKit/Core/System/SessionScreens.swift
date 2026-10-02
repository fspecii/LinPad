import SwiftUI

/// The lock screen: wallpaper, a large clock, and any tap or key press unlocks. There is no
/// password; it hides the desktop, it does not secure it.
struct LockScreen: View {
    let controller: DesktopController
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            WallpaperView(store: controller.wallpapers, source: controller.wallpaperSource(), variant: .blurred,
                          accessibilityID: "desktop.lockScreen.wallpaper")
            Color.black.opacity(0.35)
            TimelineView(.everyMinute) { context in
                VStack(spacing: 8) {
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 96, weight: .thin).monospacedDigit())
                    Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: 22, weight: .regular))
                    Spacer().frame(height: 60)
                    Label("Tap or press any key to unlock", systemImage: "lock.open")
                        .font(.system(size: 15, weight: .medium))
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { controller.unlockScreen() }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress { _ in
            controller.unlockScreen()
            return .handled
        }
        .onAppear { isFocused = true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Locked. Activate to unlock.")
        .accessibilityIdentifier("desktop.lockScreen")
    }
}

/// Shown from launch until Linux answers, so the user sees the system starting instead of
/// an empty desktop.
struct BootSplash: View {
    let controller: DesktopController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 22) {
                Text(BootSplash.logo)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                Text("Linux for iPad")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                ProgressView(value: controller.boot.progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: 260)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: controller.boot.progress)
                Text(controller.boot.step)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                if let engine = controller.cpuEngine {
                    Text("Performance: \(engine.title)")
                        .font(.system(size: 12))
                        .foregroundStyle(engine == .nativeJIT ? Color.green.opacity(0.8) : .white.opacity(0.45))
                        .accessibilityIdentifier("desktop.bootSplash.engine")
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Starting Linux. \(controller.boot.step)")
        .accessibilityIdentifier("desktop.bootSplash")
    }

    /// The same mark the guest prints (/usr/share/ish/logo.txt).
    static let logo = """
            .--.
           |o_o |
           |:_/ |
          //   \\ \\
         (|     | )
        /'\\_   _/`\\
        \\___)=(___/
        """
}

/// Boot progress, as far as the desktop can see it: the guest answering a shell command,
/// then (with Linux GUI apps) the Wayland session coming up.
@Observable @MainActor
final class BootProgress {
    private(set) var progress = 0.1
    private(set) var step = "Starting Linux…"
    private(set) var isFinished = false

    private static let sessionTimeout: Duration = .seconds(15)

    func run(host: any LinuxHost, linux: LinuxGUIBridge?) async {
        if let preparing = host as? LinuxSystemPreparing,
           let failure = await waitForPreparation(preparing.preparation) {
            step = "Linux could not be installed: \(failure)"
            try? await Task.sleep(for: .seconds(4))
            finish()
            return
        }
        step = "Configuring…"
        // `hostname` is answered by every host, including the in-memory one used for previews.
        let result = await host.run("hostname")
        progress = max(progress, 0.8)
        guard result.succeeded else {
            step = "Linux did not start: \(result.stderr)"
            try? await Task.sleep(for: .seconds(2))
            finish()
            return
        }
        if let linux {
            step = "Starting desktop…"
            let deadline = ContinuousClock.now + Self.sessionTimeout
            while linux.state != .running, ContinuousClock.now < deadline {
                if case .failed = linux.state { break }
                try? await Task.sleep(for: .milliseconds(200))
                progress = min(0.95, progress + 0.02)
            }
        }
        finish()
    }

    /// Mirrors the host's first-launch unpacking into the splash (2–70 %); nil once ready.
    private func waitForPreparation(_ preparation: LinuxSystemPreparation) async -> String? {
        while true {
            switch preparation.phase {
            case .ready:
                return nil
            case .failed(let reason):
                return reason
            case .unpacking:
                progress = 0.02 + 0.68 * preparation.fraction
                step = preparation.detail.isEmpty ? preparation.title : "\(preparation.title)  \(preparation.detail)"
            case .configuring:
                progress = max(progress, 0.72)
                step = preparation.title.isEmpty ? "Configuring…" : preparation.title
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func finish() {
        progress = 1
        step = "Ready"
        isFinished = true
    }
}

/// First run: style, appearance, auto-tiling, terminal and optional packs. The choices go
/// to UserDefaults and to /etc/ish/firstrun.json, which the guest's install scripts read.
struct OnboardingView: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme
    @AppStorage(DesktopStyle.storageKey) private var styleID = DesktopStyle.defaultStyle.rawValue
    @AppStorage(DesktopAppearance.storageKey) private var appearanceID = DesktopAppearance.styleDefault.rawValue
    @State private var tiles = false
    @State private var terminal = "native"
    @State private var packs: Set<String> = []
    @State private var installed: Set<String> = []

    static let completedKey = "desktop.onboarded"
    static let choicesKey = "desktop.firstRunChoices"

    private static let optionalPacks: [(id: String, name: String, symbol: String, probe: String)] = [
        ("vscode", "VS Code", "chevron.left.forwardslash.chevron.right", "code"),
        ("multimedia", "Multimedia (VLC)", "play.rectangle", "vlc"),
        ("gpu", "GPU tools", "cpu", "glxinfo"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Welcome to Linux for iPad")
                .font(.system(size: 26, weight: .semibold))
            Text("Choose how your desktop looks and works. You can change all of this later in Settings.")
                .font(.system(size: 14))
                .foregroundStyle(theme.secondaryText)

            section("Desktop style") {
                HStack(spacing: 10) {
                    ForEach(DesktopStyle.allCases) { style in
                        Button { styleID = style.rawValue } label: {
                            Text(style.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(styleID == style.rawValue ? theme.accent : theme.primaryText.opacity(0.08)))
                                .foregroundStyle(styleID == style.rawValue ? Color.white : theme.primaryText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(styleID == style.rawValue ? .isSelected : [])
                        .accessibilityIdentifier("onboarding.style.\(style.rawValue)")
                    }
                }
            }
            section("Appearance") {
                Picker("Appearance", selection: $appearanceID) {
                    ForEach(DesktopAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
            section("Windows") {
                Toggle("Tile windows automatically", isOn: $tiles).tint(theme.accent)
            }
            section("Terminal") {
                Picker("Terminal", selection: $terminal) {
                    Text("Native").tag("native")
                    Text("foot (Linux)").tag("foot")
                }
                .pickerStyle(.segmented)
            }
            section("Optional packs") {
                ForEach(Self.optionalPacks, id: \.id) { pack in
                    Toggle(isOn: Binding(get: { packs.contains(pack.id) || installed.contains(pack.id) },
                                         set: { on in if on { packs.insert(pack.id) } else { packs.remove(pack.id) } })) {
                        HStack {
                            Label(pack.name, systemImage: pack.symbol)
                            if installed.contains(pack.id) {
                                Text("Installed").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(theme.accent)
                            }
                        }
                    }
                    .tint(theme.accent)
                    .disabled(installed.contains(pack.id))
                }
            }
            HStack {
                Spacer()
                Button("Start Using the Desktop") { finish() }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.done")
            }
        }
        .foregroundStyle(theme.primaryText)
        .padding(28)
        .frame(width: 620)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.windowBackground))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.separator))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
        .task { await probeInstalled() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop.onboarding")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.secondaryText)
            content()
        }
    }

    private func probeInstalled() async {
        let probes = Self.optionalPacks.map { "command -v \($0.probe) >/dev/null 2>&1 && echo \($0.id)" }
        let result = await controller.host.run(probes.joined(separator: "; ") + "; true")
        installed = Set(result.stdout.split(separator: "\n").map(String.init))
    }

    private func finish() {
        let choices: [String: Any] = [
            "version": 1,
            "style": styleID,
            "appearance": appearanceID.isEmpty ? "default" : appearanceID,
            "autoTiling": tiles,
            "terminal": terminal,
            "packs": packs.sorted(),
            "installed": installed.sorted(),
        ]
        UserDefaults.standard.set(choices, forKey: Self.choicesKey)
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        if tiles { controller.windowManager.setTiling(true, workspace: 0) }
        if let json = try? JSONSerialization.data(withJSONObject: choices, options: [.prettyPrinted, .sortedKeys]) {
            Task {
                _ = await controller.host.run("mkdir -p /etc/ish")
                try? await controller.host.writeFile("/etc/ish/firstrun.json", data: json)
            }
        }
        withAnimation(DesktopMotion.standard) { controller.isOnboardingPresented = false }
    }
}
