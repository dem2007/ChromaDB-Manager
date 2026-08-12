import Foundation
import SwiftUI
import ChromaCore

/// Один подключённый агент — строка экрана активности.
///
/// «Кто подключён» и «что он делал» — разные вопросы, и второй закрывает журнал
/// доступа. Здесь только то, чего в журнале нет: соединение живо прямо сейчас.
struct MCPConnection: Identifiable, Hashable {
    let id: UUID
    let connectedAt: Date
    /// Имя клиента по его ключу. `nil` — ключ не опознан или не передан вовсе;
    /// такое соединение читать полезнее всего, потому что оно ничего не может.
    var clientName: String?
    var hasKey = false
    var callCount = 0
    var lastTool: String?
    var lastCallAt: Date?

    var title: String {
        if let clientName { return clientName }
        return hasKey
            ? String(localized: "ключ не зарегистрирован")
            : String(localized: "без ключа")
    }
}

/// MCP-сервер со стороны приложения (этап 7).
///
/// Слушает локальный сокет, к которому подключается вспомогательный
/// исполняемый файл, и отвечает на сообщения агента. Инструменты, права и
/// доступ к базе живут здесь, в одном экземпляре: мост своей логики не имеет
///.
@MainActor
final class MCPService: ObservableObject {
    /// Работает ли слушатель прямо сейчас — для экрана и для диагностики.
    @Published private(set) var isListening = false
    @Published private(set) var lastError: String?
    /// Сколько раз агент обращался за сеанс.
    @Published private(set) var callCount = 0
    /// Кто подключён прямо сейчас. Порядок — по времени подключения:
    /// список, переставляющийся сам, читать нельзя.
    @Published private(set) var connections: [MCPConnection] = []
    /// Режим «только чтение» на весь сервер.
    @Published private(set) var isReadOnly = false

    private let listener = MCPListener()
    private var channels: [ObjectIdentifier: ChannelState] = [:]
    /// Тот же флаг, но доступный из любого потока: инструменты спрашивают его
    /// синхронно на каждом вызове, а `@Published` живёт на главном акторе.
    private let readOnlyFlag = ReadOnlyFlag()

    private final class ReadOnlyFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false
        var value: Bool {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }

    /// Ключ клиента приезжает отдельным уведомлением при подключении и
    /// относится ко всему соединению: один запущенный мост — это один агент
    /// с одним ключом.
    private final class ChannelState {
        let id = UUID()
        var key: String?
        init() {}
    }

    func start(_ app: AppEnvironment) {
        guard !isListening else { return }
        self.app = app
        isReadOnly = app.settings.configuration.mcpReadOnly
        readOnlyFlag.value = isReadOnly

        let server = MCPServer(
            instructions: Self.instructions,
            serverVersion: SettingsTransferViewModel.appVersion,
            tools: MCPToolService(
                backend: AppMCPBackend(app: app),
                access: app.proxy.access,
                isReadOnlyServer: { [flag = readOnlyFlag] in flag.value },
                // Тот же журнал доступа, что у прокси: вопрос «что делали
                // с базой чужими руками» один.
                audit: { [audit = app.audit] entry in audit.record(entry) }
            )
        )

        listener.onConnection = { [weak self] channel in
            let state = ChannelState()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.channels[ObjectIdentifier(channel)] = state
                self.connections.append(MCPConnection(id: state.id, connectedAt: Date()))
            }
            channel.onMessage = { [weak self] message in
                Task { @MainActor [weak self] in
                    await self?.handle(message, from: channel, state: state, server: server)
                }
            }
            channel.onClose = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.channels[ObjectIdentifier(channel)] = nil
                    self.connections.removeAll { $0.id == state.id }
                }
            }
        }

        do {
            try listener.start()
            isListening = true
            lastError = nil
            app.log.record(.success, "MCP", "Сервер MCP слушает \(AppPaths.mcpSocketFile.path)")
        } catch {
            lastError = error.localizedDescription
            app.log.record(.error, "MCP", "Не удалось поднять сервер MCP: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isListening else { return }
        listener.stop()
        channels.removeAll()
        connections.removeAll()
        isListening = false
    }

    /// Переключить режим «только чтение» на весь сервер.
    ///
    /// Настройка сохраняется: «пусть агент посмотрит, но ничего не трогает» —
    /// решение, которое переживает перезапуск приложения, иначе оно тихо
    /// отменялось бы, а владелец узнавал бы об этом по изменившейся базе.
    func setReadOnly(_ value: Bool, app: AppEnvironment) {
        isReadOnly = value
        readOnlyFlag.value = value
        app.settings.configuration.mcpReadOnly = value
        // Не отложенной записью: настройка про безопасность, и между
        // переключателем и файлом не должно быть окна, в которое влезает
        // аварийное завершение.
        app.settings.saveNow()
        app.log.record(.info, "MCP", value
            ? "MCP переведён в режим только чтения — запись запрещена всем ключам"
            : "Режим только чтения снят: ключи с правом записи снова могут писать")
    }

    private func handle(
        _ message: Data, from channel: MCPChannel, state: ChannelState, server: MCPServer
    ) async {
        // Приветствие моста — не сообщение агента: ключ запоминается за
        // соединением, ответа на уведомление протокол не допускает.
        if let incoming = try? JSONDecoder().decode(JSONRPCIncoming.self, from: message),
           incoming.method == MCPProtocol.helloNotification {
            state.key = incoming.params?["key"]?.stringValue
            await name(state)
            return
        }

        callCount += 1
        note(call: message, for: state)
        guard let response = await server.respond(to: message, key: state.key),
              let encoded = try? response.encoded()
        else { return }
        channel.send(encoded)
    }

    /// Имя клиента по его ключу — для экрана активности.
    ///
    /// Спрашивается один раз при подключении: имя нужно человеку, а искать его
    /// по хешу на каждом вызове значило бы платить за это на горячем пути.
    private func name(_ state: ChannelState) async {
        let client = await app?.proxy.access.client(withKey: state.key)
        guard let index = connections.firstIndex(where: { $0.id == state.id }) else { return }
        connections[index].clientName = client?.name
        connections[index].hasKey = state.key?.isEmpty == false
    }

    private func note(call message: Data, for state: ChannelState) {
        guard let index = connections.firstIndex(where: { $0.id == state.id }) else { return }
        connections[index].callCount += 1
        connections[index].lastCallAt = Date()
        guard let incoming = try? JSONDecoder().decode(JSONRPCIncoming.self, from: message) else { return }
        connections[index].lastTool = incoming.method == MCPProtocol.callToolMethod
            ? incoming.params?["name"]?.stringValue ?? incoming.method
            : incoming.method
    }

    /// Приложение, чтобы спросить имя клиента по ключу. Слабо — сервис живёт
    /// столько же, сколько окно, а окружение может пережить его.
    private weak var app: AppEnvironment?

    /// Подсказка модели: что это за сервер и в каком порядке им пользоваться.
    private static let instructions = """
    Это база документов ChromaDB, доступная через ChromaDB Manager. \
    Начинай с list_collections, чтобы узнать доступные коллекции, затем \
    describe_collection, чтобы понять, по каким полям метаданных можно \
    фильтровать. Запросы к поиску пиши текстом — векторы считает приложение \
    моделью, привязанной к коллекции. Коллекции вне списка доступа не видны, \
    создавать и удалять коллекции нельзя.
    """
}

/// Доступ инструментов MCP к приложению.
///
/// Тонкая прослойка: вся логика прав и форм ответа — в ядре, здесь только
/// обращения к базе и к схемам, каждое на главном акторе, потому что там живут
/// клиент и хранилище схем.
private final class AppMCPBackend: MCPToolBackend, @unchecked Sendable {
    private weak var app: AppEnvironment?

    init(app: AppEnvironment) {
        self.app = app
    }

    enum BackendError: LocalizedError {
        case notConnected
        case noCollection(String)

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return String(localized: "ChromaDB Manager не подключён к базе. Откройте приложение и подключитесь.")
            case .noCollection(let name):
                return String(localized: "Коллекция не найдена: \(name)")
            }
        }
    }

    private func client() async throws -> ChromaClient {
        guard let client = await MainActor.run(body: { app?.client }) else {
            throw BackendError.notConnected
        }
        return client
    }

    /// Коллекция по имени — то, чем агент её называет.
    ///
    /// Имя, а не идентификатор: UUID коллекции агенту негде взять, и знать его
    /// он не должен.
    private func collection(named name: String) async throws -> ChromaCollection {
        let all = try await client().listCollections(withCounts: true)
        guard let found = all.first(where: { $0.name == name }) else {
            throw BackendError.noCollection(name)
        }
        return found
    }

    func collections(allowed: [String]) async throws -> [MCPCollectionSummary] {
        let all = try await client().listCollections(withCounts: true)
        // Whitelist пустой значит «ничего»: право доступа выдаётся явно, и
        // пустой список — это отсутствие права, а не «всё разрешено».
        return all
            .filter { allowed.contains($0.name) }
            .map { collection in
                MCPCollectionSummary(
                    name: collection.name,
                    documentCount: collection.documentCount,
                    model: collection.boundModel,
                    metric: collection.space?.rawValue,
                    dimension: collection.effectiveDimension
                )
            }
    }

    func describe(collection name: String) async throws -> MCPCollectionDescription {
        let client = try await client()
        let collection = try await self.collection(named: name)
        let summary = MCPCollectionSummary(
            name: collection.name,
            documentCount: collection.documentCount,
            model: collection.boundModel,
            metric: collection.space?.rawValue,
            dimension: collection.effectiveDimension
        )

        let schema = await MainActor.run { app?.schemaStore.schema(for: name) }
        // Примеры значений берутся из настоящих документов: без них модель
        // строит фильтр наугад и получает пустую выдачу, не понимая причины.
        let sample = try await client.getDocuments(collectionID: collection.id, limit: 50)
        let fields = Self.fields(schema: schema, sample: sample)

        return MCPCollectionDescription(
            summary: summary,
            fields: fields,
            hasSchema: schema != nil,
            allowsExtraFields: schema?.allowsExtraFields ?? true
        )
    }

    private func environment() async throws -> AppEnvironment {
        guard let app = await MainActor.run(body: { self.app }) else {
            throw BackendError.notConnected
        }
        return app
    }

    func search(_ request: MCPSearchRequest) async throws -> MCPSearchAnswer {
        let app = try await environment()
        let collection = try await collection(named: request.collection)
        // Тот же конвейер, что у экрана поиска: профиль, стадии,
        // переранжирование и настройки, которые человек подкрутил, действуют
        // и на запросы агента — иначе он ищет не в той же базе, что владелец.
        let prepared = try await app.prepareSearch(
            for: collection, smartSearch: request.smartSearch, priority: .agent
        )
        let outcome = try await prepared.pipeline.run(
            RetrievalRequest(
                text: request.query,
                collectionID: collection.id,
                collectionName: collection.name,
                nResults: request.nResults,
                filter: request.filter,
                metric: collection.space
            ),
            profile: prepared.profile
        )

        let payloads = outcome.hits.flatMap { hit -> [MCPDocumentPayload] in
            var rows = [MCPDocumentPayload(
                id: hit.id,
                text: hit.document,
                metadata: hit.metadata,
                distance: hit.distance,
                role: hit.role,
                note: hit.collapsedNote
            )]
            // Контекст едет отдельными строками с пометкой: сцепить его
            // с текстом совпадения значило бы отдать агенту документ, которого
            // в базе нет, и он процитировал бы его как настоящий.
            rows += hit.context.map { context in
                MCPDocumentPayload(
                    id: context.id,
                    text: context.document,
                    metadata: context.metadata,
                    distance: nil,
                    role: .context,
                    note: Self.contextNote(context.contextKind)
                )
            }
            return rows
        }

        await MainActor.run {
            app.log.record(
                .info, "MCP",
                "Поиск агента в «\(collection.name)»: «\(request.query.prefix(80))», найдено \(outcome.hits.count)"
            )
        }

        return MCPSearchAnswer(
            documents: payloads,
            metric: collection.space?.rawValue,
            model: prepared.model,
            note: Self.pipelineNote(
                outcome.diagnostics,
                smartSearch: prepared.smartSearchEnabled,
                decidedByKey: request.smartSearch != nil
            )
        )
    }

    func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer {
        let client = try await client()
        let collection = try await collection(named: request.collection)

        if !request.ids.isEmpty {
            let records = try await client.getDocuments(
                collectionID: collection.id, limit: request.ids.count, ids: request.ids
            )
            return MCPDocumentsAnswer(documents: records.map(Self.payload), hasMore: false)
        }

        // На один документ больше, чем нужно: «ровно limit» и «есть ещё»
        // иначе неотличимы, и агент бросает просмотр на середине коллекции.
        let records = try await client.getDocuments(
            collectionID: collection.id,
            limit: request.limit + 1,
            offset: request.offset,
            filter: request.filter
        )
        return MCPDocumentsAnswer(
            documents: records.prefix(request.limit).map(Self.payload),
            hasMore: records.count > request.limit
        )
    }

    func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer {
        let app = try await environment()
        let client = try await client()
        let collection = try await collection(named: request.collection)

        let model = try await app.bindingService.requiredModel(for: collection)
        let lmStudio = try await MainActor.run { try app.makeLMStudioClient() }
        try await app.bindingService.ensureAvailable(model: model, lmStudio: lmStudio)

        // Идентификаторы проверяются заранее и все разом: `add` на занятый id
        // отвечает 201 и не меняет ничего, то есть агент получил бы
        // «записано» на документ, которого в базе не появилось.
        let named = request.documents.compactMap(\.id)
        if !named.isEmpty {
            let taken = try await client.existingIDs(collectionID: collection.id, ids: named)
            if !taken.isEmpty {
                throw MCPToolFailure(String(
                    localized: "Эти идентификаторы уже заняты: \(taken.sorted().joined(separator: ", ")). Перезаписывать существующие документы этот инструмент не будет — задай другие id или не задавай их вовсе."
                ))
            }
        }

        // Длину текста не поймает никто ниже: LM Studio отвечает 200 на текст
        // любой длины и молча индексирует его начало.
        let contextLength = await app.bindingService.contextLength(of: model, lmStudio: lmStudio)
        let schema = await MainActor.run { app.schemaStore.schema(for: collection.name) }
        let validator = MetadataSchemaValidator()

        var records: [EmbeddedRecord] = []
        var warnings: [String] = []
        for (index, incoming) in request.documents.enumerated() {
            let number = index + 1
            if case .tooLong(let tokens, let allowed) = ContextBudget.check(incoming.text, contextLength: contextLength) {
                throw MCPToolFailure(String(
                    localized: "Документ \(number.plainDigits) длиннее контекста модели \(model): примерно \(tokens.plainDigits) токенов при пределе \(allowed.plainDigits). Раздели его на части и пришли их отдельными документами — этот инструмент текст не режет. Не записано ничего."
                ))
            }

            var metadata = incoming.metadata ?? [:]
            if let schema {
                metadata = validator.normalised(metadata, schema: schema)
                let result = validator.validate(metadata, against: schema, documentID: incoming.id)
                guard result.isValid else {
                    throw MCPToolFailure(String(
                        localized: "Документ \(number.plainDigits) не соответствует схеме коллекции: \(result.violations.map(\.message).joined(separator: "; ")). Поля и типы — в describe_collection. Не записано ничего."
                    ))
                }
            }
            // Происхождение проставляет приложение, а не агент: поле отвечает
            // на вопрос «кто это записал», и записанному со слов ответу цена
            // невелика (5.5).
            metadata.stamp(origin: .mcp)

            let vector = try await app.queue.run(QueueTicket(
                title: String(localized: "Эмбеддинг документа агента для «\(collection.name)»"),
                // Не `.interactive`: у очереди для агента есть своя ступень,
                // и она ниже человека у экрана — тот ждёт ответа сейчас.
                priority: .agent,
                group: .lmStudio,
                connectionID: app.connectionID
            )) { _ in
                try await lmStudio.embed(text: incoming.text, model: model)
            }
            try await app.bindingService.validate(vectorLength: vector.count, for: collection)

            records.append(EmbeddedRecord(
                id: incoming.id ?? UUID().uuidString,
                document: incoming.text,
                embedding: vector,
                metadata: metadata
            ))
        }

        try await client.add(collectionID: collection.id, records: records)
        // Число снимается до перехода на главный поток: читать растущую
        // переменную из параллельно исполняемого кода — гонка, пусть здесь она
        // и безобидна.
        let written = records.count
        await MainActor.run {
            app.log.record(
                .success, "MCP",
                "Агент записал в «\(collection.name)» документов: \(written)"
            )
        }

        if request.documents.contains(where: { ($0.metadata?[DocumentOrigin.metadataKey]) != nil }) {
            // Молчаливая подмена — та же ложь, что и молчаливая обрезка.
            warnings.append(String(localized: "Поле origin задано приложением: у документов, пришедших через MCP, оно всегда «mcp»."))
        }

        return MCPAddAnswer(
            ids: records.map(\.id), model: model,
            note: warnings.isEmpty ? nil : warnings.joined(separator: " ")
        )
    }

    func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer {
        let app = try await environment()
        let client = try await client()
        let collection = try await collection(named: request.collection)

        // Сначала читаем то, что собираемся снести: без этого в корзину класть
        // нечего, а «удалено 5» при трёх существующих — неправда (правило 5).
        let existing = try await client.getDocuments(
            collectionID: collection.id, limit: request.ids.count, ids: request.ids
        )
        let found = existing.map(\.id)
        let missing = request.ids.filter { !found.contains($0) }

        guard !found.isEmpty else {
            return MCPDeleteAnswer(deleted: [], missing: missing, keptInTrash: false)
        }

        let usesTrash = await MainActor.run { app.settings.configuration.trashEnabled }
        if usesTrash {
            let vectors = try await client.embeddings(collectionID: collection.id, ids: found)
            let entries = existing.map { record in
                TrashEntry(
                    documentID: record.id,
                    document: record.document,
                    metadata: record.metadata,
                    embedding: vectors[record.id],
                    collectionName: collection.name,
                    collectionMetric: collection.space,
                    collectionModel: collection.boundModel,
                    collectionDimension: collection.effectiveDimension,
                    reason: .document
                )
            }
            // Бросит, если копия не легла на диск, — и `deleteDocuments`
            // ниже тогда не выполнится вовсе. Агент получит ошибку
            // инструмента с причиной, база останется нетронутой.
            try await MainActor.run { try app.trash.record(entries) }
        }

        try await client.deleteDocuments(collectionID: collection.id, ids: found)
        await MainActor.run {
            app.log.record(
                usesTrash ? .info : .warning, "MCP",
                usesTrash
                    ? "Агент удалил из «\(collection.name)» документов: \(found.count) — копии в корзине"
                    : "Агент удалил из «\(collection.name)» документов: \(found.count) — корзина выключена, копий нет"
            )
        }
        return MCPDeleteAnswer(deleted: found, missing: missing, keptInTrash: usesTrash)
    }

    private static func payload(_ record: DocumentRecord) -> MCPDocumentPayload {
        MCPDocumentPayload(
            id: record.id, text: record.document, metadata: record.metadata, distance: nil
        )
    }

    private static func contextNote(_ kind: ContextKind?) -> String? {
        switch kind {
        case .parent: return String(localized: "раздел, к которому относится совпадение")
        case .neighbour: return String(localized: "соседний фрагмент того же файла")
        case nil: return nil
        }
    }

    /// Причина сбоя человеческими словами.
    ///
    /// Ответ чужой службы приходит вместе с телом JSON — оно попадает в лог
    /// целиком и там нужно, а модели от обрезанного посреди фигурной скобки
    /// блоба пользы нет. Берётся то, что перед ним.
    static func shortReason(_ note: String) -> String {
        let head = note.prefix(while: { $0 != "{" })
        let cleaned = head.trimmingCharacters(in: CharacterSet(charactersIn: " :\n\t"))
        let text = cleaned.isEmpty ? note : cleaned
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }

    /// Чем именно искали — одной строкой для агента.
    ///
    /// Не диагностика ради диагностики: выдача умного поиска отличается от
    /// выдачи обычного, и агент, пересказывающий результат человеку, вправе
    /// знать, что список ему переупорядочил переранжировщик.
    private static func pipelineNote(
        _ diagnostics: RetrievalDiagnostics, smartSearch: Bool, decidedByKey: Bool
    ) -> String? {
        guard smartSearch else {
            // Где именно выключено, названо прямо: иначе владелец базы будет
            // искать причину в настройках коллекции, а она в правах ключа.
            return decidedByKey
                ? String(localized: "Умный поиск выключен в правах этого ключа — обычный векторный поиск.")
                : String(localized: "Умный поиск для этой коллекции выключен — обычный векторный поиск.")
        }
        let sorted = diagnostics.stages.sorted { $0.stage.order < $1.stage.order }
        var lines: [String] = []

        let ran = sorted.filter { $0.ran && $0.stage.isOptional }.map(\.stage.title)
        if !ran.isEmpty { lines.append(String(localized: "Как искали: \(ran.joined(separator: ", ")).")) }

        // Стадия, которую попросили и которая упала, — не то же самое, что
        // выключенная. Промолчать о ней значит выдать агенту список, который
        // никто не переранжировал, за переранжированный.
        for stage in sorted where stage.failed {
            let reason = stage.note.map(Self.shortReason)
            lines.append(reason.map {
                String(localized: "Не отработало: \(stage.stage.title) — \($0). Выдача собрана без этой стадии.")
            } ?? String(localized: "Не отработало: \(stage.stage.title). Выдача собрана без этой стадии."))
        }

        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// Сколько полей уходит агенту.
    ///
    /// Не ограничение ради ограничения: у коллекции с богатыми метаданными
    /// полей бывают десятки, и все они попадут в контекст модели целиком.
    static let fieldLimit = 30

    /// Поля по схеме, а если схемы нет — по тому, что реально записано.
    static func fields(schema: MetadataSchema?, sample: [DocumentRecord]) -> [MCPFieldDescription] {
        var examples: [String: [String]] = [:]
        var types: [String: String] = [:]
        for record in sample {
            for (key, value) in record.metadata ?? [:] {
                let text = value.displayString
                guard !text.isEmpty else { continue }
                // Тип берётся из самого значения, а не назначается «строкой».
                // Модель строит по нему фильтр: увидев `chunk_index — string`,
                // она сравнит с «0» вместо 0 и получит пустую выдачу, не
                // поняв, почему.
                let observed = Self.typeName(value)
                if let known = types[key], known != observed {
                    // Поле, где встречаются разные типы, — так и называется:
                    // соврать одним из них хуже, чем сказать правду.
                    types[key] = "mixed"
                } else {
                    types[key] = observed
                }
                var list = examples[key, default: []]
                if !list.contains(text), list.count < 5 { list.append(text) }
                examples[key] = list
            }
        }

        if let schema, !schema.isEmpty {
            return schema.fields
                .filter { !$0.trimmedKey.isEmpty }
                .map { field in
                    MCPFieldDescription(
                        key: field.trimmedKey,
                        type: field.type.rawValue,
                        isRequired: field.isRequired,
                        note: field.note,
                        examples: examples[field.trimmedKey] ?? []
                    )
                }
        }

        // Служебные поля приложения агенту не нужны: фильтровать по ним он
        // не станет, а место в контексте они займут.
        return examples.keys
            .filter { !$0.hasPrefix("_cdbm") }
            .sorted()
            .prefix(fieldLimit)
            .map { key in
                MCPFieldDescription(
                    key: key, type: types[key] ?? "string", isRequired: false, note: nil,
                    examples: examples[key] ?? []
                )
            }
    }

    static func typeName(_ value: MetadataValue) -> String {
        switch value {
        case .string: return "string"
        case .int: return "int"
        case .double: return "float"
        case .bool: return "bool"
        case .null: return "null"
        }
    }
}
