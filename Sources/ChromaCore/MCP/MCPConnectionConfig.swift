import Foundation

/// Готовый фрагмент конфигурации для агентского приложения.
///
/// Формат — не часть протокола: это соглашение клиентов (Claude Desktop,
/// Claude Code и другие читают `mcpServers` с `command`, `args` и `env`).
/// Поэтому он сверен с действующей документацией MCP, а не восстановлен по
/// памяти — ровно по той же причине, по которой пересматривался сам протокол
///.
public enum MCPConnectionConfig {
    /// Имя сервера в конфигурации агента. Оно же попадёт в его интерфейс,
    /// поэтому читаемое и без пробелов.
    ///
    /// Берётся у протокола, а не пишется второй раз: это два конца
    /// одного разговора — под этим именем сервер записан у агента, и этим же
    /// именем он представляется в `serverInfo` при рукопожатии. Пока значение
    /// стояло в двух местах, переименование одного расходилось с другим молча.
    public static let serverName = MCPProtocol.serverName

    /// Что стоит вместо ключа, когда показать настоящий нечем.
    ///
    /// Ключ хранится только хешем и показывается один раз (7.4), так что для
    /// давно заведённого клиента приложение честно не может подставить его
    /// в конфигурацию — и подставляет заметную заглушку вместо тихого пропуска.
    public static let keyPlaceholder = "СЮДА-КЛЮЧ-КЛИЕНТА"

    /// Где агенты держат эту конфигурацию.
    ///
    /// Файл у каждого свой, и назвать один — значит послать не туда всех
    /// остальных. Раньше здесь стоял только путь Claude Desktop, а кнопки
    /// на той же карточке пишут в Hermes и Bionic.
    /// Пути агентов берутся у `AgentKind` — того же места, куда пишут кнопки.
    /// Второй список тех же файлов разошёлся бы с первой правкой, и карточка
    /// послала бы человека править файл, которого приложение не трогает.
    /// Считается один раз: пути не меняются, пока приложение работает, а
    /// читается это из тела экрана — то есть на каждой перерисовке.
    public static let configPaths: [String] =
        AgentKind.allCases.map {
            "\($0.title) — \(($0.configuration.path as NSString).abbreviatingWithTildeInPath)"
        } + [
            // Claude Desktop кнопками не настраивается — его путь и остаётся
            // единственным, записанным здесь.
            "Claude Desktop — ~/Library/Application Support/Claude/claude_desktop_config.json",
        ]

    /// Фрагмент JSON целиком, с подставленными путём и ключом.
    public static func json(helperPath: String, key: String?) -> String {
        let object: [String: Any] = [
            "mcpServers": [
                serverName: [
                    "command": helperPath,
                    "env": ["CHROMADB_MCP_KEY": key ?? keyPlaceholder],
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    /// Та же настройка одной командой — для тех, кто правит конфигурацию не
    /// руками. Путь берётся в кавычки: в имени бандла есть пробел.
    ///
    /// Команда — от **Hermes**, а не от Claude Code: `claude` на машине может
    /// не стоять вовсе, и совет, который некому выполнить, — это не совет.
    /// Ключи взяты у живого `hermes mcp add --help`, а не придуманы: `--env`
    /// принимает `КЛЮЧ=ЗНАЧЕНИЕ`, стоит после `--command`.
    public static func commandLine(helperPath: String, key: String?) -> String {
        "hermes mcp add \(serverName) --command \"\(helperPath)\" --env CHROMADB_MCP_KEY=\(key ?? keyPlaceholder)"
    }
}

/// Результат проверки подключения.
///
/// Список шагов, а не «работает / не работает»: подключение ломается в разных
/// местах, и человеку нужно знать, до какого места дошло.
public struct MCPConnectionCheck: Sendable, Hashable {
    /// Ступень бывает не только «прошла» и «сломалась».
    ///
    /// Третье состояние завелось после живой проверки: ключ принят, но ему не
    /// открыта ни одна коллекция — связь работает, а агент не увидит в базе
    /// ничего. Зелёный итог в этом случае отпускает человека довольным
    /// и неподключённым.
    public enum Outcome: Sendable, Hashable {
        case ok
        case warning
        case failed
    }

    public struct Step: Sendable, Hashable, Identifiable {
        public var id: String { title }
        public let title: String
        public let outcome: Outcome
        /// Что именно ответила та сторона — или что делать, если не ответила.
        public let detail: String

        public init(title: String, outcome: Outcome, detail: String) {
            self.title = title
            self.outcome = outcome
            self.detail = detail
        }

        public var isOK: Bool { outcome != .failed }
    }

    public var steps: [Step]

    public init(steps: [Step] = []) {
        self.steps = steps
    }

    public var isOK: Bool { !steps.isEmpty && steps.allSatisfy { $0.outcome == .ok } }

    /// Первая сломавшаяся ступень — то, что показывают крупно.
    public var firstProblem: Step? { steps.first { $0.outcome == .failed } }
    public var firstWarning: Step? { steps.first { $0.outcome == .warning } }

    public var summary: String {
        if steps.isEmpty { return String(localized: "Проверка не выполнялась.") }
        if let problem = firstProblem {
            return String(localized: "Не сработало: \(problem.title) — \(problem.detail)")
        }
        if let warning = firstWarning {
            return String(localized: "Связь работает, но подключение ещё не готово: \(warning.detail)")
        }
        return String(localized: "Подключение работает: агент увидит сервер и его инструменты.")
    }
}
