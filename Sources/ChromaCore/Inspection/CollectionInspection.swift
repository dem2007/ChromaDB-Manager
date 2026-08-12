import Foundation

/// Что инспектор нашёл в коллекции.
///
/// Категория — это вопрос, на который проверка отвечает, и предлагаемое
/// действие. Действие **предлагается**, а не выполняется: инспектор только
/// читает и сообщает.
public enum InspectionCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case emptyDocuments
    case withoutMetadata
    case schemaViolations
    case orphanChunks
    case outsideSources
    case chunkGaps
    case collectionBindingMissing
    case dimensionMismatch
    case duplicates
    case nearDuplicates
    case supersededPieces
    case substitutedChunking

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .emptyDocuments: return String(localized: "Пустые и слишком короткие документы")
        case .withoutMetadata: return String(localized: "Документы без метаданных")
        case .schemaViolations: return String(localized: "Несоответствие схеме")
        case .orphanChunks: return String(localized: "Чанки-сироты")
        case .outsideSources: return String(localized: "Документы вне источников")
        case .chunkGaps: return String(localized: "Разрывы в нумерации чанков")
        case .collectionBindingMissing: return String(localized: "У коллекции не записаны модель, метрика или размерность")
        case .dimensionMismatch: return String(localized: "Расхождение размерности")
        case .duplicates: return String(localized: "Дубли по тексту")
        case .nearDuplicates: return String(localized: "Похожие документы")
        case .supersededPieces: return String(localized: "Вытесненные куски перенарезки")
        case .substitutedChunking: return String(localized: "Нарезано не выбранной стратегией")
        }
    }

    /// Находка — это не всегда дефект. «Документы вне источников» — отдельная
    /// **информационная** категория: помечать их как сирот нельзя, иначе
    /// инспектор будет ложно срабатывать на каждой ручной записи.
    public var isInformational: Bool {
        self == .outsideSources || self == .substitutedChunking
    }

    public var explanation: String {
        switch self {
        case .emptyDocuments:
            return String(localized: "Текст короче порога. Такой чанк ничего не найдёт и только занимает место в выдаче.")
        case .withoutMetadata:
            return String(localized: "Метаданных нет вовсе — по такому документу нельзя ни отфильтровать, ни понять, откуда он.")
        case .schemaViolations:
            return String(localized: "Документ не проходит схему метаданных этой коллекции.")
        case .orphanChunks:
            return String(localized: "В метаданных записан источник, которого в приложении больше нет. Чанки остались, а обновлять их некому.")
        case .outsideSources:
            return String(localized: "Добавлены вручную, импортом, через MCP или другим клиентом. Это не дефект — просто их никто не синхронизирует.")
        case .chunkGaps:
            return String(localized: "У файла пропущены номера чанков — обычно это след прерванной синхронизации.")
        case .collectionBindingMissing:
            return String(localized: "Неизвестно, какой моделью считались векторы. Проверить совместимость при следующей записи будет нечем.")
        case .dimensionMismatch:
            return String(localized: "Длина векторов не совпадает с записанной у коллекции: в ней документы от разных моделей.")
        case .duplicates:
            return String(localized: "Одинаковый текст в нескольких документах. В выдаче они будут занимать места друг друга.")
        case .nearDuplicates:
            return String(localized: "Тексты почти совпадают — обычно это одно и то же, проиндексированное дважды.")
        case .substitutedChunking:
            return String(localized: "Эти чанки нарезаны не той стратегией, что записана у коллекции: у документа не нашлось структуры, либо это презентация, где слайд идёт одним чанком. Сравнивать такую коллекцию с другой по стратегии нельзя — сравниваются одинаково нарезанные данные.")
        case .supersededPieces:
            return String(localized: "Остались от прошлой перенарезки: последний пересчёт нарезал этот документ на меньшее число кусков, а лишние никто не убрал. Векторы у них от прежней модели, и в выдачу они попадают наравне с текущими.")
        }
    }

    /// Что предлагается сделать. Именно предлагается: выполняется отдельно
    /// и с подтверждением.
    public var suggestion: String {
        switch self {
        case .emptyDocuments, .duplicates, .nearDuplicates:
            return String(localized: "Просмотреть и удалить лишние — по одному или списком.")
        case .withoutMetadata, .schemaViolations:
            return String(localized: "Дописать метаданные или переиндексировать источник.")
        case .orphanChunks:
            return String(localized: "Удалить, если источник больше не нужен, или зарегистрировать его снова.")
        case .outsideSources:
            return String(localized: "Ничего делать не нужно — категория информационная.")
        case .chunkGaps:
            return String(localized: "Переиндексировать эти файлы: синхронизация допишет недостающее.")
        case .collectionBindingMissing:
            return String(localized: "Записать модель и размерность — это делает первая же синхронизация источника в эту коллекцию.")
        case .dimensionMismatch:
            return String(localized: "Пересчитать коллекцию одной моделью — экран «Пересчёт».")
        case .substitutedChunking:
            return String(localized: "Ничего чинить не нужно: подмена честная. Но если коллекция заводилась ради сравнения стратегий — сравнение по этим файлам не состоялось.")
        case .supersededPieces:
            return String(localized: "Просмотреть и удалить — приложение само их не трогает: автоматических удалений в нём нет.")
        }
    }
}

/// Одна находка.
public struct InspectionFinding: Codable, Sendable, Hashable, Identifiable {
    /// Документы входят в опознание: у дублей находка называется началом
    /// повторившегося текста, и два разных повтора могут начинаться одинаково
    ///. Списку в интерфейсе нужен ключ, который их различает.
    public var id: String {
        "\(category.rawValue)|\(subject)|\(documentIDs.joined(separator: ","))"
    }
    public let category: InspectionCategory
    /// Идентификаторы документов, которых находка касается.
    public let documentIDs: [String]
    /// О чём находка: имя файла, значение поля, текст — то, что показывается
    /// в списке.
    public let subject: String
    public let detail: String?

    public init(category: InspectionCategory, documentIDs: [String], subject: String, detail: String? = nil) {
        self.category = category
        self.documentIDs = documentIDs
        self.subject = subject
        self.detail = detail
    }
}

/// Итог прогона.
public struct InspectionReport: Codable, Sendable, Identifiable {
    public var id: UUID
    public var collectionName: String
    public var startedAt: Date
    public var duration: TimeInterval
    /// Сколько документов посмотрели и сколько их всего: инспектор работает
    /// по выборке, и это должно быть написано, а не подразумеваться.
    public var examined: Int
    public var total: Int
    public var findings: [InspectionFinding]
    /// Проверка на похожие документы — дорогая, и её могли не запускать.
    public var nearDuplicatesChecked: Bool
    /// Сколько документов было пропущено как уже просмотренные человеком.
    public var acknowledged: Int

    public init(
        id: UUID = UUID(),
        collectionName: String,
        startedAt: Date = Date(),
        duration: TimeInterval = 0,
        examined: Int = 0,
        total: Int = 0,
        findings: [InspectionFinding] = [],
        nearDuplicatesChecked: Bool = false,
        acknowledged: Int = 0
    ) {
        self.id = id
        self.collectionName = collectionName
        self.startedAt = startedAt
        self.duration = duration
        self.examined = examined
        self.total = total
        self.findings = findings
        self.nearDuplicatesChecked = nearDuplicatesChecked
        self.acknowledged = acknowledged
    }

    public var isSample: Bool { examined < total }

    public func findings(in category: InspectionCategory) -> [InspectionFinding] {
        findings.filter { $0.category == category }
    }

    public func count(of category: InspectionCategory) -> Int {
        findings(in: category).count
    }

    /// Категории с находками, в порядке перечисления, — информационные
    /// в конце: они не требуют действий.
    public var categoriesWithFindings: [InspectionCategory] {
        InspectionCategory.allCases
            .filter { count(of: $0) > 0 }
            .sorted { lhs, rhs in
                if lhs.isInformational != rhs.isInformational { return !lhs.isInformational }
                return InspectionCategory.allCases.firstIndex(of: lhs)! < InspectionCategory.allCases.firstIndex(of: rhs)!
            }
    }

    /// Находки, требующие внимания, — без информационной категории.
    public var problemCount: Int {
        findings.filter { !$0.category.isInformational }.count
    }

    public var line: String {
        guard problemCount > 0 else {
            return String(localized: "проверено документов \(examined.plainDigits), находок нет")
        }
        return String(localized: "проверено документов \(examined.plainDigits), находок \(problemCount.plainDigits)")
    }
}

/// Настройки прогона.
public struct InspectionOptions: Sendable, Hashable {
    /// Ниже этой длины документ считается пустым.
    public var minimumTextLength: Int
    /// Сколько документов смотреть. Инспектор читает страницами, и это предел
    /// на чтение, а не на коллекцию.
    public var sampleSize: Int
    /// Дорогая проверка — только по запросу.
    public var checksNearDuplicates: Bool
    /// Порог косинусного расстояния, ближе которого документы считаются
    /// похожими.
    public var nearDuplicateDistance: Double
    /// Сколько соседей спрашивать у базы на каждый документ.
    public var neighbours: Int
    /// По скольким документам искать похожие. Отдельно от `sampleSize`: дешёвые
    /// проверки идут по большой выборке, дорогая — по маленькой.
    public var nearDuplicateSampleSize: Int

    public init(
        minimumTextLength: Int = 20,
        sampleSize: Int = 5000,
        checksNearDuplicates: Bool = false,
        nearDuplicateDistance: Double = 0.05,
        neighbours: Int = 5,
        nearDuplicateSampleSize: Int = 1000
    ) {
        self.minimumTextLength = max(0, minimumTextLength)
        self.sampleSize = max(1, sampleSize)
        self.checksNearDuplicates = checksNearDuplicates
        self.nearDuplicateDistance = max(0, nearDuplicateDistance)
        self.neighbours = max(2, neighbours)
        self.nearDuplicateSampleSize = max(1, nearDuplicateSampleSize)
    }
}
