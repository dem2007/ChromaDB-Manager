import Foundation

/// Перезагрузка модели в LM Studio с нужным контекстом.
///
/// Контекст задаётся **при загрузке модели**, и по сети его не поменять: у
/// LM Studio для этого есть свой CLI `lms`, который ставится вместе с
/// приложением. Приложение вызывает его — и только по нажатию кнопки.
///
/// Само оно этого не делает никогда. Перезагрузка модели — это выгрузка чужой
/// работы, минуты ожидания и гигабайты памяти в другом приложении; такое
/// начинают по просьбе человека, а не по ходу синхронизации.
///
/// **`lms load` не перезагружает, а добавляет.** LM Studio держит несколько
/// экземпляров одной модели одновременно: после «загрузить с 128000» в памяти
/// оказались обе копии — старая на 8192 и новая, — и запросы по имени модели
/// продолжали уходить в старую. Поэтому перезагрузка здесь состоит из трёх
/// шагов: перечислить экземпляры, выгрузить все экземпляры этой модели,
/// загрузить один с нужным контекстом.
public struct LMStudioLoader: Sendable {
    /// Где искать `lms`. Порядок — от штатного места установки к общему PATH.
    public static let searchPaths = [
        "~/.lmstudio/bin/lms",
        "/usr/local/bin/lms",
        "/opt/homebrew/bin/lms",
    ]

    /// Загруженный экземпляр модели, как его называет `lms ps --json`.
    ///
    /// `identifier` и `modelKey` — разные вещи, и в этом всё дело: у второго
    /// экземпляра той же модели `modelKey` тот же, а `identifier` — «имя:2».
    /// Выгружать надо по `identifier`, искать — по `modelKey`.
    public struct Instance: Decodable, Hashable, Sendable {
        public let identifier: String
        public let modelKey: String
        public let contextLength: Int?

        public init(identifier: String, modelKey: String, contextLength: Int?) {
            self.identifier = identifier
            self.modelKey = modelKey
            self.contextLength = contextLength
        }
    }

    public enum LoadError: LocalizedError {
        case notInstalled
        case failed(command: String, status: Int32, output: String)
        case instancesUnreadable(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled:
                return String(localized: "Утилита `lms` не найдена — без неё приложение не может перезагрузить модель.")
            case .failed(let command, let status, let output):
                let tail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return tail.isEmpty
                    ? String(localized: "LM Studio отказала на `lms \(command)` (код \(status)).")
                    : String(localized: "LM Studio отказала на `lms \(command)` (код \(status)): \(tail)")
            case .instancesUnreadable(let details):
                return String(localized: "Не удалось разобрать список загруженных моделей LM Studio: \(details)")
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .notInstalled:
                return String(localized: "Она ставится вместе с LM Studio: откройте LM Studio → Developer → Install `lms` CLI. Либо загрузите модель вручную, указав контекст в диалоге загрузки.")
            case .failed:
                return String(localized: "Чаще всего это нехватка памяти под такой контекст: возьмите значение поменьше или модель полегче.")
            case .instancesUnreadable:
                // Без списка экземпляров загрузка добавила бы **вторую** копию
                // модели рядом со старой — то самое, ради чего этот шаг и есть.
                return String(localized: "Не зная, что уже загружено, приложение не станет грузить модель: в памяти оказались бы две копии сразу. Перезагрузите модель вручную в LM Studio.")
            }
        }
    }

    /// Где искать вместо штатных мест — только для тестов: настоящий поиск
    /// не должен зависеть от того, что кто-то положил рядом.
    private let paths: [String]

    public init(paths: [String] = LMStudioLoader.searchPaths) {
        self.paths = paths
    }

    /// Путь к `lms`, если он есть.
    public var executable: URL? {
        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        return nil
    }

    public var isAvailable: Bool { executable != nil }

    // MARK: - Команды

    /// Аргументы вызовов. Отдельно от запуска, чтобы их можно было и показать
    /// человеку, и проверить тестом, не запуская ничего.
    public static func psArguments() -> [String] { ["ps", "--json"] }

    public static func unloadArguments(identifier: String) -> [String] {
        ["unload", identifier]
    }

    /// `-y` — не «согласиться на всё подряд», а «не спрашивать в терминале,
    /// которого нет»: выбор модели и контекста уже сделан здесь.
    public static func loadArguments(model: String, contextLength: Int) -> [String] {
        ["load", model, "--context-length", String(contextLength), "-y"]
    }

    // MARK: - Действия

    /// Что сейчас загружено в память LM Studio.
    public func instances() async throws -> [Instance] {
        let output = try await run(Self.psArguments())
        // Вывод бывает с шапкой или предупреждением перед JSON, поэтому
        // разбор начинается с первой скобки, а не с первого символа.
        guard let start = output.firstIndex(of: "["),
              let data = String(output[start...]).data(using: .utf8)
        else {
            throw LoadError.instancesUnreadable(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do {
            return try JSONDecoder().decode([Instance].self, from: data)
        } catch {
            throw LoadError.instancesUnreadable(error.localizedDescription)
        }
    }

    public func unload(identifier: String) async throws {
        _ = try await run(Self.unloadArguments(identifier: identifier))
    }

    /// Выгружает все экземпляры модели и загружает один с нужным контекстом.
    ///
    /// Именно в этом порядке и именно все: `lms load` сам по себе не заменяет
    /// загруженное, а ставит рядом ещё одну копию — 13 ГБ памяти и запросы,
    /// продолжающие уходить в старый экземпляр.
    ///
    /// Возвращает, сколько экземпляров пришлось выгрузить, и вывод загрузки.
    @discardableResult
    public func reload(model: String, contextLength: Int) async throws -> (unloaded: Int, output: String) {
        let loaded = try await instances().filter { $0.modelKey == model || $0.identifier == model }
        for instance in loaded {
            try await unload(identifier: instance.identifier)
        }
        let output = try await run(Self.loadArguments(model: model, contextLength: contextLength))
        return (loaded.count, output)
    }

    // MARK: - Запуск

    /// Ждёт завершения: загрузка модели на десятки гигабайт занимает минуты,
    /// и «команда отправлена» здесь не ответ — человеку нужно знать, чем
    /// кончилось.
    private func run(_ arguments: [String]) async throws -> String {
        guard let executable else { throw LoadError.notInstalled }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            // Массивом, а не строкой через оболочку: имя модели приходит из
            // списка LM Studio, но собирать из него команду для `sh` — это
            // дыра, которую незачем открывать.
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            process.terminationHandler = { finished in
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                let output = String(data: data, encoding: .utf8) ?? ""
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: LoadError.failed(
                        command: arguments.joined(separator: " "),
                        status: finished.terminationStatus,
                        output: output
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
