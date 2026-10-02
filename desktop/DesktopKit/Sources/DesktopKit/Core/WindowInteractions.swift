import SwiftUI
import UIKit

// UIKit owns the window chrome's gestures: it reports pointer locations independent of the
// window moving underneath, gives trackpads real pointer shapes, and delivers secondary
// clicks and long presses to the same context menu at the touch point.

/// The draggable part of a title bar: pan to move, double-tap to maximize, long-press or
/// secondary click for the window menu.
struct TitleBarInteraction: UIViewRepresentable {
    let onBegan: (CGPoint) -> Void
    let onChanged: (CGSize, CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    let onCancelled: () -> Void
    let onDoubleTap: () -> Void
    let menu: () -> UIMenu
    let coordinator: DesktopInputCoordinator

    func makeCoordinator() -> Handler { Handler() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let handler = context.coordinator
        let pan = UIPanGestureRecognizer(target: handler, action: #selector(Handler.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = handler.tracker
        view.addGestureRecognizer(pan)
        let doubleTap = UITapGestureRecognizer(target: handler, action: #selector(Handler.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        view.addInteraction(UIContextMenuInteraction(delegate: handler))
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.configuration = self
    }

    @MainActor
    final class Handler: NSObject, UIContextMenuInteractionDelegate {
        var configuration: TitleBarInteraction?
        let tracker = TouchOriginTracker()
        private var menuLocation: CGPoint = .zero

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard let configuration else { return }
            let pointer = configuration.coordinator.location(of: recognizer)
            let translation = tracker.translation(of: recognizer)
            switch recognizer.state {
            case .began:
                configuration.onBegan(CGPoint(x: pointer.x - translation.width, y: pointer.y - translation.height))
                configuration.onChanged(translation, pointer)
            case .changed:
                configuration.onChanged(translation, pointer)
            case .ended:
                configuration.onEnded(pointer)
            case .cancelled, .failed:
                configuration.onCancelled()
            default:
                break
            }
        }

        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended { configuration?.onDoubleTap() }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            menuLocation = location
            guard let menu = configuration?.menu else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu() }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
            PointPreview.make(in: interaction.view, at: menuLocation)
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
            PointPreview.make(in: interaction.view, at: menuLocation)
        }
    }
}

/// Measures a pan from where the finger first landed. UIPanGestureRecognizer starts its own
/// translation only once the finger has moved past its slop, which would leave the window
/// trailing the finger by that distance for the whole drag. Measured in the screen's space,
/// so the window moving under the finger cannot feed back into it.
@MainActor
final class TouchOriginTracker: NSObject, UIGestureRecognizerDelegate {
    private var origin: CGPoint?

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer.state == .possible && gestureRecognizer.numberOfTouches == 0 {
            origin = touch.location(in: nil)
        }
        return true
    }

    func translation(of recognizer: UIPanGestureRecognizer) -> CGSize {
        let current = recognizer.location(in: nil)
        guard let origin else {
            let fallback = recognizer.translation(in: nil)
            return CGSize(width: fallback.x, height: fallback.y)
        }
        return CGSize(width: current.x - origin.x, height: current.y - origin.y)
    }
}

/// A zero-size preview anchored at the touch, so a context menu opens where the finger or
/// pointer is instead of lifting the view it belongs to.
enum PointPreview {
    @MainActor
    static func make(in container: UIView?, at location: CGPoint) -> UITargetedPreview? {
        guard let container else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let anchor = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        anchor.backgroundColor = .clear
        return UITargetedPreview(view: anchor, parameters: parameters,
                                 target: UIPreviewTarget(container: container, center: location))
    }
}

/// One edge or corner of a window's resize frame, with the matching resize pointer.
struct ResizeInteraction: UIViewRepresentable {
    let edge: ResizeEdge
    let onBegan: () -> Void
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Handler { Handler() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let handler = context.coordinator
        let pan = UIPanGestureRecognizer(target: handler, action: #selector(Handler.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = handler.tracker
        view.addGestureRecognizer(pan)
        view.addInteraction(UIPointerInteraction(delegate: handler))
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.configuration = self
    }

    @MainActor
    final class Handler: NSObject, UIPointerInteractionDelegate {
        var configuration: ResizeInteraction?
        let tracker = TouchOriginTracker()

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard let configuration else { return }
            let translation = tracker.translation(of: recognizer)
            switch recognizer.state {
            case .began:
                configuration.onBegan()
                configuration.onChanged(translation)
            case .changed:
                configuration.onChanged(translation)
            case .ended, .cancelled, .failed:
                configuration.onEnded()
            default:
                break
            }
        }

        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
            guard let edge = configuration?.edge else { return nil }
            return UIPointerStyle(shape: .path(ResizePointerShape.path(for: edge)), constrainedAxes: [])
        }
    }
}

/// iPadOS has no system resize cursors, so the pointer becomes a double-headed arrow along
/// the axis the edge moves.
enum ResizePointerShape {
    static func path(for edge: ResizeEdge) -> UIBezierPath {
        let path = horizontalArrow()
        let angle: CGFloat
        switch edge {
        case .left, .right: angle = 0
        case .top, .bottom: angle = .pi / 2
        case .topLeft, .bottomRight: angle = .pi / 4
        case .topRight, .bottomLeft: angle = -.pi / 4
        }
        path.apply(CGAffineTransform(rotationAngle: angle))
        return path
    }

    /// A 22 pt arrow centered on the origin.
    private static func horizontalArrow() -> UIBezierPath {
        let half: CGFloat = 11, head: CGFloat = 5, shaft: CGFloat = 1.5, headHeight: CGFloat = 5
        let path = UIBezierPath()
        path.move(to: CGPoint(x: -half, y: 0))
        path.addLine(to: CGPoint(x: -half + head, y: -headHeight))
        path.addLine(to: CGPoint(x: -half + head, y: -shaft))
        path.addLine(to: CGPoint(x: half - head, y: -shaft))
        path.addLine(to: CGPoint(x: half - head, y: -headHeight))
        path.addLine(to: CGPoint(x: half, y: 0))
        path.addLine(to: CGPoint(x: half - head, y: headHeight))
        path.addLine(to: CGPoint(x: half - head, y: shaft))
        path.addLine(to: CGPoint(x: -half + head, y: shaft))
        path.addLine(to: CGPoint(x: -half + head, y: headHeight))
        path.close()
        return path
    }
}

/// A window's drop shadow as a Core Animation shadow with an explicit path: the GPU draws
/// it without an offscreen pass, so dragging a window costs no more than moving a layer.
struct WindowShadow: UIViewRepresentable {
    let cornerRadius: CGFloat
    let isFocused: Bool
    let isHidden: Bool

    func makeUIView(context: Context) -> ShadowView {
        let view = ShadowView()
        view.isUserInteractionEnabled = false
        view.layer.shadowColor = UIColor.black.cgColor
        return view
    }

    func updateUIView(_ view: ShadowView, context: Context) {
        view.cornerRadius = cornerRadius
        view.layer.shadowOpacity = isHidden ? 0 : (isFocused ? 0.5 : 0.3)
        view.layer.shadowRadius = isFocused ? 22 : 12
        view.layer.shadowOffset = CGSize(width: 0, height: isFocused ? 10 : 5)
        view.setNeedsLayout()
    }

    final class ShadowView: UIView {
        var cornerRadius: CGFloat = 0

        override func layoutSubviews() {
            super.layoutSubviews()
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).cgPath
        }
    }
}
