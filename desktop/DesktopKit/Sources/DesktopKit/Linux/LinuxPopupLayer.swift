import SwiftUI
import UIKit

/// A transparent layer over the whole window area that holds Linux popups (menus,
/// combo boxes, tooltips), so they can extend past their window and sit above
/// every other window. Touches anywhere else pass through; a touch outside the
/// open popups also dismisses them, as on other desktops.
final class LinuxPopupLayer: UIView {
    weak var bridge: LinuxGUIBridge?
    private var lastDismissTimestamp: TimeInterval = -1

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit !== self, hit != nil {
            return hit
        }
        // hitTest runs more than once per touch; dismiss once per event.
        if !subviews.isEmpty, let event, event.type == .touches, event.timestamp != lastDismissTimestamp {
            lastDismissTimestamp = event.timestamp
            MainActor.assumeIsolated { bridge?.dismissPopups() }
        }
        return nil
    }
}

struct LinuxPopupLayerHost: UIViewRepresentable {
    let bridge: LinuxGUIBridge

    func makeUIView(context: Context) -> LinuxPopupLayer {
        let layer = LinuxPopupLayer()
        layer.backgroundColor = .clear
        layer.bridge = bridge
        bridge.popupLayer = layer
        return layer
    }

    func updateUIView(_ uiView: LinuxPopupLayer, context: Context) {}
}
