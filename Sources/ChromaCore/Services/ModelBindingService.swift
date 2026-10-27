import Foundation

public struct ModelBinding: Hashable {
    public let model: String
    public let dimension: Int

    public init(model: String, dimension: Int) {
        self.model = model
        self.dimension = dimension
    }
}

/// Модель, которой заполнена коллекция, — вместе с сервером.
///
/// Одного имени мало: `nomic-embed-text` в LM Studio и в Ollama — разные
/// файлы, иногда разные квантования, и векторы у них расходятся.
public struct BoundModel: Hashable, Sendable {
    public let model: String
    /// Сервер так, как он записан в коллекции, — строкой: сервер, которого
    /// эта сборка не знает (его записала более новая), не должен сойти ни за
    /// LM Studio, ни за Ollama. Сравнение идёт по этой строке.
    public let serverID: String

    public init(model: String, server: LLMProvider) {
        self.init(model: model, serverID: server.rawValue)
    }

    public init(model: String, serverID: String) {
        self.model = model
        self.serverID = serverID
    }

    /// `nil` — сервер, которого эта сборка не знает.
    public var server: LLMProvider? { LLMProvider(rawValue: serverID) }

    public var serverTitle: String { server?.title ?? serverID }

    /// «bge-m3» из LM Studio — для текстов ошибок.
    public var title: String { String(localized: "«\(model)» из \(serverTitle)") }
}

public enum BindingError: LocalizedError {
    case notBound(collection: String)
    case modelUnavailable(model: String, server: LLMProvider)
    case dimensionConflict(collection: String, stored: Int, model: Int)
    /// Коллекция заполнена одной моделью, а запись идёт другой.
    ///
    /// Модель — пара «имя + сервер»: под одним именем у LM Studio и Ollama
    /// бывают разные сборки и квантования. Размерность этого не ловит: у
    /// разных моделей она часто одна (1024 у bge-m3 и qwen3-embedding-0.6b).
    /// А поиск по коллекции считает вектор запроса её моделью — записанное
    /// чужой молча не находилось бы.
    case modelConflict(collection: String, bound: BoundModel, requested: BoundModel)
    /// Коллекция заполнена моделью другого сервера, а запрос посчитал бы
    /// вектор моделью текущего — пусть и с тем же именем.
    case serverConflict(collection: String, bound: BoundModel, current: LLMProvider)
    /// Векторы из корзины — другой модели, чем у коллекции, куда их
    /// возвращают. Они не пересчитываются: что сохранено, то и ляжет.
    case restoreConflict(collection: String, bound: BoundModel, restored: BoundModel, left: Int)

    public var errorDescription: String? {
        switch self {
        case .notBound(let collection):
            return String(localized: "Для коллекции «\(collection)» не указана эмбеддинг-модель.")
        case .modelUnavailable(let model, let server):
            return String(localized: "Модель «\(model)» сейчас недоступна в \(server.title).")
        case .dimensionConflict(let collection, let stored, let model):
            return String(localized: "В коллекции «\(collection)» уже лежат векторы размерности \(stored.plainDigits), а выбранная модель выдаёт \(model.plainDigits).")
        case .modelConflict(let collection, let bound, let requested):
            return String(localized: "Коллекция «\(collection)» заполнена моделью \(bound.title), а векторы сейчас считает \(requested.title). Векторы разных моделей несравнимы, и поиск по коллекции идёт её моделью, поэтому запись остановлена до первого документа.")
        case .serverConflict(let collection, let bound, let current):
            return String(localized: "Коллекция «\(collection)» заполнена моделью \(bound.title), а сейчас выбран сервер \(current.title). Модель с тем же именем у другого сервера может быть другой сборкой, и поиск сравнивал бы несравнимые векторы.")
        case .restoreConflict(let collection, let bound, let restored, let left):
            return String(localized: "Записи корзины посчитаны моделью \(restored.title), а коллекция «\(collection)» — моделью \(bound.title). Векторы разных моделей в одной коллекции не ищутся, поэтому записей осталось в корзине: \(left.plainDigits).")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notBound:
            return String(localized: "Укажите модель для коллекции — это можно сделать прямо в её карточке.")
        case .modelUnavailable(_, let server):
            return String(localized: "Загрузите эту модель в \(server.title) или выберите другую — но учтите, что векторы разных моделей несравнимы.")
        case .dimensionConflict:
            return String(localized: "Выберите модель с той же размерностью — или пересчитайте коллекцию под новую на экране «Пересчёт»: клонирование создаст копию со своей размерностью, не трогая исходную.")
        case .modelConflict(_, let bound, _):
            return String(localized: "Выберите у источника модель \(bound.title) — или пересчитайте коллекцию под новую модель на экране «Пересчёт». Если у источника стоит «по умолчанию», модель по умолчанию могла смениться вместе с сервером моделей.")
        case .serverConflict(_, let bound, _):
            return String(localized: "Переключите сервер моделей на \(bound.serverTitle) на вкладке «Эмбеддинги» → «Подключение» — или пересчитайте коллекцию под модель текущего сервера на экране «Пересчёт».")
        case .restoreConflict(_, _, let restored, _):
            return String(localized: "Чтобы вернуть их, пересчитайте коллекцию под модель \(restored.title) на экране «Пересчёт» и восстановите записи снова.")
        }
    }
}

/// То же для модели: русский текст выше — человеку у экрана.
extension BindingError: MCPReadableError {
    public var mcpReason: String {
        switch self {
        case .notBound(let collection):
            return "the collection «\(collection)» has no embedding model bound; bind one in ChromaDB Manager"
        case .modelUnavailable(let model, let server):
            return "the embedding model «\(model)» is not loaded in \(server.title) right now"
        case .dimensionConflict(let collection, let stored, let model):
            return "the collection «\(collection)» stores vectors of \(stored.plainDigits) numbers, the chosen model returns \(model.plainDigits)"
        case .modelConflict(let collection, let bound, let requested):
            return "the collection «\(collection)» was filled with the model «\(bound.model)» from \(bound.serverTitle), but «\(requested.model)» from \(requested.serverTitle) is computing the vectors now; vectors of different models are not comparable"
        case .serverConflict(let collection, let bound, let current):
            return "the collection «\(collection)» was filled with the model «\(bound.model)» from \(bound.serverTitle), but the app is set to \(current.title); a model of the same name there may be a different build, so the query vector would not be comparable"
        case .restoreConflict(let collection, let bound, let restored, let left):
            return "the trashed records were computed by «\(restored.model)» from \(restored.serverTitle), the collection «\(collection)» by «\(bound.model)» from \(bound.serverTitle); \(left.plainDigits) records stay in the trash"
        }
    }
}

/// Keeps the "collection → embedding model" binding honest.
///
/// ChromaDB has no idea what produced its vectors: the dimension is fixed by
/// the first record and mixing models inside one collection silently poisons
/// search. So the app records the binding in the collection's metadata and
/// refuses writes it cannot vouch for.
public actor ModelBindingService {
    private let log: LogHandler
    private var dimensionCache: [String: Int] = [:]
    private var contextCache: [String: Int] = [:]
    /// Models already asked about — so «context unknown» is remembered too.
    private var contextProbed: Set<String> = []
    private var loadedContextCache: [String: Int] = [:]
    private var loadedContextProbed: Set<String> = []
    /// Измеренный предел чтения — не тот, что сообщает рантайм.
    private var inputLimitCache: [String: Int] = [:]
    private var inputLimitProbed: Set<String> = []

    /// Хранилище измеренных пределов. `nil` — меряем на сессию
    /// и не запоминаем: так работают проверки, которым файл ни к чему.
    private let limits: EmbeddingLimitStore?

    public init(log: @escaping LogHandler = noopLogHandler, limits: EmbeddingLimitStore? = nil) {
        self.log = log
        self.limits = limits
    }

    /// Vector size of a model, measured once by embedding a short probe string.
    ///
    /// Takes any `EmbeddingProvider` so a sync can be tested without LM Studio.
    public func dimension(of model: String, lmStudio: EmbeddingProvider) async throws -> Int {
        // Кэши — по паре «сервер + модель»: одно имя у двух серверов —
        // две разные модели.
        let key = lmStudio.server.cacheName(of: model)
        if let cached = dimensionCache[key] { return cached }
        let vector = try await lmStudio.embed(texts: ["dimension probe"], model: model).first ?? []
        guard !vector.isEmpty else { throw BindingError.modelUnavailable(model: model, server: lmStudio.server) }
        dimensionCache[key] = vector.count
        log(.info, "Эмбеддинги", "Модель \(model): размерность \(vector.count)")
        return vector.count
    }

    public func forgetCachedDimensions() {
        dimensionCache.removeAll()
        contextCache.removeAll()
        contextProbed.removeAll()
        // Загруженный контекст меняется именно при перезагрузке модели —
        // то есть ровно тогда, когда сбрасывается всё остальное.
        loadedContextCache.removeAll()
        loadedContextProbed.removeAll()
        // Измеренный предел чтения сбрасывается только в памяти. В файле он
        // остаётся, и это не забывчивость: свежесть проверяется по контексту,
        // с которым модель загружена, — на этот метод полагаться
        // нельзя, у него нет ни одного вызова во всём приложении.
        inputLimitCache.removeAll()
        inputLimitProbed.removeAll()
    }

    /// Context length of a model, as LM Studio reports it, or `nil` when it
    /// does not say. Asked once per model: the answer only changes when the
    /// model is reloaded, and the list call is not free.
    public func contextLength(of model: String, lmStudio: LMStudioClient) async -> Int? {
        let key = lmStudio.provider.cacheName(of: model)
        if contextProbed.contains(key) { return contextCache[key] }
        // Через клиент, а не через список: у LM Studio это тот же
        // потолок, а у Ollama предел входа — окно, с которым модель работает,
        // и оно бывает меньше потолка в разы.
        let value = await lmStudio.contextLength(of: model)
        // «Неизвестно» помнится только у LM Studio: она длинное обрежет сама.
        // У Ollama неизвестный предел — сорвавшийся запрос, а не ответ, и
        // запомненный до перезапуска он оставил бы куски недорезанными: каждый
        // длиннее окна `/api/embed` отвергал бы вместе с файлом.
        if value != nil || lmStudio.truncatesSilently { contextProbed.insert(key) }
        if let value { contextCache[key] = value }
        return value
    }

    /// Контекст, с которым модель загружена сейчас. Кэшируется отдельно от
    /// `contextLength`, потому что это другое число и годится для другого:
    /// потолок — для эмбеддингов, где рантайм наращивает контекст;
    /// загруженное — для порождающих вызовов, где не наращивает.
    public func loadedContextLength(of model: String, lmStudio: LMStudioClient) async -> Int? {
        let key = lmStudio.provider.cacheName(of: model)
        if loadedContextProbed.contains(key) { return loadedContextCache[key] }
        // Через клиент, а не через список: у незагруженной модели этого числа
        // ещё нет, и разбирается с этим он.
        let value = await lmStudio.loadedContextLength(of: model)
        loadedContextProbed.insert(key)
        if let value { loadedContextCache[key] = value }
        return value
    }

    /// Сколько знаков модель эмбеддинга читает на самом деле.
    ///
    /// Отдельно от `contextLength` и `loadedContextLength`, потому что это
    /// третье число, и оно не совпадает ни с одним из двух: у qwen3-embedding
    /// сообщается 32768 и 2048, а вектор перестаёт меняться после 21 400
    /// знаков. Спросить это нельзя — только измерить, поэтому измеряется
    /// **один раз на модель** и только когда понадобилось.
    ///
    /// `nil` — обрыва не нашлось до предела пробы; тогда сравнивать не с чем
    /// и ничего не блокируется.
    public func measuredInputLimit(
        of model: String, embeddings: EmbeddingProvider
    ) async -> Int? {
        // У LM Studio ключ — само имя: измеренное в прошлые запуски лежит под ним.
        let key = embeddings.server.cacheName(of: model)
        if inputLimitProbed.contains(key) { return inputLimitCache[key] }
        // Сервер, который не обрезает вход молча, мерить незачем:
        // у Ollama длинный текст — ошибка, а не вектор начала. Проба из
        // текстов по 64 000 знаков там только сорвётся — и, как сорвавшаяся,
        // повторится на каждом файле.
        guard embeddings.truncatesSilently else {
            inputLimitProbed.insert(key)
            return nil
        }
        // Контекст, с которым модель загружена сейчас: он и есть признак
        // свежести измеренного. Перезагрузили модель с другим
        // контекстом — вчерашнее число больше ничего не значит, а звать
        // `forgetCachedDimensions()` в приложении некому: у него нет ни
        // одного вызова.
        let loaded = await embeddings.reportedLoadedContextLength(of: model)

        // Измеренное в прошлые запуски — проба стоит семи вызовов, и платить
        // за неё каждый раз незачем.
        if let remembered = await limits?.limit(for: key), remembered.isFresh(loadedContext: loaded) {
            inputLimitProbed.insert(key)
            inputLimitCache[key] = remembered.characters
            return remembered.characters
        }
        // Мимо кэша векторов: восемь текстов по 64 000 знаков в нём никому
        // не нужны, а вытеснят они векторы настоящих чанков.
        let outcome = await EmbeddingInputProbe.measureOutcome { text in
            try await embeddings.embedIgnoringCache(texts: [text], model: model).first ?? []
        }
        // Сорвавшаяся проба не запоминается как «мерили»: иначе одна
        // секунда без LM Studio выключала бы проверку длины чанка до самого
        // перезапуска приложения — при том что модель уже снова отвечает.
        guard outcome != .failed else { return nil }
        inputLimitProbed.insert(key)
        let value: Int? = { if case .measured(let measured) = outcome { return measured }; return nil }()
        if let value {
            inputLimitCache[key] = value
            log(.info, "Модели", "Модель «\(model)» читает за раз не больше \(value.plainDigits) знаков — измерено пробой")
            await limits?.remember(
                MeasuredInputLimit(model: key, characters: value, loadedContext: loaded)
            )
        }
        return value
    }

    public func ensureAvailable(model: String, lmStudio: LMStudioClient) async throws {
        let models = try await lmStudio.models()
        guard models.contains(where: { $0.id == model }) else {
            throw BindingError.modelUnavailable(model: model, server: lmStudio.provider)
        }
    }

    /// Attaches a model to a collection.
    ///
    /// For collections created elsewhere the app cannot know which model
    /// produced the existing vectors — it can only compare dimensions, and
    /// refuses the binding when they differ. That limitation is stated in the UI.
    @discardableResult
    public func bind(
        model: String,
        to collection: ChromaCollection,
        chroma: ChromaClient,
        lmStudio: LMStudioClient
    ) async throws -> ModelBinding {
        let modelDimension = try await dimension(of: model, lmStudio: lmStudio)

        var stored = collection.dimension
        if stored == nil {
            stored = try? await chroma.storedDimension(collectionID: collection.id)
        }
        if let stored, stored != modelDimension {
            throw BindingError.dimensionConflict(
                collection: collection.name,
                stored: stored,
                model: modelDimension
            )
        }

        try await chroma.updateCollection(
            id: collection.id,
            metadata: collection.metadataBinding(model: model, server: lmStudio.provider, dimension: modelDimension)
        )
        log(.success, "Эмбеддинги", "Коллекция «\(collection.name)» привязана к модели \(model) из \(lmStudio.provider.title) (размерность \(modelDimension))")
        return ModelBinding(model: model, dimension: modelDimension)
    }

    /// Guard before `add`/`upsert`: never send a request that is certain to fail.
    public func validate(vectorLength: Int, for collection: ChromaCollection) throws {
        guard let expected = collection.effectiveDimension else { return }
        guard expected == vectorLength else {
            throw BindingError.dimensionConflict(
                collection: collection.name,
                stored: expected,
                model: vectorLength
            )
        }
    }

    /// Коллекция, в которую сейчас пойдёт запись моделью `model` сервера
    /// `server`.
    ///
    /// Привязана к той же паре «модель + сервер» или не привязана вовсе —
    /// писать можно, как и раньше. Привязана к другой — решает пустота:
    /// заполненную доливать векторами чужой модели нельзя (испортится поиск),
    /// пустую можно перепривязать. Пустоту знает база, а не эта функция,
    /// поэтому она только называет обе стороны.
    public enum ModelCheck: Equatable, Sendable {
        case matches
        case differs(bound: BoundModel, requested: BoundModel)
    }

    public nonisolated func check(model: String, server: LLMProvider, for collection: ChromaCollection) -> ModelCheck {
        let requested = BoundModel(model: model, server: server)
        guard let bound = collection.binding, bound != requested else { return .matches }
        return .differs(bound: bound, requested: requested)
    }

    /// Model a collection is bound to, or an error explaining what to do.
    ///
    /// Модель другого сервера — тоже ошибка: вектор запроса посчитала
    /// бы одноимённая модель текущего, а это не обязательно та же модель.
    public nonisolated func requiredModel(for collection: ChromaCollection, server: LLMProvider) throws -> String {
        guard let bound = collection.binding else {
            throw BindingError.notBound(collection: collection.name)
        }
        guard bound.server == server else {
            throw BindingError.serverConflict(collection: collection.name, bound: bound, current: server)
        }
        return bound.model
    }
}
