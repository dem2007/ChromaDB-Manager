import Foundation
import CryptoKit
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Vectors already computed by a local model, kept so they are not computed
/// twice.
///
/// The local model is the scarcest resource in the app, and the same text is
/// embedded again in four ordinary situations: tuning chunking parameters
/// (shifting the overlap moves some boundaries and leaves most chunks alone),
/// re-extraction that produced identical text, cloning a collection onto the
/// same model, and the evaluation bench running one query across many variants.
///
/// Transparent by design: `LMStudioClient` consults it, and nothing else in the
/// app knows it exists.
public actor EmbeddingCache {
    public struct Statistics: Sendable, Equatable {
        public let entries: Int
        public let bytes: Int64
        /// Since the app started — the honest way to tell whether the cache is
        /// doing anything (8.8).
        public let hits: Int
        public let misses: Int

        public var hitRate: Double {
            let total = hits + misses
            return total > 0 ? Double(hits) / Double(total) : 0
        }

        public var sizeText: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    public static let defaultLimitBytes: Int64 = 2 * 1024 * 1024 * 1024

    private var handle: OpaquePointer?
    private let fileURL: URL
    private let log: LogHandler
    private var limitBytes: Int64
    private var hits = 0
    private var misses = 0
    /// Written bytes since the last eviction sweep, so the sweep does not run on
    /// every insert.
    private var bytesSinceSweep: Int64 = 0

    /// False when the database could not be opened or is damaged: the app keeps
    /// working without a cache rather than refusing to embed anything.
    public private(set) var isAvailable = false

    public init(
        fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("embedding-cache.sqlite3"),
        limitBytes: Int64 = EmbeddingCache.defaultLimitBytes,
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.fileURL = fileURL
        self.limitBytes = limitBytes
        self.log = log
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    // MARK: - Opening

    public func open() {
        guard handle == nil else { return }
        do {
            try AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
        } catch {
            log(.warning, "Кэш", "Каталог кэша эмбеддингов недоступен — кэш выключен: \(error.localizedDescription)")
            return
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let database else {
            log(.warning, "Кэш", "Кэш эмбеддингов не открылся — работаем без него")
            if let database { sqlite3_close(database) }
            return
        }
        handle = database

        let schema = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS vectors (
            key TEXT PRIMARY KEY,
            model TEXT NOT NULL,
            dimension INTEGER NOT NULL,
            vector BLOB NOT NULL,
            bytes INTEGER NOT NULL,
            accessed_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS vectors_accessed ON vectors(accessed_at);
        """
        if execute(schema) {
            isAvailable = true
            return
        }

        // A damaged file is not worth a dialog: it holds nothing but copies of
        // work that can be redone.
        log(.warning, "Кэш", "Кэш эмбеддингов повреждён — файл будет создан заново")
        sqlite3_close(database)
        handle = nil
        try? FileManager.default.removeItem(at: fileURL)

        var retry: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &retry, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let retry else {
            if let retry { sqlite3_close(retry) }
            log(.warning, "Кэш", "Кэш эмбеддингов выключен: базу не удалось создать")
            return
        }
        handle = retry
        if execute(schema) {
            isAvailable = true
        } else {
            sqlite3_close(retry)
            handle = nil
            log(.warning, "Кэш", "Кэш эмбеддингов выключен: базу не удалось создать")
        }
    }

    public func setLimit(bytes: Int64) {
        limitBytes = max(0, bytes)
        evictIfNeeded(force: true)
    }

    // MARK: - Keys

    /// `sha256(model_id + ":" + normalized_text)`.
    ///
    /// Normalisation is deliberately minimal — line endings and trailing
    /// whitespace only. Anything more aggressive would hand back the vector of a
    /// *different* text.
    public static func key(model: String, text: String) -> String {
        let normalized = normalize(text)
        let digest = SHA256.hash(data: Data("\(model):\(normalized)".utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                var line = String(line)
                while let last = line.last, last == " " || last == "\t" { line.removeLast() }
                return line
            }
            .joined(separator: "\n")
    }

    // MARK: - Reading and writing

    /// The dimension is **not** part of the key — at lookup time the vector does
    /// not exist yet and nobody knows it. It is a column instead, checked right
    /// after the read: a mismatch means the model behind this name changed, so
    /// the entry is dropped and the vector recomputed.
    public func vector(model: String, text: String, expectedDimension: Int? = nil) -> [Double]? {
        guard isAvailable, let handle else { return nil }
        let key = Self.key(model: model, text: text)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT dimension, vector FROM vectors WHERE key = ?", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            misses += 1
            return nil
        }
        let dimension = Int(sqlite3_column_int64(statement, 0))
        if let expectedDimension, dimension != expectedDimension {
            log(.warning, "Кэш", "Размерность в кэше (\(dimension.plainDigits)) не совпала с ожидаемой (\(expectedDimension.plainDigits)) — запись удалена, вектор будет пересчитан")
            remove(key: key)
            misses += 1
            return nil
        }
        guard let blob = sqlite3_column_blob(statement, 1) else {
            misses += 1
            return nil
        }
        let byteCount = Int(sqlite3_column_bytes(statement, 1))
        let data = Data(bytes: blob, count: byteCount)
        guard let vector = Self.decode(data), vector.count == dimension else {
            remove(key: key)
            misses += 1
            return nil
        }

        touch(key: key)
        hits += 1
        return vector
    }

    public func store(model: String, text: String, vector: [Double]) {
        guard isAvailable, let handle, !vector.isEmpty else { return }
        let key = Self.key(model: model, text: text)
        let data = Self.encode(vector)

        var statement: OpaquePointer?
        let sql = """
        INSERT INTO vectors (key, model, dimension, vector, bytes, accessed_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET accessed_at = excluded.accessed_at
        """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, model, -1, sqliteTransient)
        sqlite3_bind_int64(statement, 3, Int64(vector.count))
        _ = data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, 4, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
        }
        sqlite3_bind_int64(statement, 5, Int64(data.count))
        sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { return }

        bytesSinceSweep += Int64(data.count)
        evictIfNeeded(force: false)
    }

    /// Everything ever computed by one model. Used when the model behind a name
    /// turns out to have changed: its old vectors are not merely stale, they are
    /// answers from a different model.
    public func removeAll(model: String) {
        guard isAvailable, let handle else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "DELETE FROM vectors WHERE model = ?", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, model, -1, sqliteTransient)
        _ = sqlite3_step(statement)
        log(.warning, "Кэш", "Из кэша удалены все векторы модели \(model)")
    }

    public func clear() {
        guard isAvailable else { return }
        _ = execute("DELETE FROM vectors")
        _ = execute("VACUUM")
        hits = 0
        misses = 0
        log(.info, "Кэш", "Кэш эмбеддингов очищен")
    }

    public func statistics() -> Statistics {
        // Кэш открывает фоновая задача при старте приложения, и первый вопрос
        // о нём может прийти раньше, чем она отработает. До открытия
        // `SUM(bytes)` возвращает ноль, а ноль неотличим от пустого кэша:
        // плашка «Обзора» показывала 0 КБ при 489,9 МБ на диске. Открытие
        // идемпотентно, поэтому спросить — значит и открыть.
        if !isAvailable { open() }
        return Statistics(entries: count(), bytes: storedBytes(), hits: hits, misses: misses)
    }

    /// For the run report: «из N эмбеддингов взято из кэша M» (8.8).
    public func resetCounters() {
        hits = 0
        misses = 0
    }

    // MARK: - Eviction

    /// Oldest by **last use**, not by age: a text embedded once a year ago and
    /// read yesterday is more valuable than one written yesterday and never read.
    private func evictIfNeeded(force: Bool) {
        guard isAvailable else { return }
        // A sweep costs a SUM over the table; doing it on every insert would be
        // a bigger tax than the eviction it saves.
        guard force || bytesSinceSweep > limitBytes / 100 else { return }
        bytesSinceSweep = 0

        let total = storedBytes()
        guard total > limitBytes else { return }
        // Down to nine tenths of the limit, so the next insert does not start
        // another sweep.
        let target = Int64(Double(limitBytes) * 0.9)

        var freed: Int64 = 0
        var victims: [String] = []
        for candidate in oldestEntries() {
            guard total - freed > target else { break }
            victims.append(candidate.key)
            freed += candidate.bytes
        }
        guard !victims.isEmpty else { return }
        for key in victims { remove(key: key) }
        log(.info, "Кэш", "Кэш эмбеддингов ужат до \(ByteCountFormatter.string(fromByteCount: storedBytes(), countStyle: .file)): вытеснено записей \(victims.count.plainDigits)")
    }

    /// Oldest by **last use**, not by age: a text embedded a year ago and read
    /// yesterday is worth more than one written yesterday and never read again.
    private func oldestEntries() -> [(key: String, bytes: Int64)] {
        guard let handle else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT key, bytes FROM vectors ORDER BY accessed_at ASC", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        var entries: [(key: String, bytes: Int64)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            entries.append((String(cString: text), sqlite3_column_int64(statement, 1)))
        }
        return entries
    }

    // MARK: - Plumbing

    private func touch(key: String) {
        guard let handle else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "UPDATE vectors SET accessed_at = ? WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, key, -1, sqliteTransient)
        _ = sqlite3_step(statement)
    }

    private func remove(key: String) {
        guard let handle else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "DELETE FROM vectors WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
        _ = sqlite3_step(statement)
    }

    private func count() -> Int {
        Int(scalar("SELECT COUNT(*) FROM vectors"))
    }

    private func storedBytes() -> Int64 {
        scalar("SELECT COALESCE(SUM(bytes), 0) FROM vectors")
    }

    private func scalar(_ sql: String) -> Int64 {
        guard isAvailable, let handle else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        guard let handle else { return false }
        return sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    // MARK: - Binary form

    /// `Float`, not `Double`: half the file for the same vectors, and verified
    /// lossless against the live models this app talks to.
    static func encode(_ vector: [Double]) -> Data {
        var data = Data(capacity: vector.count * MemoryLayout<Float>.size)
        for value in vector {
            var float = Float(value)
            withUnsafeBytes(of: &float) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) -> [Double]? {
        let stride = MemoryLayout<Float>.size
        guard data.count % stride == 0 else { return nil }
        var vector: [Double] = []
        vector.reserveCapacity(data.count / stride)
        for offset in Swift.stride(from: 0, to: data.count, by: stride) {
            let float = data.subdata(in: offset..<(offset + stride)).withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            vector.append(Double(float))
        }
        return vector
    }
}
