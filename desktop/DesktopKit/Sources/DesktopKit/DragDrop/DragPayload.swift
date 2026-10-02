import Foundation
import GameController
import UIKit
import UniformTypeIdentifiers

/// One thing being dragged or dropped anywhere on the desktop: between native windows,
/// to and from Linux apps through ishwl, and to and from other iPadOS apps.
enum DragItem: Equatable, Sendable {
    /// A file or folder inside the guest.
    case guestFile(path: String, isDirectory: Bool)
    case text(String)
    case url(URL)
    /// A file from outside the guest (an iPadOS app, Photos): a host file URL that stays
    /// readable until the drop finishes, or raw data with a suggested name.
    case hostFile(URL)
    case data(Data, suggestedName: String)

    var guestPath: String? {
        if case .guestFile(let path, _) = self { return path }
        return nil
    }
}

extension UTType {
    /// Guest paths dragged inside the app. Never leaves the process: other apps get file
    /// representations instead, which are exported through the guest on demand.
    static let guestItems = UTType(exportedAs: "com.valentinneagu.ish.guest-items", conformingTo: .data)
}

/// The in-process payload behind `UTType.guestItems`.
struct GuestItemsPayload: Codable, Equatable {
    struct Item: Codable, Equatable {
        var path: String
        var isDirectory: Bool
    }

    var items: [Item]
    /// The desktop window the drag came from, so a drop on the same folder is a no-op.
    var sourceWindow: UUID?

    var paths: [String] { items.map(\.path) }
}

/// Whether a drop copies or moves, decided like a Linux file manager: within the guest a
/// drag moves unless Option is held; anything from outside the guest is always copied.
enum DropOperation: Equatable {
    case copy, move

    @MainActor
    static func forGuestDrag() -> DropOperation {
        KeyboardModifiers.isOptionDown ? .copy : .move
    }
}

/// Modifier keys at this moment. Drag and tap callbacks don't carry modifier flags, but the
/// hardware keyboard state is readable through GameController.
@MainActor
enum KeyboardModifiers {
    private static func isDown(_ codes: [GCKeyCode]) -> Bool {
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return false }
        return codes.contains { input.button(forKeyCode: $0)?.isPressed == true }
    }

    static var isOptionDown: Bool { isDown([.leftAlt, .rightAlt]) }
    static var isShiftDown: Bool { isDown([.leftShift, .rightShift]) }
    static var isCommandDown: Bool { isDown([.leftGUI, .rightGUI]) }
    static var isControlDown: Bool { isDown([.leftControl, .rightControl]) }
}

// MARK: - NSItemProvider

enum DragItemProviders {
    /// The guest items of the drag this app started most recently. A drop target can't load
    /// a provider's data until the drop, but Linux clients ask for the URI list while the
    /// drag hovers them, so in-app drags are looked up here instead.
    @MainActor static var lastGuestPayload: GuestItemsPayload?
    /// A provider for guest items: the guest paths for in-app drops, and the first item as a
    /// file for other apps, exported through the guest only if another app asks for it.
    @MainActor
    static func provider(for items: [GuestItemsPayload.Item], sourceWindow: UUID?,
                         transfer: GuestTransferService) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = GuestItemsPayload(items: items, sourceWindow: sourceWindow)
        lastGuestPayload = payload
        if let encoded = try? JSONEncoder().encode(payload) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.guestItems.identifier,
                                                visibility: .ownProcess) { completion in
                completion(encoded, nil)
                return nil
            }
        }
        guard let first = items.first else { return provider }
        let name = AppPath.lastComponent(first.path)
        provider.suggestedName = name
        let type: UTType = first.isDirectory
            ? .folder
            : (UTType(filenameExtension: AppPath.pathExtension(name)) ?? .data)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [],
                                            visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 100)
            Task { @MainActor in
                do {
                    let url = try await transfer.exportItem(first.path, isDirectory: first.isDirectory) { done, total in
                        progress.completedUnitCount = total > 0 ? Int64(Double(done) / Double(total) * 100) : 0
                    }
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }

    static func provider(forText text: String) -> NSItemProvider {
        NSItemProvider(object: text as NSString)
    }

    /// Types a drop target asks for, best first.
    static let acceptedTypes: [UTType] = [.guestItems, .fileURL, .image, .url, .plainText, .item]

    /// Reads whatever a drop carries, preferring guest paths, then files, then text.
    static func loadItems(from providers: [NSItemProvider]) async -> (payload: GuestItemsPayload?, items: [DragItem]) {
        var guestItems: [GuestItemsPayload.Item] = []
        var sourceWindow: UUID?
        var items: [DragItem] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.guestItems.identifier),
               let data = try? await loadData(provider, type: .guestItems),
               let payload = try? JSONDecoder().decode(GuestItemsPayload.self, from: data) {
                guestItems += payload.items
                sourceWindow = sourceWindow ?? payload.sourceWindow
                items += payload.items.map { .guestFile(path: $0.path, isDirectory: $0.isDirectory) }
                continue
            }
            if let item = await loadExternal(provider) {
                items.append(item)
            }
        }
        let payload = guestItems.isEmpty ? nil : GuestItemsPayload(items: guestItems, sourceWindow: sourceWindow)
        return (payload, items)
    }

    private static func loadExternal(_ provider: NSItemProvider) async -> DragItem? {
        // A web link dragged from Safari also offers text; keep it a URL.
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try? await loadURL(provider), !url.isFileURL {
            return .url(url)
        }
        if let fileType = provider.registeredTypeIdentifiers.compactMap(UTType.init).first(where: isFileLike),
           let url = try? await copyFile(provider, type: fileType) {
            return .hostFile(url)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let data = try? await loadData(provider, type: .plainText),
           let text = String(data: data, encoding: .utf8) {
            return .text(text)
        }
        if let type = provider.registeredTypeIdentifiers.compactMap(UTType.init).first,
           let data = try? await loadData(provider, type: type) {
            let ext = type.preferredFilenameExtension.map { "." + $0 } ?? ""
            return .data(data, suggestedName: (provider.suggestedName ?? "Dropped Item") + ext)
        }
        return nil
    }

    /// Text and links are content; everything else (documents, images, folders) is a file.
    private static func isFileLike(_ type: UTType) -> Bool {
        if type == .guestItems { return false }
        if type.conforms(to: .plainText) || type == .url || type.conforms(to: .url) && !type.conforms(to: .fileURL) {
            return false
        }
        return type.conforms(to: .data) || type.conforms(to: .directory) || type.conforms(to: .package)
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { continuation.resume(returning: data) } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    private static func loadURL(_ provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url { continuation.resume(returning: url) } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    /// The provider's file is only valid inside the callback, so it is copied to a staging
    /// directory the drop owns; the caller deletes it once the import is done.
    private static func copyFile(_ provider: NSItemProvider, type: UTType) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    let staging = try HostStaging.makeDirectory(prefix: "Drop")
                    let name = provider.suggestedName.map { name -> String in
                        let ext = url.pathExtension
                        return ext.isEmpty || name.hasSuffix("." + ext) ? name : name + "." + ext
                    } ?? url.lastPathComponent
                    let target = staging.appendingPathComponent(name)
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Scratch space on the host side for files passing between iPadOS and the guest.
enum HostStaging {
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DesktopTransfers", isDirectory: true)
    }

    static func makeDirectory(prefix: String) throws -> URL {
        let url = root.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Staging from earlier launches; exports handed to other apps are copied by the system.
    static func purge(olderThan age: TimeInterval = 3600) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) < cutoff { try? manager.removeItem(at: entry) }
        }
    }
}
