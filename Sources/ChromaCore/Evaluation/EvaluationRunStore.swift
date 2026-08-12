import Foundation

/// Saved runs of the evaluation stand.
///
/// One file per run rather than one file for all of them: a run holds the full
/// text of every result of every variant, so ten runs of a twenty-query set are
/// megabytes, and reading them all to show a list of names would make the
/// screen slow the day it becomes useful.
public final class EvaluationRunStore {
    private let directory: URL
    private let log: LogHandler
    /// Names and counts only — enough for the list, without the results.
    private var index: [EvaluationRunSummary]?

    public init(
        directory: URL = AppPaths.evaluationRunsDirectory,
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

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Newest first — the run just finished is the one being looked at.
    public func summaries() -> [EvaluationRunSummary] {
        if let index { return index }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        let loaded = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> EvaluationRunSummary? in
                guard let data = try? Data(contentsOf: url),
                      let run = try? Self.decoder().decode(EvaluationRun.self, from: data)
                else { return nil }
                return EvaluationRunSummary(run)
            }
            .sorted { $0.startedAt > $1.startedAt }
        index = loaded
        return loaded
    }

    public func run(id: UUID) -> EvaluationRun? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? Self.decoder().decode(EvaluationRun.self, from: data)
    }

    @discardableResult
    public func save(_ run: EvaluationRun) -> Bool {
        do {
            _ = try AppPaths.ensureDirectory(directory)
            try Self.encoder().encode(run).write(to: url(for: run.id), options: .atomic)
            index = nil
            return true
        } catch {
            log(.error, "Оценка", "Не удалось сохранить прогон «\(run.name)»: \(error.localizedDescription)")
            return false
        }
    }

    /// Removed only when the user asks (rule 1): a run is the record of work
    /// that took minutes of a local model's time, and nothing here expires it.
    public func remove(id: UUID) {
        let name = summaries().first { $0.id == id }?.name ?? id.uuidString
        try? FileManager.default.removeItem(at: url(for: id))
        index = nil
        log(.warning, "Оценка", "Прогон «\(name)» удалён")
    }

    public func exportData(_ run: EvaluationRun) throws -> Data {
        try Self.encoder().encode(run)
    }
}

/// A run without its results — what the list of runs is built from.
public struct EvaluationRunSummary: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let startedAt: Date
    public let querySetName: String
    public let variantNames: [String]
    public let queryCount: Int
    public let resultCount: Int
    public let isComplete: Bool
    public let note: String

    public init(_ run: EvaluationRun) {
        id = run.id
        name = run.name
        startedAt = run.startedAt
        querySetName = run.querySetName
        variantNames = run.variants.map(\.name)
        queryCount = run.queries.count
        resultCount = run.results.count
        isComplete = run.isComplete
        note = run.note
    }

    public var line: String {
        var parts = [
            startedAt.formatted(date: .abbreviated, time: .shortened),
            String(localized: "набор «\(querySetName)»"),
            RussianCount.phrase(queryCount, "запрос", "запроса", "запросов"),
            variantNames.joined(separator: ", "),
        ]
        if !isComplete { parts.append(String(localized: "неполный")) }
        return parts.joined(separator: " · ")
    }
}
