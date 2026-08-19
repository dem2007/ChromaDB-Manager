import Foundation
import CryptoKit

/// What the last run wrote for one row.
public struct TableRowRecord: Codable, Hashable, Sendable {
    public var documentID: String
    /// Where the row was in the file. Kept even when the key identifies the row,
    /// because it is what a person looks for when told something needs deciding.
    public var rowNumber: Int
    public var rowKey: String?
    /// Hash of the text that was embedded. A change here costs a vector.
    public var textHash: String
    /// Hash of the metadata that was written. A change here costs nothing but a
    /// write — the vector is unaffected.
    public var metadataHash: String
    /// Строки нет в файле, а документ человек решил оставить в базе.
    ///
    /// Запись **не забывается**: без неё документ остался бы в коллекции без
    /// единого способа его адресовать. Она просто больше не предлагается
    /// к решению — ровно как `isOrphaned` у файла.
    public var isOrphaned: Bool

    public init(
        documentID: String, rowNumber: Int, rowKey: String?,
        textHash: String, metadataHash: String, isOrphaned: Bool = false
    ) {
        self.documentID = documentID
        self.rowNumber = rowNumber
        self.rowKey = rowKey
        self.textHash = textHash
        self.metadataHash = metadataHash
        self.isOrphaned = isOrphaned
    }

    /// Манифест, записанный до появления `isOrphaned`, читается как есть:
    /// отсутствующее поле значит «не осиротевшая», а не «файл сломан».
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documentID = try container.decode(String.self, forKey: .documentID)
        rowNumber = try container.decode(Int.self, forKey: .rowNumber)
        rowKey = try container.decodeIfPresent(String.self, forKey: .rowKey)
        textHash = try container.decode(String.self, forKey: .textHash)
        metadataHash = try container.decode(String.self, forKey: .metadataHash)
        isOrphaned = try container.decodeIfPresent(Bool.self, forKey: .isOrphaned) ?? false
    }

    /// How this row is recognised in the next run.
    ///
    /// By key when there is one, because row numbers shift the moment somebody
    /// inserts a line; by row number when there is not, because that is then the
    /// only thing connecting «the row that was here» to «the row that is here
    /// now» — which is what makes an edit distinguishable from a deletion
    ///.
    public var identity: String { TableRowRecord.identity(rowKey: rowKey, rowNumber: rowNumber) }

    public static func identity(rowKey: String?, rowNumber: Int) -> String {
        if let rowKey, !rowKey.isEmpty { return "key\u{0}\(rowKey)" }
        return "row\u{0}\(rowNumber)"
    }
}

/// The rows of one sheet as the last run left them.
public struct SheetManifest: Codable, Hashable, Sendable {
    public var sheetName: String
    /// The mapping these rows were written under. A different one means the
    /// documents no longer match their recipe.
    public var mappingSignature: String
    public var rows: [String: TableRowRecord]

    public init(sheetName: String, mappingSignature: String = "", rows: [String: TableRowRecord] = [:]) {
        self.sheetName = sheetName
        self.mappingSignature = mappingSignature
        self.rows = rows
    }

    public var rowCount: Int { rows.count }
    public var documentIDs: [String] { rows.values.map(\.documentID) }
}

extension TableMapping {
    /// Everything about the mapping that changes what a row becomes.
    ///
    /// The sheet's own name is not part of it: renaming a sheet does not change
    /// what its rows mean. The template is, because it is what gets embedded.
    public var signature: String {
        let roles = columns.map { "\($0)=\(role(of: $0).rawValue)" }.joined(separator: ",")
        var parts = [
            "mode:\(mode.rawValue)",
            "header:\(headerRow.map(String.init) ?? "-")",
            "columns:\(columns.joined(separator: "|"))",
            "roles:\(roles)",
            "key:\(keyColumn ?? "-")",
            "template:\(textTemplate)",
        ]
        // Своё название колонки — тоже рецепт: от него зависят и ключ
        // метаданных, и подпись в тексте документа. Переименование после
        // индексации оставило бы половину коллекции с ключом `stolbec_3`,
        // а половину — с `gruppa_po`, и фильтр находил бы то одну, то другую.
        //
        // Компонент добавляется, только когда переименования есть: иначе
        // подпись изменилась бы разом у всех уже сохранённых листов и каждый
        // попросил бы переиндексацию ни за что.
        let renamed = columns.filter { title(of: $0) != $0 }
        if !renamed.isEmpty {
            parts.append("titles:" + renamed.map { "\($0)=\(title(of: $0))" }.joined(separator: ","))
        }
        return parts.joined(separator: ";")
    }
}

/// Строки листа, которые дают **один и тот же документ**.
///
/// Два источника такого совпадения, и оба означают потерю: одинаковое значение
/// ключевой колонки (id считается от ключа) и полностью совпавшие строки там,
/// где ключа нет (id считается от содержимого).
public struct DuplicateRowGroup: Sendable, Hashable, Codable {
    /// Значение ключевой колонки или `nil`, когда ключа нет и совпало всё.
    public var rowKey: String?
    /// Номера строк по возрастанию: первая записывается, остальные — нет.
    public var rows: [Int]

    public init(rowKey: String?, rows: [Int]) {
        self.rowKey = rowKey
        self.rows = rows
    }

    public var kept: Int { rows.first ?? 0 }
    public var skipped: [Int] { Array(rows.dropFirst()) }

    /// Как это называется человеку: значение и строки, где оно встретилось.
    public var line: String {
        let numbers = rows.map(\.plainDigits).joined(separator: ", ")
        if let rowKey, !rowKey.isEmpty {
            return String(localized: "«\(rowKey)» — строки \(numbers)")
        }
        return String(localized: "строки \(numbers) совпадают целиком")
    }
}

/// What a run would do to one sheet.
public struct SheetSyncPlan: Sendable {
    /// Rows the collection has never seen.
    public var added: [TableRowDocument] = []
    /// Rows whose text changed — the only ones that cost a vector.
    public var reembedded: [(document: TableRowDocument, previousID: String)] = []
    /// Rows whose text is the same but whose metadata moved. Rewritten, not
    /// re-embedded: recomputing a vector for a changed price is paying for
    /// nothing.
    public var metadataOnly: [(document: TableRowDocument, previousID: String)] = []
    public var unchanged: Int = 0
    /// Rows that are no longer in the file. **Not deleted** — rule 1 of
    /// Приложение 5 applies to a row exactly as it does to a file.
    public var disappeared: [TableRowRecord] = []
    /// Rows skipped because they had no text to embed.
    public var empty: [Int] = []
    /// Записи, которые опознаны по содержимому под новым номером:
    /// их прежние ключи из манифеста убираются, иначе следующий прогон
    /// объявит их исчезнувшими.
    public var retired: [String] = []
    /// Строки, дающие тот же документ, что и строка выше. Записывается
    /// первая из группы, остальные пропускаются — не потому, что так лучше,
    /// а потому, что база всё равно оставила бы одну, только молча.
    public var duplicates: [DuplicateRowGroup] = []
    /// Set when the mapping itself changed: every row in the sheet is now
    /// written by a different recipe, and that is a re-index, not a sync.
    public var mappingChanged: Bool = false

    public var writes: Int { added.count + reembedded.count + metadataOnly.count }
    public var embeddings: Int { added.count + reembedded.count }

    public var line: String {
        var text = String(localized: "новых \(added.count), переэмбедить \(reembedded.count), обновить метаданные \(metadataOnly.count), без изменений \(unchanged), исчезло \(disappeared.count)")
        if !duplicates.isEmpty {
            let rows = duplicates.reduce(0) { $0 + $1.skipped.count }
            text += "; " + String(localized: "повторов пропущено \(rows)")
        }
        return text
    }
}

/// Compares a sheet against what the last run wrote.
///
/// Per row, not per file: editing one cell of a twenty-thousand-row sheet must
/// cost one vector, not twenty thousand.
public enum TableSyncPlanner {
    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Metadata as a stable string. Sorted, because dictionary order is not a
    /// change.
    ///
    /// `row_number` **is** part of it, though it was left out at first on the
    /// reasoning that a shifted row «has nothing changed but the number, which
    /// gets rewritten anyway». It does not get rewritten: when nothing else
    /// moved, nothing is written at all, and the stored number quietly starts
    /// pointing at the wrong line of the file. Found by the stage's own
    /// Definition of Done run. Including it costs metadata writes for the rows
    /// below an insertion — and **no vectors**, which is the distinction that
    /// matters.
    public static func metadataSeed(_ metadata: ChromaMetadata) -> String {
        metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(describe($0.value))" }
            .joined(separator: "\u{1}")
    }

    private static func describe(_ value: MetadataValue) -> String {
        switch value {
        case .string(let value): return "s:\(value)"
        case .int(let value): return "i:\(value)"
        case .double(let value): return "d:\(value)"
        case .bool(let value): return "b:\(value)"
        case .null: return "n"
        }
    }

    public static func record(for document: TableRowDocument, rowNumber: Int) -> TableRowRecord {
        TableRowRecord(
            documentID: document.id,
            rowNumber: rowNumber,
            rowKey: document.rowKey,
            textHash: hash(document.text),
            metadataHash: hash(metadataSeed(document.metadata))
        )
    }

    /// - Parameter layout: where this file's columns are and which row holds its
    ///   headers. Not taken from the mapping: the mapping says what the columns
    /// mean, the file says where they are.
    public static func plan(
        rows: [SheetRow],
        mapping: TableMapping,
        layout: SheetLayout,
        manifest: SheetManifest,
        sourceID: UUID,
        sourceFile: String,
        coverage: SheetCoverage? = nil
    ) -> SheetSyncPlan {
        var plan = SheetSyncPlan()
        let signature = mapping.signature
        // A changed mapping rewrites every row by a different recipe. says
        // that is a re-index offered as its own operation with a backup — so the
        // plan says so and does not quietly turn every row into «changed».
        plan.mappingChanged = !manifest.mappingSignature.isEmpty && manifest.mappingSignature != signature

        // The file's own header row, not the profile's: a copy of the same
        // report with a title line above it puts the headers on row 3, and
        // trusting the profile would embed the header row as a record.
        let headerRow = layout.headerRow
        // Записи начинаются под заголовком. Пока заголовком была первая
        // непустая строка, выше неё ничего и не было; со строкой, указанной
        // руками, шапка отчёта — название, дата, подпись — иначе стала бы
        // документами наравне со строками таблицы.
        let firstDataRow = headerRow.map { $0 + 1 } ?? Int.min
        var seen: Set<String> = []
        /// Номер строки, которая первой заняла этот идентификатор документа.
        var claimedBy: [String: Int] = [:]
        var duplicates: [String: DuplicateRowGroup] = [:]

        // Строки файла собираются до разбора: без ключевой колонки строка
        // узнаётся по содержимому, а для этого надо видеть их все.
        var freshRows: [(document: TableRowDocument, record: TableRowRecord)] = []
        for row in rows where row.number >= firstDataRow {
            guard !row.isEmpty else { continue }
            guard let document = RowMapper.document(
                for: row, mapping: mapping, layout: layout,
                sourceID: sourceID, sourceFile: sourceFile, coverage: coverage
            ) else {
                plan.empty.append(row.number)
                continue
            }
            freshRows.append((document, record(for: document, rowNumber: row.number)))
        }

        // Кто узнан на своём же месте — таких искать по содержимому незачем.
        var usedPrevious: Set<String> = []
        for item in freshRows {
            if let previous = manifest.rows[item.record.identity],
               previous.textHash == item.record.textHash {
                usedPrevious.insert(item.record.identity)
            }
        }

        // Опознание по содержимому — **только без ключевой колонки**.
        //
        // Там строка узнаётся по номеру, и вставка одной строки посреди файла
        // сдвигала все остальные: каждая сравнивалась с записью соседа, текст
        // не совпадал, и хвост уходил на переэмбеддинг. Хуже того, документ
        // соседа объявлялся «прежним» и удалялся после записи — то есть
        // вставка строки **стирала из базы** живые документы всего хвоста,
        // и следующий прогон их не возвращал: манифест считал их записанными.
        //
        // С ключевой колонкой строка узнаётся по ключу и без этого — а лишнее
        // сопоставление там могло бы спутать две строки с одинаковым текстом.
        let recognisesByContent = mapping.keyColumn == nil
        var byContent: [String: [String]] = [:]
        if recognisesByContent {
            for (identity, record) in manifest.rows.sorted(by: { $0.value.rowNumber < $1.value.rowNumber })
            where !usedPrevious.contains(identity) {
                byContent[record.textHash, default: []].append(identity)
            }
        }
        // Опознание по содержимому идёт **до** разбора, а не по ходу его:
        // иначе строку-новичка сравнили бы с записью соседа по номеру раньше,
        // чем сосед успел бы назваться сам, и запись досталась бы не тому.
        var recognised: [String: String] = [:]
        if recognisesByContent {
            for (_, fresh) in freshRows where !usedPrevious.contains(fresh.identity)
                || manifest.rows[fresh.identity]?.textHash != fresh.textHash {
                guard recognised[fresh.identity] == nil else { continue }
                guard let identity = byContent[fresh.textHash]?.first else { continue }
                byContent[fresh.textHash]?.removeFirst()
                recognised[fresh.identity] = identity
                usedPrevious.insert(identity)
            }
        }

        // Записи, отданные строке с другим номером: своей строке они больше
        // не «прежние», иначе одна запись послужила бы дважды.
        var claimedElsewhere = Set(recognised.filter { $0.key != $0.value }.map(\.value))

        for (document, fresh) in freshRows {
            // Отметка о строке ставится и для повтора: без неё запись прошлого
            // прогона попала бы в «исчезло», а удаление по её id снесло бы
            // документ строки, которая никуда не девалась, — id-то один.
            seen.insert(fresh.identity)

            // Один документ на две строки. Дальше по конвейеру они
            // неразличимы: вторая запись просто затирает первую, а отчёт
            // считает обе записанными. Пропускается вторая — с именем.
            if let first = claimedBy[document.id] {
                var group = duplicates[document.id]
                    ?? DuplicateRowGroup(rowKey: document.rowKey, rows: [first])
                group.rows.append(fresh.rowNumber)
                duplicates[document.id] = group
                continue
            }
            claimedBy[document.id] = fresh.rowNumber

            /// Запись прошлого прогона, к которой относится эта строка.
            let previous: TableRowRecord?
            if let identity = recognised[fresh.identity] {
                // Строка сдвинулась: тот же текст под другим номером. Это
                // не правка — платить за вектор не за что.
                previous = manifest.rows[identity]
                seen.insert(identity)
                if identity != fresh.identity { plan.retired.append(identity) }
            } else if let own = manifest.rows[fresh.identity], !claimedElsewhere.contains(fresh.identity) {
                previous = own
                claimedElsewhere.insert(fresh.identity)
            } else {
                previous = nil
            }

            guard let previous else {
                plan.added.append(document)
                continue
            }
            if previous.textHash != fresh.textHash {
                plan.reembedded.append((document, previous.documentID))
            } else if previous.metadataHash != fresh.metadataHash {
                plan.metadataOnly.append((document, previous.documentID))
            } else {
                plan.unchanged += 1
            }
        }

        plan.duplicates = duplicates.values.sorted { $0.kept < $1.kept }
        plan.disappeared = manifest.rows
            // Осиротевшие — те, о которых человек уже сказал «оставить
            // в базе». Спрашивать о них снова каждый прогон значило бы
            // не помнить ответа.
            .filter { !seen.contains($0.key) && !$0.value.isOrphaned }
            .values
            // Документ, который занят живой строкой, исчезнувшим не считается:
            // при повторе ключа у прошлой записи и у сегодняшней строки один
            // и тот же id, и предложить его удалить значило бы предложить
            // удалить строку, которая на месте.
            .filter { claimedBy[$0.documentID] == nil }
            .sorted { $0.rowNumber < $1.rowNumber }
        return plan
    }

    /// The manifest after a run that wrote everything the plan proposed.
    ///
    /// Rows that disappeared are **kept** until the user decides: forgetting
    /// them here would delete the record of documents still in the collection,
    /// and nothing would ever be able to remove them by id.
    public static func applying(_ plan: SheetSyncPlan, to manifest: SheetManifest, mapping: TableMapping) -> SheetManifest {
        var result = manifest
        result.mappingSignature = mapping.signature
        // Прежние ключи сдвинувшихся строк — до записи новых: строка
        // одна, и оставить её под двумя ключами значило бы объявить один
        // из них исчезнувшим на следующем прогоне.
        for identity in plan.retired { result.rows[identity] = nil }
        for document in plan.added {
            let record = record(for: document, rowNumber: rowNumber(of: document))
            result.rows[record.identity] = record
        }
        for (document, _) in plan.reembedded + plan.metadataOnly {
            let record = record(for: document, rowNumber: rowNumber(of: document))
            result.rows[record.identity] = record
        }
        return result
    }

    /// The row number a document carries in its own metadata — the one place it
    /// is recorded after mapping.
    static func rowNumber(of document: TableRowDocument) -> Int {
        if case .int(let number)? = document.metadata["row_number"] { return number }
        return 0
    }

    /// Documents to delete once the user has decided a row really is gone.
    ///
    /// By explicit id, never by a `where` condition on `row_number`: a filter
    /// would take whatever else happened to share the number.
    public static func removalIDs(for records: [TableRowRecord]) -> [String] {
        records.map(\.documentID)
    }
}
