import Observation
import SwiftUI
import UIKit

/// When Linux windows get the on-screen keyboard. A Linux window takes first responder on
/// every touch (it has to, for hardware keys), and iPadOS answers that with the full
/// keyboard over half the screen; on demand, the keyboard comes up only from the panel's
/// keyboard button and stays down once dismissed.
enum LinuxKeyboardMode: String, CaseIterable, Identifiable {
    case onDemand
    case automatic

    static let storageKey = "desktop.keyboard.linuxOnScreen"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDemand: "From the Panel Button"
        case .automatic: "When a Window Takes Focus"
        }
    }

    static var current: LinuxKeyboardMode {
        UserDefaults.standard.string(forKey: storageKey).flatMap(LinuxKeyboardMode.init) ?? .onDemand
    }
}

@Observable @MainActor
final class OnScreenKeyboard {
    static let shared = OnScreenKeyboard()

    /// The user asked for the keyboard (panel button) and has not dismissed it since.
    private(set) var isRequested = false
    /// The on-screen keyboard is currently up.
    private(set) var isVisible = false

    /// Stands in for the system keyboard; with zero height nothing shows, and hardware keys
    /// still arrive as presses.
    @ObservationIgnored private lazy var placeholder: UIView = {
        let view = UIView(frame: .zero)
        view.autoresizingMask = []
        return view
    }()

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { [weak self] note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            MainActor.assumeIsolated { self?.isVisible = frame.height > 100 }
        }
        center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isVisible = false
                // Dismissed with the keyboard's own key: stay down until asked for again.
                self.isRequested = false
            }
        }
    }

    /// The input view a Linux surface reports: nil for the system keyboard, or an empty view
    /// that keeps it down. With a hardware keyboard iPadOS shows no software keyboard anyway,
    /// only the assistant bar, which carries the IME candidates, emoji and dictation, so
    /// that case is left to the system.
    func inputView(for responder: UIResponder) -> UIView? {
        if HardwareKeyboardMonitor.isAttached || LinuxKeyboardMode.current == .automatic || isRequested { return nil }
        // The app has a text field focused (text-input-v3 enable): type into it.
        if (responder as? LinuxSurfaceView)?.surface?.textInput != nil { return nil }
        return placeholder
    }

    /// Panel button: brings the keyboard up for the focused Linux window, or puts it away.
    func toggle(for controller: DesktopController) {
        guard let surface = Self.focusedSurface(in: controller) else { return }
        if isVisible {
            isRequested = false
            surface.reloadInputViews()
            surface.resignFirstResponder()
            controller.input.ensureKeyCommandsReachable()
            return
        }
        isRequested = true
        if surface.isFirstResponder {
            surface.reloadInputViews()
        } else {
            surface.becomeFirstResponder()
        }
    }

    /// The focused window's Linux surface, found in the view hierarchy.
    static func focusedSurface(in controller: DesktopController) -> LinuxSurfaceView? {
        guard let id = controller.windowManager.focusedWindowID,
              let root = controller.input.referenceView?.window else { return nil }
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            if let surface = view as? LinuxSurfaceView, surface.canBecomeFirstResponder,
               controller.input.window(containing: surface)?.id == id {
                return surface
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }
}

extension LinuxSurfaceView {
    override var inputView: UIView? {
        MainActor.assumeIsolated { OnScreenKeyboard.shared.inputView(for: self) }
    }
}

extension DesktopController {
    /// Linux apps and the terminal own their ⌘ chords (they reach the app as Ctrl).
    var focusedWindowOwnsCommandKeys: Bool {
        guard let window = windowManager.focusedWindow else { return false }
        return window.appID.hasPrefix(LinuxAppID.prefix) || window.appID == AppID.terminal
    }

    /// Sends ⌘<key> to the focused Linux window as the bridge would have (left ⌘ is Ctrl).
    func forwardCommandChord(_ usage: UIKeyboardHIDUsage) {
        guard let surface = OnScreenKeyboard.focusedSurface(in: self), let bridge = surface.bridge,
              let code = LinuxKeyCodes.evdev(for: usage) else { return }
        let control = LinuxKeyCodes.leftControl
        for (key, pressed) in [(control, true), (code, true), (code, false), (control, false)] {
            bridge.key(key, pressed: pressed, focusedSurface: surface.surfaceID)
        }
    }

    /// The panel shows a keyboard button while a Linux window has focus and only the
    /// on-screen keyboard can type into it.
    var showsKeyboardButton: Bool {
        guard !keyboard.isConnected, let window = windowManager.focusedWindow else { return false }
        return window.appID.hasPrefix(LinuxAppID.prefix)
    }
}
