import XCTest
@testable import DesktopKit

final class IdlePolicyTests: XCTestCase {
    private let policy = IdlePolicy(screensaverAfter: 120, lockAfter: 600)

    func testNothingBeforeTheTimeouts() {
        XCTAssertTrue(policy.actions(idle: 119, isLocked: false, isScreensaverShown: false, inhibited: false).isEmpty)
    }

    func testScreensaverThenLock() {
        XCTAssertEqual(policy.actions(idle: 120, isLocked: false, isScreensaverShown: false, inhibited: false),
                       .init(showScreensaver: true, lock: false))
        XCTAssertEqual(policy.actions(idle: 600, isLocked: false, isScreensaverShown: true, inhibited: false),
                       .init(showScreensaver: false, lock: true), "the lock comes in under the running screensaver")
        XCTAssertTrue(policy.actions(idle: 900, isLocked: true, isScreensaverShown: true, inhibited: false).isEmpty)
    }

    func testOffByDefault() {
        XCTAssertNil(IdlePolicy().shortestTimeout)
        XCTAssertTrue(IdlePolicy().actions(idle: 100_000, isLocked: false, isScreensaverShown: false, inhibited: false).isEmpty)
    }

    func testVideoRecordingAndKeepAwakeInhibit() {
        XCTAssertTrue(policy.actions(idle: 10_000, isLocked: false, isScreensaverShown: false, inhibited: true).isEmpty)
        var awake = policy
        awake.keepAwake = true
        XCTAssertTrue(awake.actions(idle: 10_000, isLocked: false, isScreensaverShown: false, inhibited: false).isEmpty)
    }

    func testLockOnlyWithoutScreensaver() {
        let lockOnly = IdlePolicy(screensaverAfter: nil, lockAfter: 300)
        XCTAssertEqual(lockOnly.shortestTimeout, 300)
        XCTAssertEqual(lockOnly.actions(idle: 300, isLocked: false, isScreensaverShown: false, inhibited: false),
                       .init(showScreensaver: false, lock: true))
    }

    func testChoiceTitles() {
        XCTAssertEqual(IdleSettings.title(minutes: 0), "Never")
        XCTAssertEqual(IdleSettings.title(minutes: 5), "5 min")
        XCTAssertEqual(IdleSettings.title(minutes: 60), "1 hour")
        XCTAssertEqual(IdleSettings.screensaverChoices.first, 0, "Never is the default")
    }
}
