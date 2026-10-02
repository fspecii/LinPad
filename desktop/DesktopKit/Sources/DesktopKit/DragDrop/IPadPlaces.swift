import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

/// Optional host capability: mounting a folder the user picked on the iPad (iCloud Drive,
/// On My iPad, an external drive, another app's File Provider location) into the guest, so
/// Linux apps see it too. The iSH host mounts it with iOSFS, which keeps the folder's
/// security-scoped access open and mounts it again at every boot.
@MainActor
public protocol HostDirectoryMounting: AnyObject {
    /// `url` comes from a document picker; `guestPath` is an existing empty directory.
    func mountHostDirectory(_ url: URL, at guestPath: String) throws
    func unmountHostDirectory(at guestPath: String) throws
    /// Mount points currently remembered by the host (and mounted at boot).
    var mountedHostDirectories: Set<String> { get }
}

public struct HostMountError: LocalizedError {
    public let code: Int32
    public init(code: Int32) { self.code = code }
    public var errorDescription: String? {
        switch code {
        case -1: return "Not permitted to open that folder."
        case -16: return "The folder is in use."
        default: return "Mount failed (error \(code))."
        }
    }
}

/// One iPad folder mounted at /mnt/ipad/<name>, remembered across launches.
struct IPadPlace: Codable, Identifiable, Equatable {
    var name: String
    var mountPoint: String
    /// A bookmark of the picked folder, for showing where it came from and reconnecting.
    var bookmark: Data
    var id: String { mountPoint }
}

/// The iPad places the Files sidebar shows. iOSFS owns the mounts themselves; this keeps the
/// names and notices places whose folder could not be mounted again (deleted, an unplugged
/// drive, an app that was removed), so the sidebar can offer Reconnect or Remove.
@Observable @MainActor
final class IPadPlaceStore {
    static let shared = IPadPlaceStore()
    static let storageKey = "desktop.ipadPlaces"
    static let mountRoot = "/mnt/ipad"

    private(set) var places: [IPadPlace] = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        places = Self.decode(defaults.data(forKey: Self.storageKey))
    }

    static func decode(_ data: Data?) -> [IPadPlace] {
        guard let data, let places = try? JSONDecoder().decode([IPadPlace].self, from: data) else { return [] }
        return places
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(places), forKey: Self.storageKey)
    }

    func add(_ place: IPadPlace) {
        places.removeAll { $0.mountPoint == place.mountPoint }
        places.append(place)
        save()
    }

    func remove(_ mountPoint: String) {
        places.removeAll { $0.mountPoint == mountPoint }
        save()
    }

    /// A free mount point for a folder name: "/mnt/ipad/Documents", then "Documents (2)".
    func mountPoint(for folderName: String) -> String {
        let clean = folderName.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let taken = Set(places.map { AppPath.lastComponent($0.mountPoint) })
        return AppPath.join(Self.mountRoot, FileNaming.unique(clean.isEmpty ? "Folder" : clean, existing: taken))
    }

    /// Places the host no longer has mounted.
    func unavailable(mounted: Set<String>) -> Set<String> {
        Set(places.map(\.mountPoint)).subtracting(mounted)
    }

    // MARK: Adding and removing

    /// Shows the folder picker, mounts the choice into the guest and returns its mount point.
    func addFolder(host: any LinuxHost) async throws -> String? {
        guard let mounter = host as? any HostDirectoryMounting else {
            throw HostMountError(code: -19)
        }
        guard let url = await FolderPicker.pick() else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let bookmark = (try? url.bookmarkData()) ?? Data()
        let point = mountPoint(for: url.lastPathComponent)
        try await prepareMountPoint(point, host: host)
        try mounter.mountHostDirectory(url, at: point)
        add(IPadPlace(name: url.lastPathComponent, mountPoint: point, bookmark: bookmark))
        return point
    }

    /// Mounts a remembered place again from its bookmark (after "Unavailable").
    func reconnect(_ place: IPadPlace, host: any LinuxHost) async throws {
        guard let mounter = host as? any HostDirectoryMounting else { throw HostMountError(code: -19) }
        var stale = false
        let url = try URL(resolvingBookmarkData: place.bookmark, bookmarkDataIsStale: &stale)
        try await prepareMountPoint(place.mountPoint, host: host)
        try mounter.mountHostDirectory(url, at: place.mountPoint)
        if stale, let fresh = try? url.bookmarkData() {
            add(IPadPlace(name: place.name, mountPoint: place.mountPoint, bookmark: fresh))
        }
    }

    func eject(_ place: IPadPlace, host: any LinuxHost) async throws {
        if let mounter = host as? any HostDirectoryMounting {
            try mounter.unmountHostDirectory(at: place.mountPoint)
        }
        _ = await host.run("rmdir -- \(place.mountPoint.shellQuoted) 2>/dev/null; true", cwd: nil, stdin: nil)
        remove(place.mountPoint)
    }

    /// The mount point directory, and ~/iPad pointing at /mnt/ipad for Linux apps.
    private func prepareMountPoint(_ point: String, host: any LinuxHost) async throws {
        let link = AppPath.join(host.homeDirectory, "iPad")
        let result = await host.run("""
            mkdir -p -- \(point.shellQuoted) || exit 1
            [ -e \(link.shellQuoted) ] || ln -s \(Self.mountRoot) \(link.shellQuoted)
            """, cwd: nil, stdin: nil)
        guard result.succeeded else { throw LinuxHostError.commandFailed(result) }
    }
}

/// UIDocumentPickerViewController for one folder, as an async call.
@MainActor
private final class FolderPicker: NSObject, UIDocumentPickerDelegate {
    private var continuation: CheckedContinuation<URL?, Never>?
    private static var active: FolderPicker?

    static func pick() async -> URL? {
        guard let top = HostPresenter.topViewController else { return nil }
        let picker = FolderPicker()
        active = picker
        let url = await withCheckedContinuation { continuation in
            picker.continuation = continuation
            let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
            controller.delegate = picker
            controller.allowsMultipleSelection = false
            top.present(controller, animated: true)
        }
        active = nil
        return url
    }

    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        MainActor.assumeIsolated {
            continuation?.resume(returning: urls.first)
            continuation = nil
        }
    }

    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        MainActor.assumeIsolated {
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }
}
