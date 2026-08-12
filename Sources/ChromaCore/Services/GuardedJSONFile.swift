import Foundation

/// A JSON file the user cannot afford to lose.
///
/// Every store in the app used to read its file the same way — `(try? decode)
/// ?? []` — and write the result back on the next change. That turns **one**
/// failed read into permanent loss: the store starts empty, saves an empty
/// list over the file, and nothing anywhere says so. It cost a user three data
/// sources; the same shape sat under hand-marked ground truth, search profiles,
/// metadata schemas and the manifests that make re-embedding unnecessary.
///
/// The rules here are the fix, in one place:
///
/// * **«файла нет» и «файл есть, но не прочитался» — разные события.** The first
///   is an ordinary first run and saving is right; the second means the data is
///   on disk and writing over it destroys exactly what could not be read.
/// * A read is retried, because the most common failure is not corruption but
///   the split second in which an atomic replace has unlinked the old file.
/// * A file that failed to load **blocks saving** until someone deals with it,
///   and says so out loud rather than in silence (правило 2).
/// * The previous version stays beside the current one, so «верни, как было»
///   has an answer even when something else goes wrong.
///
/// Owned by exactly one store, which is itself an actor or a `@MainActor`
/// class — hence `@unchecked Sendable`: the state below never has two writers.
public final class GuardedJSONFile<Value: Codable>: @unchecked Sendable {
    public enum Read {
        /// No file yet — an ordinary first run.
        case fresh
        case loaded(Value)
        /// The file exists and could not be turned into a value.
        case unreadable(reason: String)
    }

    public let url: URL
    private let category: String
    private let log: LogHandler
    private let keepsPreviousVersion: Bool
    private let makeDecoder: () -> JSONDecoder
    private let makeEncoder: () -> JSONEncoder

    /// Why saving is off, when it is. `nil` means everything is normal.
    public private(set) var problem: String?

    public init(
        url: URL,
        category: String,
        log: @escaping LogHandler = noopLogHandler,
        keepsPreviousVersion: Bool = true,
        decoder: @escaping () -> JSONDecoder = { GuardedJSONFile.isoDecoder() },
        encoder: @escaping () -> JSONEncoder = { GuardedJSONFile.isoEncoder() }
    ) {
        self.url = url
        self.category = category
        self.log = log
        self.keepsPreviousVersion = keepsPreviousVersion
        self.makeDecoder = decoder
        self.makeEncoder = encoder
    }

    public static func isoDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func isoEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public var previousURL: URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".previous.json")
    }

    // MARK: - Чтение

    public func read() -> Read {
        guard FileManager.default.fileExists(atPath: url.path) else {
            problem = nil
            return .fresh
        }

        // Three attempts, 50 ms apart. The window an atomic replace leaves open
        // is fractions of a millisecond wide, so this closes the whole class of
        // failure — and a file that is genuinely unreadable stays unreadable.
        //
        // Повтор охватывает **и разбор тоже**, а не только открытие файла.
        // Раньше повторялось лишь `Data(contentsOf:)`, и это оставляло дыру
        // ровно той же природы: чтение успевает вернуть содержимое, которое
        // разбирается неудачно, — и одна такая неудача на запуске выключала
        // сохранение на всю сессию, а всё измеренное за неё пропадало. В
        // журнале приложения это видно дважды, 5 и 10 августа, причём оба раза
        // на запуске и сразу у двух независимых файлов в одну миллисекунду —
        // порча двух файлов разом так не выглядит, а гонка выглядит именно так.
        /// Содержимое последней попытки и то, чем она кончилась.
        var lastBytes: Data?
        var lastFailure: Error?

        for attempt in 0..<3 {
            lastBytes = nil
            do {
                let bytes = try Data(contentsOf: url)
                lastBytes = bytes
                let value = try makeDecoder().decode(Value.self, from: bytes)
                problem = nil
                return .loaded(value)
            } catch {
                lastFailure = error
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
            }
        }

        // Файл не открылся ни разу — читать нечего.
        guard let data = lastBytes else {
            let reason = lastFailure?.localizedDescription ?? String(localized: "файл недоступен")
            problem = String(localized: "\(url.lastPathComponent) существует, но не читается: \(Self.tidy(reason)) Ничего не сохраняем, чтобы не затереть файл.")
            log(.error, category, problem ?? "")
            return .unreadable(reason: reason)
        }

        // Открылся, но не разобрался — и так три раза подряд. Теперь это
        // действительно испорченное содержимое, а не мгновение чужой записи.
        let reason = lastFailure?.localizedDescription ?? String(localized: "файл не разобран")

        // Копия ровно этого содержимого могла уже сохраниться на прошлом
        // запуске: каждый запуск с испорченным файлом плодил ещё один
        // одинаковый слепок, и в каталоге накапливался мусор.
        let rescued: URL
        let saidWhere: String
        if let existing = existingRescue(matching: data) {
            rescued = existing
            // Не «сохранена»: сохранена она была раньше. Человек, которому
            // сказали «сохранена», ищет файл с сегодняшней меткой времени —
            // и при разборе происшествия уходит не в тот день.
            saidWhere = String(localized: "Копия этого содержимого уже лежит рядом как \(existing.lastPathComponent)")
        } else {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            rescued = url.deletingLastPathComponent().appendingPathComponent(
                url.deletingPathExtension().lastPathComponent + ".unreadable-\(stamp).json"
            )
            try? data.write(to: rescued, options: .atomic)
            saidWhere = String(localized: "Копия сохранена как \(rescued.lastPathComponent)")
        }

        problem = String(localized: "\(url.lastPathComponent) не разбирается: \(Self.tidy(reason)) \(saidWhere); ничего не сохраняем, чтобы не затереть оригинал.")
        log(.error, category, problem ?? "")
        return .unreadable(reason: reason)
    }

    /// The value, or the fallback — with the problem recorded either way.
    public func value(or fallback: Value) -> Value {
        if case .loaded(let value) = read() { return value }
        return fallback
    }

    /// Tries again after the cause has been dealt with.
    @discardableResult
    public func reload() -> Read {
        let outcome = read()
        if case .loaded = outcome {
            log(.info, category, "\(url.lastPathComponent): файл прочитан заново, сохранение снова разрешено")
        }
        return outcome
    }

    // MARK: - Запись

    /// Saves — unless the file could not be read, in which case it says why and
    /// keeps its hands off.
    @discardableResult
    public func write(_ value: Value) -> Bool {
        if let problem {
            log(.warning, category, "Изменение не сохранено: \(problem)")
            return false
        }
        do {
            _ = try AppPaths.ensureDirectory(url.deletingLastPathComponent())
            let data = try makeEncoder().encode(value)
            if keepsPreviousVersion,
               let current = try? Data(contentsOf: url), current != data {
                try? current.write(to: previousURL, options: .atomic)
            }
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            log(.error, category, "Не удалось сохранить \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
        problem = nil
    }

    /// Reads bytes with the same retry as `read`, for files whose writing path
    /// is its own (the manifests fsync and swap — a guard that replaced their
    /// write would take that guarantee away).
    ///
    /// `nil` only when the file is genuinely not readable; a missing file is
    /// `nil` too, so callers check existence themselves when the difference
    /// matters — and for a manifest it matters: «нет манифеста» значит «источник
    /// новый», а «манифест не прочитан» значит «сейчас всё будет проиндексировано
    /// заново», и это разные новости.
    public static func readDataWithRetry(at url: URL) -> Data? {
        // Файла нет — ждать нечего, и это самый частый случай из всех.
        //
        // Повтор со сном заведён под файл, застигнутый на середине записи: тот
        // через полсотни миллисекунд дочитается. Отсутствующий файл за это
        // время не появится, а сон честно отрабатывал оба раза: сто
        // миллисекунд на каждый источник, у которого нет манифеста таблиц, —
        // то есть на почти каждый. На экране источников это складывалось
        // в две секунды застывшего окна, и видно это было только в снимке.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        for attempt in 0..<3 {
            if let data = try? Data(contentsOf: url) { return data }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
        }
        return nil
    }

    /// Keeps the current contents of `url` beside it as `<name>.previous.json`.
    public static func keepPreviousVersion(of url: URL, unless data: Data) {
        guard let current = try? Data(contentsOf: url), current != data else { return }
        let previous = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".previous.json")
        try? current.write(to: previous, options: .atomic)
    }

    /// System error descriptions end in a full stop; ours add another one.
    /// Уже сохранённая копия ровно этого содержимого, если она есть.
    private func existingRescue(matching data: Data) -> URL? {
        let directory = url.deletingLastPathComponent()
        let prefix = url.deletingPathExtension().lastPathComponent + ".unreadable-"
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return files.first {
            $0.lastPathComponent.hasPrefix(prefix) && (try? Data(contentsOf: $0)) == data
        }
    }

    static func tidy(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }
}
