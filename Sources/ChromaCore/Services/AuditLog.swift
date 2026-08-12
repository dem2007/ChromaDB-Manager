import Foundation

/// Чем именно пришёл запрос.
///
/// Прокси и MCP-сервер пишут в один журнал: это один и тот же вопрос — «что
/// делали с базой чужими руками», — и разводить его по двум файлам значило бы
/// заставить владельца сверять их глазами.
public enum AuditTransport: String, Codable, Sendable {
    case http
    case mcp

    public var title: String {
        switch self {
        case .http: return String(localized: "прокси")
        case .mcp: return String(localized: "MCP")
        }
    }
}

/// One proxied request.
public struct AuditEntry: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var date: Date
    /// Who asked. In 3B this is the peer address; 3C replaces it with the name
    /// of the registered client whose key was presented.
    public var client: String
    public var method: String
    public var path: String
    public var operation: String
    public var access: ChromaRoute.Access
    /// UUID or name, exactly as it appeared in the path.
    public var collection: String?
    public var requestBytes: Int
    public var responseStatus: Int?
    public var responseBytes: Int
    public var durationSeconds: Double
    /// Set when the proxy itself refused or could not complete the request.
    public var note: String?
    /// Каким транспортом пришёл запрос. У записей, сделанных до появления
    /// поля, транспорт один — прокси.
    public var transport: AuditTransport
    /// Полный текст параметров вызова. Только у MCP: у прокси эту роль
    /// играет тело запроса, которое в журнал не попадает.
    ///
    /// Хранится с маскированием секретов — как и всё остальное в этом файле.
    public var parameters: String?

    public init(
        date: Date = Date(),
        client: String,
        method: String,
        path: String,
        operation: String,
        access: ChromaRoute.Access,
        collection: String?,
        requestBytes: Int,
        responseStatus: Int?,
        responseBytes: Int,
        durationSeconds: Double,
        note: String? = nil,
        transport: AuditTransport = .http,
        parameters: String? = nil
    ) {
        self.transport = transport
        self.parameters = parameters
        self.date = date
        self.client = client
        self.method = method
        self.path = path
        self.operation = operation
        self.access = access
        self.collection = collection
        self.requestBytes = requestBytes
        self.responseStatus = responseStatus
        self.responseBytes = responseBytes
        self.durationSeconds = durationSeconds
        self.note = note
    }

    /// Записи, сделанные до появления поля транспорта, пришли через прокси —
    /// другого тогда не было.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? nil) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        client = try container.decode(String.self, forKey: .client)
        method = try container.decode(String.self, forKey: .method)
        path = try container.decode(String.self, forKey: .path)
        operation = try container.decode(String.self, forKey: .operation)
        access = try container.decode(ChromaRoute.Access.self, forKey: .access)
        collection = try container.decodeIfPresent(String.self, forKey: .collection)
        requestBytes = try container.decode(Int.self, forKey: .requestBytes)
        responseStatus = try container.decodeIfPresent(Int.self, forKey: .responseStatus)
        responseBytes = try container.decode(Int.self, forKey: .responseBytes)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        transport = ((try? container.decodeIfPresent(AuditTransport.self, forKey: .transport)) ?? nil) ?? .http
        parameters = (try? container.decodeIfPresent(String.self, forKey: .parameters)) ?? nil
    }

    public var isWrite: Bool { access == .write }

    /// Что именно сделали — одной строкой для журнала на экране.
    public var title: String {
        switch transport {
        case .http: return ChromaRoute.parse(method: method, path: path).title
        // У MCP операция — имя инструмента, и оно уже сказано так, как его
        // видит агент. Разбирать его в маршрут ChromaDB было бы враньём:
        // такого маршрута не было.
        case .mcp: return String(localized: "инструмент \(operation)")
        }
    }

    public var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(requestBytes + responseBytes), countStyle: .file)
    }
}

/// An audit file that has been rotated out of the way.
public struct AuditArchive: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let createdAt: Date
    public let bytes: Int

    public var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Append-only record of everything that went through the proxy.
///
/// The spec asks for a log of write operations. Reads are recorded too
/// and hidden behind a filter by default: while the proxy is being brought up
/// the question is «does traffic flow at all», and once permissions exist a
/// *refused read* is exactly the event worth seeing.
///
/// Stored as JSON Lines — one self-contained line per entry, so a crash in the
/// middle of a write costs the last line and not the file.
@MainActor
public final class AuditLog: ObservableObject {
    /// Newest first, capped: this is the screen's buffer, the file is the record.
    @Published public private(set) var entries: [AuditEntry] = []

    private let fileURL: URL
    private let memoryLimit: Int
    private let maximumFileBytes: Int
    private let writeQueue = DispatchQueue(label: "io.github.chromadbmanager.audit")
    private let log: LogHandler

    public init(
        fileURL: URL = AppPaths.auditLogFile,
        memoryLimit: Int = 2000,
        maximumFileBytes: Int = 8 * 1024 * 1024,
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.fileURL = fileURL
        self.memoryLimit = memoryLimit
        self.maximumFileBytes = maximumFileBytes
        self.log = log
        entries = Self.load(from: fileURL, limit: memoryLimit)
    }

    public var logFileURL: URL { fileURL }

    /// Callable from the proxy's own queues.
    public nonisolated func record(_ entry: AuditEntry) {
        // Masking happens before anything is stored, so an archive can never
        // hold a secret the live view would have hidden.
        var entry = entry
        entry.path = SecretRegistry.shared.mask(entry.path)
        entry.client = SecretRegistry.shared.mask(entry.client)
        entry.note = entry.note.map { SecretRegistry.shared.mask($0) }
        entry.parameters = entry.parameters.map { SecretRegistry.shared.mask($0) }
        appendToFile(entry)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.memoryLimit {
                self.entries.removeLast(self.entries.count - self.memoryLimit)
            }
        }
    }

    /// Archives the current file instead of deleting it.
    ///
    /// «Очистить» on an audit log used to mean «стереть», which is the one
    /// thing an audit log must not do on its own. The screen is cleared, the
    /// record is kept under a dated name, and removing archives is a separate,
    /// deliberate action.
    public func archiveCurrent() {
        entries.removeAll()
        writeQueue.async { [fileURL] in
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let archive = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(fileURL.deletingPathExtension().lastPathComponent)-\(formatter.string(from: Date())).jsonl")
            try? FileManager.default.moveItem(at: fileURL, to: archive)
        }
        log(.warning, "Аудит", "Журнал доступа заархивирован — записи сохранены в архиве, а не удалены")
    }

    /// Archived audit files, newest first.
    public func archives() -> [AuditArchive] {
        let directory = fileURL.deletingLastPathComponent()
        let prefix = fileURL.deletingPathExtension().lastPathComponent + "-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".jsonl") }
            .map { name -> AuditArchive in
                let url = directory.appendingPathComponent(name)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return AuditArchive(
                    url: url,
                    createdAt: (attributes?[.creationDate] as? Date) ?? Date.distantPast,
                    bytes: (attributes?[.size] as? Int) ?? 0
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Only ever called from an explicit, confirmed user action.
    public func removeArchive(_ archive: AuditArchive) {
        try? FileManager.default.removeItem(at: archive.url)
        log(.warning, "Аудит", "Архив журнала удалён пользователем: \(archive.url.lastPathComponent)")
    }

    /// Entries matching the screen's filters, newest first.
    public func filtered(writesOnly: Bool, collection: String?, search: String) -> [AuditEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return entries.filter { entry in
            if writesOnly && !entry.isWrite { return false }
            if let collection, entry.collection != collection { return false }
            guard !query.isEmpty else { return true }
            return entry.path.localizedCaseInsensitiveContains(query)
                || entry.client.localizedCaseInsensitiveContains(query)
                || entry.operation.localizedCaseInsensitiveContains(query)
                || (entry.collection?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    public var collections: [String] {
        Array(Set(entries.compactMap { $0.collection })).sorted()
    }

    /// CSV, because the point of an export is to open it somewhere else.
    public func exportCSV(_ rows: [AuditEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        var text = "date,client,method,operation,access,collection,status,request_bytes,response_bytes,seconds,note\n"
        for row in rows {
            let fields = [
                formatter.string(from: row.date),
                row.client,
                row.method,
                row.operation,
                row.access.rawValue,
                row.collection ?? "",
                row.responseStatus.map(String.init) ?? "",
                String(row.requestBytes),
                String(row.responseBytes),
                String(format: "%.3f", row.durationSeconds),
                row.note ?? "",
            ]
            text += fields.map(Self.escapeCSV).joined(separator: ",") + "\n"
        }
        return text
    }

    /// JSON, for whatever reads it after CSV turns out to be too flat.
    public func exportJSON(_ rows: [AuditEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(rows) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func escapeCSV(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - File

    private nonisolated func appendToFile(_ entry: AuditEntry) {
        writeQueue.async { [fileURL, maximumFileBytes] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard var data = try? encoder.encode(entry) else { return }
            data.append(0x0A)

            _ = try? AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: data)
                return
            }
            // Rotation here means **archiving**, never overwriting: the file
            // is moved aside under a dated name and a new one started. Nothing
            // is deleted without the user asking.
            if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
               size > maximumFileBytes {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                let archive = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("\(fileURL.deletingPathExtension().lastPathComponent)-\(formatter.string(from: Date())).jsonl")
                try? FileManager.default.moveItem(at: fileURL, to: archive)
                FileManager.default.createFile(atPath: fileURL.path, contents: data)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private static func load(from url: URL, limit: Int) -> [AuditEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A truncated last line is normal after a crash and must not cost the
        // whole file, so lines are decoded one by one and failures skipped.
        return text
            .split(separator: "\n")
            .suffix(limit)
            .compactMap { try? decoder.decode(AuditEntry.self, from: Data($0.utf8)) }
            .reversed()
    }
}
