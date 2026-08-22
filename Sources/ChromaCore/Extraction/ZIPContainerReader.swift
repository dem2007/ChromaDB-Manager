import Foundation
import Compression

/// One entry of an archive, as the central directory describes it.
public struct ZIPEntry: Hashable, Sendable {
    /// Normalised, `/`-separated, relative to the root of the archive.
    public let path: String
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let compressionMethod: UInt16
    /// Offset of the local header — where the data has to be found from.
    public let localHeaderOffset: UInt64
    public let isDirectory: Bool

    public var isStored: Bool { compressionMethod == 0 }
    public var isDeflated: Bool { compressionMethod == 8 }
}

public enum ZIPError: LocalizedError, Equatable {
    case notAnArchive
    case truncated
    /// Recognised and refused rather than half-read.
    case zip64Unsupported
    case unsupportedMethod(UInt16)
    case entryNotFound(String)
    case entryTooLarge(path: String, size: Int, limit: Int)
    case archiveTooLarge(size: Int, limit: Int)
    /// A path that climbs out of the archive: `../..`, or an absolute one.
    case pathEscapesRoot(String)
    case corruptedEntry(String)

    public var errorDescription: String? {
        switch self {
        case .notAnArchive:
            return String(localized: "файл не похож на ZIP-архив")
        case .truncated:
            return String(localized: "архив обрезан или повреждён")
        case .zip64Unsupported:
            return String(localized: "архив в формате ZIP64 не поддерживается")
        case .unsupportedMethod(let method):
            return String(localized: "метод сжатия \(Int(method).plainDigits) не поддерживается")
        case .entryNotFound(let path):
            return String(localized: "в архиве нет записи «\(path)»")
        case .entryTooLarge(let path, let size, let limit):
            return String(localized: "запись «\(path)» в распакованном виде больше предела (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) при пределе \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)))")
        case .archiveTooLarge(let size, let limit):
            return String(localized: "архив в распакованном виде больше предела (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) при пределе \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)))")
        case .pathEscapesRoot(let path):
            return String(localized: "путь записи выходит за пределы архива: «\(path)»")
        case .corruptedEntry(let path):
            return String(localized: "запись «\(path)» не распаковывается")
        }
    }
}

/// Reads entries out of an existing ZIP archive. Nothing else.
///
/// Creating, changing or deleting entries, encryption and multi-volume archives
/// are not implemented at all — EPUB and iWork need a reader, and every one of
/// those would be a way to corrupt a file the app does not own.
///
/// **Read through a `FileHandle`, never by loading the archive.** A Keynote
/// container can weigh hundreds of megabytes; only the entries actually asked
/// for reach memory.
public final class ZIPContainerReader {
    public struct Limits: Sendable {
        /// Per entry, uncompressed.
        public var maxEntrySize: Int
        /// The whole archive, uncompressed, as the directory declares it.
        public var maxTotalSize: Int

        public init(maxEntrySize: Int = 200 * 1024 * 1024, maxTotalSize: Int = 2 * 1024 * 1024 * 1024) {
            self.maxEntrySize = maxEntrySize
            self.maxTotalSize = maxTotalSize
        }
    }

    private let handle: FileHandle
    private let fileSize: UInt64
    private let limits: Limits
    public let entries: [ZIPEntry]

    /// How far back the End of Central Directory record is looked for. It sits
    /// at the very end unless the archive carries a comment, which can be up to
    /// 64 KB long.
    static let eocdSearchWindow = 64 * 1024 + 22

    public init(url: URL, limits: Limits = Limits()) throws {
        self.limits = limits
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ZIPError.notAnArchive
        }
        self.handle = handle
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        self.fileSize = size

        do {
            let directory = try Self.locateCentralDirectory(handle: handle, fileSize: size)
            self.entries = try Self.readCentralDirectory(handle: handle, directory: directory)
        } catch {
            try? handle.close()
            throw error
        }

        let total = entries.reduce(0) { $0 + $1.uncompressedSize }
        guard total <= limits.maxTotalSize else {
            try? handle.close()
            throw ZIPError.archiveTooLarge(size: total, limit: limits.maxTotalSize)
        }
    }

    deinit { try? handle.close() }

    public func entry(at path: String) -> ZIPEntry? {
        entries.first { $0.path == path }
    }

    public func contains(_ path: String) -> Bool { entry(at: path) != nil }

    /// The entry's bytes, decompressed. For the small entries of EPUB and iWork;
    /// a spreadsheet's worth of XML is stage 5's streaming job.
    public func read(_ path: String) throws -> Data {
        guard let entry = entry(at: path) else { throw ZIPError.entryNotFound(path) }
        return try read(entry)
    }

    public func read(_ entry: ZIPEntry) throws -> Data {
        guard entry.uncompressedSize <= limits.maxEntrySize else {
            throw ZIPError.entryTooLarge(path: entry.path, size: entry.uncompressedSize, limit: limits.maxEntrySize)
        }
        guard entry.uncompressedSize > 0 else { return Data() }

        // The local header is read for the name and extra lengths **only**: they
        // are allowed to differ from the directory's, and the data starts after
        // them. Everything else — sizes above all — comes from the directory.
        let header = try readBytes(at: entry.localHeaderOffset, count: 30)
        guard header.count == 30, Self.uint32(header, 0) == 0x0403_4b50 else {
            throw ZIPError.corruptedEntry(entry.path)
        }
        let nameLength = Int(Self.uint16(header, 26))
        let extraLength = Int(Self.uint16(header, 28))
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(nameLength) + UInt64(extraLength)

        let compressed = try readBytes(at: dataOffset, count: entry.compressedSize)
        guard compressed.count == entry.compressedSize else { throw ZIPError.truncated }

        if entry.isStored {
            guard compressed.count == entry.uncompressedSize else { throw ZIPError.corruptedEntry(entry.path) }
            return compressed
        }
        guard entry.isDeflated else { throw ZIPError.unsupportedMethod(entry.compressionMethod) }
        return try Self.inflate(compressed, expecting: entry.uncompressedSize, path: entry.path)
    }

    // MARK: - Deflate

    /// `COMPRESSION_ZLIB` in the Compression framework is **raw deflate**, with
    /// no zlib wrapper — exactly what a ZIP entry holds.
    static func inflate(_ data: Data, expecting size: Int, path: String) throws -> Data {
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase, size,
                    sourceBase, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { throw ZIPError.corruptedEntry(path) }
        return output
    }

    // MARK: - Central directory

    private struct Directory {
        let offset: UInt64
        let size: Int
        let count: Int
    }

    private static func locateCentralDirectory(handle: FileHandle, fileSize: UInt64) throws -> Directory {
        guard fileSize >= 22 else { throw ZIPError.notAnArchive }
        let windowSize = Int(min(UInt64(eocdSearchWindow), fileSize))
        let windowStart = fileSize - UInt64(windowSize)
        guard let window = try? readBytes(handle: handle, at: windowStart, count: windowSize), window.count == windowSize else {
            throw ZIPError.truncated
        }

        // From the end — but finding the signature is not enough. The comment
        // that follows the record can contain anything, including these four
        // bytes, and searching backwards would then stop at the decoy. The
        // record is the one whose own comment length reaches exactly the end of
        // the file.
        var eocd: Int?
        var index = window.count - 22
        while index >= 0 {
            if uint32(window, index) == 0x0605_4b50 {
                let commentLength = Int(uint16(window, index + 20))
                if index + 22 + commentLength == window.count {
                    eocd = index
                    break
                }
            }
            index -= 1
        }
        guard let start = eocd else {
            // A ZIP64 archive still carries a classic EOCD; no EOCD at all means
            // this is not a ZIP.
            throw ZIPError.notAnArchive
        }

        // ZIP64: the classic record cannot express these, and the real values
        // live in a record we deliberately do not read.
        let count = uint16(window, start + 10)
        let size = uint32(window, start + 12)
        let offset = uint32(window, start + 16)
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
            throw ZIPError.zip64Unsupported
        }
        if window.count >= 20, findZIP64Locator(window) {
            throw ZIPError.zip64Unsupported
        }

        guard UInt64(offset) + UInt64(size) <= fileSize else { throw ZIPError.truncated }
        return Directory(offset: UInt64(offset), size: Int(size), count: Int(count))
    }

    private static func findZIP64Locator(_ window: Data) -> Bool {
        var index = window.count - 20
        while index >= 0 {
            if uint32(window, index) == 0x0706_4b50 { return true }
            index -= 1
        }
        return false
    }

    private static func readCentralDirectory(handle: FileHandle, directory: Directory) throws -> [ZIPEntry] {
        guard let data = try? readBytes(handle: handle, at: directory.offset, count: directory.size),
              data.count == directory.size else {
            throw ZIPError.truncated
        }

        var entries: [ZIPEntry] = []
        var cursor = 0
        while cursor + 46 <= data.count {
            guard uint32(data, cursor) == 0x0201_4b50 else { break }
            let flags = uint16(data, cursor + 8)
            let method = uint16(data, cursor + 10)
            let compressedSize = uint32(data, cursor + 20)
            let uncompressedSize = uint32(data, cursor + 24)
            let nameLength = Int(uint16(data, cursor + 28))
            let extraLength = Int(uint16(data, cursor + 30))
            let commentLength = Int(uint16(data, cursor + 32))
            let localOffset = uint32(data, cursor + 42)

            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { throw ZIPError.truncated }
            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw ZIPError.zip64Unsupported
            }

            let rawName = data.subdata(in: nameStart..<(nameStart + nameLength))
            if let name = entryName(rawName, declaresUTF8: (flags & 0x800) != 0) {
                let normalised = try normalise(name)
                entries.append(ZIPEntry(
                    path: normalised,
                    compressedSize: Int(compressedSize),
                    uncompressedSize: Int(uncompressedSize),
                    compressionMethod: method,
                    localHeaderOffset: UInt64(localOffset),
                    isDirectory: name.hasSuffix("/")
                ))
            }
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Имя записи из байтов заголовка.
    ///
    /// Бит 11 обещает UTF-8. Без него имя формально в CP437, но русские
    /// архиваторы кладут туда CP866 — и это единственный случай, когда байты
    /// не разбираются как UTF-8. Прежде такое имя читалось как Latin-1 и
    /// превращалось в «ЊбзЈв» вместо «Отчёт»: обе кодировки однобайтовые,
    /// поэтому ошибка не всплывала нигде — имя просто приезжало неверным.
    ///
    /// Флаг выставлен, а UTF-8 не разбирается — запись пропускается, как и
    /// раньше: угадывать вопреки объявленному незачем.
    static func entryName(_ raw: Data, declaresUTF8: Bool) -> String? {
        if let utf8 = String(data: raw, encoding: .utf8) { return utf8 }
        guard !declaresUTF8 else { return nil }
        return String(data: raw, encoding: FileNameEncoding.dosRussian)
            ?? String(data: raw, encoding: .isoLatin1)
    }

    /// Zip-slip. The path is never written to disk here, but it *is*
    /// matched against references from the OPF, so a `../` that survives
    /// normalisation would point at something outside the book.
    static func normalise(_ path: String) throws -> String {
        let unified = path.replacingOccurrences(of: "\\", with: "/")
        guard !unified.hasPrefix("/") else { throw ZIPError.pathEscapesRoot(path) }
        var stack: [String] = []
        for component in unified.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !stack.isEmpty else { throw ZIPError.pathEscapesRoot(path) }
                stack.removeLast()
            default:
                stack.append(String(component))
            }
        }
        return stack.joined(separator: "/") + (unified.hasSuffix("/") ? "/" : "")
    }

    // MARK: - Bytes

    private func readBytes(at offset: UInt64, count: Int) throws -> Data {
        guard offset + UInt64(max(0, count)) <= fileSize else { throw ZIPError.truncated }
        return try Self.readBytes(handle: handle, at: offset, count: count)
    }

    private static func readBytes(handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0 else { throw ZIPError.truncated }
        guard count > 0 else { return Data() }
        try handle.seek(toOffset: offset)
        return (try handle.read(upToCount: count)) ?? Data()
    }

    /// Little-endian reads that refuse to walk off the end instead of trapping.
    static func uint16(_ data: Data, _ index: Int) -> UInt16 {
        guard index >= 0, index + 2 <= data.count else { return 0 }
        let base = data.startIndex + index
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    static func uint32(_ data: Data, _ index: Int) -> UInt32 {
        guard index >= 0, index + 4 <= data.count else { return 0 }
        let base = data.startIndex + index
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
