import Foundation
import Perception

/// Feeds the panel meters from /proc. Samples run back to back with a pause in between,
/// so a slow emulator never accumulates overlapping commands.
@Perceptible @MainActor
final class PanelSystemMonitor {
    private static let interval: Duration = .seconds(3)
    static let memorySeparator = "\n__LINPAD_MEMINFO__\n"
    static let sampleCommand = "head -1 /proc/stat && printf '\\n__LINPAD_MEMINFO__\\n' && cat /proc/meminfo"

    private(set) var cpuUsage: Double?
    private(set) var memoryUsage: Double?

    /// Busy and total jiffies from the previous /proc/stat sample; usage is the delta between samples.
    private var previousCPUTimes: (busy: Double, total: Double)?

    /// Views that show the numbers (every style's panel meters, the System Monitor widget)
    /// share one sampling loop; it runs while at least one of them is on screen.
    @PerceptionIgnored private var subscribers = 0
    @PerceptionIgnored private var loop: Task<Void, Never>?

    /// Keeps the shared loop alive until the calling task is cancelled.
    func poll(_ host: any LinuxHost) async {
        guard !Task.isCancelled else { return }
        subscribers += 1
        if loop == nil {
            previousCPUTimes = nil
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.sample(host)
                    do {
                        try await Task.sleep(for: Self.interval)
                    } catch {
                        return
                    }
                }
            }
        }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                break
            }
        }
        subscribers -= 1
        if subscribers == 0 {
            loop?.cancel()
            loop = nil
        }
    }

    var isSampling: Bool { loop != nil }

    private func sample(_ host: any LinuxHost) async {
        let result = await host.run(Self.sampleCommand)
        // A cancelled host command may still finish; it must not update a resumed sampler.
        guard !Task.isCancelled, result.succeeded,
              let separator = result.stdout.range(of: Self.memorySeparator) else { return }
        let stat = String(result.stdout[..<separator.lowerBound])
        let memory = String(result.stdout[separator.upperBound...])
        if let times = Self.parseCPUTimes(stat) {
            if let previous = previousCPUTimes, times.total > previous.total {
                cpuUsage = min(max((times.busy - previous.busy) / (times.total - previous.total), 0), 1)
            }
            previousCPUTimes = times
        }
        if let value = Self.parseMemoryUsage(memory) {
            memoryUsage = value
        }
    }

    /// Parses the aggregate `cpu  user nice system idle [iowait ...]` line.
    static func parseCPUTimes(_ text: String) -> (busy: Double, total: Double)? {
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.first == "cpu" else { return nil }
        let values = fields.dropFirst().compactMap { Double($0) }
        guard values.count >= 4 else { return nil }
        let total = values.reduce(0, +)
        let idle = values[3] + (values.count > 4 ? values[4] : 0)
        return (total - idle, total)
    }

    static func parseMemoryUsage(_ text: String) -> Double? {
        var kib: [Substring: Double] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == ":" || $0 == " " })
            guard fields.count >= 2, let value = Double(fields[1]) else { continue }
            kib[fields[0]] = value
        }
        guard let total = kib["MemTotal"], total > 0 else { return nil }
        let available = kib["MemAvailable"]
            ?? (kib["MemFree"] ?? 0) + (kib["Buffers"] ?? 0) + (kib["Cached"] ?? 0)
        return min(max((total - available) / total, 0), 1)
    }
}
