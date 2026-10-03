import Foundation

/// Settings › Background: whether Linux keeps running while LinPad is not in front.
/// iPadOS suspends an app about 30 s after it leaves the screen unless it plays audio,
/// uses location in the background or similar; a suspended app runs nothing, and iPadOS
/// may end it at any time to free memory.
public enum BackgroundExecution: String, CaseIterable, Identifiable, Sendable {
    /// Linux stops when LinPad leaves the screen; sound from Linux stops too.
    case off
    /// Linux keeps running while a Linux app plays (or records) sound, like a music app.
    case whileAudioPlays
    /// Linux always keeps running, through iPadOS's background location updates.
    case always

    public static let storageKey = "lifecycle.background"
    public static let defaultValue = BackgroundExecution.whileAudioPlays

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .whileAudioPlays: "While audio plays"
        case .always: "Always"
        }
    }

    public var explanation: String {
        switch self {
        case .off:
            "Linux pauses about 30 seconds after LinPad leaves the screen. Sound from Linux stops."
        case .whileAudioPlays:
            "Music and videos keep playing with the screen locked or in another app, and Linux keeps running while they do. When the sound stops, Linux pauses about 30 seconds later."
        case .always:
            "Linux keeps running in the background, for example for long builds, downloads or servers. iPadOS only allows this to apps that use location, so LinPad asks for coarse location and the blue location indicator is shown. LinPad does not read or store where you are. Uses more battery."
        }
    }

    public static var stored: BackgroundExecution {
        stored(in: .standard)
    }

    static func stored(in defaults: UserDefaults) -> BackgroundExecution {
        defaults.string(forKey: storageKey).flatMap(BackgroundExecution.init(rawValue:)) ?? defaultValue
    }
}

/// Location permission as far as the "Always" mode needs it.
public enum BackgroundLocationAccess: Equatable, Sendable {
    case notDetermined
    case allowed
    case denied
    /// This build or device cannot use location (simulator without it, restricted).
    case unavailable
}

/// What the host app provides for the app lifecycle: making the guest's files durable
/// and keeping the process alive in the background.
@MainActor
public protocol LinuxLifecycleHosting: AnyObject {
    /// Host file data and the Linux file system's metadata database written through to
    /// flash. Runs off the main thread; returns when done.
    func flushFilesystem() async
    /// The setting changed, or LinPad entered or left the background.
    func applyBackgroundExecution(_ mode: BackgroundExecution, inBackground: Bool)
    var backgroundLocationAccess: BackgroundLocationAccess { get }
    /// Shows iPadOS's location prompt. Only ever called from the user's choice in Settings.
    func requestBackgroundLocationAccess() async -> BackgroundLocationAccess
    /// LinPad is in front again after being in the background: restart what iPadOS may
    /// have stopped meanwhile (the audio session), and undo `releaseFileLocksIfSuspending`.
    func resumeAfterBackground()
    /// The last step before the grace period ends: when nothing will keep LinPad running
    /// (no audio playing, no location keep-alive), give up every lock on files in the
    /// shared container, since iPadOS ends a suspended app that holds one (0xDEAD10CC).
    /// Returns whether it did.
    func releaseFileLocksIfSuspending() -> Bool
}

/// UserDefaults keys for the rest of the lifecycle behaviour.
enum LifecycleSettings {
    /// Text Editor: save documents that have a file shortly after each change (default on).
    static let editorAutosaveKey = "lifecycle.editorAutosave"
    /// Offer the "restored after iPadOS closed LinPad" toast (default on).
    static let restoreNoticeKey = "lifecycle.restoreNotice"

    static func editorAutosaves(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: editorAutosaveKey) as? Bool ?? true
    }
}

/// The guest side of leaving and re-entering the foreground: `linpad-lifecycle`
/// (release/guest/linpad-lifecycle) runs the hooks in /etc/linpad/lifecycle.d and the
/// signals configured in /etc/linpad/lifecycle.conf. Images without it just sync.
enum GuestLifecycleCommand {
    static let suspendTimeout: TimeInterval = 6
    static let resumeTimeout: TimeInterval = 10

    static let suspend = """
        if command -v linpad-lifecycle >/dev/null 2>&1; then linpad-lifecycle suspend; else sync; fi
        """
    static let resume = """
        command -v linpad-lifecycle >/dev/null 2>&1 && linpad-lifecycle resume
        true
        """
}

/// Which saved Linux windows session restore launches. Apps that restore their own
/// windows (Firefox, VS Code, LibreOffice) are started once, however many windows they
/// had: starting them once per window would open those windows twice.
enum LinuxSessionRelaunch {
    static let selfRestoringApps: [String] = [
        "firefox", "firefox-esr", "code", "code-oss", "codium", "libreoffice", "thunderbird", "falkon",
    ]

    static func restoresOwnWindows(_ appID: String) -> Bool {
        let name = appID.hasPrefix(LinuxAppID.prefix) ? String(appID.dropFirst(LinuxAppID.prefix.count)) : appID
        let base = name.lowercased()
        return selfRestoringApps.contains { base == $0 || base.hasPrefix($0 + "-") || base.hasPrefix($0 + ".") }
            || base.hasPrefix("org.mozilla.firefox") || base.hasPrefix("libreoffice")
    }

    /// The windows to launch, in stacking order: every window of other apps, the first
    /// window of a self-restoring app.
    static func launches(for windows: [DesktopSessionSnapshot.Window]) -> [DesktopSessionSnapshot.Window] {
        var started = Set<String>()
        return windows.filter { window in
            guard restoresOwnWindows(window.appID) else { return true }
            return started.insert(window.appID).inserted
        }
    }
}

/// How the previous run ended, as far as session restore cares.
enum PreviousExit: Equatable {
    /// First launch, or the user quit (Quit, Reset to Factory).
    case clean
    /// LinPad was in the background and never came back: iPadOS ended it (memory,
    /// an update) or the user swiped it away in the app switcher.
    case endedInBackground
    /// LinPad was in front: a crash or a watchdog kill.
    case crashedInForeground

    init(marker: DiagnosticsSessionMarker?) {
        guard let marker, marker.exitedCleanly != true else {
            self = .clean
            return
        }
        self = marker.inForeground ? .crashedInForeground : .endedInBackground
    }
}

/// Runs the steps of a background flush in order, each bounded, and reports how long
/// they took (Settings › Maintenance diagnostics, tests).
struct LifecycleFlushReport: Equatable {
    var savedSession = false
    var appsSaved = 0
    var guestHookFinished = false
    var filesystemFlushed = false
    /// The file system's locks were given up because LinPad was about to be suspended.
    var locksReleased = false
    var seconds: TimeInterval = 0
}

/// Runs `operation`; gives up after `timeout` and returns nil. The operation keeps
/// running (a guest command cannot be cancelled), it is just no longer waited for. A
/// task group would not do: it waits for all of its children before returning, so a
/// guest command that never finishes would hold it forever.
@MainActor
func withLifecycleTimeout<T: Sendable>(_ timeout: TimeInterval,
                                       _ operation: @escaping @MainActor () async -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let gate = ResumeOnce()
        Task { @MainActor in
            let value = await operation()
            if gate.claim() { continuation.resume(returning: value) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            if gate.claim() { continuation.resume(returning: nil) }
        }
    }
}

@MainActor
private final class ResumeOnce {
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

public extension Notification.Name {
    /// Posted by the host when the audio output Linux was playing to went away
    /// (headphones unplugged); Linux media players are paused, as iPadOS media apps do.
    static let linuxAudioOutputLost = Notification.Name("LinPadAudioOutputLost")
}

enum LinuxMediaPause {
    static var command: String {
        MPRISCommand.sessionBus + "\nplayerctl -a pause 2>/dev/null\ntrue"
    }
}
