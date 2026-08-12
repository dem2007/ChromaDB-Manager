import Foundation
import CryptoKit

/// Что лежит в `manifest.json` пакета `.chromaexport`.
///
/// Формат зафиксирован спецификацией, и версия в нём — первое, что читает
/// импорт: пакет из будущего разбирать наугад нельзя.
public struct CollectionExportManifest: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public var formatVersion: Int
    public var exportedAt: Date
    public var collectionName: String
    public var tenant: String
    public var database: String
    public var serverVersion: String
    public var metric: String?
    public var dimension: Int?
    public var model: String?
    /// `_cdbm_*` целиком — чтобы на другой машине коллекция описывала себя
    /// так же, как здесь.
    public var collectionMetadata: ChromaMetadata
    public var documentCount: Int
    public var includesEmbeddings: Bool
    /// SHA-256 файла данных: испорченный при переносе пакет должен быть виден
    /// до того, как из него что-то запишут.
    public var dataSHA256: String
    public var dataBytes: Int
    /// Фильтр, которым выгружали подмножество, — словами, для отчёта.
    public var filterDescription: String?

    public init(
        formatVersion: Int = CollectionExportManifest.currentVersion,
        exportedAt: Date = Date(),
        collectionName: String,
        tenant: String,
        database: String,
        serverVersion: String,
        metric: String?,
        dimension: Int?,
        model: String?,
        collectionMetadata: ChromaMetadata = [:],
        documentCount: Int = 0,
        includesEmbeddings: Bool = true,
        dataSHA256: String = "",
        dataBytes: Int = 0,
        filterDescription: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.collectionName = collectionName
        self.tenant = tenant
        self.database = database
        self.serverVersion = serverVersion
        self.metric = metric
        self.dimension = dimension
        self.model = model
        self.collectionMetadata = collectionMetadata
        self.documentCount = documentCount
        self.includesEmbeddings = includesEmbeddings
        self.dataSHA256 = dataSHA256
        self.dataBytes = dataBytes
        self.filterDescription = filterDescription
    }
}

/// Одна строка `documents.jsonl`.
public struct ExportedDocument: Codable, Sendable {
    public var id: String
    public var document: String?
    public var metadata: ChromaMetadata?
    public var embedding: [Double]?

    public init(id: String, document: String?, metadata: ChromaMetadata?, embedding: [Double]?) {
        self.id = id
        self.document = document
        self.metadata = metadata
        self.embedding = embedding
    }
}

public enum TransferError: LocalizedError, Equatable {
    case notAPackage(String)
    case futureFormat(Int)
    case brokenManifest(String)
    case checksumMismatch
    case dimensionMismatch(expected: Int, got: Int)
    case notEnoughSpace(needed: Int64, free: Int64)
    case noEmbeddingsAndNoModel

    public var errorDescription: String? {
        switch self {
        case .notAPackage(let path):
            return String(localized: "\(path) не похож на пакет .chromaexport: внутри должны лежать manifest.json и documents.jsonl.")
        case .futureFormat(let version):
            return String(localized: "Пакет записан более новой версией формата (\(version.plainDigits)). Разбирать его наугад приложение не будет — обновитесь.")
        case .brokenManifest(let reason):
            return String(localized: "Манифест пакета не читается: \(reason)")
        case .checksumMismatch:
            return String(localized: "Контрольная сумма файла данных не сошлась — пакет повреждён при переносе. Импорт остановлен до первой записи.")
        case .dimensionMismatch(let expected, let got):
            return String(localized: "Размерность не совпадает: у коллекции \(expected.plainDigits), в пакете \(got.plainDigits). Такие векторы несравнимы, импорт запрещён.")
        case .notEnoughSpace(let needed, let free):
            let need = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            let have = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            return String(localized: "Нужно примерно \(need), свободно \(have). Экспорт не начат — упасть на середине хуже, чем не начаться.")
        case .noEmbeddingsAndNoModel:
            return String(localized: "В пакете нет векторов, а модель для их расчёта не выбрана.")
        }
    }
}

/// Экспорт коллекции в пакет `.chromaexport`.
///
/// Потоковый в обе стороны: файл на миллион документов не должен собираться
/// в память ни при записи, ни при чтении — потому и JSON Lines, а не один JSON.
public struct CollectionExporter: Sendable {
    public struct Options: Sendable, Hashable {
        public var includesEmbeddings: Bool
        public var pageSize: Int
        public var filter: DocumentFilter?

        public init(includesEmbeddings: Bool = true, pageSize: Int = 200, filter: DocumentFilter? = nil) {
            self.includesEmbeddings = includesEmbeddings
            self.pageSize = max(1, pageSize)
            self.filter = filter
        }
    }

    public struct Progress: Sendable {
        public var written: Int
        public var total: Int
        public var bytes: Int
    }

    public struct Result: Sendable {
        public var url: URL
        public var manifest: CollectionExportManifest
    }

    /// Что читает экспорт. Тот же принцип, что у инспектора: методов записи
    /// в протоколе нет.
    public protocol Source: Sendable {
        func count(collectionID: String) async throws -> Int
        func page(
            collectionID: String, limit: Int, offset: Int,
            filter: DocumentFilter?, includeEmbeddings: Bool
        ) async throws -> [ExportedDocument]
    }

    private let source: any Source
    private let log: LogHandler

    public init(source: any Source, log: @escaping LogHandler = noopLogHandler) {
        self.source = source
        self.log = log
    }

    /// Фильтр словами — для отчёта и для манифеста: пакет должен объяснять,
    /// почему в нём не вся коллекция.
    static func describe(_ filter: DocumentFilter?) -> String? {
        guard let filter, !filter.isEmpty else { return nil }
        var parts = filter.conditions.map { "\($0.field) \($0.op.title) \($0.value)" }
        parts += filter.textConditions.map { "\($0.op.title) «\($0.text)»" }
        return parts.isEmpty ? String(localized: "фильтр задан") : parts.joined(separator: ", ")
    }

    /// Оценка размера **до** начала выгрузки.
    ///
    /// Шестнадцать байт на компоненту вектора, а не восемь: в JSON она
    /// печатается текстом («-0.023841571» — это 12–20 байт вместе с
    /// разделителем), тогда как 8 байт — размер двоичного значения.
    /// Заниженная оценка опаснее завышенной: проверка свободного места
    /// пропустит операцию, которой не хватит диска, и она упадёт на середине.
    public static func estimatedBytes(
        documents: Int, dimension: Int?, averageTextLength: Int = 800, averageMetadataLength: Int = 200
    ) -> Int64 {
        let vector = (dimension ?? 0) * 16
        return Int64(documents) * Int64(vector + averageTextLength + averageMetadataLength + 64)
    }

    public func export(
        collection: ChromaCollection,
        to destination: URL,
        serverVersion: String,
        tenant: String,
        database: String,
        options: Options = Options(),
        freeSpace: Int64? = nil,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Result {
        let total = (try? await source.count(collectionID: collection.id)) ?? 0
        if let freeSpace {
            let needed = Self.estimatedBytes(
                documents: total,
                dimension: options.includesEmbeddings ? collection.effectiveDimension : 0
            )
            guard needed < freeSpace else {
                throw TransferError.notEnoughSpace(needed: needed, free: freeSpace)
            }
        }

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let dataURL = destination.appendingPathComponent("documents.jsonl")
        fileManager.createFile(atPath: dataURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dataURL)

        var digest = SHA256()
        var written = 0
        var bytes = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        do {
            var offset = 0
            while true {
                try Task.checkCancellation()
                let page = try await source.page(
                    collectionID: collection.id, limit: options.pageSize, offset: offset,
                    filter: options.filter, includeEmbeddings: options.includesEmbeddings
                )
                guard !page.isEmpty else { break }
                offset += page.count

                for document in page {
                    var line = try encoder.encode(document)
                    line.append(0x0A)
                    digest.update(data: line)
                    try handle.write(contentsOf: line)
                    bytes += line.count
                    written += 1
                }
                progress?(Progress(written: written, total: max(total, written), bytes: bytes))
                if page.count < options.pageSize { break }
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            // Отменённый или упавший экспорт не оставляет после себя пакета:
            // недописанный файл выглядит как готовый и однажды будет
            // импортирован.
            try? handle.close()
            try? fileManager.removeItem(at: destination)
            throw error
        }

        let manifest = CollectionExportManifest(
            collectionName: collection.name,
            tenant: tenant,
            database: database,
            serverVersion: serverVersion,
            metric: collection.space?.rawValue,
            dimension: collection.effectiveDimension,
            model: collection.boundModel,
            collectionMetadata: collection.metadata ?? [:],
            documentCount: written,
            includesEmbeddings: options.includesEmbeddings,
            dataSHA256: digest.finalize().compactMap { String(format: "%02x", $0) }.joined(),
            dataBytes: bytes,
            filterDescription: Self.describe(options.filter)
        )
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        manifestEncoder.dateEncodingStrategy = .iso8601
        try manifestEncoder.encode(manifest).write(
            to: destination.appendingPathComponent("manifest.json"), options: .atomic
        )

        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        log(.success, "Перенос", "Экспорт «\(collection.name)»: документов \(written.plainDigits), \(size) → \(destination.lastPathComponent)")
        return Result(url: destination, manifest: manifest)
    }
}

/// Клиент как источник выгрузки и как приёмник загрузки.
///
/// Отдельным расширением, а не прямой зависимостью: экспорт и импорт не знают
/// про HTTP, а тесты подставляют свои стенды.
extension ChromaClient: CollectionExporter.Source, CollectionImporter.Destination {
    public func page(
        collectionID: String, limit: Int, offset: Int,
        filter: DocumentFilter?, includeEmbeddings: Bool
    ) async throws -> [ExportedDocument] {
        let records = try await getDocuments(
            collectionID: collectionID, limit: limit, offset: offset,
            filter: filter, includeEmbeddings: includeEmbeddings
        )
        guard includeEmbeddings, !records.isEmpty else {
            return records.map {
                ExportedDocument(id: $0.id, document: $0.document, metadata: $0.metadata, embedding: nil)
            }
        }
        // Векторы — отдельным запросом по явным идентификаторам: `get` со
        // страницей векторов законен здесь (это и есть экспорт), но
        // просить их по идентификаторам дешевле и понятнее в журнале.
        let vectors = try await embeddings(collectionID: collectionID, ids: records.map(\.id))
        return records.map {
            ExportedDocument(id: $0.id, document: $0.document, metadata: $0.metadata, embedding: vectors[$0.id])
        }
    }
}
