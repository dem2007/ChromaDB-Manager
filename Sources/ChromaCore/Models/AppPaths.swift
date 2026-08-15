import Foundation

/// Every file the app writes lives under
/// `~/Library/Application Support/ChromaDBManager/` — never inside the
/// repository, so user data can not accidentally be committed.
public enum AppPaths {
    public static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ChromaDBManager", isDirectory: true)
    }()

    /// Logs live where macOS expects them, not in Application Support.
    public static let logsDirectory: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/ChromaDBManager", isDirectory: true)
    }()

    /// Output of the `chroma run` child processes, one file per run — kept
    /// apart from the app's own log so a crashed server can be read on its own.
    public static var serverLogsDirectory: URL { logsDirectory.appendingPathComponent("servers", isDirectory: true) }

    /// Everything that went through the proxy, one JSON object per line.
    public static var auditLogFile: URL { logsDirectory.appendingPathComponent("audit.jsonl") }

    public static var configFile: URL { supportDirectory.appendingPathComponent("config.json") }
    /// Metadata schemas: ChromaDB has none of its own, so the rules live here.
    public static var schemasFile: URL { supportDirectory.appendingPathComponent("schemas.json") }
    /// One manifest per data source: what was indexed, when and as which chunks.
    public static var manifestsDirectory: URL { supportDirectory.appendingPathComponent("manifests", isDirectory: true) }
    /// Intent записывается сюда до первой операции с базой; в норме каталог пуст.
    public static var syncJournalsDirectory: URL { supportDirectory.appendingPathComponent("journals", isDirectory: true) }
    /// Journal and checkpoints of re-embedding operations.
    public static var reembeddingJournalFile: URL { supportDirectory.appendingPathComponent("reembeddings.json") }
    /// Documents and collections deleted from the UI, captured before the
    /// delete request is sent.
    public static var trashFile: URL { supportDirectory.appendingPathComponent("trash.jsonl") }
    /// Measured embedding and chunking times, shown on the statistics screen.
    public static var metricsFile: URL { supportDirectory.appendingPathComponent("metrics.json") }
    /// Измеренный предел чтения моделей эмбеддинга: сколько знаков
    /// модель берёт в один вектор, прежде чем молча отбросить остальное.
    public static var embeddingLimitsFile: URL { supportDirectory.appendingPathComponent("embedding-limits.json") }
    /// Measured model speeds, kept apart from the accumulated averages:
    /// one is a controlled measurement, the other a running total of real work.
    public static var benchmarksFile: URL { supportDirectory.appendingPathComponent("benchmarks.json") }
    /// Runs of the evaluation stand, one file each: a run carries the
    /// whole output of every variant and is far too big to share a file with
    /// its neighbours.
    public static var evaluationRunsDirectory: URL {
        supportDirectory.appendingPathComponent("evaluation-runs", isDirectory: true)
    }
    /// Оценки чат-модели по прогонам — рядом с прогонами, но отдельно
    /// от них: прогон обязан оставаться неизменным, а мнений о нём может быть
    /// несколько.
    public static var modelJudgementsDirectory: URL {
        supportDirectory.appendingPathComponent("model-judgements", isDirectory: true)
    }
    /// Что известно о веб-страницах источника с прошлого раза.
    public static var webPagesDirectory: URL { supportDirectory.appendingPathComponent("web-pages", isDirectory: true) }

    /// Где был git-репозиторий источника в прошлый раз.
    public static var gitStateDirectory: URL { supportDirectory.appendingPathComponent("git-state", isDirectory: true) }

    /// Отчёты инспектора здоровья коллекций.
    public static var inspectionsDirectory: URL { supportDirectory.appendingPathComponent("inspections", isDirectory: true) }

    /// Отчёты о тематических кластерах. Отдельно от инспекций: этап
    /// необязательный, и формат файла инспекций не должен от него зависеть.
    public static var topicsDirectory: URL { supportDirectory.appendingPathComponent("topics", isDirectory: true) }

    /// Где остановился прерванный импорт коллекции.
    public static var importCheckpointsDirectory: URL { supportDirectory.appendingPathComponent("import-checkpoints", isDirectory: true) }

    /// Сертификат прокси. Файлом, а не в Keychain: сертификат не секрет,
    /// его отдают клиенту — секрет только приватный ключ, и он остаётся
    /// в Keychain.
    public static var tlsCertificateFile: URL { supportDirectory.appendingPathComponent("proxy-certificate.der") }

    public static var backupsDirectory: URL { supportDirectory.appendingPathComponent("backups", isDirectory: true) }
    public static var venvDirectory: URL { supportDirectory.appendingPathComponent("venv", isDirectory: true) }
    public static var serversDirectory: URL { supportDirectory.appendingPathComponent("servers", isDirectory: true) }
    public static var defaultEmbeddedDatabase: URL { supportDirectory.appendingPathComponent("chroma_data", isDirectory: true) }

    /// Python inside the app-managed virtual environment (may not exist yet).
    public static var venvPython: URL { venvDirectory.appendingPathComponent("bin/python3") }
    public static var venvChromaCLI: URL { venvDirectory.appendingPathComponent("bin/chroma") }

    @discardableResult
    public static func ensureDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func ensureSupportDirectory() throws {
        try ensureDirectory(supportDirectory)
    }
}
