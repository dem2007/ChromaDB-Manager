import Foundation

/// История прогонов инспектора и то, что человек уже посмотрел.
///
/// По файлу на коллекцию. Отчёты — это не данные базы, а наблюдения о ней,
/// поэтому лежат рядом с настройками приложения, а не в самой коллекции.
public struct InspectionStore: Sendable {
    /// Сколько прогонов хранить. Больше незачем: вопрос, на который отвечает
    /// история, — «стало лучше или хуже», и на него отвечают последние.
    public static let historyLimit = 20

    private struct Stored: Codable {
        var reports: [InspectionReport] = []
        /// Пары «похожих», про которые человек сказал «это не дубли».
        var acknowledgedPairs: [String] = []
    }

    private let directory: URL

    public init(directory: URL = AppPaths.inspectionsDirectory) {
        self.directory = directory
    }

    private func fileURL(for collection: String) -> URL {
        // Имя коллекции годится для имени файла: 2.2 разрешает в них только
        // латиницу, цифры, дефис и подчёркивание.
        directory.appendingPathComponent("\(collection).json")
    }

    private func load(_ collection: String) -> Stored {
        guard let data = try? Data(contentsOf: fileURL(for: collection)) else { return Stored() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Stored.self, from: data)) ?? Stored()
    }

    private func write(_ stored: Stored, collection: String) {
        do {
            try AppPaths.ensureDirectory(directory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(stored).write(to: fileURL(for: collection), options: .atomic)
        } catch {
            // История — вещь полезная, но не та, ради которой стоит ронять
            // прогон: отчёт человек уже видит на экране.
        }
    }

    /// Прогоны, новые сверху.
    public func reports(for collection: String) -> [InspectionReport] {
        load(collection).reports.sorted { $0.startedAt > $1.startedAt }
    }

    public func record(_ report: InspectionReport) {
        var stored = load(report.collectionName)
        stored.reports.append(report)
        stored.reports.sort { $0.startedAt > $1.startedAt }
        stored.reports = Array(stored.reports.prefix(Self.historyLimit))
        write(stored, collection: report.collectionName)
    }

    public func acknowledgedPairs(for collection: String) -> Set<String> {
        Set(load(collection).acknowledgedPairs)
    }

    /// «Это не дубли» — чтобы пара не всплывала в следующих прогонах.
    public func acknowledge(pairs: [String], collection: String) {
        var stored = load(collection)
        stored.acknowledgedPairs = Array(Set(stored.acknowledgedPairs).union(pairs)).sorted()
        write(stored, collection: collection)
    }

    public func forgetAcknowledged(collection: String) {
        var stored = load(collection)
        stored.acknowledgedPairs = []
        write(stored, collection: collection)
    }

    public func remove(collection: String) {
        try? FileManager.default.removeItem(at: fileURL(for: collection))
    }
}

/// Сравнение с прошлым прогоном: стало лучше или хуже.
public struct InspectionComparison: Sendable, Hashable {
    public struct Change: Sendable, Hashable, Identifiable {
        public var id: String { category.rawValue }
        public let category: InspectionCategory
        public let now: Int
        public let before: Int

        public var delta: Int { now - before }

        public var line: String {
            switch delta {
            case 0: return String(localized: "\(category.title): \(now.plainDigits) — как и было")
            case let value where value > 0:
                return String(localized: "\(category.title): \(now.plainDigits), было \(before.plainDigits) — стало больше на \(value.plainDigits)")
            default:
                return String(localized: "\(category.title): \(now.plainDigits), было \(before.plainDigits) — стало меньше на \(abs(delta).plainDigits)")
            }
        }
    }

    public let previousAt: Date
    public let changes: [Change]

    public var improved: Bool { changes.allSatisfy { $0.delta <= 0 } && changes.contains { $0.delta < 0 } }
    public var worsened: Bool { changes.contains { $0.delta > 0 } }

    /// `nil`, если сравнивать не с чем: первый прогон — это не «стало лучше».
    public static func between(_ report: InspectionReport, and previous: InspectionReport?) -> InspectionComparison? {
        guard let previous else { return nil }
        let categories = Set(report.findings.map(\.category)).union(previous.findings.map(\.category))
        let changes = categories.sorted { $0.rawValue < $1.rawValue }.map {
            Change(category: $0, now: report.count(of: $0), before: previous.count(of: $0))
        }
        guard !changes.isEmpty else { return nil }
        return InspectionComparison(previousAt: previous.startedAt, changes: changes)
    }
}

/// Отчёт в файл.
public enum InspectionExport {
    public static func json(_ report: InspectionReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    /// Читает обратно то, что записал `json`. Отдельным методом, чтобы способ
    /// записи дат и способ их чтения не могли разойтись.
    public static func decode(_ data: Data) throws -> InspectionReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(InspectionReport.self, from: data)
    }

    public static func markdown(_ report: InspectionReport, comparison: InspectionComparison? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        var lines: [String] = [
            "# Инспекция коллекции «\(report.collectionName)»",
            "",
            "- Дата: \(formatter.string(from: report.startedAt))",
            "- Проверено документов: \(report.examined.plainDigits) из \(report.total.plainDigits)"
                + (report.isSample ? " — это выборка, а не вся коллекция" : ""),
            "- Длительность: \(String(format: "%.1f", report.duration)) с",
            "- Поиск похожих документов: \(report.nearDuplicatesChecked ? "выполнялся" : "не выполнялся")",
        ]
        if report.acknowledged > 0 {
            lines.append("- Пропущено как уже просмотренное: \(report.acknowledged.plainDigits)")
        }
        lines.append("")

        guard !report.findings.isEmpty else {
            lines.append("Находок нет.")
            return lines.joined(separator: "\n") + "\n"
        }

        for category in report.categoriesWithFindings {
            let items = report.findings(in: category)
            lines.append("## \(category.title) — \(items.count.plainDigits)")
            lines.append("")
            lines.append(category.explanation)
            lines.append("")
            lines.append("**Что можно сделать:** \(category.suggestion)")
            lines.append("")
            for finding in items.prefix(200) {
                let detail = finding.detail.map { " — \($0)" } ?? ""
                lines.append("- `\(finding.subject)`\(detail)")
            }
            if items.count > 200 {
                lines.append("- …и ещё \((items.count - 200).plainDigits); полный список — в JSON")
            }
            lines.append("")
        }

        if let comparison {
            lines.append("## По сравнению с прогоном \(formatter.string(from: comparison.previousAt))")
            lines.append("")
            for change in comparison.changes { lines.append("- \(change.line)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
