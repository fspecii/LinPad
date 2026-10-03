import GameController
import SwiftUI
import UIKit

/// Reports the keyboard's end frame (with its accessory row and iPadOS's shortcuts bar)
/// as an accessibility value, "none" when nothing is on screen. That chrome lives in the
/// keyboard's own process, out of reach of UI tests otherwise.
struct KeyboardFrameProbe: View {
    @State private var frame = "none"
    @State private var gcKeyboard = "none"

    var body: some View {
        Color.clear
            .frame(width: 2, height: 2)
            .accessibilityElement()
            .accessibilityLabel("Keyboard frame")
            .accessibilityValue(frame)
            .accessibilityIdentifier("harness.keyboardFrame")
            .overlay {
                Color.clear.frame(width: 2, height: 2)
                    .accessibilityElement()
                    .accessibilityLabel("Game controller keyboard")
                    .accessibilityValue(gcKeyboard)
                    .accessibilityIdentifier("harness.gcKeyboard")
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in gcKeyboard = "connected" }
            .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in gcKeyboard = "none" }
            .onAppear { gcKeyboard = GCKeyboard.coalesced == nil ? "none" : "connected" }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { update($0) }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in frame = "none" }
    }

    private func update(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let screen = (note.object as? UIScreen) ?? UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.screen }).first else { return }
        let visible = end.intersection(screen.bounds)
        frame = visible.isNull || visible.height < 1
            ? "none"
            : "\(Int(visible.minX)),\(Int(visible.minY)),\(Int(visible.width)),\(Int(visible.height))"
    }
}
