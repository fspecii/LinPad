import AVFoundation
import SwiftUI
import UIKit

/// The on-screen display for volume, brightness and keyboard layout changes: a themed pill
/// at the bottom centre that fades after a moment.
struct OSDState: Equatable, Identifiable {
    enum Kind: Equatable {
        case volume, brightness, layout
    }

    let id = UUID()
    let kind: Kind
    /// 0…1 for volume and brightness.
    var level: Double?
    var label: String

    var symbol: String {
        switch kind {
        case .volume:
            guard let level else { return "speaker.wave.2.fill" }
            return level == 0 ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .brightness: return (level ?? 1) < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .layout: return "keyboard"
        }
    }

    static func volume(_ level: Double) -> OSDState {
        OSDState(kind: .volume, level: level, label: level == 0 ? "Muted" : "Volume \(Int((level * 100).rounded())) %")
    }

    static func brightness(_ level: Double) -> OSDState {
        OSDState(kind: .brightness, level: level, label: "Brightness \(Int((level * 100).rounded())) %")
    }

    /// "en-US" → "English (United States)".
    static func layout(_ language: String) -> OSDState {
        let name = Locale.current.localizedString(forIdentifier: language) ?? language
        return OSDState(kind: .layout, level: nil, label: name)
    }
}

/// Watches the system volume (hardware buttons, keyboard volume keys), the screen
/// brightness and the keyboard's input language, and shows the OSD for each change.
@MainActor
final class OSDObserver: NSObject {
    private weak var controller: DesktopController?
    private var observers: [NSObjectProtocol] = []
    private var volumeObservation: NSKeyValueObservation?
    private var lastLanguage: String?

    init(controller: DesktopController) {
        self.controller = controller
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIScreen.brightnessDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller?.showOSD(.brightness(Double(UIScreen.main.brightness))) }
        })
        observers.append(center.addObserver(forName: UITextInputMode.currentInputModeDidChangeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let language = (note.object as? UITextInputMode)?.primaryLanguage
            MainActor.assumeIsolated { self?.inputLanguageChanged(language) }
        })
        observers.append(center.addObserver(forName: .linuxKeyboardLayoutDidChange, object: nil, queue: .main) { [weak self] note in
            let title = note.object as? String
            MainActor.assumeIsolated { self?.linuxLayoutChanged(title) }
        })
        // Reported while the app's audio session is active (the Linux audio bridge keeps one).
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let volume = change.newValue else { return }
            Task { @MainActor in self?.controller?.showOSD(.volume(Double(volume))) }
        }
    }

    private func inputLanguageChanged(_ language: String?) {
        guard let language, language != "dictation", language != lastLanguage else { return }
        let isFirst = lastLanguage == nil
        lastLanguage = language
        if !isFirst { controller?.showOSD(.layout(language)) }
    }

    /// The Linux keymap follows the iPad's layout; a change from the Globe key joins the
    /// iPad's own layout OSD shown a moment earlier.
    private func linuxLayoutChanged(_ title: String?) {
        guard let title, let controller else { return }
        if let shown = controller.osd, shown.kind == .layout, !shown.label.contains("Linux") {
            controller.showOSD(OSDState(kind: .layout, level: nil, label: "\(shown.label) · Linux: \(title)"))
        } else {
            controller.showOSD(OSDState(kind: .layout, level: nil, label: "Linux: \(title)"))
        }
    }
}

extension DesktopController {
    func showOSD(_ state: OSDState) {
        // Quick Settings shows its own sliders.
        guard !isQuickSettingsPresented, !isLocked else { return }
        withAnimation(.easeOut(duration: 0.15)) { osd = state }
        let id = state.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard self?.osd?.id == id else { return }
            withAnimation(.easeIn(duration: 0.25)) { self?.osd = nil }
        }
    }
}

struct OSDView: View {
    let state: OSDState
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 26)
                .contentTransition(.symbolEffect(.replace))
            if let level = state.level {
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.primaryText.opacity(0.15))
                    Capsule().fill(theme.accent).frame(width: 180 * min(max(level, 0), 1))
                }
                .frame(width: 180, height: 6)
                .animation(.easeOut(duration: 0.15), value: level)
            } else {
                Text(state.label).font(.system(size: 15, weight: .medium)).lineLimit(1)
            }
        }
        .foregroundStyle(theme.primaryText)
        .padding(.horizontal, 20)
        .frame(height: 48)
        .background(Capsule().fill(theme.panelBlur ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.clear)))
        .background(Capsule().fill(theme.windowBackground.opacity(0.85)))
        .overlay(Capsule().strokeBorder(theme.borderActive ?? theme.separator, lineWidth: theme.borderActive == nil ? 1 : 2))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.label)
        .accessibilityIdentifier("desktop.osd")
    }
}
