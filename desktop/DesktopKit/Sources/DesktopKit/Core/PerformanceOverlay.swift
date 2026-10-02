import SwiftUI
import Observation
import QuartzCore

/// Frame pacing and memory measured on the device itself: frames per second, mean and
/// worst frame time over the last half second, and the app's physical memory footprint.
@Observable @MainActor
final class FrameMonitor {
    private(set) var framesPerSecond: Double = 0
    private(set) var meanFrameTime: Double = 0
    private(set) var worstFrameTime: Double = 0
    private(set) var memoryFootprint: UInt64 = 0
    private(set) var maximumFramesPerSecond = 60

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval = 0
    @ObservationIgnored private var intervals: [CFTimeInterval] = []
    @ObservationIgnored private var windowStart: CFTimeInterval = 0

    private static let sampleWindow: CFTimeInterval = 0.5

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = 0
        intervals.removeAll()
    }

    fileprivate func tick(_ link: CADisplayLink) {
        maximumFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        let now = link.timestamp
        defer { lastTimestamp = now }
        guard lastTimestamp > 0 else {
            windowStart = now
            return
        }
        intervals.append(now - lastTimestamp)
        guard now - windowStart >= Self.sampleWindow else { return }
        let total = intervals.reduce(0, +)
        framesPerSecond = Double(intervals.count) / total
        meanFrameTime = total / Double(intervals.count) * 1000
        worstFrameTime = (intervals.max() ?? 0) * 1000
        memoryFootprint = Self.physicalFootprint()
        intervals.removeAll(keepingCapacity: true)
        windowStart = now
    }

    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

/// CADisplayLink retains its target; the proxy keeps that from retaining the monitor.
private final class DisplayLinkProxy: NSObject {
    private weak var monitor: FrameMonitor?

    init(_ monitor: FrameMonitor) {
        self.monitor = monitor
    }

    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated { monitor?.tick(link) }
    }
}

struct PerformanceOverlay: View {
    @State private var monitor = FrameMonitor()

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(Int(monitor.framesPerSecond.rounded())) / \(monitor.maximumFramesPerSecond) fps")
                .foregroundStyle(fpsColor)
            Text(String(format: "%.1f ms avg · %.1f ms worst", monitor.meanFrameTime, monitor.worstFrameTime))
            Text(ByteCountFormatter.string(fromByteCount: Int64(monitor.memoryFootprint), countStyle: .memory))
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("desktop.performance")
    }

    private var fpsColor: Color {
        let ratio = monitor.framesPerSecond / Double(max(monitor.maximumFramesPerSecond, 1))
        if ratio > 0.9 { return Color(red: 0.4, green: 0.9, blue: 0.5) }
        if ratio > 0.7 { return Color(red: 1, green: 0.78, blue: 0.3) }
        return Color(red: 1, green: 0.42, blue: 0.42)
    }
}
