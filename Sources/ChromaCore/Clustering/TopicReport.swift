import Foundation

/// Один документ-пример темы.
///
/// Отрывок, а не весь текст: отчёт читают глазами, и страница текста на каждую
/// из десяти тем — это не отчёт. Полный документ открывается в просмотрщике по
/// идентификатору.
public struct TopicExample: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var excerpt: String
    /// Косинусное расстояние до центра темы: у первого примера оно самое
    /// маленькое, и по нему видно, насколько «типичен» пример.
    public var distance: Double

    public init(id: String, excerpt: String, distance: Double) {
        self.id = id
        self.excerpt = excerpt
        self.distance = distance
    }

    public static let excerptLimit = 400

    public static func excerpt(of text: String?) -> String {
        let trimmed = (text ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > excerptLimit else { return trimmed }
        return String(trimmed.prefix(excerptLimit)) + "…"
    }
}

/// Одна тема.
public struct Topic: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    /// Название от чат-модели — или «Тема N», если называть было нечем.
    public var title: String
    public var summary: String?
    /// Название дала модель, а не счётчик. Разница важна: придуманное моделью
    /// название — это утверждение о содержимом, и оно должно быть отличимо от
    /// порядкового номера.
    public var isNamed: Bool
    public var documentCount: Int
    /// Доля от того, что было прочитано, а не от всей коллекции.
    public var share: Double
    /// Насколько тема плотная: среднее расстояние до центра.
    public var averageDistance: Double
    public var examples: [TopicExample]

    public init(
        id: Int, title: String, summary: String? = nil, isNamed: Bool = false,
        documentCount: Int, share: Double, averageDistance: Double, examples: [TopicExample]
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.isNamed = isNamed
        self.documentCount = documentCount
        self.share = share
        self.averageDistance = averageDistance
        self.examples = examples
    }

    public var sharePercent: String {
        String(format: "%.1f%%", share * 100)
    }
}

/// Документы, не отнесённые ни к одной теме.
///
/// Отдельной категорией, а не молча приписанные к ближайшей: часто именно они
/// самое интересное в коллекции — то, что попало в неё случайно, или тема,
/// которой не хватило на кластер.
public struct UnassignedTopic: Codable, Sendable, Hashable {
    public var documentCount: Int
    public var share: Double
    /// Порог, за которым документ считается неотнесённым, — числом, чтобы
    /// строку в отчёте можно было проверить, а не принимать на веру.
    public var distanceThreshold: Double
    public var examples: [TopicExample]

    public init(documentCount: Int, share: Double, distanceThreshold: Double, examples: [TopicExample]) {
        self.documentCount = documentCount
        self.share = share
        self.distanceThreshold = distanceThreshold
        self.examples = examples
    }

    public var sharePercent: String {
        String(format: "%.1f%%", share * 100)
    }
}

/// Отчёт о темах коллекции.
///
/// **Отчёт, а не изменение коллекции.** Ни номер темы, ни её название в
/// метаданные документов не пишутся: кластеризация — наблюдение о базе, и
/// завтрашний прогон с другим числом тем не должен переписывать вчерашние
/// метаданные. Хранится там же, где отчёты инспектора, — рядом с настройками
/// приложения.
public struct TopicReport: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var collectionName: String
    public var startedAt: Date
    public var duration: Double
    /// Сколько документов прочитано и сколько их всего.
    public var examined: Int
    public var total: Int
    /// Сколько векторов дошло до кластеризации: документ без вектора в неё
    /// не попадает, и разница с `examined` — это не округление, а факт.
    public var clustered: Int
    /// Число тем, заданное руками, или `nil` — если подбиралось само.
    public var requestedClusters: Int?
    public var seed: UInt64
    public var namingModel: String?
    public var silhouette: Double
    public var topics: [Topic]
    public var unassigned: UnassignedTopic
    /// Оговорки прогона: что не получилось и почему.
    public var notes: [String]

    public init(
        id: UUID = UUID(),
        collectionName: String,
        startedAt: Date = Date(),
        duration: Double = 0,
        examined: Int = 0,
        total: Int = 0,
        clustered: Int = 0,
        requestedClusters: Int? = nil,
        seed: UInt64 = 42,
        namingModel: String? = nil,
        silhouette: Double = 0,
        topics: [Topic] = [],
        unassigned: UnassignedTopic = UnassignedTopic(documentCount: 0, share: 0, distanceThreshold: 0, examples: []),
        notes: [String] = []
    ) {
        self.id = id
        self.collectionName = collectionName
        self.startedAt = startedAt
        self.duration = duration
        self.examined = examined
        self.total = total
        self.clustered = clustered
        self.requestedClusters = requestedClusters
        self.seed = seed
        self.namingModel = namingModel
        self.silhouette = silhouette
        self.topics = topics
        self.unassigned = unassigned
        self.notes = notes
    }

    public var isSample: Bool { examined < total }

    public var caption: String {
        isSample
            ? String(localized: "Тем: \(topics.count.plainDigits) по выборке из \(clustered.plainDigits) документов (в коллекции \(total.plainDigits))")
            : String(localized: "Тем: \(topics.count.plainDigits) по всей коллекции — документов \(clustered.plainDigits)")
    }

    /// Насколько разбиение вообще осмысленно.
    ///
    /// Сказано словами, а не числом от −1 до 1: силуэт 0,12 сам по себе не
    /// говорит ничего тому, кто не знает, что это. Границы намеренно
    /// осторожные — заявить «темы выделились чётко» там, где их нет, хуже, чем
    /// промолчать, — и подобраны по измерению живьём: на настоящей
    /// википедийной выгрузке в 9 771 документ силуэт вышел 0,109, и это
    /// нормальная текстовая коллекция, а не плохая. Для эмбеддингов
    /// значения вообще малы: векторы лежат в узком конусе, и 0,1 здесь — то
    /// же, что 0,5 на разноцветных точках из учебника.
    public var quality: String {
        switch silhouette {
        case ..<0.03:
            return String(localized: "Темы почти не отделяются друг от друга: коллекция однородна или наоборот — в ней нет повторяющихся сюжетов. Список ниже стоит читать как приблизительный.")
        case ..<0.08:
            return String(localized: "Темы отделяются слабо: границы между ними размыты, и документ у границы мог попасть в соседнюю.")
        case ..<0.20:
            return String(localized: "Темы отделяются заметно — обычное дело для текстовой коллекции.")
        default:
            return String(localized: "Темы отделяются чётко: в коллекции хорошо различимые группы документов.")
        }
    }

    public var line: String {
        String(localized: "Тем: \(topics.count.plainDigits), не отнесено документов: \(unassigned.documentCount.plainDigits)")
    }
}

/// История прогонов кластеризации, по файлу на коллекцию.
///
/// Той же формы, что история инспектора: отчёт с датой, последние сверху,
/// глубина ограничена. Отдельным типом, а не полем в `InspectionStore`, чтобы
/// у файла инспекций не менялся формат из-за необязательного этапа.
public struct TopicReportStore: Sendable {
    public static let historyLimit = 10

    private struct Stored: Codable {
        var reports: [TopicReport] = []
    }

    private let directory: URL

    public init(directory: URL = AppPaths.topicsDirectory) {
        self.directory = directory
    }

    private func fileURL(for collection: String) -> URL {
        directory.appendingPathComponent("\(collection).json")
    }

    private func load(_ collection: String) -> Stored {
        guard let data = try? Data(contentsOf: fileURL(for: collection)) else { return Stored() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Stored.self, from: data)) ?? Stored()
    }

    public func reports(for collection: String) -> [TopicReport] {
        load(collection).reports.sorted { $0.startedAt > $1.startedAt }
    }

    public func record(_ report: TopicReport) {
        var stored = load(report.collectionName)
        stored.reports.append(report)
        stored.reports.sort { $0.startedAt > $1.startedAt }
        stored.reports = Array(stored.reports.prefix(Self.historyLimit))
        do {
            try AppPaths.ensureDirectory(directory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(stored).write(to: fileURL(for: report.collectionName), options: .atomic)
        } catch {
            // История полезна, но ронять из-за неё прогон незачем: отчёт
            // человек уже видит на экране.
        }
    }

    public func remove(collection: String) {
        try? FileManager.default.removeItem(at: fileURL(for: collection))
    }
}

/// Отчёт о темах в файл.
public enum TopicExport {
    public static func json(_ report: TopicReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    public static func decode(_ data: Data) throws -> TopicReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TopicReport.self, from: data)
    }

    public static func markdown(_ report: TopicReport) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        var lines: [String] = [
            "# Темы коллекции «\(report.collectionName)»",
            "",
            "- Дата: \(formatter.string(from: report.startedAt))",
            "- Кластеризовано документов: \(report.clustered.plainDigits) из \(report.total.plainDigits)"
                + (report.isSample ? " — это выборка, а не вся коллекция" : ""),
            "- Число тем: \(report.topics.count.plainDigits)"
                + (report.requestedClusters == nil ? " (подобрано автоматически)" : " (задано вручную)"),
            "- Зерно: \(report.seed) — при том же входе прогон повторится в точности",
            "- Названия тем: \(report.namingModel.map { "модель «\($0)»" } ?? "не запрашивались")",
            "- Длительность: \(String(format: "%.1f", report.duration)) с",
            "",
            report.quality,
            "",
        ]
        if !report.notes.isEmpty {
            lines.append("## Оговорки прогона")
            lines.append("")
            for note in report.notes { lines.append("- \(note)") }
            lines.append("")
        }

        lines.append("| Тема | Документов | Доля |")
        lines.append("|---|---:|---:|")
        for topic in report.topics {
            lines.append("| \(topic.title) | \(topic.documentCount.plainDigits) | \(topic.sharePercent) |")
        }
        lines.append("| *Не отнесены ни к одной теме* | \(report.unassigned.documentCount.plainDigits) | \(report.unassigned.sharePercent) |")
        lines.append("")

        for topic in report.topics {
            lines.append("## \(topic.title) — \(topic.documentCount.plainDigits) (\(topic.sharePercent))")
            lines.append("")
            if let summary = topic.summary, !summary.isEmpty {
                lines.append(summary)
                lines.append("")
            }
            for example in topic.examples {
                lines.append("- `\(example.id)` — \(example.excerpt)")
            }
            lines.append("")
        }

        lines.append("## Не отнесены ни к одной теме — \(report.unassigned.documentCount.plainDigits) (\(report.unassigned.sharePercent))")
        lines.append("")
        lines.append("Документы, до своего центра которых дальше, чем \(String(format: "%.3f", report.unassigned.distanceThreshold)) по косинусу. Часто именно здесь видно то, что попало в коллекцию случайно.")
        lines.append("")
        for example in report.unassigned.examples {
            lines.append("- `\(example.id)` — \(example.excerpt)")
        }
        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append("Отчёт описывает состояние коллекции на момент прогона. В метаданные документов номера и названия тем не записывались.")
        return lines.joined(separator: "\n") + "\n"
    }
}
