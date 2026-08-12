import Foundation

/// How much one write request may carry.
public struct WriteLimits: Hashable, Sendable {
    /// Used when the server does not say. Deliberately far below anything a
    /// real deployment declares.
    public static let fallbackRecords = 1000
    /// The server accepts a body up to 40 MiB and answers 413 above it — and
    /// well above it does not answer at all, it drops the connection.
    /// A cap below that keeps failures inside the HTTP conversation, where they
    /// can be read, instead of surfacing as a broken socket.
    public static let defaultBodyBytes = 32 * 1024 * 1024

    public var maxRecords: Int
    public var maxBodyBytes: Int
    /// False when `maxRecords` is our fallback rather than the server's answer.
    /// The connection card says which one it is: a guessed limit that happens
    /// to be too high fails much later, at write time.
    public var isReportedByServer: Bool

    public init(
        maxRecords: Int = WriteLimits.fallbackRecords,
        maxBodyBytes: Int = WriteLimits.defaultBodyBytes,
        isReportedByServer: Bool = false
    ) {
        self.maxRecords = max(1, maxRecords)
        self.maxBodyBytes = max(1024, maxBodyBytes)
        self.isReportedByServer = isReportedByServer
    }
}

public enum BatchSplitError: LocalizedError, Equatable {
    /// One record that does not fit on its own. Splitting further is
    /// impossible, so this is an error and not a smaller batch.
    case recordTooLarge(id: String, bytes: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .recordTooLarge(let id, let bytes, let limit):
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            let cap = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            return String(localized: "Запись «\(id)» весит \(size) — больше предельного размера запроса (\(cap)). Разбить её на части автоматически нельзя.")
        }
    }

    public var recoverySuggestion: String? {
        String(localized: "Уменьшите размер документа или включите чанкинг для источника.")
    }
}

/// Cuts a write into requests the server will accept.
///
/// Two limits at once, because either one alone lets the other through: a
/// thousand rows of 1024-dimensional vectors is tens of megabytes of JSON, and
/// a body that large fails long before the row count does.
public enum BatchSplitter {
    /// Braces, key names and the array brackets around the four parallel lists.
    private static let envelopeBytes = 128

    public static func split(_ records: [EmbeddedRecord], limits: WriteLimits) throws -> [[EmbeddedRecord]] {
        guard !records.isEmpty else { return [] }

        var batches: [[EmbeddedRecord]] = []
        var current: [EmbeddedRecord] = []
        var currentBytes = envelopeBytes

        for record in records {
            let bytes = estimatedBytes(of: record)
            guard bytes + envelopeBytes <= limits.maxBodyBytes else {
                throw BatchSplitError.recordTooLarge(id: record.id, bytes: bytes, limit: limits.maxBodyBytes)
            }
            let full = current.count >= limits.maxRecords || currentBytes + bytes > limits.maxBodyBytes
            if full, !current.isEmpty {
                batches.append(current)
                current = []
                currentBytes = envelopeBytes
            }
            current.append(record)
            currentBytes += bytes
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// An upper bound on the JSON this record adds to a request body.
    ///
    /// An estimate rather than a measurement: serialising every record twice to
    /// find out how to split them would double the cost of every write. It errs
    /// high on purpose — under-estimating means a 413 from the server, while
    /// over-estimating only means one extra request.
    public static func estimatedBytes(of record: EmbeddedRecord) -> Int {
        var total = jsonStringBytes(record.id) + 1
        total += jsonStringBytes(record.document) + 1
        // Longest shortest-round-trip form of a Double is 24 characters
        // ("-1.2345678901234567e-05"), plus the separator.
        total += record.embedding.count * 25 + 2
        total += 2
        for (key, value) in record.metadata {
            total += jsonStringBytes(key) + 2
            switch value {
            case .string(let text): total += jsonStringBytes(text)
            case .int, .double: total += 25
            case .bool: total += 5
            case .null: total += 4
            }
        }
        return total
    }

    /// Exactly what JSONSerialization writes for a string: quotes, plus two
    /// bytes for an escaped quote or backslash and six for a control character.
    /// Non-ASCII goes out as raw UTF-8 and costs its own length.
    private static func jsonStringBytes(_ value: String) -> Int {
        var total = 2
        for byte in value.utf8 {
            if byte == 0x22 || byte == 0x5C {
                total += 2
            } else if byte < 0x20 {
                total += 6
            } else {
                total += 1
            }
        }
        return total
    }
}
