import Foundation

/// A LinPad backup file is a plain POSIX tar, so any tar can open it:
///
///     manifest.json            BackupManifest
///     desktop/settings.plist   the desktop's settings (UserDefaults), optional
///     desktop/files/...        wallpapers and calendar from Application Support, optional
///     linux.tar.zst            /root and /home as the guest's tar made them (or .tar.gz)
///
/// The payload is last because the guest appends it straight into the file: the host writes
/// the small members and a placeholder header, the guest's compressor appends, and the
/// host fills in the header with the final size (`BackupArchiveWriter`).
enum BackupArchive {
    static let blockSize = 512
    static let settingsMember = "desktop/settings.plist"
    static let desktopFilesPrefix = "desktop/files/"

    enum Problem: Error, Equatable, LocalizedError {
        case notABackup
        case damaged(String)
        case nameTooLong(String)

        var errorDescription: String? {
            switch self {
            case .notABackup: return "This file is not a LinPad backup."
            case .damaged(let detail): return "The backup file is damaged (\(detail))."
            case .nameTooLong(let name): return "A file name is too long for the backup: \(name)"
            }
        }
    }

    struct Member: Equatable {
        let name: String
        let offset: UInt64
        let size: UInt64
    }

    // MARK: Header encoding

    static func header(name: String, size: UInt64, mode: Int = 0o644, mtime: Date = Date(),
                       typeflag: UInt8 = UInt8(ascii: "0")) throws -> Data {
        var block = [UInt8](repeating: 0, count: blockSize)
        let (prefix, base) = try splitName(name)
        put(Array(base.utf8), into: &block, at: 0, length: 100)
        putOctal(UInt64(mode), into: &block, at: 100, length: 8)
        putOctal(0, into: &block, at: 108, length: 8)
        putOctal(0, into: &block, at: 116, length: 8)
        putSize(size, into: &block, at: 124)
        putOctal(UInt64(max(0, mtime.timeIntervalSince1970)), into: &block, at: 136, length: 12)
        block[156] = typeflag
        put(Array("ustar\0".utf8), into: &block, at: 257, length: 6)
        put(Array("00".utf8), into: &block, at: 263, length: 2)
        put(Array("root".utf8), into: &block, at: 265, length: 32)
        put(Array("root".utf8), into: &block, at: 297, length: 32)
        put(Array(prefix.utf8), into: &block, at: 345, length: 155)
        for index in 148..<156 { block[index] = UInt8(ascii: " ") }
        let checksum = block.reduce(0) { $0 + Int($1) }
        let digits = Array(String(format: "%06o", checksum).utf8)
        for (index, digit) in digits.enumerated() { block[148 + index] = digit }
        block[154] = 0
        block[155] = UInt8(ascii: " ")
        return Data(block)
    }

    /// ustar keeps names up to 100 bytes, or 255 split at a "/" into prefix and name.
    static func splitName(_ name: String) throws -> (prefix: String, name: String) {
        let bytes = Array(name.utf8)
        if bytes.count <= 100 { return ("", name) }
        guard bytes.count <= 256 else { throw Problem.nameTooLong(name) }
        for (index, byte) in bytes.enumerated().reversed() where byte == UInt8(ascii: "/") {
            let prefix = bytes[..<index]
            let rest = bytes[(index + 1)...]
            if prefix.count <= 155, rest.count <= 100, !rest.isEmpty {
                return (String(decoding: prefix, as: UTF8.self), String(decoding: rest, as: UTF8.self))
            }
        }
        throw Problem.nameTooLong(name)
    }

    static func padding(for size: UInt64) -> Int {
        let remainder = Int(size % UInt64(blockSize))
        return remainder == 0 ? 0 : blockSize - remainder
    }

    private static func put(_ bytes: [UInt8], into block: inout [UInt8], at offset: Int, length: Int) {
        for (index, byte) in bytes.prefix(length).enumerated() { block[offset + index] = byte }
    }

    private static func putOctal(_ value: UInt64, into block: inout [UInt8], at offset: Int, length: Int) {
        let digits = Array(String(value, radix: 8).utf8)
        let field = [UInt8](repeating: UInt8(ascii: "0"), count: max(0, length - 1 - digits.count)) + digits
        put(field, into: &block, at: offset, length: length - 1)
    }

    /// Sizes past 8 GiB use the GNU base-256 form, which ustar readers in busybox, GNU tar
    /// and bsdtar all accept.
    private static func putSize(_ size: UInt64, into block: inout [UInt8], at offset: Int) {
        if size < 0o77777777777 {
            putOctal(size, into: &block, at: offset, length: 12)
            return
        }
        block[offset] = 0x80
        for index in 0..<8 {
            block[offset + 11 - index] = UInt8((size >> (8 * UInt64(index))) & 0xff)
        }
    }

    // MARK: Header decoding

    static func parseHeader(_ block: Data) throws -> (name: String, size: UInt64, typeflag: UInt8)? {
        guard block.count == blockSize else { throw Problem.damaged("short header") }
        let bytes = [UInt8](block)
        if bytes.allSatisfy({ $0 == 0 }) { return nil }
        var sum = 0
        for (index, byte) in bytes.enumerated() { sum += (148..<156).contains(index) ? 32 : Int(byte) }
        guard let stored = octal(bytes[148..<156]), stored == UInt64(sum) else { throw Problem.damaged("checksum") }
        let name = string(bytes[0..<100])
        let prefix = bytes[257..<262].elementsEqual("ustar".utf8) ? string(bytes[345..<500]) : ""
        let size: UInt64
        if bytes[124] & 0x80 != 0 {
            size = bytes[128..<136].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        } else {
            guard let value = octal(bytes[124..<136]) else { throw Problem.damaged("size") }
            size = value
        }
        return (prefix.isEmpty ? name : prefix + "/" + name, size, bytes[156])
    }

    private static func string(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func octal(_ bytes: ArraySlice<UInt8>) -> UInt64? {
        let text = string(bytes).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        if text.isEmpty { return 0 }
        return UInt64(text, radix: 8)
    }

    // MARK: Reading

    /// The members of a backup file, reading headers only.
    static func members(of url: URL) throws -> [Member] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        var offset: UInt64 = 0
        var members: [Member] = []
        while offset + UInt64(blockSize) <= length {
            try handle.seek(toOffset: offset)
            guard let block = try handle.read(upToCount: blockSize), block.count == blockSize else { break }
            guard let header = try parseHeader(block) else { break }
            let start = offset + UInt64(blockSize)
            guard start + header.size <= length else { throw Problem.damaged("\(header.name) is cut short") }
            if header.typeflag == UInt8(ascii: "0") || header.typeflag == 0 {
                members.append(Member(name: header.name, offset: start, size: header.size))
            }
            offset = start + header.size + UInt64(padding(for: header.size))
        }
        return members
    }

    static func read(_ member: Member, from url: URL, limit: UInt64 = 64 << 20) throws -> Data {
        guard member.size <= limit else { throw Problem.damaged("\(member.name) is too large") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: member.offset)
        let data = try handle.read(upToCount: Int(member.size)) ?? Data()
        guard data.count == Int(member.size) else { throw Problem.damaged("\(member.name) is cut short") }
        return data
    }

    /// The manifest and where the Linux payload is.
    struct Contents {
        let manifest: BackupManifest
        let payload: Member
        let members: [Member]
        let fileSize: UInt64
    }

    static func contents(of url: URL) throws -> Contents {
        let members: [Member]
        do {
            members = try self.members(of: url)
        } catch Problem.damaged(let detail) where detail == "checksum" {
            throw Problem.notABackup
        }
        guard let first = members.first, first.name == BackupManifest.memberName else { throw Problem.notABackup }
        let manifest = try BackupManifest.decode(read(first, from: url, limit: 4 << 20))
        guard let payload = members.first(where: { $0.name == manifest.compression.payloadName }) else {
            throw Problem.damaged("no Linux files in it")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        return Contents(manifest: manifest, payload: payload, members: members, fileSize: size)
    }
}

/// Writes the host's part of a backup file, leaving the payload's header for `finish`.
final class BackupArchiveWriter {
    private let handle: FileHandle
    private(set) var payloadHeaderOffset: UInt64?

    init(url: URL) throws {
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
    }

    deinit { try? handle.close() }

    func add(name: String, data: Data, mtime: Date = Date()) throws {
        try handle.write(contentsOf: BackupArchive.header(name: name, size: UInt64(data.count), mtime: mtime))
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data(count: BackupArchive.padding(for: UInt64(data.count))))
    }

    /// Writes a zeroed block where the payload's header goes; the payload follows it.
    func reservePayloadHeader() throws {
        payloadHeaderOffset = try handle.offset()
        try handle.write(contentsOf: Data(count: BackupArchive.blockSize))
        try handle.synchronize()
    }

    func close() throws { try handle.close() }

    /// After the guest appended the payload: its header, padding and the end-of-archive blocks.
    static func finish(url: URL, payloadName: String, headerOffset: UInt64, mtime: Date = Date()) throws -> UInt64 {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let start = headerOffset + UInt64(BackupArchive.blockSize)
        guard end >= start else { throw BackupArchive.Problem.damaged("payload missing") }
        let size = end - start
        try handle.write(contentsOf: Data(count: BackupArchive.padding(for: size) + 2 * BackupArchive.blockSize))
        try handle.seek(toOffset: headerOffset)
        try handle.write(contentsOf: BackupArchive.header(name: payloadName, size: size, mtime: mtime))
        try handle.synchronize()
        return size
    }
}
