import XCTest
import UIKit
@testable import DesktopKit

/// Replies can arrive after cancellation, like a command already running in the guest.
@MainActor
private final class DelayedPanelHost: LinuxHost {
    let hostName = "test"
    let homeDirectory = "/root"
    private(set) var commands: [String] = []
    private(set) var completedCommands = 0
    private var replies: [CheckedContinuation<CommandResult, Never>] = []

    func run(_ command: String, cwd: String?, stdin: Data?) async -> CommandResult {
        commands.append(command)
        let result = await withCheckedContinuation { replies.append($0) }
        completedCommands += 1
        return result
    }

    func completeNext(_ output: String) {
        replies.removeFirst().resume(returning: CommandResult(stdout: output))
    }

    func finishPending() {
        for reply in replies { reply.resume(returning: CommandResult(stdout: "", exitCode: 1)) }
        replies.removeAll()
    }

    func listDirectory(_ path: String) async throws -> [FileEntry] { [] }
    func readFile(_ path: String) async throws -> Data { Data() }
    func writeFile(_ path: String, data: Data) async throws {}
    func makeTerminalViewController(command: String?, cwd: String?) -> UIViewController { UIViewController() }
}

@MainActor
final class PanelMonitorSharingTests: XCTestCase {
    func testOneSamplingLoopServesEveryViewAndStopsWithTheLast() async throws {
        let monitor = PanelSystemMonitor()
        let host = MockLinuxHost(latency: .milliseconds(1))
        let panel = Task { await monitor.poll(host) }
        let widget = Task { await monitor.poll(host) }
        for _ in 0..<100 where monitor.memoryUsage == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(monitor.memoryUsage, "the meters get numbers")
        XCTAssertEqual(host.commandLog, [PanelSystemMonitor.sampleCommand], "both meters and subscribers share one guest command")
        XCTAssertTrue(monitor.isSampling)
        panel.cancel()
        await panel.value
        XCTAssertTrue(monitor.isSampling, "the widget still needs it")
        widget.cancel()
        await widget.value
        XCTAssertFalse(monitor.isSampling, "nobody on screen: no polling")
    }

    func testLateCancelledSampleCannotPublishIntoAResumedSampler() async throws {
        let monitor = PanelSystemMonitor()
        let host = DelayedPanelHost()
        let first = Task { await monitor.poll(host) }
        defer { first.cancel(); host.finishPending() }
        try await waitUntil { host.commands.count == 1 }
        first.cancel()
        await first.value
        XCTAssertFalse(monitor.isSampling)

        let resumed = Task { await monitor.poll(host) }
        defer { resumed.cancel() }
        try await waitUntil { host.commands.count == 2 }
        host.completeNext("cpu 10 0 0 90\n\n__LINPAD_MEMINFO__\nMemTotal: 100 kB\nMemAvailable: 10 kB\n")
        try await waitUntil { host.completedCommands == 1 }
        XCTAssertNil(monitor.memoryUsage, "the retired sampler cannot overwrite the current readings")

        host.completeNext("cpu 20 0 0 180\n\n__LINPAD_MEMINFO__\nMemTotal: 100 kB\nMemAvailable: 75 kB\n")
        try await waitUntil { host.completedCommands == 2 }
        XCTAssertEqual(monitor.memoryUsage, 0.25)
        XCTAssertNil(monitor.cpuUsage, "CPU deltas start with the resumed sampler, not the cancelled sample")
        resumed.cancel()
        await resumed.value
        XCTAssertFalse(monitor.isSampling)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 where !predicate() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "the sampler completed the expected step")
    }
}
