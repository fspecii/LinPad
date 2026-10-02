import Foundation
import Observation

/// The first-run screens, in order.
enum OnboardingStep: String, CaseIterable, Codable, Identifiable, Sendable {
    case intro
    case tour
    case personalize
    case apps
    case fastMode
    case keyboard
    case finale

    var id: String { rawValue }

    var title: String {
        switch self {
        case .intro: "Welcome"
        case .tour: "What it does"
        case .personalize: "Make it yours"
        case .apps: "Apps"
        case .fastMode: "Fast mode"
        case .keyboard: "Keyboard & touch"
        case .finale: "Ready"
        }
    }
}

/// Everything onboarding asks. Each value is applied to the desktop as soon as it is picked;
/// the whole set is saved for resuming and, at the end, written to /etc/ish/firstrun.json.
struct OnboardingChoices: Codable, Equatable, Sendable {
    var style: String
    /// `DesktopAppearance` raw value; "" is the style's default.
    var appearance: String
    /// A `ColorThemeStore` id; "" keeps the style's own colours.
    var colorTheme: String
    /// `WallpaperSource.identifier`, nil to keep the current wallpaper.
    var wallpaper: String?
    var autoTiling: Bool
    /// "foot" or "native": the terminal the desktop opens.
    var terminal: String
    /// Catalog pack ids to install after onboarding.
    var packs: [String]
    /// Open the Wallpapers app on Wallhaven once onboarding is over.
    var browseWallhaven: Bool

    init(style: String = DesktopStyle.defaultStyle.rawValue, appearance: String = "", colorTheme: String = "",
         wallpaper: String? = nil, autoTiling: Bool = false, terminal: String = "foot", packs: [String] = [],
         browseWallhaven: Bool = false) {
        self.style = style
        self.appearance = appearance
        self.colorTheme = colorTheme
        self.wallpaper = wallpaper
        self.autoTiling = autoTiling
        self.terminal = terminal
        self.packs = packs
        self.browseWallhaven = browseWallhaven
    }

    /// The desktop's current settings, so a first run starts from the defaults and a replay
    /// starts from what the user has.
    @MainActor
    static func current(defaults: UserDefaults = .standard) -> OnboardingChoices {
        let tiling = TilingSettings.decode(defaults.string(forKey: DesktopSettings.tilingKey) ?? "")
        return OnboardingChoices(
            style: DesktopStyle.stored(defaults.string(forKey: DesktopStyle.storageKey) ?? "").rawValue,
            appearance: defaults.string(forKey: DesktopAppearance.storageKey) ?? "",
            colorTheme: defaults.string(forKey: ColorThemeStore.storageKey) ?? "",
            autoTiling: tiling?.first?.isEnabled ?? false,
            terminal: defaults.string(forKey: LinuxTerminal.settingKey) == LinuxTerminal.builtin.rawValue ? "native" : "foot")
    }
}

/// The onboarding state machine: which step is showing, what was chosen, and how it ended.
/// It persists itself after every change, so a first run interrupted by the app being
/// closed resumes where it stopped. Once onboarding has completed, opening it again
/// (Settings › About › Replay Welcome) is a replay: it starts at the beginning, is not
/// resumable, and skipping it leaves the saved first-run choices alone.
@Observable @MainActor
final class OnboardingFlow {
    static let completedKey = "desktop.onboarded"
    static let choicesKey = "desktop.firstRunChoices"
    static let progressKey = "desktop.onboarding.progress"
    static let firstRunPath = "/etc/ish/firstrun.json"
    static let firstRunVersion = 1

    enum Outcome: Equatable {
        case finished
        case skipped
    }

    private struct Progress: Codable {
        var step: OnboardingStep
        var choices: OnboardingChoices
    }

    let steps = OnboardingStep.allCases
    let isReplay: Bool
    private(set) var step: OnboardingStep {
        didSet { save() }
    }
    var choices: OnboardingChoices {
        didSet { save() }
    }
    private(set) var outcome: Outcome?
    /// Forward or back, for the direction of the step transition.
    private(set) var movedForward = true

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, current: OnboardingChoices? = nil) {
        self.defaults = defaults
        isReplay = defaults.bool(forKey: Self.completedKey)
        let fallback = current ?? OnboardingChoices.current(defaults: defaults)
        if !isReplay, let data = defaults.data(forKey: Self.progressKey),
           let progress = try? JSONDecoder().decode(Progress.self, from: data) {
            step = progress.step
            choices = progress.choices
        } else {
            step = .intro
            choices = fallback
        }
    }

    var position: Int { steps.firstIndex(of: step) ?? 0 }
    var isFirst: Bool { position == 0 }
    var isLast: Bool { position == steps.count - 1 }
    var isComplete: Bool { outcome != nil }

    func advance() {
        guard !isComplete, !isLast else { return }
        movedForward = true
        step = steps[position + 1]
    }

    func back() {
        guard !isComplete, !isFirst else { return }
        movedForward = false
        step = steps[position - 1]
    }

    func go(to target: OnboardingStep) {
        guard !isComplete, target != step else { return }
        movedForward = (steps.firstIndex(of: target) ?? 0) > position
        step = target
    }

    func togglePack(_ id: String) {
        if let index = choices.packs.firstIndex(of: id) {
            choices.packs.remove(at: index)
        } else {
            choices.packs.append(id)
            choices.packs.sort()
        }
    }

    /// Ends onboarding at the last step's "Show me" or "Start fresh". `installed`: catalog
    /// packs already in the Linux system.
    func finish(installed: [String] = []) {
        complete(.finished, installed: installed)
    }

    /// Ends onboarding early, keeping whatever was chosen so far and the defaults for the rest.
    func skip(installed: [String] = []) {
        complete(.skipped, installed: installed)
    }

    private func complete(_ result: Outcome, installed: [String]) {
        guard outcome == nil else { return }
        outcome = result
        defaults.removeObject(forKey: Self.progressKey)
        if isReplay && result == .skipped { return }
        defaults.set(firstRunChoices(installed: installed), forKey: Self.choicesKey)
        defaults.set(true, forKey: Self.completedKey)
    }

    /// What /etc/ish/firstrun.json holds. `linpad-apps pending` reads `packs`; the rest is
    /// a record of the first-run choices for scripts and support.
    func firstRunChoices(installed: [String] = []) -> [String: Any] {
        var result: [String: Any] = [
            "version": Self.firstRunVersion,
            "style": choices.style,
            "appearance": choices.appearance.isEmpty ? "default" : choices.appearance,
            "autoTiling": choices.autoTiling,
            "terminal": choices.terminal,
            "packs": choices.packs.sorted(),
            "installed": installed.sorted(),
            "colorTheme": choices.colorTheme.isEmpty ? "none" : choices.colorTheme,
        ]
        if let wallpaper = choices.wallpaper { result["wallpaper"] = wallpaper }
        return result
    }

    func firstRunJSON(installed: [String] = []) -> Data? {
        try? JSONSerialization.data(withJSONObject: firstRunChoices(installed: installed),
                                    options: [.prettyPrinted, .sortedKeys])
    }

    private func save() {
        guard !isReplay, outcome == nil,
              let data = try? JSONEncoder().encode(Progress(step: step, choices: choices)) else { return }
        defaults.set(data, forKey: Self.progressKey)
    }
}
