import SwiftUI
import UIKit

// The contract between the desktop shell, its apps, and the Linux runtime.
// Core/ implements the shell, Apps/ implements the built-in apps, and the
// iSH app target implements LinuxHost. Changes here affect all three.

// MARK: - Linux runtime

public struct CommandResult: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String, stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public var succeeded: Bool { exitCode == 0 }
}

public struct FileEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: Int64
    public var modified: Date?
    public var permissions: String

    public init(path: String, name: String, isDirectory: Bool, isSymlink: Bool = false,
                size: Int64 = 0, modified: Date? = nil, permissions: String = "") {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }
}

public enum LinuxHostError: Error, LocalizedError {
    case commandFailed(CommandResult)
    case invalidPath(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let r): return r.stderr.isEmpty ? "Command failed (\(r.exitCode))" : r.stderr
        case .invalidPath(let p): return "Invalid path: \(p)"
        }
    }
}

/// Everything the desktop needs from Linux. Paths are guest paths ("/root/app").
/// `listDirectory`, `readFile` and `writeFile` have default implementations
/// built on `run` (Core/HostDefaults.swift); hosts may override them for speed.
@MainActor
public protocol LinuxHost: AnyObject {
    var hostName: String { get }
    var homeDirectory: String { get }

    /// Run a shell command (`/bin/sh -c`) to completion.
    func run(_ command: String, cwd: String?, stdin: Data?) async -> CommandResult

    /// Run a shell command, delivering combined stdout/stderr chunks as they arrive.
    /// Returns the exit code.
    func stream(_ command: String, cwd: String?, onOutput: @escaping @MainActor (String) -> Void) async -> Int32

    func listDirectory(_ path: String) async throws -> [FileEntry]
    func readFile(_ path: String) async throws -> Data
    func writeFile(_ path: String, data: Data) async throws

    /// A live, interactive terminal session. `command` nil means a login shell.
    func makeTerminalViewController(command: String?, cwd: String?) -> UIViewController
}

public extension LinuxHost {
    func run(_ command: String) async -> CommandResult {
        await run(command, cwd: nil, stdin: nil)
    }
}

/// Optional: a host whose guest filesystem the app can also reach directly.
/// Hosts that adopt it get Linux GUI apps: each Wayland toplevel opens as a
/// desktop window (Linux/LinuxGUIBridge.swift). The bridge shares frame buffers
/// and FIFOs with the in-guest compositor through this directory.
@MainActor
public protocol LinuxGraphicsHost: LinuxHost {
    /// Where the guest's "/" lives on the host filesystem, or nil when unavailable.
    var guestRootURL: URL? { get }
    /// Whether a guest program holds a flock() lock on the file at this guest path (a
    /// program's "I am running" lock). nil: the host maps guest locks to host locks, so
    /// probing the host file with flock answers it.
    func guestHoldsFileLock(_ guestPath: String) -> Bool?
}

public extension LinuxGraphicsHost {
    func guestHoldsFileLock(_ guestPath: String) -> Bool? { nil }
}

/// Hosts that have to prepare the Linux system before it can boot, such as unpacking
/// the bundled root filesystem on first launch. The boot splash shows `preparation`
/// until it is `.ready`, and offers `availableSystemUpdate` once the desktop is up.
@MainActor
public protocol LinuxSystemPreparing: AnyObject {
    var preparation: LinuxSystemPreparation { get }
    /// A newer bundled Linux system than the installed one (its version), or nil.
    var availableSystemUpdate: String? { get }
    /// Installs `availableSystemUpdate` the next time the app starts: system directories
    /// are replaced, /root, /home and the user's account files are kept.
    func scheduleSystemUpdate()
}

/// Progress of the host's preparation, observed by the boot splash.
@Observable @MainActor
public final class LinuxSystemPreparation {
    public enum Phase: Equatable, Sendable {
        /// Unpacking a root filesystem; `fraction` and `detail` say how far.
        case unpacking
        /// Booting the kernel on the unpacked system.
        case configuring
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase
    /// 0...1 within `.unpacking`.
    public private(set) var fraction: Double = 0
    /// What is being done, e.g. "Unpacking Linux…" or "Updating Linux…".
    public private(set) var title = "Unpacking Linux…"
    /// Amounts, e.g. "312 of 690 MB · 41,230 files".
    public private(set) var detail = ""

    /// The CPU emulation engine the kernel runs on, known once it has booted.
    public enum CPUEngine: Equatable, Sendable {
        /// Guest code translated to native ARM64 (jit/); needs a debugger-granted JIT on iOS.
        case nativeJIT
        /// The portable threaded-code engine (asbestos); several times slower.
        case compatibility
    }

    public private(set) var engine: CPUEngine?
    /// Whether this build contains the native JIT, so enabling it is worth explaining.
    public private(set) var jitCompiledIn = false

    public init(phase: Phase = .ready) {
        self.phase = phase
    }

    public func setEngine(_ engine: CPUEngine, jitCompiledIn: Bool) {
        self.engine = engine
        self.jitCompiledIn = jitCompiledIn
        UserDefaults.standard.set(engine == .nativeJIT ? "native" : "compatibility", forKey: LinuxDeviceInfo.cpuEngineKey)
    }

    public func update(phase: Phase, fraction: Double? = nil, title: String? = nil, detail: String? = nil) {
        self.phase = phase
        if let fraction { self.fraction = min(max(fraction, 0), 1) }
        if let title { self.title = title }
        if let detail { self.detail = detail }
    }
}

/// Host-side system controls the desktop's quick settings drive. All optional: the
/// desktop hides a control whose host value is nil.
@MainActor
public protocol DesktopSystemControls: AnyObject {
    /// 0...1 output volume of the Linux audio bridge.
    var volume: Float? { get set }
    var isMuted: Bool { get set }
    /// Whether the host can reboot the Linux guest.
    var canRebootLinux: Bool { get }
    func rebootLinux() async
}

// MARK: - Apps

public enum AppCategory: String, CaseIterable, Sendable {
    case accessories = "Accessories"
    case development = "Development"
    case internet = "Internet"
    case system = "System"
    case settings = "Settings"
    /// Apps found in the guest's /usr/share/applications.
    case linux = "Linux"
}

/// Well-known launch argument keys.
public enum AppArgument {
    public static let path = "path"        // Files, Text Editor
    public static let url = "url"          // Web Browser
    public static let command = "command"  // Terminal
    public static let cwd = "cwd"          // Terminal
    public static let recovery = "recovery" // Text Editor: its unsaved-changes snapshot
}

/// The window an app instance lives in.
@MainActor
public protocol WindowHandle: AnyObject {
    var id: UUID { get }
    func setTitle(_ title: String)
    func close()
    /// Changes an argument the window was opened with, so session restore reopens it with
    /// the new value (e.g. a document's recovery id). nil removes it.
    func setArgument(_ value: String?, forKey key: String)
}

public extension WindowHandle {
    func setArgument(_ value: String?, forKey key: String) {}
}

/// Actions an app may ask of the desktop.
@MainActor
public protocol DesktopActions: AnyObject {
    func open(appID: String, arguments: [String: String])
    func notify(_ message: String)
}

public struct AppLaunchContext {
    public let host: any LinuxHost
    public let arguments: [String: String]
    public let window: any WindowHandle
    public let desktop: any DesktopActions

    public init(host: any LinuxHost, arguments: [String: String],
                window: any WindowHandle, desktop: any DesktopActions) {
        self.host = host
        self.arguments = arguments
        self.window = window
        self.desktop = desktop
    }
}

public struct DesktopAppDescriptor: Identifiable {
    public let id: String
    public let name: String
    /// SF Symbol name.
    public let symbol: String
    /// A PNG to show instead of `symbol` when present (Linux apps' icons from the
    /// guest's per-style icon cache).
    public let iconURL: URL?
    public let category: AppCategory
    public let defaultSize: CGSize
    public let allowsMultipleWindows: Bool
    public let showsOnDesktop: Bool
    public let makeContent: @MainActor (AppLaunchContext) -> AnyView

    public init(id: String, name: String, symbol: String, category: AppCategory,
                defaultSize: CGSize = CGSize(width: 720, height: 480),
                allowsMultipleWindows: Bool = true, showsOnDesktop: Bool = false, iconURL: URL? = nil,
                makeContent: @escaping @MainActor (AppLaunchContext) -> AnyView) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.iconURL = iconURL
        self.category = category
        self.defaultSize = defaultSize
        self.allowsMultipleWindows = allowsMultipleWindows
        self.showsOnDesktop = showsOnDesktop
        self.makeContent = makeContent
    }
}

/// Built-in app ids.
public enum AppID {
    public static let terminal = "terminal"
    public static let files = "files"
    public static let editor = "editor"
    public static let browser = "browser"
    public static let taskManager = "taskmanager"
    public static let packages = "packages"
    public static let settings = "settings"
}

// MARK: - Theme

public struct DesktopTheme: Equatable {
    public var accent: Color
    public var panelBackground: Color
    public var windowBackground: Color
    public var titleBarActive: Color
    public var titleBarInactive: Color
    public var primaryText: Color
    public var secondaryText: Color
    public var separator: Color
    public var cornerRadius: CGFloat
    public var monospacedFontSize: CGFloat
    /// Text and list selection fill.
    public var selection: Color = Color.accentColor.opacity(0.3)
    /// Badges, close-button hover, errors.
    public var urgent: Color = Color(red: 0.94, green: 0.33, blue: 0.31)
    /// The focus ring around the focused window, and around everything else.
    public var borderActive: Color? = nil
    public var borderInactive: Color = Color(red: 0x59 / 255, green: 0x59 / 255, blue: 0x59 / 255).opacity(0.67)
    /// 0 turns the focus ring off.
    public var borderWidth: CGFloat = 0
    public var hoverFill: Color = Color.primary.opacity(0.08)
    /// Behind the launcher, overview and pickers.
    public var scrim: Color = Color.black.opacity(0.45)
    /// The 16 ANSI colours for terminals; empty keeps each terminal's own.
    public var terminalPalette: [Color] = []
    /// The colour theme these colours came from ("" for the style's own).
    public var colorThemeID: String = ""
    /// With a value, the focus ring runs from `borderActive` to this colour (45°).
    public var borderGradientEnd: Color? = nil
    public var showsFocusRing = true
    public var showsWindowShadows = true
    /// Panels and docks blur what is behind them (the style's material); off is flat colour.
    public var panelBlur = true

    public init(accent: Color, panelBackground: Color, windowBackground: Color,
                titleBarActive: Color, titleBarInactive: Color, primaryText: Color,
                secondaryText: Color, separator: Color, cornerRadius: CGFloat = 10,
                monospacedFontSize: CGFloat = 14) {
        self.accent = accent
        self.panelBackground = panelBackground
        self.windowBackground = windowBackground
        self.titleBarActive = titleBarActive
        self.titleBarInactive = titleBarInactive
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.separator = separator
        self.cornerRadius = cornerRadius
        self.monospacedFontSize = monospacedFontSize
    }

    public static let dark = DesktopTheme(
        accent: Color(red: 0.36, green: 0.62, blue: 1.0),
        panelBackground: Color(white: 0.09).opacity(0.92),
        windowBackground: Color(white: 0.13),
        titleBarActive: Color(white: 0.19),
        titleBarInactive: Color(white: 0.15),
        primaryText: Color(white: 0.94),
        secondaryText: Color(white: 0.62),
        separator: Color(white: 0.26))
}

private struct DesktopThemeKey: EnvironmentKey {
    static let defaultValue = DesktopTheme.dark
}

private struct DesktopWindowIsVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

private struct DesktopWindowIsFocusedKey: EnvironmentKey {
    static let defaultValue = true
}

public extension EnvironmentValues {
    var desktopTheme: DesktopTheme {
        get { self[DesktopThemeKey.self] }
        set { self[DesktopThemeKey.self] = newValue }
    }

    /// False while the app's window is minimized or on another workspace.
    /// Windows stay in the view tree when hidden, so apps should pause polling on this.
    var desktopWindowIsVisible: Bool {
        get { self[DesktopWindowIsVisibleKey.self] }
        set { self[DesktopWindowIsVisibleKey.self] = newValue }
    }

    /// True while the app's window is the focused window and no shell overlay is open.
    /// Apps that host their own first responder (a terminal) should take the keyboard
    /// when this turns true and give it up when it turns false.
    var desktopWindowIsFocused: Bool {
        get { self[DesktopWindowIsFocusedKey.self] }
        set { self[DesktopWindowIsFocusedKey.self] = newValue }
    }
}
