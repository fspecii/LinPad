import SwiftUI

/// Fast mode (the native JIT) as the host can request it: on iPadOS through the
/// user-installed StikDebug app, which the host opens with its `stikdebug://enable-jit`
/// URL. The desktop shows the state, the setting and a retry.
@MainActor
public protocol FastModeControlling: AnyObject {
    var fastMode: FastModeModel { get }
}

@Observable @MainActor
public final class FastModeModel {
    public enum Setting: String, CaseIterable, Identifiable, Sendable {
        /// Ask StikDebug at every launch, before Linux starts.
        case automatic
        case off

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .automatic: "Automatic (StikDebug)"
            case .off: "Off"
            }
        }
    }

    public enum Status: Equatable, Sendable {
        case idle
        case enabling
        /// `newProgramsOnly`: enabled after Linux started; programs already running stay
        /// in Compatibility mode until they are restarted.
        case on(newProgramsOnly: Bool)
        case failed(String)
    }

    /// The same key the host reads before booting (AppDelegate: ISHFastModeSettingKey).
    public static let settingKey = "fastMode.setting"

    public var setting: Setting {
        didSet { UserDefaults.standard.set(setting.rawValue, forKey: Self.settingKey) }
    }

    /// Translated-code cache in MB, 0 = automatic (256 MB when iPadOS reports more than
    /// 3 GB available, else less). Read when the JIT starts, so it applies at the next
    /// launch. Firefox needs about 256 MB; less makes it retranslate all the time.
    public static let codeCacheKey = "fastMode.codeCacheMB"
    public static let codeCacheChoices = [0, 128, 256, 384, 512]
    public var codeCacheMB: Int {
        didSet { UserDefaults.standard.set(codeCacheMB, forKey: Self.codeCacheKey) }
    }
    public private(set) var status: Status = .idle
    /// Why fast mode can't be requested here, or nil.
    public private(set) var unavailableReason: String?
    @ObservationIgnored private let retryAction: @MainActor () -> Void

    public init(retry: @escaping @MainActor () -> Void) {
        setting = Setting(rawValue: UserDefaults.standard.string(forKey: Self.settingKey) ?? "") ?? .automatic
        codeCacheMB = UserDefaults.standard.integer(forKey: Self.codeCacheKey)
        retryAction = retry
    }

    public func update(status: Status, unavailableReason: String?) {
        self.status = status
        self.unavailableReason = unavailableReason
    }

    public func retry() {
        retryAction()
    }

    public var canRetry: Bool {
        guard unavailableReason == nil else { return false }
        switch status {
        case .idle, .failed: return true
        case .enabling, .on: return false
        }
    }

    public var statusText: String {
        switch status {
        case .idle: unavailableReason ?? "Not enabled"
        case .enabling: "Enabling via StikDebug…"
        case .on(let newOnly): newOnly ? "On for programs started from now on" : "On"
        case .failed(let message): message
        }
    }
}

extension DesktopController {
    var fastMode: FastModeModel? {
        (host as? FastModeControlling)?.fastMode
    }

    /// After boot: fast mode was asked for and did not come on. Offer to try again.
    func offerFastModeRetryIfFailed() {
        guard let fastMode, case .failed(let message) = fastMode.status, fastMode.canRetry else { return }
        notify("Fast mode is off: \(message) Linux runs in Compatibility mode.",
               action: DesktopToast.Action(title: "Retry fast mode") { [weak self] in
                   fastMode.retry()
                   self?.watchFastModeRetry()
               }, lifetime: .seconds(30))
    }

    /// Reports how a retry ended.
    func watchFastModeRetry() {
        guard let fastMode else { return }
        Task { [weak self] in
            // StikDebug is in front meanwhile; give up watching after two minutes
            for _ in 0..<480 where fastMode.status == .enabling || fastMode.status == .idle {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self else { return }
            switch fastMode.status {
            case .on(let newOnly):
                notify(newOnly ? "Fast mode is on. Programs started from now on use the native JIT; restart open Linux apps to speed them up."
                               : "Fast mode is on.")
            default:
                offerFastModeRetryIfFailed()
            }
        }
    }
}

extension LinuxSystemPreparation.CPUEngine {
    var title: String {
        switch self {
        case .nativeJIT: "Native JIT ✓"
        case .compatibility: "Compatibility mode"
        }
    }
}

extension DesktopController {
    /// The host's CPU engine, when it reports one (iSH: after the kernel has booted).
    var cpuEngine: LinuxSystemPreparation.CPUEngine? {
        (host as? LinuxSystemPreparing)?.preparation.engine
    }

    /// Fast mode can be explained only when the build has the JIT and it is not running.
    var canExplainFastMode: Bool {
        guard let preparation = (host as? LinuxSystemPreparing)?.preparation else { return false }
        return preparation.jitCompiledIn && preparation.engine == .compatibility
    }
}

/// "Performance: Native JIT ✓ / Compatibility mode" with the way to fast mode.
struct PerformanceModeRow: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        if let engine = controller.cpuEngine {
            HStack(spacing: 10) {
                Image(systemName: engine == .nativeJIT ? "bolt.fill" : "tortoise")
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Performance").font(.system(size: 13))
                    Text(engine.title)
                        .font(.system(size: 12))
                        .foregroundStyle(engine == .nativeJIT ? Color.green : theme.secondaryText)
                        .accessibilityLabel("Performance: \(engine.title)")
                        .accessibilityIdentifier("quickSettings.performanceMode")
                }
                Spacer()
                if controller.canExplainFastMode {
                    Button(controller.fastMode?.status == .enabling ? "Enabling…" : "Enable fast mode") {
                        controller.dismissAllOverlays()
                        if let fastMode = controller.fastMode, fastMode.canRetry {
                            fastMode.retry()
                            controller.watchFastModeRetry()
                        } else {
                            controller.isFastModeHelpPresented = true
                        }
                    }
                    .disabled(controller.fastMode?.status == .enabling)
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.accent)
                    .accessibilityIdentifier("quickSettings.fastModeHelp")
                }
            }
        }
    }
}

/// How to get the native JIT on an iPad: iOS only grants executable memory to an app a
/// debugger is attached to, and StikDebug is that debugger on the device itself.
struct FastModeHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FastModeHelpText()
                }
                .font(.system(size: 15))
                .padding(24)
            }
            .navigationTitle("Enable fast mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("desktop.fastModeHelp")
    }
}

/// The setup steps, shared by the help sheet and Settings.
struct FastModeHelpText: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Linux runs in Compatibility mode: every instruction is emulated. Fast mode translates Linux programs to native ARM64 code and makes them several times faster (about 5x on average).")
            Text("iPadOS only lets an app create native code while a debugger is attached to it. StikDebug, a separate app, provides that debugger on the iPad itself. Linux for iPad only asks it to attach; it does not include a debugger.")
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Once: install StikDebug and LocalDevVPN, and give StikDebug a pairing file for this iPad (for example made with iloader on a computer). Follow StikDebug's instructions.")
                step(2, "Connect LocalDevVPN.")
                step(3, "With Settings › Fast mode on Automatic, Linux for iPad opens StikDebug when it starts, StikDebug attaches and returns to the app, and Linux starts with the native JIT. Quick Settings then shows “Performance: Native JIT ✓”.")
                step(4, "If that fails, Linux starts in Compatibility mode and offers “Retry fast mode”. A retry after Linux has started speeds up programs started afterwards.")
            }
            Text("You can also open StikDebug yourself and select “Linux for iPad” in its app list. Your files and Linux system are the same in both modes.")
                .foregroundStyle(.secondary)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.system(size: 15, weight: .bold)).frame(width: 18)
            Text(text)
        }
    }
}
