import XCTest
@testable import DesktopKit

@MainActor
final class OnboardingFlowTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "onboarding-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeFlow(_ choices: OnboardingChoices = OnboardingChoices()) -> OnboardingFlow {
        OnboardingFlow(defaults: defaults, current: choices)
    }

    private func firstRunFile(_ flow: OnboardingFlow, installed: [String] = []) throws -> [String: Any] {
        let data = try XCTUnwrap(flow.firstRunJSON(installed: installed))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Steps

    func testStartsAtTheIntroAndWalksEveryStepInOrder() {
        let flow = makeFlow()
        XCTAssertEqual(flow.step, .intro)
        XCTAssertFalse(flow.isReplay)
        var visited = [flow.step]
        while !flow.isLast {
            flow.advance()
            visited.append(flow.step)
        }
        XCTAssertEqual(visited, OnboardingStep.allCases)
        flow.advance()
        XCTAssertEqual(flow.step, .finale, "advance stops at the last step")
    }

    func testBackStopsAtTheIntroAndRecordsDirection() {
        let flow = makeFlow()
        flow.back()
        XCTAssertEqual(flow.step, .intro)
        flow.advance()
        flow.advance()
        XCTAssertTrue(flow.movedForward)
        flow.back()
        XCTAssertEqual(flow.step, .tour)
        XCTAssertFalse(flow.movedForward)
        flow.go(to: .keyboard)
        XCTAssertEqual(flow.step, .keyboard)
        XCTAssertTrue(flow.movedForward)
    }

    func testTogglePackKeepsTheListSortedAndUnique() {
        let flow = makeFlow()
        flow.togglePack("vscode")
        flow.togglePack("gimp")
        flow.togglePack("thunderbird")
        flow.togglePack("gimp")
        XCTAssertEqual(flow.choices.packs, ["thunderbird", "vscode"])
    }

    // MARK: Resume

    func testAnInterruptedFirstRunResumesWhereItStopped() {
        let first = makeFlow()
        first.advance()
        first.advance()
        first.choices.style = DesktopStyle.macos.rawValue
        first.choices.colorTheme = "tokyo-night"
        first.togglePack("vscode")

        let resumed = makeFlow()
        XCTAssertEqual(resumed.step, .personalize)
        XCTAssertEqual(resumed.choices.style, "macos")
        XCTAssertEqual(resumed.choices.colorTheme, "tokyo-night")
        XCTAssertEqual(resumed.choices.packs, ["vscode"])
    }

    func testCorruptProgressStartsOver() {
        defaults.set(Data("not json".utf8), forKey: OnboardingFlow.progressKey)
        let flow = makeFlow(OnboardingChoices(style: "windows"))
        XCTAssertEqual(flow.step, .intro)
        XCTAssertEqual(flow.choices.style, "windows")
    }

    func testFinishingClearsProgressAndMarksOnboardingDone() {
        let flow = makeFlow()
        flow.go(to: .finale)
        XCTAssertNotNil(defaults.data(forKey: OnboardingFlow.progressKey))
        flow.finish()
        XCTAssertEqual(flow.outcome, .finished)
        XCTAssertNil(defaults.data(forKey: OnboardingFlow.progressKey))
        XCTAssertTrue(defaults.bool(forKey: OnboardingFlow.completedKey))
        flow.advance()
        flow.choices.style = "kylin"
        XCTAssertNil(defaults.data(forKey: OnboardingFlow.progressKey), "nothing is saved after the end")
        XCTAssertEqual(flow.step, .finale)
    }

    // MARK: Skip

    func testSkipKeepsChoicesMadeSoFarAndDefaultsForTheRest() throws {
        let flow = makeFlow()
        flow.advance()
        flow.advance()
        flow.choices.style = "ubuntu"
        flow.skip(installed: ["vlc"])
        XCTAssertEqual(flow.outcome, .skipped)
        XCTAssertTrue(defaults.bool(forKey: OnboardingFlow.completedKey))
        XCTAssertNil(defaults.data(forKey: OnboardingFlow.progressKey))
        let saved = try XCTUnwrap(defaults.dictionary(forKey: OnboardingFlow.choicesKey))
        XCTAssertEqual(saved["style"] as? String, "ubuntu")
        XCTAssertEqual(saved["packs"] as? [String], [])
        XCTAssertEqual(saved["installed"] as? [String], ["vlc"])
        XCTAssertEqual(saved["autoTiling"] as? Bool, false)
    }

    func testCompletingTwiceKeepsTheFirstOutcome() {
        let flow = makeFlow()
        flow.skip()
        flow.finish()
        XCTAssertEqual(flow.outcome, .skipped)
    }

    // MARK: Replay

    func testReplayStartsFromTheBeginningWithTheCurrentSettings() {
        let first = makeFlow()
        first.advance()
        first.finish()

        let replay = makeFlow(OnboardingChoices(style: "windows", colorTheme: "gruvbox"))
        XCTAssertTrue(replay.isReplay)
        XCTAssertEqual(replay.step, .intro)
        XCTAssertEqual(replay.choices.style, "windows")
        XCTAssertEqual(replay.choices.colorTheme, "gruvbox")
        replay.advance()
        XCTAssertNil(defaults.data(forKey: OnboardingFlow.progressKey), "a replay is not resumable")
    }

    func testSkippingAReplayLeavesTheSavedChoicesAlone() throws {
        let first = makeFlow(OnboardingChoices(style: "macos"))
        first.finish()
        let replay = makeFlow(OnboardingChoices(style: "kylin"))
        replay.skip()
        let saved = try XCTUnwrap(defaults.dictionary(forKey: OnboardingFlow.choicesKey))
        XCTAssertEqual(saved["style"] as? String, "macos")
        XCTAssertTrue(defaults.bool(forKey: OnboardingFlow.completedKey))
    }

    func testFinishingAReplaySavesTheNewChoices() throws {
        makeFlow(OnboardingChoices(style: "macos")).finish()
        let replay = makeFlow(OnboardingChoices(style: "kylin"))
        replay.go(to: .finale)
        replay.finish()
        let saved = try XCTUnwrap(defaults.dictionary(forKey: OnboardingFlow.choicesKey))
        XCTAssertEqual(saved["style"] as? String, "kylin")
    }

    // MARK: firstrun.json

    func testFirstRunFileHasTheContractKeys() throws {
        let flow = makeFlow(OnboardingChoices(style: "windows", appearance: "", colorTheme: "", wallpaper: "gradient:aurora",
                                              autoTiling: true, terminal: "foot"))
        flow.togglePack("vscode")
        flow.togglePack("gimp")
        let file = try firstRunFile(flow, installed: ["vlc"])
        XCTAssertEqual(file["version"] as? Int, 1)
        XCTAssertEqual(file["style"] as? String, "windows")
        XCTAssertEqual(file["appearance"] as? String, "default", "an empty appearance is written as default")
        XCTAssertEqual(file["autoTiling"] as? Bool, true)
        XCTAssertEqual(file["terminal"] as? String, "foot")
        XCTAssertEqual(file["packs"] as? [String], ["gimp", "vscode"], "linpad-apps pending reads this")
        XCTAssertEqual(file["installed"] as? [String], ["vlc"])
        XCTAssertEqual(file["colorTheme"] as? String, "none")
        XCTAssertEqual(file["wallpaper"] as? String, "gradient:aurora")
    }

    func testFirstRunFileOmitsAnUnchangedWallpaperAndKeepsAppearance() throws {
        let flow = makeFlow(OnboardingChoices(style: "kylin", appearance: "dark", colorTheme: "catppuccin"))
        let file = try firstRunFile(flow)
        XCTAssertNil(file["wallpaper"])
        XCTAssertEqual(file["appearance"] as? String, "dark")
        XCTAssertEqual(file["colorTheme"] as? String, "catppuccin")
        XCTAssertEqual(file["packs"] as? [String], [], "nothing is preselected")
    }

    func testFirstRunFileIsStableJSON() throws {
        let flow = makeFlow()
        let data = try XCTUnwrap(flow.firstRunJSON())
        let text = String(decoding: data, as: UTF8.self)
        let keys = ["appearance", "autoTiling", "colorTheme", "installed", "packs", "style", "terminal", "version"]
        let positions = keys.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        XCTAssertEqual(positions.count, keys.count)
        XCTAssertEqual(positions, positions.sorted(), "keys are sorted so the file diffs cleanly")
    }

    // MARK: Helpers

    func testWallpaperIdentifiersRoundTrip() {
        for source in [WallpaperSource.gradient("aurora"), .image("builtin-dunes"), .color(0x1A2B3C)] {
            XCTAssertEqual(WallpaperSource(identifier: source.identifier), source)
        }
        XCTAssertNil(WallpaperSource(identifier: "nonsense"))
        XCTAssertNil(WallpaperSource(identifier: "color:zz"))
    }

    func testCurrentChoicesReadTheDesktopSettings() {
        defaults.set("macos", forKey: DesktopStyle.storageKey)
        defaults.set("light", forKey: DesktopAppearance.storageKey)
        defaults.set("nord", forKey: ColorThemeStore.storageKey)
        defaults.set(LinuxTerminal.builtin.rawValue, forKey: LinuxTerminal.settingKey)
        defaults.set(TilingSettings.encode([TilingState(isEnabled: true)]), forKey: DesktopSettings.tilingKey)
        let choices = OnboardingChoices.current(defaults: defaults)
        XCTAssertEqual(choices.style, "macos")
        XCTAssertEqual(choices.appearance, "light")
        XCTAssertEqual(choices.colorTheme, "nord")
        XCTAssertEqual(choices.terminal, "native")
        XCTAssertTrue(choices.autoTiling)
        XCTAssertEqual(choices.packs, [])
    }
}
