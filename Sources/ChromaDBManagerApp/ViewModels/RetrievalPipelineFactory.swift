import Foundation
import ChromaCore

/// Сборка конвейера поиска — в одном месте на всё приложение.
///
/// Экран коллекций и быстрый поиск из строки меню обязаны искать
/// **одинаково**: со вторым способом настройки, которые человек подкрутил,
/// применялись бы на одном экране и не применялись на другом.
extension AppEnvironment {

    struct PreparedSearch {
        let pipeline: RetrievalPipeline
        /// Модель коллекции — её называют человеку в сводке.
        let model: String
        let profile: SearchProfile
        /// Выключенный умный поиск — это профиль со всеми необязательными
        /// стадиями выключенными, то есть поиск этапа 2.
        let smartSearchEnabled: Bool
    }

    /// Стадия 7 со всеми вызовами модели: одна сборка на три места.
    ///
    /// Кроме обычного поиска её просит поиск сразу по нескольким коллекциям —
    /// он спрашивает модель один раз про слитую выдачу. Собирать
    /// вызовы модели в каждом месте по-своему значит разойтись в мелочах:
    /// очередь, приоритет, место под ответ.
    ///
    /// - Parameter title: что показывать в очереди — при слитом поиске это
    ///   не «в такой-то коллекции», а «по нескольким».
    @MainActor
    func makeRerankStage(
        for profile: SearchProfile,
        title: String,
        priority: QueuePriority
    ) async throws -> RerankStage {
        let lmStudio = try makeLMStudioClient()
        // Контекст переранжировщика спрашивается только когда стадия включена:
        // лишний вызов к LM Studio на каждый поиск не нужен.
        let asked = profile.rerankEnabled && !profile.rerankModel.isEmpty
        let contextTokens: Int? = asked
            ? await bindingService.loadedContextLength(of: profile.rerankModel, lmStudio: lmStudio)
            : nil
        // «3.5 символа на токен» ошибается на русском юридическом тексте
        // на 40 % в опасную сторону — берётся измеренное.
        let charactersPerToken: Double? = asked
            ? await lmStudio.charactersPerToken(of: profile.rerankModel)
            : nil
        return RerankStage(
            complete: { [queue = queue, id = connectionID] prompt, chatModel, schema in
                try await queue.run(QueueTicket(
                    title: title, priority: priority, group: .lmStudio, connectionID: id
                )) { _ in
                    try await lmStudio.complete(prompt: prompt, model: chatModel, schema: schema)
                }
            },
            completePlain: { [queue = queue, id = connectionID] prompt, model, maxTokens in
                // Переранжировщику — прямой вызов без шаблона чата,
                // и место под ответ называет стадия.
                try await queue.run(QueueTicket(
                    title: title, priority: priority, group: .lmStudio, connectionID: id
                )) { _ in
                    try await lmStudio.rawCompletion(
                        prompt: prompt, model: model, maxTokens: maxTokens
                    )
                }
            },
            contextTokens: contextTokens,
            charactersPerToken: charactersPerToken
        )
    }

    /// Готовит конвейер для коллекции: проверяет модель, поднимает её в
    /// LM Studio и подставляет очередь на каждый вызов модели.
    ///
    /// - Parameters:
    ///   - smartSearch: решение вместо настройки коллекции — им пользуются
    ///     права ключа MCP. `nil` — как настроено у коллекции.
    ///   - priority: место в очереди к модели. По умолчанию наивысшее — так
    /// ищет человек у экрана; у запросов агента ступень своя и ниже.
    @MainActor
    func prepareSearch(
        for collection: ChromaCollection,
        smartSearch smartSearchOverride: Bool? = nil,
        priority: QueuePriority = .interactive
    ) async throws -> PreparedSearch {
        guard let client else {
            throw NSError(domain: "ChromaDBManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Нет подключения к базе."),
            ])
        }
        let model = try await bindingService.requiredModel(for: collection)
        let lmStudio = try makeLMStudioClient()
        try await bindingService.ensureAvailable(model: model, lmStudio: lmStudio)

        let smartSearch = smartSearchOverride ?? searchProfiles.isPipelineEnabled(for: collection.name)
        // Не `effectiveProfile`: она смотрит на переключатель коллекции, а
        // здесь решение может прийти извне. Выключенный умный поиск — это
        // профиль со всеми необязательными стадиями выключенными, то есть
        // поиск этапа 2.
        let configured = searchProfiles.defaultProfile(for: collection.name, model: model)
        let profile = smartSearch
            ? configured
            : SearchProfile.plain(collectionName: collection.name, name: configured.name)
        let rerankStage = try await makeRerankStage(
            for: profile,
            title: String(localized: "Переранжирование в «\(collection.name)»"),
            priority: priority
        )

        let pipeline = RetrievalPipeline(
            database: client,
            shapes: collectionShapes,
            embed: { [binding = bindingService, queue = queue, id = connectionID] text in
                // Человек ждёт у экрана: наивысший приоритет — и всё равно
                // через очередь, иначе поиск во время синхронизации отнимал
                // бы у неё модель.
                let vector = try await queue.run(QueueTicket(
                    title: String(localized: "Поиск в «\(collection.name)»"),
                    priority: priority,
                    group: .lmStudio,
                    connectionID: id
                )) { _ in
                    try await lmStudio.embed(text: text, model: model)
                }
                try await binding.validate(vectorLength: vector.count, for: collection)
                return vector
            },
            rerank: rerankStage,
            log: logHandler
        )
        return PreparedSearch(
            pipeline: pipeline, model: model, profile: profile,
            smartSearchEnabled: smartSearch
        )
    }
}
