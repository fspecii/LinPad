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
