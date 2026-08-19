import Foundation

public struct ModelBinding: Hashable {
    public let model: String
    public let dimension: Int

    public init(model: String, dimension: Int) {
        self.model = model
        self.dimension = dimension
    }
}

public enum BindingError: LocalizedError {
    case notBound(collection: String)
    case modelUnavailable(model: String)
    case dimensionConflict(collection: String, stored: Int, model: Int)

    public var errorDescription: String? {
        switch self {
        case .notBound(let collection):
            return String(localized: "Для коллекции «\(collection)» не указана эмбеддинг-модель.")
        case .modelUnavailable(let model):
            return String(localized: "Модель «\(model)» сейчас недоступна в LM Studio.")
        case .dimensionConflict(let collection, let stored, let model):
            return String(localized: "В коллекции «\(collection)» уже лежат векторы размерности \(stored.plainDigits), а выбранная модель выдаёт \(model.plainDigits).")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notBound:
            return String(localized: "Укажите модель для коллекции — это можно сделать прямо в её карточке.")
        case .modelUnavailable:
            return String(localized: "Загрузите эту модель в LM Studio или выберите другую — но учтите, что векторы разных моделей несравнимы.")
        case .dimensionConflict:
            return String(localized: "Выберите модель с той же размерностью — или пересчитайте коллекцию под новую на экране «Пересчёт»: клонирование создаст копию со своей размерностью, не трогая исходную.")
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
        if let cached = dimensionCache[model] { return cached }
        let vector = try await lmStudio.embed(texts: ["dimension probe"], model: model).first ?? []
        guard !vector.isEmpty else { throw BindingError.modelUnavailable(model: model) }
        dimensionCache[model] = vector.count
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
        if contextProbed.contains(model) { return contextCache[model] }
        let value = (try? await lmStudio.models())?.first { $0.id == model }?.contextLength
        contextProbed.insert(model)
        if let value { contextCache[model] = value }
        return value
    }

    /// Контекст, с которым модель загружена сейчас. Кэшируется отдельно от
    /// `contextLength`, потому что это другое число и годится для другого:
    /// потолок — для эмбеддингов, где рантайм наращивает контекст;
    /// загруженное — для порождающих вызовов, где не наращивает.
    public func loadedContextLength(of model: String, lmStudio: LMStudioClient) async -> Int? {
        if loadedContextProbed.contains(model) { return loadedContextCache[model] }
        // Через клиент, а не через список: у незагруженной модели этого числа
        // ещё нет, и разбирается с этим он.
        let value = await lmStudio.loadedContextLength(of: model)
        loadedContextProbed.insert(model)
        if let value { loadedContextCache[model] = value }
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
        if inputLimitProbed.contains(model) { return inputLimitCache[model] }
        // Контекст, с которым модель загружена сейчас: он и есть признак
        // свежести измеренного. Перезагрузили модель с другим
        // контекстом — вчерашнее число больше ничего не значит, а звать
        // `forgetCachedDimensions()` в приложении некому: у него нет ни
        // одного вызова.
        let loaded = await embeddings.reportedLoadedContextLength(of: model)

        // Измеренное в прошлые запуски — проба стоит семи вызовов, и платить
        // за неё каждый раз незачем.
        if let remembered = await limits?.limit(for: model), remembered.loadedContext == loaded {
            inputLimitProbed.insert(model)
            inputLimitCache[model] = remembered.characters
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
        inputLimitProbed.insert(model)
        let value: Int? = { if case .measured(let measured) = outcome { return measured }; return nil }()
        if let value {
            inputLimitCache[model] = value
            log(.info, "Модели", "Модель «\(model)» читает за раз не больше \(value.plainDigits) знаков — измерено пробой")
            await limits?.remember(
                MeasuredInputLimit(model: model, characters: value, loadedContext: loaded)
            )
        }
        return value
    }

    public func ensureAvailable(model: String, lmStudio: LMStudioClient) async throws {
        let models = try await lmStudio.models()
        guard models.contains(where: { $0.id == model }) else {
            throw BindingError.modelUnavailable(model: model)
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
            metadata: collection.metadataBinding(model: model, dimension: modelDimension)
        )
        log(.success, "Эмбеддинги", "Коллекция «\(collection.name)» привязана к модели \(model) (размерность \(modelDimension))")
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

    /// Model a collection is bound to, or an error explaining what to do.
    public func requiredModel(for collection: ChromaCollection) throws -> String {
        guard let model = collection.boundModel else {
            throw BindingError.notBound(collection: collection.name)
        }
        return model
    }
}
