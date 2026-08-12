import Foundation

/// Распределение по одному полю метаданных.
public struct Facet: Sendable, Hashable, Identifiable {
    public struct Value: Sendable, Hashable, Identifiable {
        public var id: String { text }
        public let text: String
        public let count: Int
        /// Значение для фильтра — по нему строится переход в список документов
        ///. Для дат это месяц, а не исходная отметка времени, поэтому
        /// фильтр строится по диапазону, а не по равенству.
        public let filterValue: MetadataValue?

        public init(text: String, count: Int, filterValue: MetadataValue? = nil) {
            self.text = text
            self.count = count
            self.filterValue = filterValue
        }
    }

    public var id: String { field }
    public let field: String
    public let title: String
    public let values: [Value]
    /// Сколько документов выборки поля не имеют вовсе.
    public let missing: Int

    public init(field: String, title: String, values: [Value], missing: Int = 0) {
        self.field = field
        self.title = title
        self.values = values
        self.missing = missing
    }
}

/// Гистограмма длин документов.
///
/// Быстрый способ увидеть, что стратегия чанкинга настроена неудачно: горб
/// у нуля — это чанки, из которых ничего не найдётся, а хвост за пределом
/// контекста — чанки, которые модель прочитает не целиком.
public struct LengthHistogram: Sendable, Hashable {
    public struct Bucket: Sendable, Hashable, Identifiable {
        public var id: Int { lowerBound }
        public let lowerBound: Int
        public let upperBound: Int?
        public let count: Int

        public var title: String {
            guard let upperBound else { return String(localized: "\(lowerBound.plainDigits)+") }
            return "\(lowerBound.plainDigits)–\(upperBound.plainDigits)"
        }
    }

    public let buckets: [Bucket]
    public let median: Int
    public let shortest: Int
    public let longest: Int

    public init(buckets: [Bucket], median: Int, shortest: Int, longest: Int) {
        self.buckets = buckets
        self.median = median
        self.shortest = shortest
        self.longest = longest
    }
}

/// Обзор коллекции: что внутри, откуда пришло, чего много, чего мало.
public struct CollectionOverview: Sendable {
    public let collectionName: String
    public let examined: Int
    public let total: Int
    public let facets: [Facet]
    public let lengths: LengthHistogram?

    public init(collectionName: String, examined: Int, total: Int, facets: [Facet], lengths: LengthHistogram?) {
        self.collectionName = collectionName
        self.examined = examined
        self.total = total
        self.facets = facets
        self.lengths = lengths
    }

    /// Считалось по выборке — и в заголовке это должно быть написано, а не
    /// подразумеваться.
    public var isSample: Bool { examined < total }

    public var caption: String {
        isSample
            ? String(localized: "Оценка по выборке: \(examined.plainDigits) документов из \(total.plainDigits)")
            : String(localized: "По всей коллекции: документов \(examined.plainDigits)")
    }
}

/// Считает обзор по выборке.
///
/// **По выборке, а не по всей коллекции**: у ChromaDB нет агрегирующих
/// запросов, а вытягивать миллион документов ради гистограммы нельзя.
///
/// К запрету 6.4 это отношения не имеет: он про визуализацию **векторов** —
/// проекции, PCA, UMAP, диаграммы рассеяния. Здесь же столбики по значениям
/// метаданных и длинам текста, то есть состав коллекции, а не векторное
/// пространство. Оговорено явно, чтобы K1 не вырезали заодно с запрещённым.
public struct CollectionFacetBuilder: Sendable {
    /// Поля, по которым обзор строится всегда: они есть у всего, что пишет
    /// приложение.
    public static let standardFields = [
        "source_file", "source_id", "file_ext", "container_format", "extractor_id",
        "_cdbm_source_name", "chunk_level", "source_url", "git_branch",
    ]
    /// Дата, которую показываем помесячно.
    public static let dateFields = ["file_mtime", "fetched_at", "last_commit_date"]
    /// Сколько значений показывать в одном фасете.
    public static let valueLimit = 15
    static let pageSize = 500

    private let reader: any InspectionReader

    public init(reader: any InspectionReader) {
        self.reader = reader
    }

    public func overview(
        collection: ChromaCollection,
        sampleSize: Int = 5000,
        extraFields: [String] = [],
        progress: ((_ done: Int, _ total: Int) -> Void)? = nil
    ) async throws -> CollectionOverview {
        let total = (try? await reader.count(collectionID: collection.id)) ?? 0
        var counts: [String: [String: Int]] = [:]
        var present: [String: Int] = [:]
        var lengths: [Int] = []
        var examined = 0
        var offset = 0

        let fields = Self.standardFields + extraFields.filter { !Self.standardFields.contains($0) }
        let dates = Self.dateFields + extraFields.filter { Self.dateFields.contains($0) }

        while examined < sampleSize {
            try Task.checkCancellation()
            let limit = min(Self.pageSize, sampleSize - examined)
            let page = try await reader.documents(collectionID: collection.id, limit: limit, offset: offset)
            guard !page.isEmpty else { break }
            offset += page.count
            examined += page.count

            for record in page {
                lengths.append((record.document ?? "").count)
                let metadata = record.metadata ?? [:]
                for field in fields {
                    guard let value = metadata[field] else { continue }
                    counts[field, default: [:]][value.displayString, default: 0] += 1
                    present[field, default: 0] += 1
                }
                for field in dates {
                    guard let value = metadata[field], let month = Self.month(of: value) else { continue }
                    counts[field, default: [:]][month, default: 0] += 1
                    present[field, default: 0] += 1
                }
            }
            progress?(examined, min(total, sampleSize))
        }

        var facets: [Facet] = []
        for field in (fields + dates) {
            guard let values = counts[field], !values.isEmpty else { continue }
            let top = values.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(Self.valueLimit)
            facets.append(Facet(
                field: field,
                title: Self.title(of: field),
                values: top.map { key, count in
                    Facet.Value(
                        text: key, count: count,
                        // У месяца фильтр по равенству не сработает: в базе
                        // лежит полная отметка времени. Такие значения ведут
                        // в список без готового фильтра.
                        filterValue: dates.contains(field) ? nil : .string(key)
                    )
                },
                missing: examined - (present[field] ?? 0)
            ))
        }

        return CollectionOverview(
            collectionName: collection.name,
            examined: examined,
            total: max(total, examined),
            facets: facets,
            lengths: Self.histogram(of: lengths)
        )
    }

    // MARK: - Мелочи

    static func month(of value: MetadataValue) -> String? {
        let text = value.displayString
        // ISO-8601: «2026-08-08T10:00:00Z» → «2026-08».
        guard text.count >= 7 else { return nil }
        let month = String(text.prefix(7))
        guard month.count == 7, month.dropFirst(4).first == "-" else { return nil }
        guard Int(month.prefix(4)) != nil, Int(month.suffix(2)) != nil else { return nil }
        return month
    }

    static func title(of field: String) -> String {
        switch field {
        case "source_file": return String(localized: "Файл")
        case "source_id": return String(localized: "Источник")
        case "_cdbm_source_name": return String(localized: "Имя источника")
        case "file_ext": return String(localized: "Расширение")
        case "container_format": return String(localized: "Формат")
        case "extractor_id": return String(localized: "Экстрактор")
        case "chunk_level": return String(localized: "Уровень чанка")
        case "file_mtime": return String(localized: "Изменён (по месяцам)")
        case "fetched_at": return String(localized: "Загружен (по месяцам)")
        case "last_commit_date": return String(localized: "Последний коммит (по месяцам)")
        case "source_url": return String(localized: "Адрес страницы")
        case "git_branch": return String(localized: "Ветка")
        default: return field
        }
    }

    /// Границы подобраны под размеры чанков, которыми приложение работает:
    /// всё, что короче 200 знаков, обычно мусор, а всё, что длиннее 4000, —
    /// повод посмотреть на стратегию.
    static let bounds = [0, 100, 200, 500, 1000, 2000, 4000]

    static func histogram(of lengths: [Int]) -> LengthHistogram? {
        guard !lengths.isEmpty else { return nil }
        var buckets: [LengthHistogram.Bucket] = []
        for (index, lower) in bounds.enumerated() {
            let upper = index + 1 < bounds.count ? bounds[index + 1] - 1 : nil
            let count = lengths.filter { value in
                guard let upper else { return value >= lower }
                return value >= lower && value <= upper
            }.count
            buckets.append(LengthHistogram.Bucket(lowerBound: lower, upperBound: upper, count: count))
        }
        let sorted = lengths.sorted()
        return LengthHistogram(
            buckets: buckets,
            median: sorted[sorted.count / 2],
            shortest: sorted.first ?? 0,
            longest: sorted.last ?? 0
        )
    }
}
