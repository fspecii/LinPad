import Foundation

/// Optional host capability: install a Linux system downloaded from a GitHub release
/// through the same path as the app's bundled system ("Update Linux system": the system
/// directories are replaced at the next launch, /root, /home and the user's packages kept).
@MainActor
public protocol LinuxSystemUpdating: AnyObject {
    /// The installed system's version stamp, or nil for a system made before stamps.
    var installedSystemVersion: String? { get }
    /// A newer system the app can install without a download (bundled in the app, or
    /// downloaded earlier), or nil.
    var installableSystemVersion: String? { get }
    /// The system that installs at the next launch, if one is scheduled.
    var scheduledSystemUpdate: String? { get }
    /// Takes over a verified rootfs tarball (moved, not copied) and schedules it for the
    /// next launch.
    func installDownloadedSystem(at archive: URL, version: String) throws
    /// iOS relaunched the app for the background download session and every event has
    /// been delivered: lets the system take its snapshot and suspend the app again.
    func backgroundDownloadEventsFinished()
}

/// Optional host capability: go back to the Linux system an update replaced. The app keeps
/// that system after every update; rolling back makes it the default again at the next
/// launch, carrying /root, /home and the user's files over, and keeps the newer one.
@MainActor
public protocol LinuxSystemRollingBack: AnyObject {
    /// The kept earlier system's version, or nil when there is none to go back to.
    var previousSystemVersion: String? { get }
    /// Whether a rollback is scheduled for the next launch.
    var isRollbackScheduled: Bool { get }
    func scheduleRollback() throws
    func cancelRollback()
}
