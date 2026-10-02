import CryptoKit
import Foundation

public enum FileDigest {
    /// Lowercase hex SHA-256 of a file, read in 4 MB chunks (rootfs tarballs are ~700 MB).
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 4 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func matches(_ url: URL, sha256 expected: String) throws -> Bool {
        try sha256(of: url) == expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
