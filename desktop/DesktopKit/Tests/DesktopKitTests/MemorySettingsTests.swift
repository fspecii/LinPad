import XCTest
@testable import DesktopKit

final class MemorySettingsTests: XCTestCase {
    // What kernel/oom.c's oom_show_memory prints.
    private let sample = """
        footprint_mb 1862
        allowance_mb 2500
        headroom_mb 637
        soft_mb 500
        hard_mb 320
        oom_enabled 1
        kills 1
        kill 1791008573 114 395 2196 2500 a Firefox tab process
        proc 22 388 0 0 Firefox
        proc 340 220 100 0 a Firefox tab process
        proc 19 5 0 1 pulseaudio

        """

    func testParsesTheMonitorsReport() {
        let status = GuestMemoryStatus(parsing: sample)
        XCTAssertEqual(status.footprintMB, 1862)
        XCTAssertEqual(status.allowanceMB, 2500)
        XCTAssertEqual(status.softMB, 500)
        XCTAssertEqual(status.hardMB, 320)
        XCTAssertTrue(status.killerEnabled)
        XCTAssertEqual(status.processes.count, 3)
        XCTAssertEqual(status.processes[1], .init(pid: 340, megabytes: 220, adjustment: 100, isProtected: false,
                                                  name: "a Firefox tab process"))
        XCTAssertTrue(status.processes[2].isProtected)
        XCTAssertEqual(status.closes.count, 1)
        XCTAssertEqual(status.closes[0].name, "a Firefox tab process")
        XCTAssertEqual(status.closes[0].freedMB, 395)
        XCTAssertEqual(status.closes[0].footprintMB, 2196)
        XCTAssertEqual(status.closes[0].allowanceMB, 2500)
        XCTAssertEqual(status.fraction, 1862.0 / 2500, accuracy: 0.0001)
    }

    func testNoLimitAndGarbage() {
        let status = GuestMemoryStatus(parsing: "footprint_mb 40\nallowance_mb 0\noom_enabled 0\nproc x\nnonsense\n")
        XCTAssertEqual(status.allowanceMB, 0)
        XCTAssertEqual(status.fraction, 0)
        XCTAssertFalse(status.killerEnabled)
        XCTAssertTrue(status.processes.isEmpty)
    }

    func testPolicyLines() {
        XCTAssertEqual(MemorySettings.policy(enabled: false), "enabled 0\n")
        XCTAssertEqual(MemorySettings.policy(protecting: " code, ,firefox-esr\nfoot "), "protect code,firefox-esr,foot\n")
        XCTAssertEqual(MemorySettings.policy(protecting: ""), "protect \n")
    }

    @MainActor
    func testReopenOffersOnlyAnAppsOwnProcess() {
        let entries = [
            LinuxDesktopEntry(id: "firefox-esr", name: "Firefox", command: "firefox-esr", icon: "firefox",
                              categories: [], startupWMClass: nil),
            LinuxDesktopEntry(id: "foot", name: "Terminal", command: "foot", icon: "foot", categories: [], startupWMClass: nil),
        ]
        XCTAssertEqual(MemorySettings.reopenableApp(named: "Firefox", in: entries)?.id, "firefox-esr")
        XCTAssertEqual(MemorySettings.reopenableApp(named: "foot", in: entries)?.id, "foot", "matched by its binary")
        XCTAssertNil(MemorySettings.reopenableApp(named: "a Firefox tab process", in: entries))
        XCTAssertNil(MemorySettings.reopenableApp(named: "", in: entries))
    }

    @MainActor
    func testClosedAppToastLinksToMemorySettings() {
        let controller = DesktopController(host: MockLinuxHost(latency: .zero), apps: BuiltinApps.all())
        controller.guestAppClosedForMemory(app: "a Firefox tab process",
                                           message: "Closed a Firefox tab process to free memory.")
        let toast = controller.toasts.last
        XCTAssertEqual(toast?.message, "Closed a Firefox tab process to free memory.")
        XCTAssertEqual(toast?.action?.title, "Memory Settings")
        XCTAssertNil(toast?.secondaryAction, "a tab process cannot be reopened")
    }
}
