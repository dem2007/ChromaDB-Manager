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

    public init(id: UUID = UUID(), field: String = "", op: FilterOperator = .equals, value: String = "") {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
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
            let kinds = Set(parts.map { MetadataValue.inferred(from: $0).kindName })
            if kinds.count > 1 {
                return String(localized: "«\(field)»: в списке значения разных типов (\(kinds.sorted().joined(separator: ", "))) — сервер такой запрос отклоняет.")
            }
            return nil
        }
        if op.needsNumber, !MetadataValue.inferred(from: value).isNumber {
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
                  let op = FilterOperator(rawValue: rawOperator),
                  let text = describe(rawValue, asList: op.wantsList) else { return nil }
            return .leaf(MetadataCondition(field: key, op: op, value: text))
        }

        // {"field": value} — the shorthand for $eq, accepted by the server.
        guard let text = describe(value, asList: false) else { return nil }
        return .leaf(MetadataCondition(field: key, op: .equals, value: text))
    }

    private static func describe(_ value: Any, asList: Bool) -> String? {
        if asList {
            guard let array = value as? [Any] else { return nil }
            let items = array.compactMap { describe($0, asList: false) }
            guard items.count == array.count else { return nil }
            return items.joined(separator: ", ")
        }
        switch value {
        case let text as String: return text
        case let flag as Bool: return flag ? "true" : "false"
        case let number as Int: return String(number)
        case let number as Double: return String(number)
        case let number as NSNumber: return number.stringValue
        default: return nil
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

    public func whereDocumentClause() -> [String: Any]? {
        let raw = rawWhereDocumentJSON.trimmingCharacters(in: .whitespaces)
        if !raw.isEmpty {
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  !object.isEmpty else { return nil }
            return object
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
    static func encode(_ condition: MetadataCondition) -> Any {
        if condition.op.wantsList {
            return listItems(condition.value)
                .map { MetadataValue.inferred(from: $0) }
                .map(unwrap)
        }
        return unwrap(MetadataValue.inferred(from: condition.value))
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
        guard let clause = whereDocumentClause(),
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
