import SwiftUI
import UIKit

/// Shows one Linux surface and turns touch, pointer and keyboard input into
/// Wayland input through the bridge. One point is one Linux logical pixel; the
/// image carries `scale` pixels per point. Popups live in LinuxPopupLayer.
@MainActor
final class LinuxSurfaceView: UIView {
    private enum Button {
        static let left: UInt32 = 0x110
        static let right: UInt32 = 0x111
    }

    private enum TouchState {
        case pending(start: CGPoint)  // may still become a tap, a scroll or a hold
        case held(start: CGPoint)     // held still: release = right click, move = drag
        case scrolling
        case dragging                 // a button is down
        case consumed
    }

    /// UserDefaults key: whether a one-finger drag on Linux content scrolls (default) or
    /// presses and drags (selects), as a mouse would.
    static let touchDragScrollsKey = "desktop.linux.touchDragScrolls"
    private static var touchDragScrolls: Bool {
        UserDefaults.standard.object(forKey: touchDragScrollsKey) as? Bool ?? true
    }

    private static let dragThreshold: CGFloat = 6
    private static let holdDelay: Duration = .milliseconds(450)
    private static let configureDelay: Duration = .milliseconds(60)

    let surfaceID: UInt32
    weak var surface: LinuxSurface?
    weak var bridge: LinuxGUIBridge?
    private let contentLayer = CALayer()

    private var trackedTouch: UITouch?
    private var touchState = TouchState.consumed
    private var pressedButton = Button.left
    private var holdTask: Task<Void, Never>?
    private var lastScrollPoint = CGPoint.zero
    private var configureTask: Task<Void, Never>?
    private var requestedSize: CGSize?

    // Text input state for LinuxTextInput.swift (extensions cannot store properties).
    var markedText: String?
    var markedSelection = NSRange(location: 0, length: 0)
    var markedTextStyle: [NSAttributedString.Key: Any]?
    weak var inputDelegate: UITextInputDelegate?
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)
    /// Hardware presses handed to the text system, so their release goes there too.
    private var textSystemPresses = Set<ObjectIdentifier>()

    private var isToplevel: Bool { surface?.kind == .toplevel }

    init(surface: LinuxSurface, bridge: LinuxGUIBridge) {
        surfaceID = surface.id
        self.surface = surface
        self.bridge = bridge
        super.init(frame: CGRect(origin: .zero, size: surface.size))
        isMultipleTouchEnabled = true
        clipsToBounds = surface.kind == .popup
        contentLayer.anchorPoint = .zero
        contentLayer.contentsGravity = .resize
        contentLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(contentLayer)
        if surface.kind == .popup {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.35
            layer.shadowRadius = 10
            layer.shadowOffset = CGSize(width: 0, height: 4)
        }
        installGestures()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func showFrame() {
        guard let surface, let image = surface.image else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.bounds = CGRect(origin: .zero, size: surface.size)
        contentLayer.contentsScale = surface.scale
        contentLayer.contents = image
        CATransaction.commit()
        if surface.kind == .popup {
            layer.shadowPath = UIBezierPath(rect: CGRect(origin: .zero, size: surface.size)).cgPath
        }
    }

    // MARK: - Size

    override func layoutSubviews() {
        super.layoutSubviews()
        guard isToplevel, let surface else { return }
        let size = CGSize(width: bounds.width.rounded(.down), height: bounds.height.rounded(.down))
        guard size.width >= 1, size.height >= 1, size != surface.size, size != requestedSize else { return }
        requestedSize = size
        // Coalesce a live resize into a configure every few frames; each one makes GTK re-layout.
        configureTask?.cancel()
        configureTask = Task { [weak self] in
            try? await Task.sleep(for: Self.configureDelay)
            guard !Task.isCancelled, let self, let size = self.requestedSize else { return }
            self.bridge?.configure(self.surfaceID, size: size, maximized: false)
        }
    }

    // MARK: - Pointer

    /// Touch: tap = click, drag = scroll (or select, see `touchDragScrolls`), hold and
    /// release = right click, hold then drag = press-and-drag (text selection).
    /// Trackpad and mouse (indirect pointer): buttons, drags and hover as on a desktop.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedTouch == nil, let touch = touches.first, (event?.allTouches?.count ?? 1) == 1 else { return }
        trackedTouch = touch
        focusKeyboard()
        let point = touch.location(in: self)
        if touch.type == .indirectPointer {
            // Secondary clicks belong to `secondaryClick`; UIKit does not reliably deliver
            // them here, and handling both would send BTN_RIGHT twice.
            if event?.buttonMask.contains(.secondary) == true {
                touchState = .consumed
                return
            }
            pressedButton = Button.left
            bridge?.pointerButton(surfaceID, point, button: pressedButton, pressed: true)
            touchState = .dragging
            return
        }
        pressedButton = Button.left
        touchState = .pending(start: point)
        lastScrollPoint = point
        bridge?.pointerMotion(surfaceID, point)
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: Self.holdDelay)
            guard !Task.isCancelled, let self, case .pending(let start) = self.touchState else { return }
            self.touchState = .held(start: start)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        let point = touch.location(in: self)
        switch touchState {
        case .pending(let start):
            guard hypot(point.x - start.x, point.y - start.y) > Self.dragThreshold else { return }
            holdTask?.cancel()
            if Self.touchDragScrolls {
                touchState = .scrolling
                scroll(by: CGPoint(x: point.x - lastScrollPoint.x, y: point.y - lastScrollPoint.y))
                lastScrollPoint = point
            } else {
                startDrag(from: start, to: point)
            }
        case .held(let start):
            guard hypot(point.x - start.x, point.y - start.y) > Self.dragThreshold else { return }
            startDrag(from: start, to: point)
        case .scrolling:
            scroll(by: CGPoint(x: point.x - lastScrollPoint.x, y: point.y - lastScrollPoint.y))
            lastScrollPoint = point
        case .dragging:
            bridge?.pointerMotion(surfaceID, point)
        case .consumed:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouch(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouch(touches)
    }

    private func startDrag(from start: CGPoint, to point: CGPoint) {
        touchState = .dragging
        bridge?.pointerButton(surfaceID, start, button: pressedButton, pressed: true)
        bridge?.pointerMotion(surfaceID, point)
    }

    /// Content follows the finger, so the scroll delta is the opposite of its movement.
    private func scroll(by fingerDelta: CGPoint) {
        guard fingerDelta != .zero else { return }
        bridge?.pointerAxis(surfaceID, dx: -fingerDelta.x, dy: -fingerDelta.y, source: .finger)
    }

    private func finishTouch(_ touches: Set<UITouch>) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        trackedTouch = nil
        holdTask?.cancel()
        let point = touch.location(in: self)
        switch touchState {
        case .pending(let start):
            bridge?.pointerButton(surfaceID, start, button: Button.left, pressed: true)
            bridge?.pointerButton(surfaceID, start, button: Button.left, pressed: false)
        case .held(let start):
            bridge?.pointerButton(surfaceID, start, button: Button.right, pressed: true)
            bridge?.pointerButton(surfaceID, start, button: Button.right, pressed: false)
        case .dragging:
            bridge?.pointerButton(surfaceID, point, button: pressedButton, pressed: false)
        case .scrolling:
            bridge?.pointerAxisStop(surfaceID)
        case .consumed:
            break
        }
        touchState = .consumed
    }

    private func installGestures() {
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))

        // Trackpad two-finger click or mouse right button: BTN_RIGHT at once, no hold.
        let secondary = UITapGestureRecognizer(target: self, action: #selector(secondaryClick(_:)))
        secondary.buttonMaskRequired = .secondary
        secondary.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        secondary.cancelsTouchesInView = false
        addGestureRecognizer(secondary)

        // Trackpad two-finger scrolling: smooth pixel deltas, finished with axis_stop.
        let trackpad = UIPanGestureRecognizer(target: self, action: #selector(trackpadScroll(_:)))
        trackpad.allowedScrollTypesMask = .continuous
        trackpad.allowedTouchTypes = []
        addGestureRecognizer(trackpad)

        // Mouse wheel: notches.
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheelScroll(_:)))
        wheel.allowedScrollTypesMask = .discrete
        wheel.allowedTouchTypes = []
        addGestureRecognizer(wheel)

        let twoFinger = UIPanGestureRecognizer(target: self, action: #selector(trackpadScroll(_:)))
        twoFinger.minimumNumberOfTouches = 2
        twoFinger.maximumNumberOfTouches = 2
        twoFinger.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFinger.cancelsTouchesInView = false
        addGestureRecognizer(twoFinger)
    }

    @objc private func secondaryClick(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: self)
        focusKeyboard()
        bridge?.pointerMotion(surfaceID, point)
        bridge?.pointerButton(surfaceID, point, button: Button.right, pressed: true)
        bridge?.pointerButton(surfaceID, point, button: Button.right, pressed: false)
    }

    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            bridge?.pointerMotion(surfaceID, recognizer.location(in: self))
        case .ended, .cancelled:
            bridge?.pointerLeave()
        default:
            break
        }
    }

    @objc private func trackpadScroll(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            let delta = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            bridge?.pointerMotion(surfaceID, recognizer.location(in: self))
            scroll(by: delta)
        case .ended, .cancelled:
            bridge?.pointerAxisStop(surfaceID)
        default:
            break
        }
    }

    @objc private func wheelScroll(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        let delta = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        guard delta != .zero else { return }
        bridge?.pointerMotion(surfaceID, recognizer.location(in: self))
        bridge?.pointerAxis(surfaceID, dx: -delta.x, dy: -delta.y, source: .wheel)
    }

    // MARK: - Keyboard

    /// The toplevel's view takes the keyboard; a popup leaves it where it is, since
    /// ishwl routes keys to the open menu anyway.
    func focusKeyboard() {
        if isToplevel && !isFirstResponder {
            becomeFirstResponder()
        }
    }

    override var canBecomeFirstResponder: Bool { isToplevel }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let toText = presses.filter(routesToTextSystem)
        textSystemPresses.formUnion(toText.map(ObjectIdentifier.init))
        let unhandled = forward(presses.subtracting(toText), pressed: true).union(toText)
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = finish(presses)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = finish(presses)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func finish(_ presses: Set<UIPress>) -> Set<UIPress> {
        let toText = presses.filter { textSystemPresses.remove(ObjectIdentifier($0)) != nil }
        return forward(presses.subtracting(toText), pressed: false).union(toText)
    }

    private func forward(_ presses: Set<UIPress>, pressed: Bool) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let code = LinuxKeyCodes.evdev(for: key.keyCode) else {
                unhandled.insert(press)
                continue
            }
            bridge?.key(code, pressed: pressed, focusedSurface: surfaceID)
        }
        return unhandled
    }

    // Linux apps do their own correction; the iPad's would fight the app's text.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
}

/// A desktop window's content for a Linux toplevel.
struct LinuxWindowContent: UIViewRepresentable {
    let view: LinuxSurfaceView

    func makeUIView(context: Context) -> LinuxSurfaceView {
        view
    }

    func updateUIView(_ uiView: LinuxSurfaceView, context: Context) {}
}
