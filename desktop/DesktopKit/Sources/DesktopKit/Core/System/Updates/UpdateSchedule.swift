import Foundation

/// When the desktop looks for updates on its own: at launch and every 6 hours for releases,
/// weekly for Alpine packages; never offline, and not on Low Data Mode (a manual check
/// still runs there).
public enum UpdateSchedule {
    public static let releaseInterval: TimeInterval = 6 * 3600
    public static let packageInterval: TimeInterval = 7 * 24 * 3600

    public enum Network: Equatable, Sendable {
        case offline
        /// Low Data Mode.
        case constrained
        case available
    }

    public static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastCheck else { return true }
        // A clock set back makes the last check look like the future; check then too.
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now
    }

    public static func shouldCheckAutomatically(enabled: Bool, lastCheck: Date?, now: Date,
                                                network: Network, interval: TimeInterval = releaseInterval) -> Bool {
        enabled && network == .available && isDue(lastCheck: lastCheck, now: now, interval: interval)
    }

    public static func canCheckManually(network: Network) -> Bool {
        network != .offline
    }
}
