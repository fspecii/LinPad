import Foundation

/// The Text Editor's unsaved text, kept on the iPad side (Application Support) so it
/// survives iPadOS ending LinPad even when the guest could not save the file: a new
/// document, a read-only folder, autosave turned off, or a guest that does not answer.
/// One record per editor window, named by the window's recovery argument.
struct EditorRecoveryRecord: Codable, Equatable {
    var path: String?
    var text: String
    var savedAt: Date
}

struct EditorRecoveryStore {
    static let shared = EditorRecoveryStore(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EditorRecovery", isDirectory: true))
    /// Records no window refers to any more are deleted after this long.
    static let orphanLifetime: TimeInterval = 7 * 24 * 3600

    let directory: URL

    private func url(for id: String) -> URL? {
        // The id comes back from the saved session; never let it name another file.
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return directory.appendingPathComponent(id + ".json")
    }

    func read(_ id: String) -> EditorRecoveryRecord? {
        guard let url = url(for: id), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.recovery.decode(EditorRecoveryRecord.self, from: data)
    }

    /// Atomic (temporary file, then rename): a kill mid-write keeps the previous record.
    @discardableResult
    func write(_ record: EditorRecoveryRecord, id: String) -> Bool {
        guard let url = url(for: id), let data = try? JSONEncoder.recovery.encode(record) else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
    }

    func remove(_ id: String) {
        guard let url = url(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes records that no open or saved window refers to, once they are old enough
    /// that no window being restored could still want them.
    func prune(keeping ids: Set<String>, now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            guard !ids.contains(id), let record = read(id),
                  now.timeIntervalSince(record.savedAt) > Self.orphanLifetime else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

private extension JSONEncoder {
    static let recovery: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let recovery: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
