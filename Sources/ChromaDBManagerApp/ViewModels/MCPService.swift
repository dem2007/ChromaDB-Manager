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
    @Published var lastError: String?
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
                audit: { [audit = app.audit] entry in audit.record(entry) },
                // …и та же отметка «ключ работал», что у прокси.
                // Без неё карточка клиента говорила «ещё не подключался» про
                // ключ, которым минуту назад искали, — и это видно на экране
                // рядом с журналом, где те же вызовы перечислены поимённо.
                onClientSeen: { [weak app] id in
                    Task { @MainActor [weak app] in app?.noteClientSeen(id) }
                }
            )
        )

        // Тот же сервер обслуживает и сокет, и HTTP: инструменты, права
        // и журнал у обоих транспортов одни. Второй экземпляр означал
        // бы, что «через сокет можно, а по сети нельзя» — и наоборот.
        self.server = server
        applyHTTPMode(app)

        listener.onConnection = { [weak self] channel in
            let state = ChannelState()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.channels[ObjectIdentifier(channel)] = state
                self.connections.append(MCPConnection(id: state.id, connectedAt: Date()))
                // В журнал, а не только в живой список на экране.
                // Список показывает, кто подключён **сейчас**; вопрос «рвутся
                // ли сессии» — про прошлое, и до этой записи ответить на него
                // было нечем: в журнале за сутки не было ни одной строки
                // о мостах, только «сервер слушает» после запуска.
                app.log.record(.info, "MCP", "Мост подключился (соединений: \(self.connections.count.plainDigits))")
            }
            channel.onMessage = { [weak self] message in
                Task { @MainActor [weak self] in
                    await self?.handle(message, from: channel, state: state, server: server)
                }
            }
            channel.onClose = { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.channels[ObjectIdentifier(channel)] = nil
                    let closing = self.connections.first { $0.id == state.id }
                    self.connections.removeAll { $0.id == state.id }
                    // Кто ушёл, сколько успел спросить и сколько прожил —
                    // и по чьей вине, если связь оборвалась с ошибкой.
                    let name = closing?.clientName ?? String(localized: "без ключа")
                    let calls = closing?.callCount ?? 0
                    let lived = closing.map { Int(Date().timeIntervalSince($0.connectedAt)) } ?? 0
                    if let error {
                        app.log.record(.warning, "MCP", "Мост «\(name)» отключён с ошибкой: \(error.localizedDescription) (вызовов \(calls.plainDigits), \(lived.plainDigits) с)")
                    } else {
                        app.log.record(.info, "MCP", "Мост «\(name)» отключился (вызовов \(calls.plainDigits), \(lived.plainDigits) с)")
                    }
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

    // MARK: - HTTP-режим

    /// Сервер, общий для сокета и HTTP. Хранится, чтобы HTTP-режим можно было
    /// включить и выключить, не перезапуская слушатель сокета.
    private var server: MCPServer?

    /// Отдаётся ли MCP по сети прямо сейчас — для экрана.
    @Published private(set) var isServedOverHTTP = false

    /// Адрес, который получит агент. `nil`, когда отдавать нечего.
    func httpAddress(_ app: AppEnvironment) -> String? {
        // `isServedOverHTTP`, а не настройка: пока сервер MCP не поднялся,
        // отдавать по сети нечего, и показывать адрес, по которому придёт
        // отказ, — хуже, чем не показывать ничего.
        guard isServedOverHTTP, case .running(let address, let port) = app.proxy.state else {
            return nil
        }
        let scheme = app.proxy.tls.scheme
        // Адрес показывается тот, по которому клиент действительно придёт:
        // `0.0.0.0` — это «слушаем везде», а не адрес для подключения.
        let host = address == "0.0.0.0" ? (LocalNetwork.addresses().first ?? "127.0.0.1") : address
        return "\(scheme)://\(host):\(port.plainDigits)\(MCPHTTPTransport.endpointPath)"
    }

    func setHTTP(_ value: Bool, app: AppEnvironment) {
        app.settings.configuration.mcpOverHTTP = value
        // Сразу на диск: настройка про то, открыта ли дверь наружу.
        app.settings.saveNow()
        applyHTTPMode(app)
        guard value else {
            app.log.record(.info, "MCP", "MCP по сети выключен — остаётся только stdio")
            return
        }
        // Включить настройку и включить режим — не одно и то же: без
        // поднятого сервера MCP отдавать нечего, и рапортовать об успехе
        // в этом случае значит соврать.
        if isServedOverHTTP {
            app.log.record(.info, "MCP", "MCP отдаётся по сети на \(httpAddress(app) ?? MCPHTTPTransport.endpointPath)")
        } else {
            lastError = String(localized: "MCP-сервер не запущен, поэтому по сети он пока недоступен.")
            app.log.record(.warning, "MCP", "Режим по сети включён, но сервер MCP не запущен — отдавать нечего")
        }
    }

    /// Ставит или снимает обработчик у прокси по текущей настройке.
    ///
    /// Обработчик живёт у прокси, а не у его слушателя, и перезапуск прокси
    /// (смена режима доступа, включение TLS) его не теряет — проверено тем,
    /// что `stop()` его не трогает.
    func applyHTTPMode(_ app: AppEnvironment) {
        guard let server, app.settings.configuration.mcpOverHTTP else {
            app.proxy.mcp = nil
            isServedOverHTTP = false
            return
        }
        let transport = MCPHTTPTransport(
            server: server,
            // Список origin'ов у приложения уже есть — в правах клиентов.
            isOriginAllowed: { [access = app.proxy.access] origin in
                await access.originIsAllowedByAnyClient(origin)
            }
        )
        app.proxy.mcp = { method, headers, body, key in
            await transport.handle(method: method, headers: headers, body: body, key: key)
        }
        isServedOverHTTP = true
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
        // Подключение — это уже активность ключа. Раньше отметка
        // ставилась только на вызове инструмента, и агент, который поднял
        // мост и ничего не спросил, оставался «ещё не подключался» —
        // при том что соединение в этот момент открыто и видно рядом.
        if let client, client.isEnabled {
            app?.noteClientSeen(client.id)
        }
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
    /// Подсказка модели при рукопожатии.
    ///
    /// Здесь же и главное правило выбора инструмента: агент, которому
    /// его не сказали, на вопрос «во всех ли документах это есть» зовёт поиск
    /// по смыслу и получает три файла из тринадцати. Текст короткий нарочно:
    /// он попадает в контекст **каждой** сессии. Язык — английский по:
    /// читатель этого текста — модель, а не человек за экраном.
    /// Открыто для сторожа `MCPHandshakeLanguageTests`: подсказку читает модель,
    /// и её язык обязан проверяться, а не заявляться.
    static let instructions = """
    This is a ChromaDB document base reached through ChromaDB Manager. \
    Start with list_collections to learn which collections are available and \
    what the ceilings of your key are, then describe_collection to learn which \
    metadata fields you may filter on. Write search queries as text — the \
    application computes the vectors with the model bound to the collection. \
    Pick the tool by the question. «What does it say about this» — search. \
    «Show every place this appears», «is it described in every document» — \
    collect_mentions: search by meaning does not give coverage, and the \
    measurement on a live base is chunks of three files out of thirteen at any \
    number of results. \
    A whole document — get_file: it returns continuous text, and you page it \
    with the «offset» the answer gives you. Every answer also names \
    «sourcePath», where the document sits on this machine's disk — if you can \
    read files there, that is the whole document in one step. To work with a \
    large document without reading it whole, ask get_file for «outline» \
    first — it says what the file costs to read whole and which section you \
    want — then that section by «heading». \
    The documents are in whatever language the corpus is in — and so are the \
    stems for «contains» and the names of table columns: they are literal \
    substrings of the corpus, pass them in its language. Answer the user in \
    the language the user wrote in. \
    If the answer holds table rows, their columns are the filter fields; ask \
    for only the ones you need in «fields», or the row brings all of its \
    columns and the answer is cut off by size. \
    Collections outside the access list are invisible; creating and deleting \
    collections is not allowed.
    """
}

/// Доступ инструментов MCP к приложению.
///
/// Тонкая прослойка: вся логика прав и форм ответа — в ядре, здесь только
/// обращения к базе и к схемам, каждое на главном акторе, потому что там живут
/// клиент и хранилище схем.
/// Видимость обычная, не `private`: заметки этого класса уезжают в ответ
/// модели, и сторож `MCPAnswerLanguageTests` обязан до них дотянуться.
final class AppMCPBackend: MCPToolBackend, @unchecked Sendable {
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
                return "ChromaDB Manager is not connected to the database. Open the application and connect."
            case .noCollection(let name):
                return "Collection not found: \(name)"
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
    ///
    /// Список — без счётчиков, а число документов спрашивается у одной
    /// найденной: каждый вызов инструмента иначе делал по запросу `count`
    /// на каждую коллекцию базы.
    private func collection(named name: String) async throws -> ChromaCollection {
        let client = try await client()
        let all = try await client.listCollections(withCounts: false)
        guard var found = all.first(where: { $0.name == name }) else {
            throw BackendError.noCollection(name)
        }
        found.documentCount = try? await client.count(collectionID: found.id)
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
        //
        // Выборка — **с нескольких мест коллекции**, а не первые полсотни
        // подряд. Строки таблиц лежат там, куда их положила
        // синхронизация, и в начало не попадают: на живой коллекции из 5765
        // чанков 1290 строк таблиц, а в первых пятидесяти документах не
        // оказалось ни одной. Колонки с ценами — «стоимость_тыс_руб»,
        // «итого», «2026» — агенту не показывались вовсе, и фильтр по ним
        // он составить не мог.
        let sample = try await MCPFieldSummary.spreadSample(client: client, collection: collection)
        let described = MCPFieldSummary.fields(schema: schema, sample: sample)

        return MCPCollectionDescription(
            summary: summary,
            fields: described.shown,
            hasSchema: schema != nil,
            allowsExtraFields: schema?.allowsExtraFields ?? true,
            otherFields: described.hidden
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
        // Несколько коллекций — отдельным путём: вектор запроса
        // считается по разу на модель, а не на коллекцию.
        if request.isMultiCollection {
            return try await searchAcross(request, app: app)
        }
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

    /// Поиск сразу по нескольким коллекциям — тем же ядром, что и на экране.
    ///
    /// Каждая коллекция ищется **тем же** конвейером и своим профилем, как
    /// и при обычном поиске: агент обязан получать ту же выдачу, что
    /// человек за экраном, а не вторую реализацию поиска.
    private func searchAcross(
        _ request: MCPSearchRequest, app: AppEnvironment
    ) async throws -> MCPSearchAnswer {
        var targets: [MultiCollectionSearch.Target] = []
        var missing: [String] = []
        for name in request.collections {
            guard let collection = try? await collection(named: name) else {
                missing.append(name)
                continue
            }
            let prepared = try await app.prepareSearch(
                for: collection, smartSearch: request.smartSearch, priority: .agent
            )
            targets.append(MultiCollectionSearch.Target(
                collectionID: collection.id, collectionName: collection.name,
                model: prepared.model, metric: collection.space, profile: prepared.profile
            ))
        }

        // Вектор считается здесь и по разу на модель, а не внутри конвейера
        // каждой коллекции: в этом весь выигрыш. Через ту же очередь
        // и с тем же приоритетом агента, что и обычный поиск.
        let (lmStudio, queue, connectionID) = try await MainActor.run {
            (try app.makeLMStudioClient(), app.queue, app.connectionID)
        }
        let client = try await client()
        let shapes = app.collectionShapes

        // Стадия 7 — одна на всю слитую выдачу, а не по разу на коллекцию:
        // модель обязана сравнивать кандидатов между коллекциями.
        // Чьими настройками спрашивать, решает правило согласия профилей.
        let plan = MultiCollectionSearch.rerankPlan(targets: targets)
        var rerank: RerankStage?
        if let governing = plan.profile {
            rerank = try await app.makeRerankStage(
                for: governing,
                title: String(localized: "Переранжирование по нескольким коллекциям"),
                priority: .agent
            )
        }

        let search = MultiCollectionSearch(
            embed: { text, model in
                try await queue.run(QueueTicket(
                    title: String(localized: "Поиск агента по нескольким коллекциям"),
                    priority: .agent,
                    group: .lmStudio,
                    connectionID: connectionID
                )) { _ in
                    try await lmStudio.embed(text: text, model: model)
                }
            },
            search: { target, query, vector in
                // Тот же `RetrievalPipeline`, что и везде, только
                // с уже посчитанным вектором — как в стенде оценки.
                let pipeline = RetrievalPipeline(
                    database: client, shapes: shapes, embed: { _ in vector }
                )
                return try await pipeline.run(
                    RetrievalRequest(
                        text: query,
                        collectionID: target.collectionID,
                        collectionName: target.collectionName,
                        nResults: target.results(forRequested: request.nResults),
                        filter: request.filter,
                        metric: target.metric
                    ),
                    profile: target.profile
                )
            },
            rerank: rerank
        )
        let answer = await search.run(
            query: request.query, targets: targets, nResults: request.nResults
        )

        let payloads = answer.hits.map { hit in
            MCPDocumentPayload(
                id: hit.id, text: hit.document, metadata: hit.metadata,
                distance: hit.distance, role: hit.role, note: hit.collapsedNote,
                collection: hit.collectionName
            )
        }

        var notes = [answer.line]
        if !missing.isEmpty {
            notes.append("Collections not found: \(missing.joined(separator: ", ")) — check the names with list_collections.")
        }
        for report in answer.collections where report.failure != nil {
            notes.append("The collection «\(report.name)» did not answer: \(report.failure ?? "")")
        }

        await MainActor.run {
            app.log.record(
                .info, "MCP",
                "Поиск агента по коллекциям \(request.collections.joined(separator: ", ")): «\(request.query.prefix(80))», \(answer.line)"
            )
        }

        return MCPSearchAnswer(
            documents: payloads,
            // Метрика у коллекций разная, и одна на всю выдачу была бы
            // неправдой: у каждого результата она своя, а расстояния между
            // коллекциями и так несравнимы — выдача упорядочена рангами.
            metric: nil,
            model: nil,
            note: notes.joined(separator: " ")
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

        if request.orderedByChunkIndex {
            return try await orderedChunks(of: collection.id, request: request, client: client)
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

    /// Чанки файла по порядку.
    ///
    /// Порядок требует **всей** выборки: `get` у ChromaDB его не обещает, и
    /// отсортировать страницу, взятую произвольно, значит отдать не те куски
    /// в правильном на вид порядке. Поэтому сначала перечисляются все чанки
    /// файла — без текстов, одни метаданные, — потом берётся окно, и только
    /// за ним запрашиваются тексты.
    ///
    /// Две ходки вместо одной — цена детерминированного листания: агент,
    /// читающий файл страницами, получает одни и те же границы при каждом
    /// вызове, а не «как база отдала в этот раз».
    private func orderedChunks(
        of collectionID: String, request: MCPDocumentsRequest, client: ChromaClient
    ) async throws -> MCPDocumentsAnswer {
        let (scanned, overflowed) = try await MCPFileChunks.collect { limit, offset in
            try await client.getDocuments(
                collectionID: collectionID, limit: limit, offset: offset,
                filter: request.filter, includeDocuments: false
            ).map(Self.payload)
        }
        let ordered = overflowed ? scanned : MCPFileChunks.ordered(scanned)
        let window = MCPFileChunks.page(ordered, offset: request.offset, limit: request.limit)
        guard !window.page.isEmpty else {
            return MCPDocumentsAnswer(
                documents: [], hasMore: false, total: ordered.count, orderUnavailable: overflowed
            )
        }

        // Оглавлению текст не нужен вовсе: оно строится по заголовкам
        // и номерам, а окно у него — весь файл. Ходить за текстами тысячи
        // кусков, чтобы их выбросить, — это ровно та цена, ради ухода от
        // которой оглавление и сделано.
        guard request.needsText else {
            return MCPDocumentsAnswer(
                documents: window.page, hasMore: window.hasMore,
                total: ordered.count, orderUnavailable: overflowed
            )
        }

        // Тексты — только у окна. Порядок восстанавливается по списку id:
        // выдача `get` по идентификаторам тоже не обязана его сохранять.
        let ids = window.page.map(\.id)
        let records = try await client.getDocuments(
            collectionID: collectionID, limit: ids.count, ids: ids
        )
        let byID = Dictionary(records.map { ($0.id, Self.payload($0)) }, uniquingKeysWith: { first, _ in first })
        return MCPDocumentsAnswer(
            documents: ids.compactMap { byID[$0] },
            hasMore: window.hasMore,
            total: ordered.count,
            orderUnavailable: overflowed
        )
    }

    func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer {
        let app = try await environment()
        let client = try await client()
        let collection = try await collection(named: request.collection)

        // Ошибки привязки и LM Studio отвечают по-русски — их тексты писались
        // человеку у экрана. Модели они уходят по-английски: `BindingError`
        // и `LMStudioError` умеют говорить с ней сами (`MCPReadableError`,
        //). Оборачивать их здесь своей формулировкой нельзя: «модель
        // не загружена» вместо «LM Studio не отвечает» — это подмена причины.
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
                throw MCPToolFailure(
                    "These identifiers are already taken: \(taken.sorted().joined(separator: ", ")). This tool will not overwrite existing documents — give other ids, or give none at all."
                )
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
                throw MCPToolFailure(
                    "Document \(number.plainDigits) is longer than the context of the model \(model): about \(tokens.plainDigits) tokens against a limit of \(allowed.plainDigits). Split it and send the parts as separate documents — this tool does not cut text. Nothing was written."
                )
            }

            var metadata = incoming.metadata ?? [:]
            if let schema {
                metadata = validator.normalised(metadata, schema: schema)
                let result = validator.validate(metadata, against: schema, documentID: incoming.id)
                guard result.isValid else {
                    throw MCPToolFailure(
                        "Document \(number.plainDigits) does not match the collection schema: \(result.violations.map(\.message).joined(separator: "; ")). The fields and their types are in describe_collection. Nothing was written."
                    )
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
            warnings.append("The origin field is set by the application: for documents that arrive over MCP it is always «mcp».")
        }

        return MCPAddAnswer(
            ids: records.map(\.id), model: model,
            note: warnings.isEmpty ? nil : warnings.joined(separator: " ")
        )
    }

    /// Где лежит исходный файл — тем же разбором, каким его открывает
    /// просмотрщик.
    ///
    /// Агент работает на той же машине: назвать путь дешевле любого чтения
    /// через канал вызовов. Своего разбора здесь нет нарочно — второй способ
    /// собрать путь означал бы второй набор ошибок.
    func fileOnDisk(metadata: ChromaMetadata?) async -> MCPFileOnDisk? {
        guard let app = try? await environment() else { return nil }
        let sources = await MainActor.run { app.settings.configuration.dataSources }
        guard case .found(let url, _, _) = DocumentLocator.resolve(
            metadata: metadata, sources: sources
        ) else { return nil }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
        return MCPFileOnDisk(path: url.path, bytes: bytes)
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

    /// Открыто для сторожа `MCPAnswerLanguageTests`: этот ярлык
    /// уезжает в ответ модели, и его язык обязан проверяться.
    static func contextNote(_ kind: ContextKind?) -> String? {
        switch kind {
        case .parent: return "the section the match belongs to"
        case .neighbour: return "a neighbouring chunk of the same file"
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
    /// Открыто для сторожа `MCPAnswerLanguageTests`: заметка уезжает
    /// в ответ модели, и её язык обязан проверяться, а не заявляться.
    static func pipelineNote(
        _ diagnostics: RetrievalDiagnostics, smartSearch: Bool, decidedByKey: Bool
    ) -> String? {
        guard smartSearch else {
            // Где именно выключено, названо прямо: иначе владелец базы будет
            // искать причину в настройках коллекции, а она в правах ключа.
            return decidedByKey
                ? "Smart search is switched off in this key's rights — a plain vector search."
                : "Smart search is switched off for this collection — a plain vector search."
        }
        let sorted = diagnostics.stages.sorted { $0.stage.order < $1.stage.order }
        var lines: [String] = []

        let ran = sorted.filter { $0.ran && $0.stage.isOptional }.map(\.stage.agentName)
        if !ran.isEmpty { lines.append("How the list was built: \(ran.joined(separator: ", ")).") }

        // Стадия, которую попросили и которая упала, — не то же самое, что
        // выключенная. Промолчать о ней значит выдать агенту список, который
        // никто не переранжировал, за переранжированный.
        for stage in sorted where stage.failed {
            let reason = stage.note.map(Self.shortReason)
            lines.append(reason.map {
                "Did not run: \(stage.stage.agentName) — \($0). The list was assembled without that stage."
            } ?? "Did not run: \(stage.stage.agentName). The list was assembled without that stage.")
        }

        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

}

/// Поля коллекции для `describe_collection` — счёт по выборке документов
///.
///
/// Отдельным типом, а не методом соединения: расчёт чистый — зависит только от
/// схемы и выборки, — и проверяется тестом без сети, LM Studio и ChromaDB.
/// Пока он жил в приватном классе, проверить его было нечем, и обе беды
/// (выборка подряд и молчаливая обрезка полей) нашлись только на живых данных.
enum MCPFieldSummary {
    /// Сколько полей уходит агенту.
    ///
    /// Не ограничение ради ограничения: у коллекции с богатыми метаданными
    /// полей бывают десятки, и все они попадут в контекст модели целиком.
    static let fieldLimit = 30

    /// Выборка документов **с разных мест коллекции**.
    ///
    /// Пять окон вместо одного: столько же документов, но увиденное перестаёт
    /// зависеть от того, что синхронизация положила первым. Меньше окон не
    /// даёт разброса, больше — платится запросами ради всё той же полусотни.
    static func spreadSample(
        client: ChromaClient, collection: ChromaCollection, total: Int = 50, windows: Int = 5
    ) async throws -> [DocumentRecord] {
        let count = collection.documentCount ?? 0
        let perWindow = max(1, total / windows)
        guard count > total else {
            return try await client.getDocuments(collectionID: collection.id, limit: total)
        }
        var records: [DocumentRecord] = []
        var seen = Set<String>()
        // Строки таблиц спрашиваются **отдельно и первым делом**.
        // Разброса по коллекции для них мало: на живой базе с 14% строк
        // таблиц пять окон по пятьдесят документов не поймали ни одной, а
        // именно их колонки — «стоимость_тыс_руб», «итого» — и есть то, ради
        // чего агент приходит к таблицам. Условие «есть номер строки» стоит
        // 39–61 мс и находит их в любой коллекции, где они вообще есть.
        var tableRows = DocumentFilter()
        tableRows.conditions = [MetadataCondition(field: "row_number", op: .greaterOrEqual, value: "0")]
        if let rows = try? await client.getDocuments(
            collectionID: collection.id, limit: max(1, perWindow), filter: tableRows
        ) {
            for record in rows where seen.insert(record.id).inserted { records.append(record) }
        }
        for window in 0..<windows {
            // Последнее окно упирается в конец коллекции, а не выходит за него.
            let offset = min(count - perWindow, window * (count / windows))
            let batch = try await client.getDocuments(
                collectionID: collection.id, limit: perWindow, offset: max(0, offset)
            )
            for record in batch where seen.insert(record.id).inserted {
                records.append(record)
            }
        }
        return records
    }

    /// Поля по схеме, а если схемы нет — по тому, что реально записано.
    static func fields(
        schema: MetadataSchema?, sample: [DocumentRecord]
    ) -> (shown: [MCPFieldDescription], hidden: [String]) {
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
            let bySchema = schema.fields
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
            // Поля, встреченные в документах, но не объявленные в схеме, —
            // тоже именами: схема бывает неполной, а фильтровать по ним можно.
            let declared = Set(bySchema.map(\.key))
            let extra = examples.keys
                .filter { !$0.hasPrefix("_cdbm") && !declared.contains($0) }
                .sorted()
            return (bySchema, extra)
        }

        // Служебные поля приложения агенту не нужны: фильтровать по ним он
        // не станет, а место в контексте они займут.
        let visible = examples.keys.filter { !$0.hasPrefix("_cdbm") }.sorted()
        let described = visible.prefix(fieldLimit).map { key in
            MCPFieldDescription(
                key: key, type: types[key] ?? "string", isRequired: false, note: nil,
                examples: examples[key] ?? []
            )
        }
        // Отрезанные поля называются именами: имя стоит десяток знаков,
        // примеры — сотни, и режется ради контекста модели именно второе.
        // Без имени агент не составит фильтр вовсе.
        return (Array(described), Array(visible.dropFirst(fieldLimit)))
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
