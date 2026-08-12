import Foundation

/// How the files of one source are distributed between collections.
///
/// The mode decides two things at once: the target collection of every file and
/// whether the file's place in the folder tree survives as metadata.
public enum SourceMapping: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Everything lands in one collection named on the source card.
    case folderToCollection
    /// Every first-level subfolder gets its own collection; files lying directly
    /// in the root go to the source's own collection.
    case subfoldersToCollections
    /// One collection, and the path inside the folder is kept in `relative_path`.
    case singleCollectionWithRelativePath
    /// A regular expression over the relative path picks the collection name.
    case manualRule

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .folderToCollection:
            return String(localized: "Папка → одна коллекция")
        case .subfoldersToCollections:
            return String(localized: "Подпапки первого уровня → отдельные коллекции")
        case .singleCollectionWithRelativePath:
            return String(localized: "Одна коллекция + путь в метаданных")
        case .manualRule:
            return String(localized: "Ручное правило (regex по пути)")
        }
    }

    public var summary: String {
        switch self {
        case .folderToCollection:
            return String(localized: "Простой случай: вся папка — одна тема, один набор векторов.")
        case .subfoldersToCollections:
            return String(localized: "Каждая подпапка первого уровня становится отдельной коллекцией. Имена приводятся к допустимым для ChromaDB.")
        case .singleCollectionWithRelativePath:
            return String(localized: "Всё в одной коллекции, но у каждого чанка есть поле relative_path — по нему можно фильтровать вместо разделения на коллекции.")
        case .manualRule:
            return String(localized: "Имя коллекции получается из пути по регулярному выражению. Файлы, не подошедшие под правило, не индексируются, если не задана коллекция по умолчанию.")
        }
    }

    /// Only the manual mode needs the pattern fields shown.
    public var needsRule: Bool { self == .manualRule }
}

/// Where one file goes, and what the mapping mode adds to its metadata.
public struct CollectionRoute: Hashable {
    public let collectionName: String
    public let extraMetadata: ChromaMetadata

    public init(collectionName: String, extraMetadata: ChromaMetadata = [:]) {
        self.collectionName = collectionName
        self.extraMetadata = extraMetadata
    }
}

public enum RoutingOutcome: Hashable {
    case routed(CollectionRoute)
    /// The file is not indexed, and the reason is shown to the user rather than
    /// the file quietly disappearing from the run.
    case unroutable(reason: String)

    public var route: CollectionRoute? {
        if case .routed(let route) = self { return route }
        return nil
    }
}

/// Turns a relative file path into a target collection.
///
/// Pure and synchronous on purpose: the sync planner runs it over thousands of
/// paths, and the source editor runs it over a handful to preview the result.
public struct CollectionRouter {
    public init() {}

    public func route(relativePath: String, source: DataSource) -> RoutingOutcome {
        let path = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = CollectionNaming.sanitize(source.collectionName)

        switch source.mapping {
        case .folderToCollection:
            return .routed(CollectionRoute(collectionName: base))

        case .singleCollectionWithRelativePath:
            return .routed(CollectionRoute(
                collectionName: base,
                extraMetadata: ["relative_path": .string(path)]
            ))

        case .subfoldersToCollections:
            let components = path.split(separator: "/").map(String.init)
            guard components.count > 1 else {
                // A file in the root has no subfolder to name a collection
                // after; the source's own collection is the honest place for it.
                return .routed(CollectionRoute(collectionName: base))
            }
            return .routed(CollectionRoute(
                collectionName: CollectionNaming.sanitize(components[0]),
                extraMetadata: ["relative_path": .string(path)]
            ))

        case .manualRule:
            return manualRoute(path: path, source: source, fallback: base)
        }
    }

    private func manualRoute(path: String, source: DataSource, fallback: String) -> RoutingOutcome {
        let pattern = source.rulePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            return .unroutable(reason: String(localized: "правило не задано"))
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return .unroutable(reason: String(localized: "регулярное выражение не компилируется"))
        }

        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        guard let match = regex.firstMatch(in: path, options: [], range: range) else {
            return unmatched(source: source, fallback: fallback, path: path)
        }

        let template = source.ruleTemplate.isEmpty ? "$1" : source.ruleTemplate
        let expanded = regex.replacementString(for: match, in: path, offset: 0, template: template)
        let name = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return unmatched(source: source, fallback: fallback, path: path)
        }
        return .routed(CollectionRoute(
            collectionName: CollectionNaming.sanitize(name),
            extraMetadata: ["relative_path": .string(path)]
        ))
    }

    private func unmatched(source: DataSource, fallback: String, path: String) -> RoutingOutcome {
        guard source.ruleUsesFallbackCollection else {
            return .unroutable(reason: String(localized: "путь не подошёл под правило"))
        }
        return .routed(CollectionRoute(
            collectionName: fallback,
            extraMetadata: ["relative_path": .string(path)]
        ))
    }

    /// Reason the rule cannot be used, for the source editor. `nil` means fine.
    public static func ruleProblem(pattern: String, template: String) -> String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(localized: "Задайте регулярное выражение по относительному пути файла.")
        }
        guard let regex = try? NSRegularExpression(pattern: trimmed) else {
            return String(localized: "Регулярное выражение не компилируется.")
        }
        // A template referring to a group the pattern does not have yields an
        // empty name at sync time — better to say so while it is being typed.
        let referenced = Self.referencedGroups(in: template.isEmpty ? "$1" : template)
        if let highest = referenced.max(), highest > regex.numberOfCaptureGroups {
            return String(localized: "Шаблон ссылается на группу $\(highest), а в выражении их \(regex.numberOfCaptureGroups).")
        }
        return nil
    }

    private static func referencedGroups(in template: String) -> [Int] {
        var result: [Int] = []
        var digits = ""
        var previousWasDollar = false
        for character in template {
            if character == "$" {
                if !digits.isEmpty, let value = Int(digits) { result.append(value) }
                digits = ""
                previousWasDollar = true
                continue
            }
            if previousWasDollar, character.isNumber {
                digits.append(character)
                continue
            }
            if !digits.isEmpty, let value = Int(digits) { result.append(value) }
            digits = ""
            previousWasDollar = false
        }
        if !digits.isEmpty, let value = Int(digits) { result.append(value) }
        return result
    }
}
