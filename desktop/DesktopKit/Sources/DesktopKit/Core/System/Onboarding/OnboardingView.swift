import SwiftUI
import UIKit

/// First run, and Settings › About › Replay Welcome: a cinematic intro while Linux unpacks,
/// a feature reel, personalisation applied live, apps, fast mode, keyboard tips and a demo
/// workspace. Every step can be skipped; arrows and Return drive it from a keyboard.
struct OnboardingView: View {
    let controller: DesktopController
    @State private var flow = OnboardingFlow()
    @State private var tourPage = 0
    @State private var triedShortcut = false
    @Environment(\.desktopTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var catalog: AppCatalogModel { AppCatalogModel.shared(for: controller.host) }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Nothing under onboarding takes a touch: taps on empty areas stop here.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)
                if flow.step == .intro {
                    OnboardingBackdrop(accent: theme.accent)
                        .transition(.opacity)
                    intro
                        .transition(.opacity)
                } else {
                    Color.black.opacity(0.38)
                        .ignoresSafeArea()
                        .transition(.opacity)
                    panel(in: proxy.size)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.45), value: flow.step == .intro)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .background {
            OnboardingKeyCatcher { key in
                switch key {
                case .left: _ = backward()
                case .right: _ = forward()
                case .enter: primaryAction()
                }
            }
            .accessibilityHidden(true)
        }
        .onAppear { controller.previewOnboardingChoices(flow.choices) }
        .onDisappear {
            // Hand the keyboard back to the desktop so its shortcuts work without a tap.
            DispatchQueue.main.async { controller.input.ensureKeyCommandsReachable() }
        }
        .onChange(of: controller.isLauncherPresented) { _, presented in
            // ⌃⌥A reaches the desktop's key commands; here it only lights up the cheat card.
            guard presented else { return }
            controller.isLauncherPresented = false
            if flow.step == .keyboard { triedShortcut = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop.onboarding")
    }

    // MARK: Intro

    private var intro: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip Setup") { complete(skipped: true) }
                    .buttonStyle(OnboardingButtonStyle(kind: .quiet, onDark: true))
                    .accessibilityIdentifier("onboarding.skip")
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            OnboardingIntro(controller: controller)
            Button { flow.advance() } label: {
                HStack(spacing: 8) {
                    Text(flow.isReplay ? "Take the Tour" : "Get Started")
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(OnboardingButtonStyle(kind: .hero))
            .accessibilityIdentifier("onboarding.next")
            .padding(.top, 26)
            .padding(.bottom, 48)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.step.intro")
    }

    // MARK: Panel

    private func panel(in size: CGSize) -> some View {
        let width = min(1000, size.width - (size.width > 900 ? 64 : 32))
        let height = min(720, size.height - (size.height > 800 ? 64 : 32))
        return VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 22)
            if flow.step != .tour && flow.step != .finale {
                Text(flow.step.title)
                    .font(.system(.largeTitle, weight: .bold))
                    .padding(.horizontal, 28)
                    .padding(.top, 18)
                    .padding(.bottom, 14)
                    .accessibilityAddTraits(.isHeader)
            }
            content
                .id(flow.step)
                .transition(stepTransition)
                .padding(.horizontal, 28)
                .padding(.vertical, flow.step == .tour || flow.step == .finale ? 12 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .environment(\.horizontalSizeClass, width < 800 ? .compact : .regular)
            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
        }
        .foregroundStyle(theme.primaryText)
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(theme.windowBackground))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(theme.separator))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 40, y: 16)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.32), value: flow.step)
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let edge: Edge = flow.movedForward ? .trailing : .leading
        return .asymmetric(insertion: .opacity.combined(with: .move(edge: edge)),
                           removal: .opacity)
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                ForEach(flow.steps) { step in
                    Capsule()
                        .fill(flow.steps.firstIndex(of: step)! <= flow.position ? theme.accent : theme.primaryText.opacity(0.14))
                        .frame(width: step == flow.step ? 26 : 14, height: 5)
                }
            }
            .animation(DesktopMotion.standard, value: flow.position)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(flow.position + 1) of \(flow.steps.count): \(flow.step.title)")
            .accessibilityIdentifier("onboarding.progress")
            Text("\(flow.position + 1) of \(flow.steps.count)")
                .font(.system(.footnote, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.secondaryText)
                .accessibilityHidden(true)
            Spacer()
            if !BootProgressVisibility.hidden(flow.step), !controller.boot.isFinished {
                BootStatus(controller: controller, compact: true)
                    .environment(\.colorScheme, .dark)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .transition(.opacity)
            }
            if flow.step != .finale {
                Button("Skip") { complete(skipped: true) }
                    .buttonStyle(OnboardingButtonStyle(kind: .quiet))
                    .accessibilityHint("Closes setup and keeps the defaults for the remaining steps")
                    .accessibilityIdentifier("onboarding.skip")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.step {
        case .intro:
            EmptyView()
        case .tour:
            OnboardingTour(page: $tourPage)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("onboarding.step.tour")
        case .personalize:
            OnboardingPersonalize(flow: flow, controller: controller)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("onboarding.step.personalize")
        case .apps:
            OnboardingApps(flow: flow, controller: controller, catalog: catalog)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("onboarding.step.apps")
        case .fastMode:
            OnboardingFastMode(controller: controller)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("onboarding.step.fastMode")
        case .keyboard:
            OnboardingKeyboard(controller: controller, triedShortcut: triedShortcut)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("onboarding.step.keyboard")
        case .finale:
            OnboardingFinale(controller: controller,
                             onShowMe: { complete(skipped: false, showDemo: true) },
                             onStartFresh: { complete(skipped: false) })
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("onboarding.step.finale")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                _ = backward()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(OnboardingButtonStyle(kind: .secondary))
            .accessibilityIdentifier("onboarding.back")
            Spacer()
            if controller.keyboard.hasPointerOrKeyboard {
                Text(flow.step == .tour ? "← → to browse  ·  ↩ next" : "← →  to move between steps")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityHidden(true)
            }
            if flow.step != .finale {
                Button {
                    _ = forward()
                } label: {
                    HStack(spacing: 6) {
                        Text(primaryTitle)
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(OnboardingButtonStyle(kind: flow.step == .fastMode && controller.fastMode != nil
                                                   && controller.cpuEngine != .nativeJIT ? .secondary : .primary))
                .accessibilityIdentifier("onboarding.next")
            }
        }
    }

    private var primaryTitle: String {
        switch flow.step {
        case .tour: tourPage < OnboardingTour.cards.count - 1 ? "Next" : "Continue"
        case .apps: flow.choices.packs.isEmpty ? "Continue" : "Continue with \(flow.choices.packs.count)"
        case .fastMode: controller.cpuEngine == .nativeJIT || controller.fastMode == nil ? "Continue" : "Later"
        default: "Continue"
        }
    }

    // MARK: Navigation

    /// Return: what the step's filled button does.
    private func primaryAction() {
        switch flow.step {
        case .intro: flow.advance()
        case .finale: complete(skipped: false, showDemo: true)
        default: _ = forward()
        }
    }

    /// Right arrow or Return: the next tour card, then the next step.
    private func forward() -> Bool {
        switch flow.step {
        case .tour where tourPage < OnboardingTour.cards.count - 1:
            withAnimation(DesktopMotion.standard) { tourPage += 1 }
        case .finale:
            return false
        default:
            flow.advance()
        }
        return true
    }

    private func backward() -> Bool {
        switch flow.step {
        case .intro:
            return false
        case .tour where tourPage > 0:
            withAnimation(DesktopMotion.standard) { tourPage -= 1 }
        case .personalize:
            tourPage = OnboardingTour.cards.count - 1
            flow.back()
        default:
            flow.back()
        }
        return true
    }

    private func complete(skipped: Bool, showDemo: Bool = false) {
        controller.completeOnboarding(flow, catalog: catalog, skipped: skipped, showDemo: showDemo)
    }
}

/// Steps that already show Linux's progress themselves.
private enum BootProgressVisibility {
    static func hidden(_ step: OnboardingStep) -> Bool {
        step == .intro || step == .apps || step == .finale
    }
}

/// Onboarding's buttons: larger than the desktop's toolbar buttons, at least 44 pt tall.
struct OnboardingButtonStyle: ButtonStyle {
    enum Kind {
        /// The intro's call to action.
        case hero
        case primary
        case secondary
        /// Text only, for Skip.
        case quiet
    }

    let kind: Kind
    /// Over the intro's dark backdrop, whatever the theme.
    var onDark = false
    @Environment(\.desktopTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)
        configuration.label
            .font(.system(kind == .hero ? .title3 : .body, weight: .semibold))
            .padding(.horizontal, kind == .hero ? 30 : (kind == .quiet ? 14 : 20))
            .frame(minHeight: kind == .hero ? 54 : 44)
            .foregroundStyle(foreground)
            .background {
                switch kind {
                case .hero, .primary: shape.fill(theme.accent)
                case .secondary: shape.fill(theme.primaryText.opacity(0.06))
                case .quiet: Color.clear
                }
            }
            .overlay {
                if kind == .secondary { shape.strokeBorder(theme.separator) }
            }
            .shadow(color: kind == .hero ? theme.accent.opacity(0.45) : .clear, radius: 18, y: 6)
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .animation(DesktopMotion.quick, value: configuration.isPressed)
            .hoverEffect(.highlight)
    }

    private var foreground: Color {
        switch kind {
        case .hero, .primary: theme.accent.readableLabel
        case .secondary: theme.primaryText
        case .quiet: onDark ? Color.white.opacity(0.75) : theme.secondaryText
        }
    }
}

/// Arrows and Return for onboarding, as UIKit key commands: SwiftUI focus never sees these
/// keys while the desktop's input anchor holds first responder, so this view takes it from
/// the anchor while onboarding is on screen. The shell's own shortcuts (⌃⌥A for the cheat
/// card) stay reachable: they sit on the root view controller, on this view's chain.
struct OnboardingKeyCatcher: UIViewRepresentable {
    let onKey: (Key) -> Void

    enum Key: String {
        case left, right, enter
    }

    func makeUIView(context: Context) -> KeyView {
        let view = KeyView()
        view.onKey = onKey
        return view
    }

    func updateUIView(_ view: KeyView, context: Context) {
        view.onKey = onKey
    }

    static func dismantleUIView(_ view: KeyView, coordinator: ()) {
        view.uninstall()
    }

    final class KeyView: UIView {
        var onKey: ((Key) -> Void)?
        private weak var host: UIViewController?
        private var commands: [UIKeyCommand] = []
        fileprivate static weak var active: KeyView?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let root = window?.rootViewController { install(on: root) } else { uninstall() }
        }

        private func install(on root: UIViewController) {
            guard host !== root else { return }
            uninstall()
            host = root
            Self.active = self
            commands = [(UIKeyCommand.inputLeftArrow, Key.left), (UIKeyCommand.inputRightArrow, .right)]
                .map { input, key in
                    let command = UIKeyCommand(title: "", action: #selector(UIResponder.onboardingPerformKey(_:)),
                                               input: input, modifierFlags: [], propertyList: key.rawValue)
                    command.wantsPriorityOverSystemBehavior = true
                    return command
                }
            // The anchor takes first responder back after taps; reclaim it from there (or from
            // nobody), never from a text field or a sheet.
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.claimKeyboardIfUnowned() }
            }
            claimKeyboardIfUnowned()
        }

        private var timer: Timer?

        override var canBecomeFirstResponder: Bool { true }

        override var keyCommands: [UIKeyCommand]? { commands }

        /// Return arrives as a press rather than through a key command.
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let returns: Set<UIKeyboardHIDUsage> = [.keyboardReturnOrEnter, .keypadEnter]
            if presses.contains(where: { $0.key.map { returns.contains($0.keyCode) && $0.modifierFlags.isEmpty } ?? false }) {
                onKey?(.enter)
            } else {
                super.pressesBegan(presses, with: event)
            }
        }

        private func claimKeyboardIfUnowned() {
            guard window != nil, !isFirstResponder else { return }
            let current = UIResponder.desktopCurrentFirstResponder
            if current == nil || current is DesktopInputAnchor.AnchorView { becomeFirstResponder() }
        }

        func uninstall() {
            timer?.invalidate()
            timer = nil
            if isFirstResponder { resignFirstResponder() }
            commands = []
            host = nil
        }

        fileprivate static func perform(_ key: Key) {
            active?.onKey?(key)
        }
    }
}

extension UIResponder {
    @objc func onboardingPerformKey(_ sender: UIKeyCommand) {
        guard let raw = sender.propertyList as? String, let key = OnboardingKeyCatcher.Key(rawValue: raw) else { return }
        MainActor.assumeIsolated { OnboardingKeyCatcher.KeyView.perform(key) }
    }
}
