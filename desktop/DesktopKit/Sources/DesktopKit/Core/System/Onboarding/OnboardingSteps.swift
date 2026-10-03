import SwiftUI

// MARK: - Apps

/// The optional-apps catalog with checkboxes. Nothing is ticked to begin with.
struct OnboardingApps: View {
    @Bindable var flow: OnboardingFlow
    let controller: DesktopController
    let catalog: AppCatalogModel
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LinPad starts small. Tick what you want and it installs in the background after setup. LinPad Store has hundreds more, and adds or removes apps later.")
                .font(.callout)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if controller.boot.isFinished {
                ScrollView {
                    StorePicker(store: StoreModel.shared(for: controller.host), selection: selection)
                        .padding(.trailing, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                VStack(spacing: 14) {
                    BootStatus(controller: controller)
                        .environment(\.colorScheme, .dark)
                        .padding(.horizontal, 18).padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.75)))
                    Text("The app list appears as soon as Linux is ready. You can keep going; this step will wait for you.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !flow.choices.packs.isEmpty {
                Text(summary)
                    .font(.system(.footnote, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.accent)
                    .accessibilityIdentifier("onboarding.apps.summary")
            }
        }
        .task(id: controller.boot.isFinished) {
            guard controller.boot.isFinished, !catalog.hasLoaded else { return }
            await catalog.load()
        }
    }

    private var selection: Binding<Set<String>> {
        Binding(get: { Set(flow.choices.packs) },
                set: { flow.choices.packs = $0.sorted() })
    }

    private var summary: String {
        StorePicker.summary(Set(flow.choices.packs), store: StoreModel.shared(for: controller.host))
    }
}

// MARK: - Fast mode

struct OnboardingFastMode: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme
    @State private var showsSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color.yellow)
                    .frame(width: 64, height: 64)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.8)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Run Linux programs as native ARM64 code, about 5× faster.")
                        .font(.system(.title3, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("iPadOS only allows that while a debugger is attached. LinPad asks StikDebug, a separate app, to attach at launch; it also needs LocalDevVPN and a one-time pairing file. Without it, everything still works in Compatibility mode.")
                        .font(.callout)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            statusRow
            HStack(spacing: 12) {
                if let fastMode = controller.fastMode {
                    Button("Set Up Now") { showsSetup = true }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("onboarding.fastMode.setup")
                        .sheet(isPresented: $showsSetup) { FastModeSetupSheet(fastMode: fastMode) }
                }
            }
            Text(controller.fastMode == nil ? "Fast mode needs the release build of LinPad on an iPad."
                                            : "Not now? “Later” moves on; Settings › Fast Mode has the same setup any time.")
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var statusRow: some View {
        let (symbol, text, tint): (String, String, Color) = {
            switch controller.cpuEngine {
            case .nativeJIT?: return ("checkmark.seal.fill", "Fast mode is on: Linux runs on the native JIT.", .green)
            case .compatibility?: return ("tortoise.fill", "Linux is running in Compatibility mode right now.", theme.secondaryText)
            case nil:
                return controller.fastMode == nil
                    ? ("info.circle", "This build of LinPad has no fast mode.", theme.secondaryText)
                    : ("hourglass", "LinPad will know which mode Linux uses once it has started.", theme.secondaryText)
            }
        }()
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(tint == .green ? theme.primaryText : tint)
            .symbolRenderingMode(.hierarchical)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.primaryText.opacity(0.06)))
            .accessibilityIdentifier("onboarding.fastMode.status")
    }
}

// MARK: - Keyboard and touch

/// A cheat card that reacts to the launcher shortcut, and the touch gestures.
struct OnboardingKeyboard: View {
    let controller: DesktopController
    let triedShortcut: Bool
    @Environment(\.desktopTheme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasKeyboard: Bool { controller.keyboard.hasPointerOrKeyboard }

    var body: some View {
        let layout = sizeClass == .compact
            ? AnyLayout(VStackLayout(spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        ScrollView {
            layout {
                if hasKeyboard {
                    keyboardCard
                    touchCard
                } else {
                    touchCard
                    keyboardCard
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var launcher: DesktopCommand? { DesktopCommand.all.first { $0.id == "launcher" } }

    private var keyboardCard: some View {
        card(title: "Keyboard & trackpad", symbol: "keyboard") {
            if let launcher {
                VStack(alignment: .leading, spacing: 12) {
                    Text(triedShortcut ? "That's the launcher. It opens from anywhere, even inside a Linux app."
                                       : hasKeyboard ? "Try it: press" : "With a keyboard attached, press")
                        .font(.callout)
                        .foregroundStyle(triedShortcut ? theme.primaryText : theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        ForEach(Array(keycaps(launcher).enumerated()), id: \.offset) { _, cap in
                            Keycap(label: cap, lit: triedShortcut)
                        }
                        if triedShortcut {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(theme.accent)
                                .transition(.scale.combined(with: .opacity))
                        }
                        Spacer(minLength: 0)
                    }
                    .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: triedShortcut)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(triedShortcut ? "Applications shortcut works" : "Press \(launcher.shortcutLabel) to open Applications")
                    .accessibilityIdentifier("onboarding.keyboard.try")
                    .accessibilityValue(triedShortcut ? "done" : "waiting")
                }
            }
            Divider().overlay(theme.separator)
            VStack(spacing: 8) {
                ForEach(shortcuts, id: \.id) { command in
                    HStack {
                        Text(command.title).font(.callout)
                        Spacer()
                        Text(command.shortcutLabel)
                            .font(.system(.callout, design: .rounded, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .opacity(hasKeyboard || triedShortcut ? 1 : 0.8)
    }

    private var shortcuts: [DesktopCommand] {
        let ids = ["terminal", "snap.left", "snap.right", "overview", "switcher", "theme.picker"]
        let all = DesktopCommand.all
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    private func keycaps(_ command: DesktopCommand) -> [String] {
        let label = command.shortcutLabel
        let modifiers = label.prefix { "⌃⌥⇧⌘".contains($0) }.map(String.init)
        return modifiers + [String(label.dropFirst(modifiers.count))]
    }

    private var touchCard: some View {
        card(title: "Touch", symbol: "hand.point.up.left") {
            VStack(alignment: .leading, spacing: 14) {
                gesture("hand.draw", "Drag a title bar to a screen edge", "Snaps the window to half or a quarter of the screen.")
                gesture("hand.tap", "Double-tap a title bar", "Maximizes the window, or restores it.")
                gesture("hand.point.up.left.and.text", "Touch and hold", "Opens the context menu, like a right-click.")
                gesture("hand.raised.fingers.spread", "Swipe with three fingers", "Up shows the overview, sideways switches workspace.")
            }
        }
    }

    private func gesture(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(theme.accent)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.callout, weight: .semibold))
                Text(detail).font(.footnote).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func card<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.primaryText.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.separator))
    }
}

struct Keycap: View {
    let label: String
    var lit = false
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        Text(label)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .foregroundStyle(lit ? theme.accent.readableLabel : theme.primaryText)
            .frame(minWidth: 46, minHeight: 46)
            .padding(.horizontal, label.count > 1 ? 8 : 0)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(lit ? theme.accent : theme.primaryText.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(lit ? theme.accent : theme.separator, lineWidth: 1))
            .shadow(color: .black.opacity(lit ? 0 : 0.25), radius: 0, y: 2)
            .scaleEffect(lit ? 1.04 : 1)
    }
}

// MARK: - Finale

struct OnboardingFinale: View {
    let controller: DesktopController
    let onShowMe: () -> Void
    let onStartFresh: () -> Void
    @Environment(\.desktopTheme) private var theme

    private var demoApps: String {
        let browser = controller.hasLinuxApplication("firefox-esr") ? "Firefox" : "the browser"
        let code = controller.hasLinuxApplication("code") ? ", VS Code" : ""
        return "\(browser), a terminal\(code) and Files"
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            LinPadMark(accent: theme.accent, animates: false)
                .scaleEffect(0.7)
                .frame(width: 190, height: 140)
                .environment(\.colorScheme, .dark)
                .background(Circle().fill(Color.black.opacity(0.8)).frame(width: 210, height: 210))
                .accessibilityHidden(true)
            Text("You're set.")
                .font(.system(.largeTitle, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text("Want to see what this iPad can do? LinPad will open \(demoApps), tiled side by side.")
                .font(.title3)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button("Start Fresh", action: onStartFresh)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(theme.accent)
                    .accessibilityIdentifier("onboarding.startFresh")
                Button(action: onShowMe) {
                    Label("Show Me", systemImage: "sparkles")
                        .font(.system(.body, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier("onboarding.showMe")
            }
            if !controller.boot.isFinished {
                BootStatus(controller: controller, compact: true)
                    .environment(\.colorScheme, .dark)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                Text("The windows open as soon as Linux is ready.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
