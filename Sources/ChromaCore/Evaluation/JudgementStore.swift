import Foundation

/// Оценки чат-модели, по файлу на прогон.
///
/// **Отдельный каталог, а не поле внутри прогона.** Прогон — это то, что
/// ответил поиск; оценка модели — мнение о нём, снятое потом и, возможно,
/// несколько раз разными промптами. Положив их в один файл, мы бы переписывали
/// прогон при каждой переоценке — то есть трогали запись, которая обязана
/// оставаться неизменной, чтобы через месяц к ней можно было вернуться.
public final class JudgementStore {
    private let directory: URL
    private let log: LogHandler

    public init(
        directory: URL = AppPaths.modelJudgementsDirectory,
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.directory = directory
        self.log = log
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func url(for runID: UUID) -> URL {
        directory.appendingPathComponent("\(runID.uuidString).json")
    }

    public func set(for runID: UUID) -> JudgementSet? {
        guard let data = try? Data(contentsOf: url(for: runID)) else { return nil }
        return try? Self.decoder().decode(JudgementSet.self, from: data)
    }

    @discardableResult
    public func save(_ set: JudgementSet) -> Bool {
        do {
            _ = try AppPaths.ensureDirectory(directory)
            try Self.encoder().encode(set).write(to: url(for: set.runID), options: .atomic)
            return true
        } catch {
            log(.error, "Оценка", "Не удалось сохранить оценки модели: \(error.localizedDescription)")
            return false
        }
    }

    /// Убирается вместе с прогоном: мнение о том, чего больше нет, — мусор,
    /// который потом невозможно опознать.
    public func remove(runID: UUID) {
        try? FileManager.default.removeItem(at: url(for: runID))
    }
}
