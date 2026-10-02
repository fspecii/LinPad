import SwiftUI

/// The lock screen: wallpaper, a large clock, and any tap or key press unlocks. There is no
/// password; it hides the desktop, it does not secure it.
struct LockScreen: View {
    let controller: DesktopController
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            WallpaperView(store: controller.wallpapers, source: controller.wallpaperSource(), variant: .blurred,
                          accessibilityID: "desktop.lockScreen.wallpaper")
            Color.black.opacity(0.35)
            TimelineView(.everyMinute) { context in
                VStack(spacing: 8) {
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 96, weight: .thin).monospacedDigit())
                    Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: 22, weight: .regular))
                    Spacer().frame(height: 60)
                    Label("Tap or press any key to unlock", systemImage: "lock.open")
                        .font(.system(size: 15, weight: .medium))
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { controller.unlockScreen() }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress { _ in
            controller.unlockScreen()
            return .handled
        }
        .onAppear { isFocused = true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Locked. Activate to unlock.")
        .accessibilityIdentifier("desktop.lockScreen")
    }
}

/// Shown from launch until Linux answers, so the user sees the system starting instead of
/// an empty desktop.
struct BootSplash: View {
    let controller: DesktopController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 22) {
                Text(BootSplash.logo)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                Text("Linux for iPad")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                ProgressView(value: controller.boot.progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: 260)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: controller.boot.progress)
                Text(controller.boot.step)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                if let engine = controller.cpuEngine {
                    Text("Performance: \(engine.title)")
                        .font(.system(size: 12))
                        .foregroundStyle(engine == .nativeJIT ? Color.green.opacity(0.8) : .white.opacity(0.45))
                        .accessibilityIdentifier("desktop.bootSplash.engine")
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Starting Linux. \(controller.boot.step)")
        .accessibilityIdentifier("desktop.bootSplash")
    }

    /// The same mark the guest prints (/usr/share/ish/logo.txt).
    static let logo = """
            .--.
           |o_o |
           |:_/ |
          //   \\ \\
         (|     | )
        /'\\_   _/`\\
        \\___)=(___/
        """
}

/// Boot progress, as far as the desktop can see it: the guest answering a shell command,
/// then (with Linux GUI apps) the Wayland session coming up.
@Observable @MainActor
final class BootProgress {
    private(set) var progress = 0.1
    private(set) var step = "Starting Linux…"
    private(set) var isFinished = false

    private static let sessionTimeout: Duration = .seconds(15)

    func run(host: any LinuxHost, linux: LinuxGUIBridge?) async {
        if let preparing = host as? LinuxSystemPreparing,
           let failure = await waitForPreparation(preparing.preparation) {
            step = "Linux could not be installed: \(failure)"
            try? await Task.sleep(for: .seconds(4))
            finish()
            return
        }
        step = "Configuring…"
        // `hostname` is answered by every host, including the in-memory one used for previews.
        let result = await host.run("hostname")
        progress = max(progress, 0.8)
        guard result.succeeded else {
            step = "Linux did not start: \(result.stderr)"
            try? await Task.sleep(for: .seconds(2))
            finish()
            return
        }
        if let linux {
            step = "Starting desktop…"
            let deadline = ContinuousClock.now + Self.sessionTimeout
            while linux.state != .running, ContinuousClock.now < deadline {
                if case .failed = linux.state { break }
                try? await Task.sleep(for: .milliseconds(200))
                progress = min(0.95, progress + 0.02)
            }
        }
        finish()
    }

    /// Mirrors the host's first-launch unpacking into the splash (2–70 %); nil once ready.
    private func waitForPreparation(_ preparation: LinuxSystemPreparation) async -> String? {
        while true {
            switch preparation.phase {
            case .ready:
                return nil
            case .failed(let reason):
                return reason
            case .unpacking:
                progress = 0.02 + 0.68 * preparation.fraction
                step = preparation.detail.isEmpty ? preparation.title : "\(preparation.title)  \(preparation.detail)"
            case .configuring:
                progress = max(progress, 0.72)
                step = preparation.title.isEmpty ? "Configuring…" : preparation.title
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func finish() {
        progress = 1
        step = "Ready"
        isFinished = true
    }
}
