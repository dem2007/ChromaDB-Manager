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

    public init(documentID: String, rowNumber: Int, rowKey: String?, textHash: String, metadataHash: String) {
        self.documentID = documentID
        self.rowNumber = rowNumber
        self.rowKey = rowKey
        self.textHash = textHash
        self.metadataHash = metadataHash
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
    /// Set when the mapping itself changed: every row in the sheet is now
    /// written by a different recipe, and that is a re-index, not a sync.
    public var mappingChanged: Bool = false

    public var writes: Int { added.count + reembedded.count + metadataOnly.count }
    public var embeddings: Int { added.count + reembedded.count }

    public var line: String {
        String(localized: "новых \(added.count), переэмбедить \(reembedded.count), обновить метаданные \(metadataOnly.count), без изменений \(unchanged), исчезло \(disappeared.count)")
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
        sourceFile: String
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

        for row in rows where row.number >= firstDataRow {
            guard !row.isEmpty else { continue }
            guard let document = RowMapper.document(
                for: row, mapping: mapping, layout: layout,
                sourceID: sourceID, sourceFile: sourceFile
            ) else {
                plan.empty.append(row.number)
                continue
            }

            let fresh = record(for: document, rowNumber: row.number)
            seen.insert(fresh.identity)

            guard let previous = manifest.rows[fresh.identity] else {
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

        plan.disappeared = manifest.rows
            .filter { !seen.contains($0.key) }
            .values
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
