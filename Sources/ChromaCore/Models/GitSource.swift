import Foundation

/// Настройки источника «git-репозиторий».
public struct GitSourceSettings: Codable, Hashable, Sendable {
    /// Индексировать рабочую копию как есть (по умолчанию) или только
    /// состояние последнего коммита.
    public var indexesWorkingCopy: Bool
    /// `last_commit_date` и `last_commit_author` в метаданных чанков.
    ///
    /// Выключено по умолчанию: это отдельный вызов `git log` **на каждый файл**,
    /// и на большом репозитории он стоит заметного времени.
    public var includesCommitInfo: Bool
    /// Исключения поверх `.gitignore` — простыми масками (`*.lock`, `docs/*`).
    public var excludedGlobs: [String]

    public init(
        indexesWorkingCopy: Bool = true,
        includesCommitInfo: Bool = false,
        excludedGlobs: [String] = []
    ) {
        self.indexesWorkingCopy = indexesWorkingCopy
        self.includesCommitInfo = includesCommitInfo
        self.excludedGlobs = excludedGlobs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        indexesWorkingCopy = try container.decodeIfPresent(Bool.self, forKey: .indexesWorkingCopy) ?? true
        includesCommitInfo = try container.decodeIfPresent(Bool.self, forKey: .includesCommitInfo) ?? false
        excludedGlobs = try container.decodeIfPresent([String].self, forKey: .excludedGlobs) ?? []
    }

    /// Подходит ли путь под одну из масок исключения.
    public func excludes(_ relativePath: String) -> Bool {
        excludedGlobs.contains { glob in
            let pattern = glob.trimmed
            guard !pattern.isEmpty else { return false }
            return fnmatch(pattern, relativePath, 0) == 0
                || fnmatch(pattern, (relativePath as NSString).lastPathComponent, 0) == 0
        }
    }
}

/// Где репозиторий был в прошлый раз.
///
/// Отдельно от манифеста, как и у веба: манифест отвечает на вопрос «что мы
/// записали в базу», а здесь — «от какого состояния считать разницу».
public struct GitSourceState: Codable, Hashable, Sendable {
    public var commit: String?
    public var branch: String?
    public var syncedAt: Date?

    public init(commit: String? = nil, branch: String? = nil, syncedAt: Date? = nil) {
        self.commit = commit
        self.branch = branch
        self.syncedAt = syncedAt
    }
}

public struct GitStateStore: Sendable {
    private let directory: URL

    public init(directory: URL = AppPaths.gitStateDirectory) {
        self.directory = directory
    }

    public func fileURL(for sourceID: UUID) -> URL {
        directory.appendingPathComponent("\(sourceID.uuidString).json")
    }

    public func load(sourceID: UUID) -> GitSourceState {
        guard let data = try? Data(contentsOf: fileURL(for: sourceID)) else { return GitSourceState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Не прочиталось — значит, разницу считать не от чего: источник просто
        // сверится по содержимому, как папка. Это дороже, но не неправильно.
        return (try? decoder.decode(GitSourceState.self, from: data)) ?? GitSourceState()
    }

    public func save(_ state: GitSourceState, sourceID: UUID) {
        do {
            try AppPaths.ensureDirectory(directory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(state).write(to: fileURL(for: sourceID), options: .atomic)
        } catch {
            // Молча: потеря этого файла стоит одной полной сверки, а не данных.
        }
    }

    public func remove(sourceID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: sourceID))
    }
}
