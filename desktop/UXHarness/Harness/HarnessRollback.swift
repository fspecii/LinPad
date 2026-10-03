import DesktopKit
import Foundation

/// A stand-in for the app's rollback (Roots), so Settings › Updates shows its rows in UI
/// tests: `-harness.previousSystem VERSION` pretends an earlier system is kept.
extension MockLinuxHost: @retroactive LinuxSystemRollingBack {
    public var previousSystemVersion: String? {
        UserDefaults.standard.string(forKey: "harness.previousSystem")
    }

    public var isRollbackScheduled: Bool { HarnessRollbackState.isScheduled }

    public func scheduleRollback() throws {
        HarnessRollbackState.isScheduled = true
    }

    public func cancelRollback() {
        HarnessRollbackState.isScheduled = false
    }
}

@MainActor
private enum HarnessRollbackState {
    static var isScheduled = false
}
