import Foundation

/// Файл коллекции — все её куски, пришедшие из одного исходника.
///
/// Нужен там, где данные отдельного куска не нужны: скопировать `file_id`
/// для `get_file`, увидеть, что вообще лежит в коллекции, найти файл по
/// имени. Собирается из метаданных кусков — тех же полей, что пишет
/// синхронизация, — и ничего не знает о том, есть ли файл на диске.
public struct CollectionFile: Identifiable, Hashable, Sendable {
    /// Отпечаток файла — тот, что принимает `get_file`. Нет у кусков,
    /// записанных ранними сборками: тогда файл узнаётся по пути.
    public let fileID: String?
    /// `source_file`: путь от корня источника.
    public let path: String
    public let name: String
    public let sourceName: String?
    public let chunks: Int
    /// Сколько кусков синхронизация записала файлу (`chunk_count`), — если
    /// записала. Меньше этого в коллекции — запись оборвалась.
    public let expectedChunks: Int?
    public let sizeBytes: Int64?
    /// `file_mtime` как записан: строкой ISO 8601.
    public let modified: String?
    public let format: String?
    public let pages: Int?
    /// Метаданные первого встреченного куска — откуда просмотрщик узнаёт,
    /// где лежит исходник.
    public let sample: ChromaMetadata?

    public var id: String { fileID.map { "id:" + $0 } ?? "path:" + path }

    public var folder: String { (path as NSString).deletingLastPathComponent }

    public var isIncomplete: Bool { expectedChunks.map { chunks < $0 } ?? false }

    public var modifiedDate: Date? {
        guard let modified else { return nil }
        return CollectionFiles.isoWithFraction.date(from: modified) ?? CollectionFiles.iso.date(from: modified)
    }

    /// Условие, которым выбираются куски этого файла: по отпечатку, а без
    /// него — по пути.
    public var condition: MetadataCondition {
        if let fileID { return MetadataCondition(field: "file_id", equals: .string(fileID)) }
        return MetadataCondition(field: "source_file", equals: .string(path))
    }
}

/// Все файлы коллекции — по всей коллекции, а не по выборке: выборка
/// в пять тысяч кусков пропустила бы файлы целиком.
public struct CollectionFileList: Sendable {
    /// По пути.
    public let files: [CollectionFile]
    /// Сколько кусков прочитано.
    public let records: Int
    /// Записи без `source_file`: добавленные агентом, импортированные,
    /// введённые руками.
    public let recordsWithoutFile: Int
    /// Сколько записей было в коллекции, когда список собирали, — по нему
    /// видно, что список устарел.
    public let documentCount: Int
    public let builtAt: Date

    public var filesWithoutID: Int { files.filter { $0.fileID == nil }.count }
}

/// Что сборке списка позволено делать с базой — только читать.
public protocol CollectionFileReader: Sendable {
    func count(collectionID: String) async throws -> Int
    /// Метаданные страницы — без текстов и векторов.
    func metadataPage(collectionID: String, filter: DocumentFilter?, limit: Int, offset: Int) async throws -> [DocumentRecord]
}

extension ChromaClient: CollectionFileReader {
    public func metadataPage(collectionID: String, filter: DocumentFilter?, limit: Int, offset: Int) async throws -> [DocumentRecord] {
        try await getDocuments(
            collectionID: collectionID, limit: limit, offset: offset, filter: filter, includeDocuments: false
        )
    }
}

public enum CollectionFiles {
    /// Страница обхода. Без текстов метаданные одного куска — сотни байт,
    /// и две тысячи на запрос не упираются ни в какой предел ответа.
    public static let pageSize = 2_000

    static let iso = ISO8601DateFormatter()
    static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Обходит коллекцию и собирает её файлы. `filter` сужает обход —
    /// агенту он нужен, чтобы перечислить файлы одного года или источника.
    public static func build(
        reader: any CollectionFileReader,
        collectionID: String,
        filter: DocumentFilter? = nil,
        pageSize: Int = CollectionFiles.pageSize,
        now: Date = Date(),
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> CollectionFileList {
        let total = try await reader.count(collectionID: collectionID)
        var grouping = Grouping()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await reader.metadataPage(
                collectionID: collectionID, filter: filter, limit: pageSize, offset: offset
            )
            if page.isEmpty { break }
            for record in page { grouping.take(record.metadata) }
            offset += page.count
            progress(offset, total)
            // Короткая страница — конец, только если всё уже прочитано:
            // сервер вправе отдавать меньше, чем просили, и остановка на
            // первой такой странице молча обрезала бы список. Без лишней
            // ходки за пустой страницей, когда счёт уже сошёлся.
            if page.count < pageSize, offset >= total { break }
        }
        return grouping.list(documentCount: total, builtAt: now)
    }

    /// Группировка кусков по файлам — отдельно от обхода, чтобы правило
    /// проверялось тестом без базы.
    ///
    /// Ключ — отпечаток, а без него путь: два файла с одним путём из разных
    /// источников — разные файлы, и у каждого свой `file_id`.
    public struct Grouping {
        private struct Bucket {
            var fileID: String?
            var path: String
            var name: String?
            var sourceName: String?
            var chunks = 0
            var expected: Int?
            var size: Int64?
            var modified: String?
            var format: String?
            var pages: Int?
            var sample: ChromaMetadata?
        }

        private var buckets: [String: Bucket] = [:]
        private var records = 0
        private var withoutFile = 0

        public init() {}

        public mutating func take(_ metadata: ChromaMetadata?) {
            records += 1
            let fileID = Self.string(metadata, "file_id")
            let path = Self.string(metadata, "source_file")
            guard fileID != nil || path != nil else {
                withoutFile += 1
                return
            }
            let key = fileID.map { "id:" + $0 } ?? "path:" + (path ?? "")
            var bucket = buckets[key] ?? Bucket(fileID: fileID, path: path ?? "", sample: metadata)
            bucket.chunks += 1
            if bucket.path.isEmpty, let path { bucket.path = path }
            bucket.name = bucket.name ?? Self.string(metadata, "file_name")
            bucket.sourceName = bucket.sourceName ?? Self.string(metadata, "_cdbm_source_name")
            if let expected = Self.int(metadata, "chunk_count") { bucket.expected = max(bucket.expected ?? 0, expected) }
            bucket.size = bucket.size ?? Self.int(metadata, "file_size").map(Int64.init)
            bucket.modified = bucket.modified ?? Self.string(metadata, "file_mtime")
            bucket.format = bucket.format ?? Self.string(metadata, "file_ext")
            bucket.pages = bucket.pages ?? Self.int(metadata, "page_count")
            buckets[key] = bucket
        }

        public func list(documentCount: Int, builtAt: Date) -> CollectionFileList {
            var files: [CollectionFile] = []
            files.reserveCapacity(buckets.count)
            for bucket in buckets.values {
                // У строк таблицы `file_name` нет — имя в конце пути.
                let fallback: String = bucket.path.isEmpty
                    ? (bucket.fileID ?? "")
                    : (bucket.path as NSString).lastPathComponent
                files.append(CollectionFile(
                    fileID: bucket.fileID,
                    path: bucket.path,
                    name: bucket.name ?? fallback,
                    sourceName: bucket.sourceName,
                    chunks: bucket.chunks,
                    expectedChunks: bucket.expected,
                    sizeBytes: bucket.size,
                    modified: bucket.modified,
                    format: bucket.format,
                    pages: bucket.pages,
                    sample: bucket.sample
                ))
            }
            files.sort { left, right in
                if left.path != right.path { return left.path < right.path }
                return (left.fileID ?? "") < (right.fileID ?? "")
            }
            return CollectionFileList(
                files: files, records: records, recordsWithoutFile: withoutFile,
                documentCount: documentCount, builtAt: builtAt
            )
        }

        static func string(_ metadata: ChromaMetadata?, _ key: String) -> String? {
            guard case .string(let value)? = metadata?[key], !value.isEmpty else { return nil }
            return value
        }

        static func int(_ metadata: ChromaMetadata?, _ key: String) -> Int? {
            switch metadata?[key] {
            case .int(let value)?: return value
            case .double(let value)?: return Int(value)
            default: return nil
            }
        }
    }

    /// Совпадает ли файл с тем, что набрано в поиске: по имени и по пути,
    /// без учёта регистра, «ё» и «е» — одна буква.
    public static func matches(_ file: CollectionFile, query: String) -> Bool {
        let needle = folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return true }
        return folded(file.path).contains(needle) || folded(file.name).contains(needle)
    }

    static func folded(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    /// Список целиком — чтобы открыть его там, где его удобнее читать.
    public static func csv(_ list: CollectionFileList) -> String {
        var text = "name,path,file_id,source,chunks,expected_chunks,bytes,modified,format,pages\n"
        for file in list.files {
            let fields = [
                file.name, file.path, file.fileID ?? "", file.sourceName ?? "",
                String(file.chunks), file.expectedChunks.map(String.init) ?? "",
                file.sizeBytes.map(String.init) ?? "", file.modified ?? "",
                file.format ?? "", file.pages.map(String.init) ?? "",
            ]
            text += fields.map(CSVText.field).joined(separator: ",") + "\n"
        }
        return text
    }
}

/// Поле CSV: в кавычках, если в нём запятая, кавычка или перевод строки.
///
/// Начало «=», «+», «-», «@» таблица прочитает как формулу — а имя файла
/// и заметку журнала может записать агент. Такое поле получает впереди
/// апостроф: таблица покажет текст, а не выполнит его.
public enum CSVText {
    public static func field(_ value: String) -> String {
        var value = value
        if let first = value.first, "=+-@\t\r".contains(first) { value = "'" + value }
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
