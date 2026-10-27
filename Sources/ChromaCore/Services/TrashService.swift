import Foundation

/// One document captured just before it was deleted.
///
/// Self-contained JSON Lines record, the same reasoning as the audit log
/// (`AuditLog`): a crash mid-write costs only the last line, never the file.
/// Collection binding (model / dimension / metric) travels with every entry
/// rather than being looked up once, because the whole point of `.collection`
/// entries is surviving the collection itself being gone.
public struct TrashEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// This document alone was deleted.
        case document
        /// The document went with the whole collection.
        case collection
    }

    public var id: UUID
    public var deletedAt: Date
    public var documentID: String
    public var document: String?
    public var metadata: ChromaMetadata?
    public var embedding: [Double]?
    public var collectionName: String
    public var collectionMetric: DistanceMetric?
    public var collectionModel: String?
    /// Сервер этой модели — `LLMProvider.rawValue`. Строкой, а не
    /// перечислением: незнакомое значение не должно делать запись корзины
    /// нечитаемой. `nil` — запись до или коллекция без модели.
    public var collectionServer: String?
    public var collectionDimension: Int?
    public var reason: Reason
    /// Сколько чисел в векторе и полей в метаданных — у записи, которую
    /// держат в памяти без них. Корзина в сто тысяч документов
    /// держала в памяти все их векторы: гигабайт ради столбца «Вектор: есть».
    /// Сами данные читаются из файла при восстановлении (`fullEntries`).
    public fileprivate(set) var embeddingLength = 0
    public fileprivate(set) var metadataCount = 0
    /// Длина полного текста в байтах — у записи, текст которой в памяти
    /// обрезан до начала. Ноль — текст в памяти целиком.
    public fileprivate(set) var documentBytes = 0

    /// Сколько знаков текста держится в памяти: столько видно в таблице
    /// корзины и столько ищется её поиском. Целиком — `fullEntries`.
    public static let previewCharacters = 400

    /// Текст в памяти — только начало.
    public var isDocumentTruncated: Bool { documentBytes > (document?.utf8.count ?? 0) }

    private enum CodingKeys: String, CodingKey {
        case id, deletedAt, documentID, document, metadata, embedding
        case collectionName, collectionMetric, collectionModel, collectionServer, collectionDimension, reason
    }

    public init(
        id: UUID = UUID(),
        deletedAt: Date = Date(),
        documentID: String,
        document: String?,
        metadata: ChromaMetadata?,
        embedding: [Double]?,
        collectionName: String,
        collectionMetric: DistanceMetric?,
        collectionModel: String?,
        collectionServer: String?,
        collectionDimension: Int?,
        reason: Reason
    ) {
        self.id = id
        self.deletedAt = deletedAt
        self.documentID = documentID
        self.document = document
        self.metadata = metadata
        self.embedding = embedding
        self.collectionName = collectionName
        self.collectionMetric = collectionMetric
        self.collectionModel = collectionModel
        self.collectionServer = collectionServer
        self.collectionDimension = collectionDimension
        self.reason = reason
    }

    /// Rough size on disk, for the volume-limited eviction. Exact to the byte
    /// is not the point — knowing whether the trash is 10 MB or 10 GB is.
    var sizeEstimate: Int {
        var bytes = max(document?.utf8.count ?? 0, documentBytes) + max(embedding?.count ?? 0, embeddingLength) * 8
        bytes += max(metadata?.count ?? 0, metadataCount) * 32
        return bytes
    }

    /// Есть ли у записи вектор — и у облегчённой тоже.
    public var hasEmbedding: Bool { embedding != nil || embeddingLength > 0 }

    /// Та же запись без вектора и метаданных — для памяти.
    func lightened() -> TrashEntry {
        var light = self
        light.embeddingLength = embedding?.count ?? embeddingLength
        light.metadataCount = metadata?.count ?? metadataCount
        light.embedding = nil
        light.metadata = nil
        light.trimDocument()
        return light
    }

    /// Текст — до начала: сто тысяч удалённых документов держали
    /// в памяти четверть гигабайта текста ради столбца с его первой строкой.
    fileprivate mutating func trimDocument() {
        guard let text = document, text.count > Self.previewCharacters else { return }
        documentBytes = max(documentBytes, text.utf8.count)
        document = String(text.prefix(Self.previewCharacters))
    }
}

/// Что из корзины можно вернуть в коллекцию.
///
/// Векторы корзины не пересчитываются — в коллекцию ложится то, что
/// сохранено. Значит, модель и сервер записей обязаны совпасть с привязкой
/// коллекции: иначе в ней окажутся векторы двух моделей. Удалённая
/// коллекция создаётся заново с привязкой первой записи, у которой модель
/// есть, — и тогда сверка с ней.
public struct TrashRestorePlan: Sendable {
    /// Привязка, с которой сверялись; `nil` — сверять не с чем.
    public let target: BoundModel?
    public let restorable: [TrashEntry]
    /// Записи другой модели — остаются в корзине.
    public let left: [TrashEntry]

    /// `existing` — коллекция, если она есть: `.some(nil)` — есть, но без
    /// модели, и тогда сверять не с чем, как и раньше.
    public init(entries: [TrashEntry], existing: BoundModel??) {
        let target: BoundModel?
        switch existing {
        case .some(let binding): target = binding
        case .none: target = entries.lazy.compactMap(\.vectorBinding).first
        }
        self.target = target
        var restorable: [TrashEntry] = []
        var left: [TrashEntry] = []
        for entry in entries {
            if let target, let own = entry.vectorBinding, own != target {
                left.append(entry)
            } else {
                restorable.append(entry)
            }
        }
        self.restorable = restorable
        self.left = left
    }

    /// Запись, с чьей привязкой создавать коллекцию заново.
    public var template: TrashEntry? {
        restorable.first { $0.vectorBinding == target } ?? restorable.first
    }

    /// Почему часть записей осталась в корзине; `nil` — вернутся все.
    public func conflict(collection: String) -> BindingError? {
        guard let target, let other = left.first?.vectorBinding else { return nil }
        return .restoreConflict(collection: collection, bound: target, restored: other, left: left.count)
    }
}

public extension TrashEntry {
    /// Модель и сервер, которыми посчитан вектор записи; `nil` — коллекция
    /// была без модели. Записи до сервера не знают — значит, LM Studio.
    var vectorBinding: BoundModel? {
        collectionModel.map { BoundModel(model: $0, serverID: collectionServer ?? LLMProvider.lmStudio.rawValue) }
    }
}

/// Local recycle bin for documents and collections deleted through the UI.
///
/// Rule 1 of Приложение 5: automatic deletions are forbidden, but nothing
/// protects the user from a *manual* delete they did not mean to make. This is
/// that protection — the data is written here before the delete request ever
/// reaches ChromaDB, so a slipped click or a wrong row is not automatically
/// unrecoverable.
///
/// Deliberately not append-only like `AuditLog`: an audit trail must never
/// lose a record on its own, but a recycle bin that never actually empties
/// defeats its own volume limit. Restoring, expiring by age and emptying by
/// hand all remove entries for real — each one is a visible, explicit action
/// (rule 2), the same standing the embedding cache's LRU eviction and the
/// log's own rotation already have.
@MainActor
public final class TrashService: ObservableObject {
    /// `nonisolated`: это просто числа, и они нужны значениями по умолчанию
    /// в местах, не привязанных к главному потоку, — например в `Configuration`.
    public nonisolated static let defaultLimitBytes: Int64 = 1024 * 1024 * 1024
    public nonisolated static let defaultRetentionDays = 14

    /// Newest first. Без векторов и метаданных: полные записи —
    /// `fullEntries(withIDs:)`.
    @Published public private(set) var entries: [TrashEntry] = []
    /// Файл ещё читается. Корзина в сто тысяч записей читается
    /// секунды, и запуск приложения их не ждёт.
    @Published public private(set) var isLoading = false

    /// Снятое из корзины, пока файл читался: прочитанное не должно его
    /// вернуть. `nil` вместо набора — корзину очистили целиком.
    private var removedWhileLoading: Set<UUID>? = []

    private let fileURL: URL
    private var retentionDays: Int
    private var limitBytes: Int64
    private let writeQueue = DispatchQueue(label: "io.github.chromadbmanager.trash")
    private let log: LogHandler

    public init(
        fileURL: URL = AppPaths.trashFile,
        retentionDays: Int = TrashService.defaultRetentionDays,
        limitBytes: Int64 = TrashService.defaultLimitBytes,
        log: @escaping LogHandler = noopLogHandler,
        loadsInBackground: Bool = false
    ) {
        self.fileURL = fileURL
        self.retentionDays = retentionDays
        self.limitBytes = limitBytes
        self.log = log
        guard loadsInBackground else {
            entries = Self.load(from: fileURL)
            applyRetention()
            return
        }
        isLoading = true
        let url = fileURL
        Task.detached(priority: .utility) { [weak self] in
            let loaded = Self.load(from: url)
            await self?.finishLoading(loaded)
        }
    }

    /// Прочитанное — к тому, что успели записать за время чтения; снятое
    /// за это время не возвращается.
    private func finishLoading(_ loaded: [TrashEntry]) {
        defer { removedWhileLoading = [] }
        // Дальше список полон: перезапись и вытеснение его больше не ждут.
        isLoading = false
        guard let removed = removedWhileLoading else { return }
        let present = Set(entries.map(\.id))
        entries = (entries + loaded.filter { !present.contains($0.id) && !removed.contains($0.id) })
            .sorted { $0.deletedAt > $1.deletedAt }
        if !removed.isEmpty { rewriteFile() }
        applyRetention()
        MemoryRelief.soon()
    }

    public var fileLocation: URL { fileURL }

    public var collectionNames: [String] {
        Array(Set(entries.map(\.collectionName))).sorted()
    }

    /// Предел объёма корзины — по той же оценке, что и `totalBytes`.
    public var capacityBytes: Int64 { limitBytes }

    /// Оценка объёма записей — та, по которой работает вытеснение.
    public static func estimatedBytes(of entries: [TrashEntry]) -> Int {
        entries.reduce(0) { $0 + $1.sizeEstimate }
    }

    public var totalBytes: Int {
        entries.reduce(0) { $0 + $1.sizeEstimate }
    }

    /// Called whenever the settings screen changes retention — re-sweeps
    /// immediately so a tightened limit takes effect without waiting for the
    /// next delete.
    public func updateRetention(days: Int, limitBytes: Int64) {
        retentionDays = days
        self.limitBytes = limitBytes
        applyRetention()
    }

    /// Что захват не состоялся.
    ///
    /// Своим типом, а не `Bool`: вызывающая сторона обязана отменить удаление
    /// и **сказать человеку почему**, а для этого нужна причина, а не «нет».
    public struct CaptureFailed: LocalizedError {
        public let reason: String

        public var errorDescription: String? {
            String(localized: "Не удалось положить копию в корзину: \(reason). Удаление отменено — без копии оно было бы необратимым.")
        }
    }

    /// Records documents about to be deleted. Called **before** the delete
    /// request is sent — see `CollectionsViewModel.deleteDocument` /
    /// `deleteSelected` — so a crash between the two leaves the backup copy
    /// and the still-live document, never neither.
    ///
    /// **Бросает, если копия не легла на диск, и вызывающая сторона обязана
    /// тогда не удалять**. Раньше метод возвращал `Void`, писал файл
    /// асинхронно и глотал каждую ошибку внутри — узнать об отказе было
    /// физически нечем, и все четыре пути удаления шли дальше в любом случае.
    /// При недоступном `trash.jsonl` это давало ровно то, что корзина обязана
    /// исключать: приложение говорит «копии в корзине», из базы документы
    /// уходят, а после перезапуска восстанавливать нечего.
    ///
    /// Запись идёт **до** появления в памяти: показывать в окне копии,
    /// которых нет на диске, — тоже враньё, просто менее заметное.
    public func record(_ batch: [TrashEntry]) throws {
        guard !batch.isEmpty else { return }
        do {
            try appendToFile(batch)
        } catch {
            // Системная ошибка сама по себе говорит только «нет разрешения на
            // сохранение файла». Человеку в этот момент важнее другое: что
            // из-за неё **удаление не состоялось** и база цела. Поэтому
            // причина оборачивается, а не пробрасывается как есть.
            let failure = CaptureFailed(reason: Self.tidy(error.localizedDescription))
            log(.error, "Корзина", failure.errorDescription ?? "")
            throw failure
        }
        entries.insert(contentsOf: batch.map { $0.lightened() }, at: 0)
        applyRetention()
    }

    /// Системные описания заканчиваются точкой, а наше предложение продолжается.
    private static func tidy(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }

    public func record(_ entry: TrashEntry) throws {
        try record([entry])
    }

    public func entries(withIDs ids: Set<UUID>) -> [TrashEntry] {
        entries.filter { ids.contains($0.id) }
    }

    /// Записи целиком — с векторами и метаданными, из файла.
    ///
    /// Строка разбирается, только если в ней есть идентификатор записи:
    /// восстановить один документ из корзины в сто тысяч не значит
    /// раскодировать все сто тысяч векторов. Файл читается в очереди
    /// записи, а не на главном потоке: корзина бывает в полтора гигабайта.
    public func fullEntries(withIDs ids: Set<UUID>) async -> [TrashEntry] {
        guard !ids.isEmpty else { return [] }
        let url = fileURL
        let found = await withCheckedContinuation { (continuation: CheckedContinuation<[TrashEntry], Never>) in
            writeQueue.async {
                continuation.resume(returning: Self.readFullEntries(withIDs: ids, from: url))
            }
        }
        return found.sorted { $0.deletedAt > $1.deletedAt }
    }

    private nonisolated static func readFullEntries(withIDs ids: Set<UUID>, from url: URL) -> [TrashEntry] {
        let wanted = Set(ids.map { Data($0.uuidString.utf8) })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var found: [TrashEntry] = []
        JSONLines.forEachLine(at: url) { line in
            guard let id = entryID(in: line), wanted.contains(id),
                  let entry = try? decoder.decode(TrashEntry.self, from: line),
                  ids.contains(entry.id) else { return }
            found.append(entry)
        }
        return found
    }

    /// Идентификатор записи в строке файла — без разбора всей строки.
    private nonisolated static let idMarker = Data(#""id":""#.utf8)

    private nonisolated static func entryID(in line: Data) -> Data? {
        // Внутри строк JSON кавычка экранирована, поэтому `"id":"` из текста
        // документа сюда не попадает; проверка UUID — на всякий случай.
        line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let base = raw.baseAddress else { return nil }
            var from = 0
            while from < raw.count {
                let found = idMarker.withUnsafeBytes { marker in
                    memmem(base + from, raw.count - from, marker.baseAddress, marker.count)
                }
                guard let found else { return nil }
                let start = base.distance(to: UnsafeRawPointer(found)) + idMarker.count
                if start + 37 <= raw.count, raw[start + 36] == UInt8(ascii: "\"") {
                    let candidate = Data(bytes: base + start, count: 36)
                    if let text = String(data: candidate, encoding: .utf8), UUID(uuidString: text) != nil { return candidate }
                }
                from = start
            }
            return nil
        }
    }

    /// Removes entries after they were successfully written back to the
    /// database — a restored copy is not a backup of anything any more.
    public func forget(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        // Пока файл читается, перезаписывать его по неполному списку
        // нельзя: стёрлись бы непрочитанные записи.
        if isLoading {
            removedWhileLoading?.formUnion(ids)
            return
        }
        rewriteFile()
    }

    /// The one place that throws everything away for good — only ever called
    /// from an explicit, confirmed user action, the same standing
    /// `AuditLog.removeArchive` has.
    public func emptyTrash() {
        let count = entries.count
        entries.removeAll()
        if isLoading { removedWhileLoading = nil }
        writeQueue.async { [fileURL] in
            try? FileManager.default.removeItem(at: fileURL)
        }
        log(.warning, "Корзина", "Корзина очищена вручную: удалено записей \(count.plainDigits)")
        MemoryRelief.soon()
    }

    // MARK: - Retention

    /// Age limit, then volume limit. Both are silent-but-visible housekeeping
    /// on the app's own backup copy, not on the database itself (rule 2): every
    /// sweep that removes something says so in the log.
    private func applyRetention() {
        // По неполному списку и вытеснять, и перезаписывать файл нельзя.
        guard !isLoading else { return }
        var removedForAge = 0
        if retentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
            let expired = entries.filter { $0.deletedAt < cutoff }
            if !expired.isEmpty {
                entries.removeAll { $0.deletedAt < cutoff }
                removedForAge = expired.count
            }
        }

        var removedForSize = 0
        var total = entries.reduce(0) { $0 + $1.sizeEstimate }
        if total > limitBytes {
            // Oldest first: a document just deleted is the one most likely to
            // still be wanted back.
            for entry in entries.sorted(by: { $0.deletedAt < $1.deletedAt }) {
                if total <= limitBytes { break }
                total -= entry.sizeEstimate
                removedForSize += 1
            }
            if removedForSize > 0 {
                let toDrop = Set(entries.sorted(by: { $0.deletedAt < $1.deletedAt }).prefix(removedForSize).map(\.id))
                entries.removeAll { toDrop.contains($0.id) }
            }
        }

        guard removedForAge > 0 || removedForSize > 0 else { return }
        rewriteFile()
        if removedForAge > 0 {
            log(.info, "Корзина", "Просрочено (старше \(retentionDays.plainDigits) дн.) и удалено из корзины: \(removedForAge.plainDigits)")
        }
        if removedForSize > 0 {
            log(.warning, "Корзина", "Превышен предел объёма корзины — вытеснено самых старых записей: \(removedForSize.plainDigits)")
        }
    }

    // MARK: - File

    /// Дописывает копии в файл — синхронно и с отчётом.
    ///
    /// `writeQueue.sync`, а не `async`: удаление ждёт результата, а очередь
    /// сохраняется, чтобы дозапись не столкнулась с полной перезаписью файла
    /// из `forget` и вытеснения. Взаимоблокировки нет — на самой очереди
    /// `record` не вызывается ниоткуда.
    private func appendToFile(_ batch: [TrashEntry]) throws {
        try writeQueue.sync { [fileURL] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = Data()
            for entry in batch {
                // Не `try?`: незакодированная запись — это документ, копии
                // которого не будет, и молча пропустить его нельзя.
                var line = try encoder.encode(entry)
                line.append(0x0A)
                data.append(line)
            }
            guard !data.isEmpty else { return }
            _ = try AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())

            if !FileManager.default.fileExists(atPath: fileURL.path) {
                // `Data.write`, а не `FileManager.createFile`: второй возвращает
                // `Bool` и причину отказа не сообщает вовсе.
                try data.write(to: fileURL, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            // Без этого «записано» значит «лежит в кэше страниц»: аварийное
            // завершение сразу после удаления забрало бы копию с собой,
            // то есть ровно в том случае, ради которого корзина и заведена.
            try handle.synchronize()
        }
    }

    /// Removals (restore, expiry, manual purge) rewrite the whole file: unlike
    /// the audit log this store's entries can legitimately disappear one at a
    /// time, and there is no append-only way to do that.
    ///
    /// Из самого файла, а не из памяти: в памяти записи без векторов,
    /// и перезапись из них стёрла бы векторы на диске. Строки оставленных
    /// записей переносятся как есть — побайтно, без разбора.
    private func rewriteFile() {
        let kept = Set(entries.map { Data($0.id.uuidString.utf8) })
        writeQueue.async { [fileURL] in
            guard !kept.isEmpty else {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            let temporary = fileURL.appendingPathExtension("rewrite")
            FileManager.default.createFile(atPath: temporary.path, contents: nil)
            guard let output = try? FileHandle(forWritingTo: temporary) else { return }
            var failed = false
            JSONLines.forEachLine(at: fileURL) { line in
                guard !failed, let id = Self.entryID(in: line), kept.contains(id) else { return }
                do {
                    try output.write(contentsOf: line)
                    try output.write(contentsOf: Data([0x0A]))
                } catch {
                    failed = true
                }
            }
            try? output.synchronize()
            try? output.close()
            guard !failed else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }
            _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        }
    }

    private nonisolated static func load(from url: URL) -> [TrashEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A truncated last line is normal after a crash and must not cost the
        // whole file (same reasoning as `AuditLog.load`).
        //
        // Правило было объявлено здесь и раньше, но не выполнялось до конца:
        // файл сперва раскодировался целиком, и обрыв **внутри** знака делал
        // негодным весь. Для корзины это стоило дороже всего: следующая
        // перезапись затирала записи, которых разбор не прочитал.
        //
        // Вектор при загрузке не разбирается вовсе: тысяча чисел на
        // запись — почти весь файл и почти всё время разбора. Его длина
        // считается по запятым в строке — она нужна оценке объёма.
        var loaded: [TrashEntry] = []
        JSONLines.forEachLine(at: url) { line in
            let (stripped, length) = Self.withoutEmbedding(line)
            guard let header = try? decoder.decode(LightEntry.self, from: stripped) else { return }
            var entry = TrashEntry(
                id: header.id, deletedAt: header.deletedAt, documentID: header.documentID,
                document: header.document, metadata: nil, embedding: nil,
                collectionName: header.collectionName, collectionMetric: header.collectionMetric,
                collectionModel: header.collectionModel, collectionServer: header.collectionServer,
                collectionDimension: header.collectionDimension,
                reason: header.reason
            )
            entry.embeddingLength = length
            entry.trimDocument()
            loaded.append(entry)
        }
        return loaded.sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Запись без вектора и метаданных — то, что разбирается при загрузке.
    ///
    /// Метаданные не разбираются тоже: это половина оставшегося времени,
    /// а для экрана корзины и оценки объёма они не нужны — в оценке
    /// у прочитанных записей их нет (несколько процентов объёма).
    private struct LightEntry: Decodable {
        let id: UUID
        let deletedAt: Date
        let documentID: String
        let document: String?
        let collectionName: String
        let collectionMetric: DistanceMetric?
        let collectionModel: String?
        let collectionServer: String?
        let collectionDimension: Int?
        let reason: TrashEntry.Reason
    }

    private nonisolated static let embeddingMarker = Data(#""embedding":["#.utf8)

    /// Строка с пустым вектором — и сколько чисел в нём было.
    ///
    /// Разбор JSON идёт по всей строке, даже если поле не нужно: вектор
    /// на тысячу чисел — почти вся строка, и 100 тысяч записей грузились
    /// семнадцать секунд. Массив вырезается до разбора: внутри массива
    /// чисел нет ни строк, ни вложенных скобок, поэтому его конец — первая
    /// `]`, а чисел — запятых плюс одно.
    nonisolated static func withoutEmbedding(_ line: Data) -> (line: Data, length: Int) {
        line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (line: Data, length: Int) in
            guard let base = raw.baseAddress else { return (line, 0) }
            let found = embeddingMarker.withUnsafeBytes { marker in
                memmem(base, raw.count, marker.baseAddress, marker.count)
            }
            guard let found else { return (line, 0) }
            let open = base.distance(to: UnsafeRawPointer(found)) + embeddingMarker.count
            guard let closing = memchr(base + open, Int32(UInt8(ascii: "]")), raw.count - open) else { return (line, 0) }
            let close = base.distance(to: UnsafeRawPointer(closing))
            var commas = 0
            var hasValue = false
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in open..<close {
                let byte = bytes[index]
                if byte == UInt8(ascii: ",") { commas += 1 } else if byte != UInt8(ascii: " ") { hasValue = true }
            }
            var stripped = Data(bytes: base, count: open)
            stripped.append(Data(bytes: base + close, count: raw.count - close))
            return (stripped, hasValue ? commas + 1 : 0)
        }
    }
}
