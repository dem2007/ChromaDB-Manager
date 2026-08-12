import Foundation
import Combine

public struct LogEntry: Identifiable, Hashable {
    public enum Level: String, CaseIterable, Hashable {
        case debug, info, success, warning, error

        /// One character in front of the message.
        ///
        /// Plain glyphs rather than emoji: colour carries the meaning in the
        /// interface, and a log line that is copied or written to a file reads
        /// better without pictures in it.
        public var symbol: String {
            switch self {
            case .debug: return "·"
            case .info: return "•"
            case .success: return "✓"
            case .warning: return "!"
            case .error: return "×"
            }
        }

        public var title: String {
            switch self {
            case .debug: return String(localized: "Отладка")
            case .info: return String(localized: "Инфо")
            case .success: return String(localized: "Успех")
            case .warning: return String(localized: "Предупреждение")
            case .error: return String(localized: "Ошибка")
            }
        }
    }

    public let id = UUID()
    public let date: Date
    public let level: Level
    /// Source of the record: «Сервер», «ChromaDB», «LM Studio», «Установка»…
    public let category: String
    public let message: String

    public init(date: Date = Date(), level: Level, category: String, message: String) {
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }

    public var formatted: String {
        "[\(LogEntry.timeFormatter.string(from: date))] \(level.symbol) [\(category)] \(message)"
    }

    public var fileLine: String {
        "\(LogEntry.fileFormatter.string(from: date)) \(level.rawValue.uppercased()) [\(category)] \(message)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}

/// Values that must never reach the log or a report. The app registers tokens
/// here as soon as it reads them from the Keychain.
public final class SecretRegistry {
    public static let shared = SecretRegistry()

    private let lock = NSLock()
    private var secrets: Set<String> = []

    public func register(_ secret: String?) {
        guard let secret, secret.count >= 4 else { return }
        lock.lock(); secrets.insert(secret); lock.unlock()
    }

    public func forget(_ secret: String) {
        lock.lock(); secrets.remove(secret); lock.unlock()
    }

    public func mask(_ text: String) -> String {
        lock.lock()
        let snapshot = secrets
        lock.unlock()

        var masked = text
        for secret in snapshot {
            masked = masked.replacingOccurrences(of: secret, with: "•••")
        }
        // Catch tokens the app has never seen, e.g. echoed back by a server.
        masked = masked.replacingOccurrences(
            of: #"(?i)(bearer|x-chroma-token:?|token=)\s*[A-Za-z0-9._\-]{6,}"#,
            with: "$1 •••",
            options: .regularExpression
        )
        // Client keys have a shape of their own — `cdbm_` and 48 hex digits —
        // so a whole key is recognisable wherever it appears, even in a line
        // written by code that had no idea it was handling a secret. The
        // 12-character prefix shown in the client list is deliberately shorter
        // than this pattern and survives.
        masked = masked.replacingOccurrences(
            of: #"cdbm_[A-Fa-f0-9]{16,}"#,
            with: "cdbm_•••",
            options: .regularExpression
        )
        return masked
    }
}

/// How much log to keep, on screen and on disk.
public struct LogRetention: Codable, Hashable, Sendable {
    /// Lines the Logs screen holds in memory; the file has the full picture.
    public var inMemoryLines: Int
    public var megabytesPerFile: Int
    public var filesKept: Int

    public init(inMemoryLines: Int = 5000, megabytesPerFile: Int = 10, filesKept: Int = 5) {
        self.inMemoryLines = inMemoryLines
        self.megabytesPerFile = megabytesPerFile
        self.filesKept = filesKept
    }

    /// A hand-edited config must not be able to ask for a zero-line buffer or
    /// an unbounded file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LogRetention()
        func read(_ key: CodingKeys, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
            guard let value = ((try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil),
                  range.contains(value) else { return fallback }
            return value
        }
        inMemoryLines = read(.inMemoryLines, defaults.inMemoryLines, 100...200_000)
        megabytesPerFile = read(.megabytesPerFile, defaults.megabytesPerFile, 1...1024)
        filesKept = read(.filesKept, defaults.filesKept, 1...100)
    }

    public var bytesPerFile: Int { megabytesPerFile * 1024 * 1024 }
}

/// In-app console plus a rolling file in `~/Library/Logs/ChromaDBManager/`.
@MainActor
public final class LogStore: ObservableObject {
    public static let shared = LogStore()

    @Published public private(set) var entries: [LogEntry] = []
    private var limit: Int
    private let fileWriter: LogFileWriter?

    public init(writesToFile: Bool = true, retention: LogRetention = LogRetention()) {
        limit = retention.inMemoryLines
        fileWriter = writesToFile ? LogFileWriter(retention: retention) : nil
    }

    /// Applied when the user changes the setting, without a restart.
    public func apply(_ retention: LogRetention) {
        limit = retention.inMemoryLines
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        fileWriter?.apply(retention)
    }

    public var logFileURL: URL? { fileWriter?.fileURL }

    /// Every distinct source seen so far — feeds the filter in the Logs screen.
    public var categories: [String] {
        Array(Set(entries.map(\.category))).sorted()
    }

    public func append(_ entry: LogEntry) {
        let masked = LogEntry(
            date: entry.date,
            level: entry.level,
            category: entry.category,
            message: SecretRegistry.shared.mask(entry.message)
        )
        entries.append(masked)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        fileWriter?.write(masked.fileLine)
    }

    public func log(_ level: LogEntry.Level, _ category: String, _ message: String) {
        append(LogEntry(level: level, category: category, message: message))
    }

    public func clear() { entries.removeAll() }

    /// Журнал событий текстом — тем же отбором, что видно на экране.
    ///
    /// Поиск здесь не для полноты API: экран отдаёт в файл ровно то, что на
    /// нём показано, иначе сохранённый журнал шире экранного и человек ищет
    /// в нём не то, что видел.
    public func exportText(
        level: LogEntry.Level? = nil, category: String? = nil, search: String = ""
    ) -> String {
        entries
            .filter { entry in
                (level == nil || entry.level == level)
                    && (category == nil || entry.category == category)
                    && (search.isEmpty
                        || entry.message.localizedCaseInsensitiveContains(search)
                        || entry.category.localizedCaseInsensitiveContains(search))
            }
            .map(\.formatted)
            .joined(separator: "\n")
    }

    /// Callable from any thread / any actor; hops to the main actor.
    public nonisolated func record(_ level: LogEntry.Level, _ category: String, _ message: String) {
        let entry = LogEntry(level: level, category: category, message: message)
        Task { @MainActor in self.append(entry) }
    }

    /// Handler handed to services, which never import SwiftUI.
    public nonisolated var handler: LogHandler {
        { [weak self] level, category, message in
            self?.record(level, category, message)
        }
    }
}

/// Appends lines to a per-day log file, rotating it by size. Failures are
/// silent by design: losing a log line must never break the operation that
/// produced it.
final class LogFileWriter {
    let fileURL: URL
    private let queue = DispatchQueue(label: "io.github.chromadbmanager.log", qos: .utility)
    private var retention: LogRetention

    init(retention: LogRetention = LogRetention()) {
        self.retention = retention
        let directory = AppPaths.logsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        fileURL = directory.appendingPathComponent("ChromaDBManager-\(formatter.string(from: Date())).log")

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    func apply(_ retention: LogRetention) {
        queue.async { [weak self] in self?.retention = retention }
    }

    func write(_ line: String) {
        queue.async { [weak self, fileURL] in
            guard let self else { return }
            self.rotateIfNeeded()
            guard let data = (line + "\n").data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// `file.log` → `file.log.1` → … → `file.log.N`, oldest dropped.
    ///
    /// Ordinary logs are allowed to disappear; the audit log is not, and it
    /// rotates by archiving instead.
    private func rotateIfNeeded() {
        let manager = FileManager.default
        guard let size = try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size > retention.bytesPerFile else { return }

        let oldest = fileURL.appendingPathExtension(String(retention.filesKept))
        try? manager.removeItem(at: oldest)
        for index in stride(from: retention.filesKept - 1, through: 1, by: -1) {
            let from = fileURL.appendingPathExtension(String(index))
            guard manager.fileExists(atPath: from.path) else { continue }
            try? manager.removeItem(at: fileURL.appendingPathExtension(String(index + 1)))
            try? manager.moveItem(at: from, to: fileURL.appendingPathExtension(String(index + 1)))
        }
        try? manager.moveItem(at: fileURL, to: fileURL.appendingPathExtension("1"))
        manager.createFile(atPath: fileURL.path, contents: nil)
    }
}

/// What services accept instead of a concrete logger.
///
/// `@Sendable`: журнал зовут из фоновых задач — синхронизация, обход сайта,
/// пересчёт, — и без этой пометки каждая служба, хранящая обработчик, перестаёт
/// быть `Sendable` сама. Требование выполнимое: все обработчики в приложении
/// либо ничего не захватывают, либо переходят на главный поток сами.
public typealias LogHandler = @Sendable (LogEntry.Level, String, String) -> Void

public let noopLogHandler: LogHandler = { _, _, _ in }
