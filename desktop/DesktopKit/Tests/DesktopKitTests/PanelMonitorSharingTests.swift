import XCTest
@testable import DesktopKit

@MainActor
final class PanelMonitorSharingTests: XCTestCase {
    func testOneSamplingLoopServesEveryViewAndStopsWithTheLast() async throws {
        let monitor = PanelSystemMonitor()
        let host = MockLinuxHost(latency: .milliseconds(1))
        let panel = Task { await monitor.poll(host) }
        let widget = Task { await monitor.poll(host) }
        for _ in 0..<100 where monitor.memoryUsage == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(monitor.memoryUsage, "the meters get numbers")
        XCTAssertTrue(monitor.isSampling)
        panel.cancel()
        await panel.value
        XCTAssertTrue(monitor.isSampling, "the widget still needs it")
        widget.cancel()
        await widget.value
        XCTAssertFalse(monitor.isSampling, "nobody on screen: no polling")
    }
}
