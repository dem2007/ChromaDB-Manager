import AppIntents
import AppKit
import Foundation
import ChromaCore

/// Интенты для Shortcuts.
///
/// Три действия, названные по-русски так же, как они называются в
/// приложении. Каждое выполняется **в самом приложении**, а не в отдельном
/// расширении: расширения обязаны работать в песочнице, из которой основное
/// приложение выведено (2.5).
///
/// Все три требуют, чтобы приложение уже было подключено к базе. Интент,
/// который сам поднимает сервер и ждёт модель, из Shortcuts выглядел бы
/// зависшим; вместо этого он честно говорит, чего не хватает.
@available(macOS 13.0, *)
enum IntentSupport {
    /// Общая точка входа: интент работает с тем же окружением, что и окно.
    @MainActor
    static func environment() throws -> AppEnvironment {
        guard let delegate = NSApp.delegate as? AppDelegate,
              let environment = delegate.environment
        else {
            throw IntentProblem.notReady
        }
        return environment
    }
}

@available(macOS 13.0, *)
enum IntentProblem: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case notConnected
    case noCollection(String)
    case noSource(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady:
            return "Приложение ещё не запущено — откройте ChromaDB Manager и повторите."
        case .notConnected:
            return "Нет подключения к базе — откройте ChromaDB Manager и подключитесь."
        case .noCollection(let name):
            return "Коллекции «\(name)» нет."
        case .noSource(let name):
            return "Источника «\(name)» нет."
        }
    }
}

/// «Найти в коллекции» — поиск тем же конвейером, что и везде.
@available(macOS 13.0, *)
struct SearchCollectionIntent: AppIntent {
    static var title: LocalizedStringResource = "Найти в коллекции"
    static var description = IntentDescription(
        "Ищет в коллекции ChromaDB и возвращает найденные фрагменты текста."
    )
    /// Приложение не выводится на передний план: интент могли позвать
    /// из сценария, где никакого окна не ждут.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Коллекция") var collection: String
    @Parameter(title: "Запрос") var query: String
    @Parameter(title: "Сколько результатов", default: 5) var count: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let app = try IntentSupport.environment()
        guard let client = app.client else { throw IntentProblem.notConnected }
        let collections = try await client.listCollections()
        guard let target = collections.first(where: { $0.name == collection }) else {
            throw IntentProblem.noCollection(collection)
        }
        let prepared = try await app.prepareSearch(for: target)
        let outcome = try await prepared.pipeline.run(
            RetrievalRequest(
                text: query,
                collectionID: target.id,
                collectionName: target.name,
                nResults: max(1, min(50, count)),
                filter: nil,
                metric: target.space
            ),
            profile: prepared.profile
        )
        return .result(value: outcome.hits.compactMap(\.document))
    }
}

/// «Добавить текст в коллекцию».
///
/// Текст добавляется **одним документом, без нарезки**: нарезка живёт
/// в источниках (2C). Слишком длинный текст отвергается с объяснением,
/// а не режется молча по границе контекста.
@available(macOS 13.0, *)
struct AddTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Добавить текст в коллекцию"
    static var description = IntentDescription(
        "Добавляет текст в коллекцию ChromaDB одним документом."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Коллекция") var collection: String
    @Parameter(title: "Текст") var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let app = try IntentSupport.environment()
        guard let client = app.client else { throw IntentProblem.notConnected }
        let collections = try await client.listCollections()
        guard let target = collections.first(where: { $0.name == collection }) else {
            throw IntentProblem.noCollection(collection)
        }
        let model = try await app.bindingService.requiredModel(for: target)
        let lmStudio = try app.makeLMStudioClient()
        try await app.bindingService.ensureAvailable(model: model, lmStudio: lmStudio)
        let limit = await app.bindingService.contextLength(of: model, lmStudio: lmStudio)

        // Ничего не режем: слишком длинный текст отвергается с объяснением,
        // а не тихо обрезается по границе контекста.
        if case .tooLong(let tokens, let allowed) = ContextBudget.check(text, contextLength: limit) {
            throw ContextError.tooLong(estimatedTokens: tokens, limit: allowed, model: model)
        }
        let documents = [PreparedDocument(
            id: nil, text: text, metadata: ["origin": .string("shortcuts")]
        )]

        let summary = try await app.queue.run(QueueTicket(
            title: String(localized: "Добавление текста в «\(target.name)»"),
            priority: .agent,
            group: .lmStudio,
            connectionID: app.connectionID
        )) { context in
            try await app.importService.importDocuments(
                documents,
                into: target,
                model: model,
                chroma: client,
                lmStudio: lmStudio,
                binding: app.bindingService,
                yield: { await context.yieldToHigherPriority() },
                progress: { _ in }
            )
        }
        return .result(value: String(localized: "Добавлено документов: \(summary.written)"))
    }
}

/// «Синхронизировать источник» — та же синхронизация, что по кнопке.
@available(macOS 13.0, *)
struct SyncSourceIntent: AppIntent {
    static var title: LocalizedStringResource = "Синхронизировать источник"
    static var description = IntentDescription(
        "Запускает синхронизацию источника ChromaDB Manager по его имени."
    )
    /// Синхронизация — длинная работа, и человеку полезно видеть ход:
    /// это единственный из трёх интентов, который открывает окно.
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Источник") var source: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let app = try IntentSupport.environment()
        guard app.client != nil else { throw IntentProblem.notConnected }
        guard let target = app.settings.configuration.dataSources.first(where: { $0.name == source })
        else {
            throw IntentProblem.noSource(source)
        }
        // Интент не синхронизирует сам: он просит окно сделать это тем же
        // путём, что кнопка, — со всеми проверками, планом и очередью.
        app.pendingRequest = .syncSource(target.id)
        return .result(value: String(localized: "Синхронизация «\(target.name)» запущена."))
    }
}

/// Набор интентов, который Shortcuts показывает без настройки.
@available(macOS 13.0, *)
struct ChromaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchCollectionIntent(),
            phrases: ["Найти в \(.applicationName)"],
            shortTitle: "Найти в коллекции",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: AddTextIntent(),
            phrases: ["Добавить текст в \(.applicationName)"],
            shortTitle: "Добавить текст",
            systemImageName: "text.badge.plus"
        )
        AppShortcut(
            intent: SyncSourceIntent(),
            phrases: ["Синхронизировать источник в \(.applicationName)"],
            shortTitle: "Синхронизировать источник",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
