import Perception
import SwiftUI

// iOS 16 shims for the iOS 17 SwiftUI APIs LinPad uses. On iOS 17+ the native
// API runs; on iOS 16 the closest older behaviour is used instead.

extension View {

    /// `onKeyPress(_:action:)` (iOS 17). The action returns whether the key was handled.
    /// iOS 16 has no keyboard focus for SwiftUI views, so there the key is a UIKit key command
    /// bound while `iOS16Active` is true, and it is always consumed: fold any "not handled"
    /// condition into `iOS16Active`.
    @ViewBuilder func keyPressCompat(_ key: KeyEquivalent, iOS16Active: Bool,
                                     _ action: @escaping () -> Bool) -> some View {
        if #available(iOS 17, *) {
            onKeyPress(key) { action() ? .handled : .ignored }
        } else {
            keyCommandRelay(DesktopKeyCommands.input(for: key), [], isActive: iOS16Active) { _ = action() }
        }
    }

    /// `onKeyPress(action:)` (iOS 17) for any key. The action returns whether the key was handled.
    /// On iOS 16 a hidden view takes first responder while `iOS16Active` is true and gets every key.
    @ViewBuilder func anyKeyPressCompat(iOS16Active: Bool, _ action: @escaping () -> Bool) -> some View {
        if #available(iOS 17, *) {
            onKeyPress { _ in action() ? .handled : .ignored }
        } else {
            background {
                AnyKeyRelay(isActive: iOS16Active) { _ = action() }
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Command plus a character key. Plain presses of the character are left alone.
    @ViewBuilder func commandKeyPressCompat(_ character: Character, iOS16Active: Bool,
                                            _ action: @escaping () -> Void) -> some View {
        if #available(iOS 17, *) {
            onKeyPress(characters: CharacterSet(charactersIn: String(character)), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                action()
                return .handled
            }
        } else {
            keyCommandRelay(String(character), .command, isActive: iOS16Active, action)
        }
    }

    @ViewBuilder func scrollTargetLayoutCompat() -> some View {
        if #available(iOS 17, *) {
            scrollTargetLayout()
        } else {
            self
        }
    }

    /// Tab key, passing whether Shift is held. The action returns whether the key was handled.
    /// iOS 16 behaves as `keyPressCompat`.
    @ViewBuilder func tabKeyPressCompat(iOS16Active: Bool, _ action: @escaping (_ shift: Bool) -> Bool) -> some View {
        if #available(iOS 17, *) {
            onKeyPress(.tab, phases: .down) { press in
                action(press.modifiers.contains(.shift)) ? .handled : .ignored
            }
        } else {
            keyCommandRelay("\t", [], isActive: iOS16Active) { _ = action(false) }
                .keyCommandRelay("\t", .shift, isActive: iOS16Active) { _ = action(true) }
        }
    }

    private func keyCommandRelay(_ input: String, _ modifiers: UIKeyModifierFlags, isActive: Bool,
                                 _ action: @escaping () -> Void) -> some View {
        background {
            KeyCommandRelay(input: input, modifiers: modifiers, isActive: isActive, action: action)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder func focusableWithoutEffectCompat() -> some View {
        if #available(iOS 17, *) {
            focusable().focusEffectDisabled()
        } else {
            self
        }
    }

    /// `scrollBounceBehavior(.basedOnSize)` (iOS 16.4).
    @ViewBuilder func scrollBounceBasedOnSizeCompat() -> some View {
        if #available(iOS 16.4, *) {
            scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }

    /// `fontDesign` (iOS 16.1).
    @ViewBuilder func fontDesignCompat(_ design: Font.Design?) -> some View {
        if #available(iOS 16.1, *) {
            fontDesign(design)
        } else {
            self
        }
    }

    /// `presentationCompactAdaptation(.popover)` (iOS 16.4).
    @ViewBuilder func popoverCompactAdaptationCompat() -> some View {
        if #available(iOS 16.4, *) {
            presentationCompactAdaptation(.popover)
        } else {
            self
        }
    }



    /// Two-parameter `onChange(of:initial:_:)` (iOS 17) with the same signature.
    /// iOS 16 keeps the previous value in state and calls the current body's action.
    @ViewBuilder func onChangeCompat<Value: Equatable>(of value: Value, initial: Bool = false,
                                                       _ action: @escaping (Value, Value) -> Void) -> some View {
        if #available(iOS 17, *) {
            onChange(of: value, initial: initial, action)
        } else {
            modifier(ChangeCompatModifier(value: value, initial: initial, action: action))
        }
    }

    @ViewBuilder func viewAlignedScrollCompat() -> some View {
        if #available(iOS 17, *) {
            scrollTargetBehavior(.viewAligned)
        } else {
            self
        }
    }

    @ViewBuilder func symbolPulseCompat() -> some View {
        if #available(iOS 17, *) {
            symbolEffect(.pulse)
        } else {
            self
        }
    }

    @ViewBuilder func symbolReplaceCompat() -> some View {
        if #available(iOS 17, *) {
            contentTransition(.symbolEffect(.replace))
        } else {
            contentTransition(.opacity)
        }
    }

    /// A horizontal card that is 40pt narrower than its scroll container, capped at 860pt.
    /// iOS 16 sizes it from `containerWidth`, the scroll view's measured width.
    @ViewBuilder func containerWidthCardCompat(containerWidth: CGFloat) -> some View {
        if #available(iOS 17, *) {
            containerRelativeFrame(.horizontal) { width, _ in max(320, min(width - 40, 860)) }
        } else {
            frame(width: max(320, min(containerWidth - 40, 860)))
        }
    }
}

// MARK: - Bindings into perceptible models

// SwiftUI reads a binding's value after the body has returned, outside `WithPerceptionTracking`,
// so on iOS 16 a control or `.sheet` bound to a perceptible model would miss its changes. These
// read the value once while the body is being built, which subscribes the body to it. On iOS 17
// Observation tracks the binding itself and the extra read is harmless.

extension Binding {
    /// `Binding(get:set:)` that subscribes the enclosing body to the value on iOS 16.
    init(tracking get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        _ = get()
        self.init(get: get, set: set)
    }
}

extension Perceptible where Self: AnyObject {
    /// `$model.property` that subscribes the enclosing body to the property on iOS 16.
    func binding<Value>(_ keyPath: ReferenceWritableKeyPath<Self, Value>) -> Binding<Value> {
        Binding(tracking: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}

/// iOS 16's `onChange(of:perform:)` runs the closure captured by the render before the
/// change, so `action` would see the old environment, properties and locals of its view.
/// The latest action is kept in a reference instead and called from there.
private struct ChangeCompatModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let initial: Bool
    let action: (Value, Value) -> Void
    @State private var latest: Latest

    final class Latest {
        var previous: Value
        var action: (Value, Value) -> Void

        init(previous: Value, action: @escaping (Value, Value) -> Void) {
            self.previous = previous
            self.action = action
        }
    }

    init(value: Value, initial: Bool, action: @escaping (Value, Value) -> Void) {
        self.value = value
        self.initial = initial
        self.action = action
        _latest = State(initialValue: Latest(previous: value, action: action))
    }

    func body(content: Content) -> some View {
        let latest = latest
        latest.action = action
        return content
            .onAppear { if initial { latest.action(value, value) } }
            .onChange(of: value) { newValue in
                let old = latest.previous
                latest.previous = newValue
                latest.action(old, newValue)
            }
    }
}

/// `ContentUnavailableView` (iOS 17); on iOS 16 the same layout built by hand.
struct CompatUnavailableView: View {
    let title: String
    let systemImage: String
    var message: String?
    var actions: AnyView?

    init(_ title: String, systemImage: String, message: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    init<Actions: View>(_ title: String, systemImage: String, message: String? = nil,
                        @ViewBuilder actions: () -> Actions) {
        self.init(title, systemImage: systemImage, message: message)
        self.actions = AnyView(actions())
    }

    var body: some View {
        if #available(iOS 17, *) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                if let message { Text(message) }
            } actions: {
                actions
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                actions
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - iOS 16 keyboard

/// One UIKit key command, added to the window's root view controller while active. The root
/// controller is on every responder chain, so the key arrives whether a text field or nothing
/// holds first responder, the same route `DesktopKeyCommands` uses.
private struct KeyCommandRelay: UIViewRepresentable {
    let input: String
    let modifiers: UIKeyModifierFlags
    let isActive: Bool
    let action: () -> Void

    func makeUIView(context: Context) -> KeyCommandRelayView {
        let view = KeyCommandRelayView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: KeyCommandRelayView, context: Context) {
        view.action = action
        view.configure(input: input, modifiers: modifiers, isActive: isActive)
    }
}

final class KeyCommandRelayView: UIView {
    var action: () -> Void = {}
    private let token = UUID().uuidString
    private var command: UIKeyCommand?
    private var isActive = false
    private weak var host: UIViewController?

    private static let views = NSMapTable<NSString, KeyCommandRelayView>.strongToWeakObjects()

    func configure(input: String, modifiers: UIKeyModifierFlags, isActive: Bool) {
        if command?.input != input || command?.modifierFlags != modifiers {
            detach()
            let command = UIKeyCommand(title: "", action: #selector(UIResponder.keyCommandRelayPerform(_:)),
                                       input: input, modifierFlags: modifiers, propertyList: token)
            command.wantsPriorityOverSystemBehavior = true
            self.command = command
            Self.views.setObject(self, forKey: token as NSString)
        }
        self.isActive = isActive
        sync()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sync()
    }

    private func sync() {
        let target = isActive ? window?.rootViewController : nil
        guard target !== host else { return }
        detach()
        guard let target, let command else { return }
        host = target
        target.addKeyCommand(command)
    }

    private func detach() {
        if let command { host?.removeKeyCommand(command) }
        host = nil
    }

    static func perform(_ token: String) {
        views.object(forKey: token as NSString)?.action()
    }
}

extension UIResponder {
    /// Sent up the responder chain by `KeyCommandRelayView`'s key commands. UIKit matches
    /// key commands before it delivers presses to the first responder, so an overlay waiting
    /// for any key (`AnyKeyRelayView`, the lock screen and screensaver) takes the key here
    /// instead of letting it reach a view underneath.
    @objc func keyCommandRelayPerform(_ sender: UIKeyCommand) {
        if let anyKey = self as? AnyKeyRelayView {
            MainActor.assumeIsolated { anyKey.action() }
            return
        }
        guard let token = sender.propertyList as? String else { return }
        MainActor.assumeIsolated { KeyCommandRelayView.perform(token) }
    }
}

/// Takes first responder while active and treats every hardware key press as handled.
private struct AnyKeyRelay: UIViewRepresentable {
    let isActive: Bool
    let action: () -> Void

    func makeUIView(context: Context) -> AnyKeyRelayView {
        let view = AnyKeyRelayView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: AnyKeyRelayView, context: Context) {
        view.action = action
        view.isActive = isActive
        if isActive, !view.isFirstResponder {
            DispatchQueue.main.async { if view.window != nil { view.becomeFirstResponder() } }
        } else if !isActive, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}

final class AnyKeyRelayView: UIView {
    var action: () -> Void = {}
    var isActive = false

    private static let relays = NSHashTable<AnyKeyRelayView>.weakObjects()

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.key != nil }) else { return super.pressesBegan(presses, with: event) }
        action()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            Self.relays.add(self)
        } else {
            Self.relays.remove(self)
            DispatchQueue.main.async { Self.reassignKeyboard() }
        }
    }

    /// A view leaving the window drops first responder, and nothing takes it back: keys
    /// (and the shell's shortcuts) would stop until the next tap. The keyboard goes to
    /// another overlay still waiting for a key (the lock screen under a screensaver), else
    /// back to the desktop's key commands.
    private static func reassignKeyboard() {
        guard UIResponder.desktopCurrentFirstResponder == nil else { return }
        if let next = relays.allObjects.last(where: { $0.isActive && $0.window != nil }) {
            next.becomeFirstResponder()
        } else {
            DesktopKeyCommands.active?.makeReachable()
        }
    }
}
