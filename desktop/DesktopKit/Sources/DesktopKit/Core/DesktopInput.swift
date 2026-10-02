import GameController
import Observation
import SwiftUI
import UIKit

/// Whether a hardware keyboard is attached, and the modifier releases UIKit key commands
/// cannot report (Option-Tab's switcher commits when Option is let go). GameController sees
/// the keyboard below the responder chain, so this works while a terminal or Linux window
/// holds first responder.
@Observable @MainActor
final class HardwareKeyboardMonitor {
    private(set) var isConnected = GCKeyboard.coalesced != nil
    private(set) var hasPointer = GCMouse.current != nil

    var hasPointerOrKeyboard: Bool { isConnected || hasPointer }
    @ObservationIgnored var onSwitcherModifierReleased: (() -> Void)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Search fields focus themselves only with a hardware keyboard: on touch alone, opening
    /// a menu must not throw the on-screen keyboard over the panel. Some Bluetooth keyboards
    /// reach GameController only after their first key, so a recent hardware key press counts.
    static var isAttached: Bool {
        GCKeyboard.coalesced != nil || lastHardwareKeyPress.map { Date().timeIntervalSince($0) < 600 } ?? false
    }

    private static var lastHardwareKeyPress: Date?

    /// Called for presses that carry a key (on-screen keyboard taps arrive as text instead).
    static func noteHardwareKeyPress() {
        lastHardwareKeyPress = Date()
    }

    /// Without GameController keyboard events the switcher stays open until Return or a click.
    var canObserveModifiers: Bool { GCKeyboard.coalesced?.keyboardInput != nil }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach() }
        })
        observers.append(center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isConnected = GCKeyboard.coalesced != nil }
        })
        for name in [Notification.Name.GCMouseDidConnect, .GCMouseDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hasPointer = GCMouse.current != nil }
            })
        }
        attach()
    }

    private func attach() {
        isConnected = GCKeyboard.coalesced != nil
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            guard !pressed, keyCode == .leftAlt || keyCode == .rightAlt else { return }
            Task { @MainActor in self?.onSwitcherModifierReleased?() }
        }
    }
}

/// The shell's UIKit side: the gestures that must see every touch on the screen (focus on
/// touch-down, three-finger swipes), the on-screen keyboard's frame, and screen snapshots
/// for the window switcher. It lives on a view pinned to the desktop area's origin, which
/// doubles as the reference for converting UIKit locations into desktop coordinates.
@MainActor
final class DesktopInputCoordinator: NSObject, UIGestureRecognizerDelegate {
    weak var controller: DesktopController?
    private(set) weak var referenceView: UIView?
    private weak var installedWindow: UIWindow?
    private var recognizers: [UIGestureRecognizer] = []
    private var keyboardObserver: NSObjectProtocol?
    private var hideObservers: [NSObjectProtocol] = []
    private var keyboardFrame: CGRect = .null
    private var pendingInterfaceStyle: UIUserInterfaceStyle?

    private static let snapshotScale: CGFloat = 0.5
    private static let swipeDistance: CGFloat = 70

    func attach(to view: UIView) {
        referenceView = view
        guard let window = view.window, window !== installedWindow else { return }
        recognizers.forEach { $0.view?.removeGestureRecognizer($0) }
        installedWindow = window
        if let pendingInterfaceStyle { window.overrideUserInterfaceStyle = pendingInterfaceStyle }

        let focus = TouchDownRecognizer(target: self, action: #selector(touchDown(_:)))
        focus.delegate = self
        let swipe = UIPanGestureRecognizer(target: self, action: #selector(threeFingerPan(_:)))
        swipe.minimumNumberOfTouches = 3
        swipe.maximumNumberOfTouches = 3
        swipe.cancelsTouchesInView = false
        swipe.delegate = self
        recognizers = [focus, swipe]
        recognizers.forEach(window.addGestureRecognizer)

        if let controller, let root = window.rootViewController {
            controller.keyCommands.install(on: root)
            DesktopKeyCommands.active = controller.keyCommands
        }
        DispatchQueue.main.async { [weak self] in self?.ensureKeyCommandsReachable() }
        guard keyboardObserver == nil else { return }
        let center = NotificationCenter.default
        keyboardObserver = center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                              queue: .main) { [weak self] note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { self?.keyboardFrameChanged(frame ?? .null) }
        }
        for name in [UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification,
                     UIApplication.didEnterBackgroundNotification] {
            hideObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardHidden() }
            })
        }
    }

    /// Key commands are looked up from the first responder; with none (after a text field
    /// goes away, or a tap on the wallpaper) UIKit drops hardware shortcuts altogether. The
    /// anchor view then takes first responder: it accepts no text, so no on-screen keyboard
    /// appears, and the shell's key commands are on its responder chain.
    func ensureKeyCommandsReachable() {
        guard let referenceView, referenceView.window != nil,
              UIResponder.desktopCurrentFirstResponder == nil else { return }
        referenceView.becomeFirstResponder()
    }

    /// Context menus, the keyboard and other UIKit chrome follow the desktop's appearance.
    func setInterfaceStyle(_ style: UIUserInterfaceStyle) {
        referenceView?.window?.overrideUserInterfaceStyle = style
        pendingInterfaceStyle = style
    }

    func location(of recognizer: UIGestureRecognizer) -> CGPoint {
        recognizer.location(in: referenceView)
    }

    /// The desktop-coordinate rectangle in screen (UIWindow) coordinates.
    func windowRect(forDesktopRect rect: CGRect) -> CGRect? {
        guard let referenceView, let window = referenceView.window else { return nil }
        return referenceView.convert(rect, to: window)
    }

    // MARK: Snapshots

    /// Remembers what the window looks like right now. Only valid while it is on top and
    /// no overlay covers it, which is when the window manager calls this.
    func captureSnapshot(of window: DesktopWindow) {
        guard let controller, !controller.isOverlayPresented, controller.windowManager.isVisible(window),
              controller.windowManager.visibleStack().first?.id == window.id,
              let uiWindow = referenceView?.window,
              let rect = windowRect(forDesktopRect: controller.windowManager.displayFrame(for: window)),
              rect.width >= 1, rect.height >= 1 else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = Self.snapshotScale
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: rect, format: format).image { _ in
            uiWindow.drawHierarchy(in: uiWindow.bounds, afterScreenUpdates: false)
        }
        window.snapshot = image
    }

    // MARK: Keyboard avoidance

    private func keyboardFrameChanged(_ screenFrame: CGRect) {
        keyboardFrame = screenFrame
        guard let referenceView, let window = referenceView.window else { return }
        let local = screenFrame.isNull ? nil : referenceView.convert(screenFrame, from: window.screen.coordinateSpace)
        controller?.windowManager.updateKeyboard(local, hardwareKeyboard: HardwareKeyboardMonitor.isAttached)
    }

    private func keyboardHidden() {
        keyboardFrame = .null
        controller?.windowManager.resetKeyboard()
    }

    // MARK: Gestures

    /// Click-to-focus, on touch-down like desktop window managers, for every kind of window
    /// content: SwiftUI views, the terminal's web view and Linux surfaces alike.
    @objc private func touchDown(_ recognizer: TouchDownRecognizer) {
        DispatchQueue.main.async { [weak self] in self?.ensureKeyCommandsReachable() }
        guard let controller, !controller.isOverlayPresented, let referenceView else { return }
        let point = recognizer.location(in: referenceView)
        guard referenceView.bounds.contains(point) else { return }
        if let hit = recognizer.hitView, hit.isDescendant(ofType: LinuxPopupLayer.self) { return }
        let manager = controller.windowManager
        let target = manager.visibleStack().first { manager.displayFrame(for: $0).insetBy(dx: -10, dy: -10).contains(point) }
        if let target, target.id != manager.focusedWindowID {
            manager.focus(target.id)
        }
    }

    @objc private func threeFingerPan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended, let controller else { return }
        let translation = recognizer.translation(in: recognizer.view)
        let velocity = recognizer.velocity(in: recognizer.view)
        let horizontal = abs(translation.x) > abs(translation.y)
        let distance = horizontal ? translation.x : translation.y
        guard abs(distance) > Self.swipeDistance || abs(horizontal ? velocity.x : velocity.y) > 600 else { return }
        if horizontal {
            withAnimation(DesktopMotion.standard) {
                controller.windowManager.switchWorkspace(by: distance < 0 ? 1 : -1)
            }
        } else {
            controller.setOverviewPresented(distance < 0)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// Observes the first finger of every touch sequence without ever claiming it.
final class TouchDownRecognizer: UIGestureRecognizer {
    private(set) weak var hitView: UIView?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, let touch = touches.first, (event.allTouches?.count ?? 1) == touches.count else {
            return
        }
        hitView = touch.view
        state = .recognized
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

private extension UIView {
    func isDescendant<T: UIView>(ofType type: T.Type) -> Bool {
        var view: UIView? = self
        while let current = view {
            if current is T { return true }
            view = current.superview
        }
        return false
    }
}

/// Pins the coordinator to the desktop area's origin.
struct DesktopInputAnchor: UIViewRepresentable {
    let coordinator: DesktopInputCoordinator

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.coordinator = coordinator
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {}

    final class AnchorView: UIView {
        weak var coordinator: DesktopInputCoordinator?

        // Interaction stays enabled because UIKit skips key commands for a first responder
        // that does not take events; touches still pass through.
        override var canBecomeFirstResponder: Bool { true }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { coordinator?.attach(to: self) }
        }
    }
}

extension DesktopController {
    /// Typing must go to the focused window. Apps take the keyboard themselves (the terminal
    /// through `desktopWindowIsFocused`, Linux windows through the bridge); this takes it
    /// away from whatever text input still holds it in another window.
    func keyboardFocusChanged(to windowID: UUID?) {
        defer { DispatchQueue.main.async { [weak self] in self?.input.ensureKeyCommandsReachable() } }
        guard let responder = UIResponder.desktopCurrentFirstResponder as? UIView,
              responder !== input.referenceView,
              let owner = input.window(containing: responder), owner.id != windowID else { return }
        responder.resignFirstResponder()
    }
}

extension DesktopInputCoordinator {
    /// The desktop window a hosted UIKit view belongs to: the topmost window whose content
    /// area holds the view's frame.
    func window(containing view: UIView) -> DesktopWindow? {
        guard let controller, let referenceView, view.window === referenceView.window else { return nil }
        let frame = view.convert(view.bounds, to: referenceView)
        let manager = controller.windowManager
        return manager.windows
            .filter { !$0.isMinimized && $0.workspace == manager.currentWorkspace }
            .sorted { manager.stackingOrder(of: $0) > manager.stackingOrder(of: $1) }
            .first { manager.displayFrame(for: $0).insetBy(dx: -1, dy: -1).contains(frame) }
    }
}

extension UIResponder {
    private static weak var foundFirstResponder: UIResponder?

    /// UIKit has no public accessor; an action sent to a nil target goes to the first responder.
    static var desktopCurrentFirstResponder: UIResponder? {
        foundFirstResponder = nil
        UIApplication.shared.sendAction(#selector(desktopCaptureFirstResponder(_:)), to: nil, from: nil, for: nil)
        // With no first responder UIKit delivers the action to the key window instead.
        return foundFirstResponder?.isFirstResponder == true ? foundFirstResponder : nil
    }

    @objc private func desktopCaptureFirstResponder(_ sender: Any?) {
        UIResponder.foundFirstResponder = self
    }
}
