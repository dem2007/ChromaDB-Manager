import Foundation

/// Перенос чанков переименованного файла.
///
/// Очевидный вариант «обновить метаданные» неосуществим: идентификатор чанка
/// производен от относительного пути (`sha256(relative_path)`, 8.4), и при
/// переименовании он меняется. Значит, чанки надо переложить — но **не**
/// пересчитывать: текст тот же, вектор тот же, платить за него второй раз не
/// за что.
///
/// Порядок — тот же, что в A6, и он не переставляется: прочитать старое вместе
/// с векторами, записать новое, удалить старое, обновить манифест. Любой другой
/// порядок оставляет после сбоя либо дыру, либо двойника.
public enum GitRenames {
    public struct Outcome: Sendable, Hashable {
        public var moved: Int = 0
        public var chunks: Int = 0
        /// Файлы, чанки которых перенести не удалось: они просто будут
        /// проиндексированы заново под новым именем — дороже, но не неправильно.
        public var failed: [String] = []
    }

    public static func apply(
        _ renames: [(from: String, to: String)],
        sourceID: UUID,
        manifest: inout SourceManifest,
        chroma: any SyncDatabase,
        log: LogHandler = noopLogHandler
    ) async -> Outcome {
        var outcome = Outcome()
        guard !renames.isEmpty else { return outcome }
        var collectionIDs: [String: String] = [:]

        for rename in renames {
            guard let entry = manifest.entries[rename.from], !entry.chunkIDs.isEmpty else { continue }
            do {
                let collectionID: String
                if let cached = collectionIDs[entry.collectionName] {
                    collectionID = cached
                } else {
                    collectionID = try await chroma.resolveID(of: entry.collectionName)
                    collectionIDs[entry.collectionName] = collectionID
                }

                let records = try await chroma.documents(collectionID: collectionID, ids: entry.chunkIDs)
                let vectors = try await chroma.embeddings(collectionID: collectionID, ids: entry.chunkIDs)
                guard !records.isEmpty, records.count == vectors.count else {
                    // Чанков в базе нет или векторы отдали не все — переносить
                    // нечего, файл будет проиндексирован заново.
                    outcome.failed.append(rename.from)
                    continue
                }

                var moved: [EmbeddedRecord] = []
                var newIDs: [String] = []
                for record in records {
                    guard let vector = vectors[record.id], !vector.isEmpty else {
                        outcome.failed.append(rename.from)
                        moved = []
                        break
                    }
                    let index = chunkIndex(of: record)
                    // Источник берётся из самой записи: отпечаток считается
                    // от пары «источник + путь» (П6.16), и переезд на новое
                    // имя обязан остаться в пределах своего источника.
                    let recordSource = SourceSyncService.recordedSourceID(record.metadata)
                    let id = SourceSyncService.documentID(
                        relativePath: rename.to, chunkIndex: index, sourceID: recordSource
                    )
                    var metadata = record.metadata ?? [:]
                    // Метаданные, в которых записан путь, обязаны переехать
                    // вместе с чанком: иначе фильтр по `source_file` будет
                    // находить документы под именем, которого больше нет.
                    metadata["source_file"] = .string(rename.to)
                    if metadata["git_relative_path"] != nil {
                        metadata["git_relative_path"] = .string(rename.to)
                    }
                    // Отпечаток файла тоже считается от пути: без пересчёта
                    // переехавший чанк отдавал агенту отпечаток старого имени,
                    // `get_file` по новому не находил ничего, а уборка путей
                    // объявляла каждый переименованный файл испорченным.
                    // Имя и расширение — тем же правилом, что при записи:
                    // по ним ищут похожие пути и фильтруют по типу.
                    let renamed = URL(fileURLWithPath: rename.to)
                    if metadata["file_name"] != nil {
                        metadata["file_name"] = .string(FileNameEncoding.repaired(renamed.lastPathComponent))
                    }
                    if metadata["file_ext"] != nil {
                        metadata["file_ext"] = .string(renamed.pathExtension.lowercased())
                    }
                    if metadata["file_id"] != nil {
                        metadata["file_id"] = .string(
                            SourceSyncService.fileFingerprint(rename.to, sourceID: recordSource)
                        )
                    }
                    if let parent = metadata["parent_chunk_id"], case .string(let value) = parent,
                       let parentIndex = Int(value.split(separator: "-").last.map(String.init) ?? "") {
                        metadata["parent_chunk_id"] = .string(
                            SourceSyncService.documentID(
                                relativePath: rename.to, chunkIndex: parentIndex, sourceID: recordSource
                            )
                        )
                    }
                    moved.append(EmbeddedRecord(
                        id: id, document: record.document ?? "", embedding: vector, metadata: metadata
                    ))
                    newIDs.append(id)
                }
                guard !moved.isEmpty else { continue }

                try await chroma.upsert(collectionID: collectionID, records: moved)
                // Только теперь старые — явным списком, никогда фильтром.
                try await chroma.deleteDocuments(collectionID: collectionID, ids: entry.chunkIDs)

                var updated = entry
                updated.relativePath = rename.to
                updated.chunkIDs = newIDs
                manifest.forget(relativePath: rename.from)
                manifest.record(updated)

                outcome.moved += 1
                outcome.chunks += moved.count
                log(.info, "Git", "Файл переименован: \(rename.from) → \(rename.to); чанков перенесено \(moved.count.plainDigits), векторы не пересчитывались")
            } catch {
                outcome.failed.append(rename.from)
                log(.warning, "Git", "Не удалось перенести чанки \(rename.from) → \(rename.to): \(error.localizedDescription). Файл будет проиндексирован заново.")
            }
        }
        return outcome
    }

    /// Номер чанка: из метаданных, а если их нет — из хвоста идентификатора.
    static func chunkIndex(of record: DocumentRecord) -> Int {
        if let value = record.metadata?["chunk_index"], case .int(let index) = value { return index }
        return Int(record.id.split(separator: "-").last.map(String.init) ?? "") ?? 0
    }
}
