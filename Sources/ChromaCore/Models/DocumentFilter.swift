import Foundation

/// Operators ChromaDB accepts inside a `where` clause. Verified against
/// chroma 1.4.4 (and).
public enum FilterOperator: String, CaseIterable, Identifiable, Codable, Sendable {
    case equals = "$eq"
    case notEquals = "$ne"
    case greater = "$gt"
    case greaterOrEqual = "$gte"
    case less = "$lt"
    case lessOrEqual = "$lte"
    case inList = "$in"
    case notInList = "$nin"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .equals: return "="
        case .notEquals: return "≠"
        case .greater: return ">"
        case .greaterOrEqual: return "≥"
        case .less: return "<"
        case .lessOrEqual: return "≤"
        case .inList: return String(localized: "в списке")
        case .notInList: return String(localized: "не в списке")
        }
    }

    /// `$in`/`$nin` take an array; the UI shows a comma-separated field.
    public var wantsList: Bool { self == .inList || self == .notInList }

    /// Comparisons work on numbers only — the server answers 400 for a string
    /// or a boolean, including ISO dates, which are strings.
    public var needsNumber: Bool {
        switch self {
        case .greater, .greaterOrEqual, .less, .lessOrEqual: return true
        default: return false
        }
    }
}

public enum FilterLogic: String, CaseIterable, Identifiable, Codable, Sendable {
    case and = "$and"
    case or = "$or"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .and: return String(localized: "все условия (И)")
        case .or: return String(localized: "любое условие (ИЛИ)")
        }
    }

    public var shortTitle: String {
        switch self {
        case .and: return String(localized: "И")
        case .or: return String(localized: "ИЛИ")
        }
    }
}

public struct MetadataCondition: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var field: String
    public var op: FilterOperator
    public var value: String
    /// Значение уходит строкой, как бы оно ни выглядело.
    ///
    /// Без этого «2025» всегда уходило числом: тип угадывался по тексту,
    /// и равенство по полю, где лежат строки (`file_id`, уровень пути
    /// `year`, значение фасета), не находило ничего. Приложение ставит
    /// признак само там, где тип известен; в конструкторе его включает
    /// человек.
    public var valueIsText: Bool

    public init(
        id: UUID = UUID(),
        field: String = "",
        op: FilterOperator = .equals,
        value: String = "",
        valueIsText: Bool = false
    ) {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
        self.valueIsText = valueIsText
    }

    /// Условие на точное значение метаданных — с его настоящим типом.
    public init(field: String, equals value: MetadataValue) {
        if case .string = value {
            self.init(field: field, op: .equals, value: value.displayString, valueIsText: true)
        } else {
            self.init(field: field, op: .equals, value: value.displayString)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, field, op, value, valueIsText
    }

    // Сохранённые до признака фильтры его не знают — для них тип угадывается,
    // как и раньше.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        field = try container.decode(String.self, forKey: .field)
        op = try container.decode(FilterOperator.self, forKey: .op)
        value = try container.decode(String.self, forKey: .value)
        valueIsText = try container.decodeIfPresent(Bool.self, forKey: .valueIsText) ?? false
    }

    /// Значение, которое уйдёт на сервер, — одно, без списка.
    public func typedValue(_ text: String) -> MetadataValue {
        valueIsText ? .string(text.trimmingCharacters(in: .whitespaces)) : MetadataValue.inferred(from: text)
    }

    /// Похоже ли значение на что-то кроме строки — тогда у конструктора
    /// есть смысл спросить, строка ли это.
    public var valueLooksTyped: Bool {
        let parts = op.wantsList ? DocumentFilter.listItems(value) : [value]
        return parts.contains { !MetadataValue.inferred(from: $0).isString }
    }

    public var isComplete: Bool {
        !field.trimmingCharacters(in: .whitespaces).isEmpty
            && !value.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What the server would refuse, said before the request goes out.
    public var problem: String? {
        guard isComplete else { return nil }
        let field = self.field.trimmingCharacters(in: .whitespaces)
        if op.wantsList {
            let parts = DocumentFilter.listItems(value)
            guard !parts.isEmpty else {
                return String(localized: "«\(field)»: список пуст.")
            }
            let kinds = Set(parts.map { typedValue($0).kindName })
            if kinds.count > 1 {
                return String(localized: "«\(field)»: в списке значения разных типов (\(kinds.sorted().joined(separator: ", "))) — сервер такой запрос отклоняет.")
            }
            return nil
        }
        if op.needsNumber, !typedValue(value).isNumber {
            return String(localized: "«\(field)»: сравнение \(op.title) работает только с числами. Строки и даты сравнивать нельзя — для них подходят = и ≠.")
        }
        return nil
    }
}

/// `where_document` operators. Both verified on 1.4.4, including nested inside
/// `$and`/`$or`.
public enum DocumentTextOperator: String, CaseIterable, Identifiable, Codable, Sendable {
    case contains = "$contains"
    case notContains = "$not_contains"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .contains: return String(localized: "содержит")
        case .notContains: return String(localized: "не содержит")
        }
    }
}

public struct DocumentTextCondition: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var op: DocumentTextOperator
    public var text: String

    public init(id: UUID = UUID(), op: DocumentTextOperator = .contains, text: String = "") {
        self.id = id
        self.op = op
        self.text = text
    }

    public var isComplete: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// A node of the condition tree: either a group with a logic and children, or a
/// single condition.
///
/// A struct rather than an indirect enum because SwiftUI binds to fields, and
/// an enum with associated values needs a wrapper at every level of the editor.
public struct FilterNode: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    /// Non-nil for a group; `nil` means this node is a condition.
    public var logic: FilterLogic?
    public var children: [FilterNode]
    public var condition: MetadataCondition?

    public init(id: UUID = UUID(), logic: FilterLogic? = nil, children: [FilterNode] = [], condition: MetadataCondition? = nil) {
        self.id = id
        self.logic = logic
        self.children = children
        self.condition = condition
    }

    public static func group(_ logic: FilterLogic = .and, _ children: [FilterNode] = []) -> FilterNode {
        FilterNode(logic: logic, children: children)
    }

    public static func leaf(_ condition: MetadataCondition) -> FilterNode {
        FilterNode(condition: condition)
    }

    public var isGroup: Bool { logic != nil }

    /// Conditions that would actually be sent, at any depth.
    public var completeConditions: [MetadataCondition] {
        if let condition { return condition.isComplete ? [condition] : [] }
        return children.flatMap(\.completeConditions)
    }

    public var problems: [String] {
        if let condition { return condition.problem.map { [$0] } ?? [] }
        return children.flatMap(\.problems)
    }

    /// The `where` clause for this node, or `nil` when it says nothing.
    ///
    /// A group of one collapses into its child: `{"$and": [x]}` is accepted by
    /// the server but harder to read, and the JSON is shown to the user.
    public func clause() -> [String: Any]? {
        if let condition {
            guard condition.isComplete else { return nil }
            let field = condition.field.trimmingCharacters(in: .whitespaces)
            return [field: [condition.op.rawValue: DocumentFilter.encode(condition)]]
        }
        let parts = children.compactMap { $0.clause() }
        switch parts.count {
        case 0: return nil
        case 1: return parts[0]
        default: return [(logic ?? .and).rawValue: parts]
        }
    }

    /// Reads a `where` clause back into a tree.
    ///
    /// `nil` means «this JSON is valid but the editor cannot show it» — the raw
    /// mode stays, and the filter is still sent as written.
    public static func parse(_ object: [String: Any]) -> FilterNode? {
        guard object.count == 1, let (key, value) = object.first else { return nil }

        if let logic = FilterLogic(rawValue: key) {
            guard let array = value as? [[String: Any]] else { return nil }
            let children = array.compactMap { parse($0) }
            guard children.count == array.count else { return nil }
            return .group(logic, children)
        }

        // {"field": {"$op": value}}
        if let expression = value as? [String: Any] {
            guard expression.count == 1,
                  let (rawOperator, rawValue) = expression.first,
                  let op = FilterOperator(rawValue: rawOperator) else { return nil }
            return leaf(field: key, op: op, rawValue: rawValue)
        }

        // {"field": value} — the shorthand for $eq, accepted by the server.
        return leaf(field: key, op: .equals, rawValue: value)
    }

    /// Условие из значения JSON — так, чтобы при сборке обратно ушло то же.
    ///
    /// Строка, похожая на число, помечается строкой; а если строки в списке
    /// перемешаны с числами, одним признаком этого не выразить — такое
    /// остаётся в JSON.
    private static func leaf(field: String, op: FilterOperator, rawValue: Any) -> FilterNode? {
        let values: [MetadataValue]
        if op.wantsList {
            guard let array = rawValue as? [Any] else { return nil }
            let items = array.compactMap(scalar)
            guard items.count == array.count else { return nil }
            values = items
        } else {
            guard let item = scalar(rawValue) else { return nil }
            values = [item]
        }
        let texts = values.map(\.displayString)
        let stringsLookTyped = values.contains {
            if case .string(let text) = $0 { return !MetadataValue.inferred(from: text).isString }
            return false
        }
        let hasNonStrings = values.contains { !$0.isString }
        if stringsLookTyped && hasNonStrings { return nil }
        // Запятая внутри значения списка разрезала бы его на два.
        if op.wantsList, texts.contains(where: { $0.contains(",") }) { return nil }
        return .leaf(MetadataCondition(
            field: field,
            op: op,
            value: texts.joined(separator: ", "),
            valueIsText: stringsLookTyped
        ))
    }

    /// Одно значение JSON.
    ///
    /// Числа из `JSONSerialization` приходят `NSNumber`, а `NSNumber` 0 и 1
    /// охотно отдаются как `Bool` — поэтому тип спрашивается у самого числа,
    /// иначе `chunk_level = 0` возвращался из JSON условием `= false`.
    private static func scalar(_ value: Any) -> MetadataValue? {
        if let text = value as? String { return .string(text) }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
        switch String(cString: number.objCType) {
        case "f", "d":
            let double = number.doubleValue
            return double.isFinite ? .double(double) : nil
        default:
            return .int(number.intValue)
        }
    }
}

public enum FilterError: LocalizedError {
    case invalidRawJSON(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRawJSON(let details):
            return String(localized: "Не удалось разобрать JSON фильтра: \(details)")
        }
    }
}

/// Фильтр приходит и от агента, значит и отказ по нему адресован ему.
extension FilterError: MCPReadableError {
    public var mcpReason: String {
        switch self {
        case .invalidRawJSON(let details):
            return "the filter is not valid JSON: «\(details)»"
        }
    }
}

/// A condition builder for `where` / `where_document`, with a raw-JSON escape
/// hatch for people who already know the query language.
public struct DocumentFilter: Hashable, Codable, Sendable {
    /// The tree of metadata conditions. Always a group at the top, so the
    /// editor has something to add to.
    public var root: FilterNode
    /// `where_document` conditions, combined by `textLogic`.
    public var textConditions: [DocumentTextCondition]
    public var textLogic: FilterLogic
    /// When set, replaces the built `where` clause entirely.
    public var rawWhereJSON: String
    /// Same for `where_document`.
    public var rawWhereDocumentJSON: String

    public init(
        root: FilterNode = .group(.and, []),
        textConditions: [DocumentTextCondition] = [],
        textLogic: FilterLogic = .and,
        rawWhereJSON: String = "",
        rawWhereDocumentJSON: String = ""
    ) {
        self.root = root
        self.textConditions = textConditions
        self.textLogic = textLogic
        self.rawWhereJSON = rawWhereJSON
        self.rawWhereDocumentJSON = rawWhereDocumentJSON
    }

    /// Kept for the many call sites that build a flat list of conditions.
    public init(conditions: [MetadataCondition], documentContains: String = "", rawWhereJSON: String = "") {
        self.init(
            root: .group(.and, conditions.map(FilterNode.leaf)),
            textConditions: documentContains.trimmingCharacters(in: .whitespaces).isEmpty
                ? []
                : [DocumentTextCondition(op: .contains, text: documentContains)],
            rawWhereJSON: rawWhereJSON
        )
    }

    public init(documentContains: String) {
        self.init(conditions: [], documentContains: documentContains)
    }

    /// Flat view of the tree, for callers that never build groups.
    public var conditions: [MetadataCondition] {
        get { root.completeConditions }
        set { root = .group(root.logic ?? .and, newValue.map(FilterNode.leaf)) }
    }

    public var isEmpty: Bool {
        root.completeConditions.isEmpty
            && textConditions.allSatisfy { !$0.isComplete }
            && rawWhereJSON.trimmingCharacters(in: .whitespaces).isEmpty
            && rawWhereDocumentJSON.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var usesRawJSON: Bool {
        !rawWhereJSON.trimmingCharacters(in: .whitespaces).isEmpty
            || !rawWhereDocumentJSON.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Everything the server would reject, collected before sending.
    public var problems: [String] { root.problems }

    /// Тот же фильтр плюс условие, которое дописывает приложение.
    ///
    /// Условие кладётся **рядом с корнем**, а не к его детям. Пока брались
    /// дети, корень терял собственную логику: человек собрал «файл A ИЛИ
    /// файл Б», приложение добавляло свой уровень или пометку — и выходило
    /// «A И Б И условие». У документа одно значение `source_file`, поэтому
    /// такой запрос невыполним, и поиск молча возвращал пусто. Выбор логики
    /// стоит на каждом уровне дерева, включая корень, так что случай не
    /// экзотический.
    ///
    /// Пустой корень при этом ничего не портит: пустая группа не даёт
    /// условия и схлопывается при сборке запроса.
    public func adding(_ condition: MetadataCondition) -> DocumentFilter {
        var copy = self
        copy.root = .group(.and, [root, .leaf(condition)])
        return copy
    }

    /// `where` clause, or `nil` when nothing is filtered.
    ///
    /// Never `{}`: an empty object is answered with `400 Invalid where clause`
    ///, so «no filter» has to mean «no parameter».
    public func whereClause() throws -> [String: Any]? {
        let text = rawWhereJSON.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FilterError.invalidRawJSON(String(text.prefix(120)))
            }
            return object.isEmpty ? nil : object
        }
        return root.clause()
    }

    /// Чем фильтр отличается от другого — для «тот же ли это запрос».
    ///
    /// Оба условия, `where` **и** `where_document`: одни и те же слова
    /// с другим текстовым условием — другой запрос, а история и набор
    /// запросов сливали их в один. И JSON с упорядоченными ключами, а не
    /// `String(describing:)` словаря: порядок ключей в описании словаря
    /// не обещан, и равные фильтры могли дать разные строки.
    public var identityKey: String {
        func text(_ clause: [String: Any]?) -> String {
            guard let clause else { return "" }
            guard JSONSerialization.isValidJSONObject(clause),
                  let data = try? JSONSerialization.data(withJSONObject: clause, options: [.sortedKeys])
            else { return String(describing: clause) }
            return String(decoding: data, as: UTF8.self)
        }
        // Испорченный сырой `where` — тоже различие: сравнивается его текст.
        // Не через `try?`: он склеил бы «условия нет» с «условие не разобралось».
        let metadata: String
        do {
            metadata = text(try whereClause())
        } catch {
            metadata = "invalid:" + rawWhereJSON
        }
        let document: String
        do {
            document = text(try whereDocumentClause())
        } catch {
            document = "invalid:" + rawWhereDocumentJSON
        }
        // Пустой фильтр — то же, что никакого.
        return metadata.isEmpty && document.isEmpty ? "" : metadata + "\u{0}" + document
    }

    /// `where_document`, или `nil`, когда по тексту не отбирается ничего.
    ///
    /// Бросает на испорченном JSON — как и `whereClause()`. Молча вернуть
    /// `nil` значило снять условие: фильтр выглядел применённым, а список
    /// показывал всю коллекцию.
    public func whereDocumentClause() throws -> [String: Any]? {
        let raw = rawWhereDocumentJSON.trimmingCharacters(in: .whitespaces)
        if !raw.isEmpty {
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FilterError.invalidRawJSON(String(raw.prefix(120)))
            }
            return object.isEmpty ? nil : object
        }

        let parts = textConditions
            .filter(\.isComplete)
            .map { [$0.op.rawValue: $0.text.trimmingCharacters(in: .whitespaces)] as [String: Any] }
        switch parts.count {
        case 0: return nil
        case 1: return parts[0]
        default: return [textLogic.rawValue: parts]
        }
    }

    /// Loads a raw `where` back into the tree, so switching modes does not lose
    /// the filter. `false` when the JSON is valid but not representable —
    /// the editor stays locked and the raw text is what gets sent.
    public mutating func adoptRawWhereIntoTree() -> Bool {
        let text = rawWhereJSON.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if object.isEmpty {
            root = .group(.and, [])
            rawWhereJSON = ""
            return true
        }
        guard let parsed = FilterNode.parse(object) else { return false }
        root = parsed.isGroup ? parsed : .group(.and, [parsed])
        rawWhereJSON = ""
        return true
    }

    public mutating func adoptRawWhereDocumentIntoTree() -> Bool {
        let text = rawWhereDocumentJSON.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parsed = Self.parseTextClause(object) else { return false }
        textConditions = parsed.conditions
        textLogic = parsed.logic
        rawWhereDocumentJSON = ""
        return true
    }

    /// Only the shapes the editor can show: one condition, or one level of
    /// `$and`/`$or` over conditions. Anything deeper stays in raw mode.
    static func parseTextClause(_ object: [String: Any]) -> (conditions: [DocumentTextCondition], logic: FilterLogic)? {
        guard object.count == 1, let (key, value) = object.first else { return nil }
        if let op = DocumentTextOperator(rawValue: key), let text = value as? String {
            return ([DocumentTextCondition(op: op, text: text)], .and)
        }
        guard let logic = FilterLogic(rawValue: key), let array = value as? [[String: Any]] else { return nil }
        var conditions: [DocumentTextCondition] = []
        for item in array {
            guard item.count == 1, let (rawOperator, rawText) = item.first,
                  let op = DocumentTextOperator(rawValue: rawOperator),
                  let text = rawText as? String else { return nil }
            conditions.append(DocumentTextCondition(op: op, text: text))
        }
        return (conditions, logic)
    }

    /// Puts the current tree into the raw fields, so the JSON editor opens on
    /// what the user already built instead of an empty box.
    public mutating func moveTreeIntoRawJSON() {
        if rawWhereJSON.trimmingCharacters(in: .whitespaces).isEmpty, let text = whereJSONString() {
            rawWhereJSON = text
            root = .group(.and, [])
        }
        if rawWhereDocumentJSON.trimmingCharacters(in: .whitespaces).isEmpty, let text = whereDocumentJSONString() {
            rawWhereDocumentJSON = text
            textConditions = []
        }
    }

    static func listItems(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Values keep their type: "5" filters as a number, "true" as a boolean —
    /// ChromaDB compares typed metadata, so a quoted 5 would match nothing.
    /// Unless the condition says the value is text (`valueIsText`).
    static func encode(_ condition: MetadataCondition) -> Any {
        if condition.op.wantsList {
            return listItems(condition.value)
                .map { condition.typedValue($0) }
                .map(unwrap)
        }
        return unwrap(condition.typedValue(condition.value))
    }

    private static func unwrap(_ value: MetadataValue) -> Any {
        switch value {
        case .string(let text): return text
        case .int(let number): return number
        case .double(let number): return number
        case .bool(let flag): return flag
        case .null: return NSNull()
        }
    }

    /// Canonical JSON, used by tests and shown in the UI as "what will be sent".
    public func whereJSONString() -> String? {
        guard let clause = ((try? whereClause()) ?? nil) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: clause, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func whereDocumentJSONString() -> String? {
        guard let clause = ((try? whereDocumentClause()) ?? nil),
              let data = try? JSONSerialization.data(withJSONObject: clause, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A filter the user gave a name to, kept per collection.
public struct SavedFilter: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var collectionName: String
    public var filter: DocumentFilter
    public var savedAt: Date

    public init(id: UUID = UUID(), name: String, collectionName: String, filter: DocumentFilter, savedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.collectionName = collectionName
        self.filter = filter
        self.savedAt = savedAt
    }
}
