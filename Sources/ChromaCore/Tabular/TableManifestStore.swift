import Foundation

/// Row-level manifests, one file per source.
///
/// Kept apart from `ManifestStore` because it answers a different question: that
/// one knows which files were indexed, this one knows which **rows** were, and
/// mixing them would make the file-level manifest grow by a line per row of
/// every spreadsheet.
public final class TableManifestStore {
    private let directory: URL
    private let log: LogHandler
    private let queue = DispatchQueue(label: "app.chromadbmanager.tablemanifests")

    public init(directory: URL = AppPaths.manifestsDirectory, log: @escaping LogHandler = noopLogHandler) {
        self.directory = directory
        self.log = log
    }

    public func fileURL(for sourceID: UUID) -> URL {
        directory.appendingPathComponent("\(sourceID.uuidString)-tables.json")
    }

    /// Keyed by the file's path inside the source.
    public func load(sourceID: UUID) -> [String: TableFileManifest] {
        queue.sync {
            let url = fileURL(for: sourceID)
            guard let data = GuardedJSONFile<[String: TableFileManifest]>.readDataWithRetry(at: url) else {
                if FileManager.default.fileExists(atPath: url.path) {
                    log(.error, "Таблицы", "Манифест таблиц есть, но не читается — строки будут проиндексированы заново.")
                }
                return [:]
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let manifests = try? decoder.decode([String: TableFileManifest].self, from: data) else {
                log(.warning, "Таблицы", "Манифест таблиц источника повреждён и будет пересоздан")
                return [:]
            }
            return manifests
        }
    }

    /// Atomic and durable, for the same reason the file manifest is: a manifest
    /// caught half-written by a power cut takes the source with it.
    public func save(_ manifests: [String: TableFileManifest], sourceID: UUID) {
        queue.sync {
            do {
                try AppPaths.ensureDirectory(directory)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(manifests)

                let destination = fileURL(for: sourceID)
                GuardedJSONFile<[String: TableFileManifest]>.keepPreviousVersion(of: destination, unless: data)
                let temporary = directory.appendingPathComponent(".\(sourceID.uuidString)-tables.tmp")
                FileManager.default.createFile(atPath: temporary.path, contents: nil)
                let handle = try FileHandle(forWritingTo: temporary)
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } catch {
                log(.error, "Таблицы", "Не удалось сохранить манифест таблиц: \(error.localizedDescription)")
            }
        }
    }

    public func remove(sourceID: UUID) {
        queue.sync { try? FileManager.default.removeItem(at: fileURL(for: sourceID)) }
    }
}

/// One line of's statistics: how many rows came from which table.
public struct TableStatisticsRow: Hashable, Sendable, Identifiable {
    public var id: String { "\(sourceName)\u{0}\(relativePath)\u{0}\(sheetName)" }
    public let sourceName: String
    public let relativePath: String
    public let sheetName: String
    public let collectionName: String
    public let rows: Int

    public init(sourceName: String, relativePath: String, sheetName: String, collectionName: String, rows: Int) {
        self.sourceName = sourceName
        self.relativePath = relativePath
        self.sheetName = sheetName
        self.collectionName = collectionName
        self.rows = rows
    }
}

extension TableManifestStore {
    /// Исчезнувшие строки всех таблиц источника — то, что ждёт решения.
    ///
    /// По листам, а не по файлам: решение принимают о строках одного листа,
    /// и «прайс.xlsx — 40 строк» не сказало бы, о каком из двух листов речь.
    public func pendingRemovals(sourceID: UUID) -> [PendingRowRemoval] {
        load(sourceID: sourceID).values
            .flatMap { file in
                file.pendingRemovals
                    .filter { !$0.value.rows.isEmpty }
                    .map { sheetName, removal in
                        PendingRowRemoval(
                            relativePath: file.relativePath,
                            sheetName: sheetName,
                            collectionName: file.collectionName,
                            rows: removal.rows.sorted { $0.rowNumber < $1.rowNumber },
                            noticedAt: removal.noticedAt
                        )
                    }
            }
            .sorted { ($0.relativePath, $0.sheetName) < ($1.relativePath, $1.sheetName) }
    }

    /// «сколько строк из каких таблиц проиндексировано».
    ///
    /// Per sheet rather than per file: one workbook routinely holds a catalogue
    /// and a reference table, and «прайс.xlsx — 12 000 строк» would say nothing
    /// about which of them.
    public func statistics(sourceID: UUID, sourceName: String) -> [TableStatisticsRow] {
        load(sourceID: sourceID).values
            .flatMap { file in
                file.sheets.values.map { sheet in
                    TableStatisticsRow(
                        sourceName: sourceName,
                        relativePath: file.relativePath,
                        sheetName: sheet.sheetName,
                        collectionName: file.collectionName,
                        rows: sheet.rowCount
                    )
                }
            }
            .sorted { ($0.relativePath, $0.sheetName) < ($1.relativePath, $1.sheetName) }
    }
}
