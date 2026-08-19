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
    /// One collection; the path inside the folder is kept in `source_file`,
    /// like everywhere else.
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
            return String(localized: "Всё в одной коллекции, а место файла в дереве папок остаётся в поле source_file — по нему можно фильтровать вместо разделения на коллекции.")
        case .manualRule:
            return String(localized: "Имя коллекции получается из пути по регулярному выражению. Файлы, не подошедшие под правило, не индексируются, если не задана коллекция по умолчанию.")
        }
    }

    /// Only the manual mode needs the pattern fields shown.
    public var needsRule: Bool { self == .manualRule }
}

/// Один уровень вложенности папок как поле метаданных.
///
/// Структура папок уже несёт смысл: `Системы/2025/Система 1/устав.docx` —
/// это год и название системы, написанные человеком и лежащие мёртвым грузом
/// в `relative_path`, по которому не отфильтруешь. Уровень, которому дали имя,
/// превращается в обычное поле чанка: `year = 2025`, `system = Система 1`.
///
/// Номер уровня — это позиция в массиве источника, а не поле здесь: уровень
/// определяется местом в пути, и хранить его дважды значит однажды разойтись.
public struct PathLevel: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Ключ метаданных. Латиницей — по нему фильтруют запросы, ходят
    /// MCP-инструменты и переносы; **значение** при этом остаётся тем, что
    /// написано на папке, хоть кириллицей, хоть с пробелами.
    public var key: String
    public var type: MetadataFieldType
    /// Значение для файла, который лежит **выше** этого уровня
    /// (`Системы/2025/устав.docx` при названном втором уровне). Пустое — поле
    /// такому файлу не пишется вовсе: выдуманное значение хуже отсутствующего.
    public var fallbackValue: String

    public init(
        id: UUID = UUID(),
        key: String = "",
        type: MetadataFieldType = .string,
        fallbackValue: String = ""
    ) {
        self.id = id
        self.key = key
        self.type = type
        self.fallbackValue = fallbackValue
    }

    public var trimmedKey: String { key.trimmingCharacters(in: .whitespaces) }
    /// Уровень без имени не пишется никуда — это «не назвали», а не «пусто».
    public var isNamed: Bool { !trimmedKey.isEmpty }
    public var parsedFallback: MetadataValue? {
        fallbackValue.isEmpty ? nil : type.parse(fallbackValue)
    }
    /// Значение по умолчанию, не приводящееся к типу уровня, — ловушка:
    /// оно молча не запишется ничем.
    public var defaultIsBroken: Bool {
        !fallbackValue.isEmpty && type.parse(fallbackValue) == nil
    }

    /// Значение уровня из имени папки, приведённое к типу поля.
    ///
    /// `nil` — имя папки к типу не приводится (уровень объявлен числом, а папка
    /// называется «архив»). Тогда поле не пишется, и об этом говорится в плане:
    /// записать строку в числовое поле значило бы поссорить чанк со схемой
    /// коллекции на ровном месте.
    public func value(for folderName: String) -> MetadataValue? {
        type.parse(folderName)
    }

    /// Что не так с ключом. `nil` — ключ годится.
    ///
    /// Латиница, цифры и подчёркивание, первый знак — буква: так выглядят все
    /// остальные ключи метаданных приложения, и так их принимают фильтры
    /// `$eq`/`$in` без экранирования.
    public static func keyProblem(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Полный список того, что приложение пишет само. `language`
        // и `keywords` в `sourceProvidedKeys` не входят, а пишутся
        // **после** полей маршрута — уровень с таким ключом молча
        // перезаписался бы языком чанка, и человек увидел бы в базе не то,
        // что показал ему предпросмотр.
        if MetadataSchema.isTechnicalKey(trimmed)
            || MetadataSchema.isReservedKey(trimmed)
            || SourceSyncService.extractionMetadataKeys.contains(trimmed) {
            return String(localized: "«\(trimmed)» — служебное поле приложения, его нельзя занимать.")
        }
        guard let first = trimmed.first, first.isLetter, first.isASCII else {
            return String(localized: "Ключ начинается с латинской буквы.")
        }
        let allowed = trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        guard allowed else {
            return String(localized: "В ключе только латинские буквы, цифры и подчёркивание — значение при этом может быть любым.")
        }
        return nil
    }

    /// Больше этого уровней не называется. Не запрет ради запрета: каждое поле
    /// пишется в метаданные **каждого** чанка, и восемь длинных названий папок
    /// — это уже заметная часть предела на размер метаданных документа.
    public static let maximumLevels = 8
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
        let outcome: RoutingOutcome

        switch source.mapping {
        case .folderToCollection:
            outcome = .routed(CollectionRoute(collectionName: base))

        case .singleCollectionWithRelativePath:
            // Путь в метаданные пишет синхронизация — полем `source_file`
            //. Прежде маршрутизатор клал рядом второе поле,
            // `relative_path`, слово в слово равное первому: на 4119
            // проверенных чанках они не разошлись ни разу. Новым записям
            // дубль не нужен, старые остаются как есть.
            outcome = .routed(CollectionRoute(collectionName: base))

        case .subfoldersToCollections:
            let components = path.split(separator: "/").map(String.init)
            guard components.count > 1 else {
                // A file in the root has no subfolder to name a collection
                // after; the source's own collection is the honest place for it.
                return adding(levels: source, to: .routed(CollectionRoute(collectionName: base)), path: path)
            }
            outcome = .routed(CollectionRoute(
                collectionName: CollectionNaming.sanitize(components[0])
            ))

        case .manualRule:
            outcome = manualRoute(path: path, source: source, fallback: base)
        }
        return adding(levels: source, to: outcome, path: path)
    }

    /// Поля из пути — поверх любого режима.
    ///
    /// Именно поверх, а не вместо: режим решает, в какую коллекцию попадёт
    /// файл, уровни — что о нём известно из места в дереве. Файлу, который
    /// никуда не попал, поля не нужны: его не будет в базе.
    private func adding(levels source: DataSource, to outcome: RoutingOutcome, path: String) -> RoutingOutcome {
        guard let route = outcome.route, !source.pathLevels.isEmpty else { return outcome }
        let fields = Self.levelFields(for: path, levels: source.pathLevels)
        guard !fields.isEmpty else { return outcome }
        var metadata = route.extraMetadata
        for (key, value) in fields { metadata[key] = value }
        return .routed(CollectionRoute(collectionName: route.collectionName, extraMetadata: metadata))
    }

    /// Значения полей уровней для одного пути.
    ///
    /// Папки пути — это всё, кроме последней составляющей: имя файла уровнем
    /// не является. Уровень без имени пропускается; уровень, до которого путь
    /// не достаёт, берёт значение по умолчанию, а без него не пишется вовсе —
    /// выдуманное значение хуже отсутствующего (правило 2 приложения 5).
    /// Имя папки, не приводящееся к типу уровня, тоже не пишется: строка
    /// в числовом поле поссорила бы чанк со схемой коллекции.
    public static func levelFields(for path: String, levels: [PathLevel]) -> ChromaMetadata {
        let folders = path.split(separator: "/").map(String.init).dropLast()
        var result: ChromaMetadata = [:]
        for (index, level) in levels.prefix(PathLevel.maximumLevels).enumerated() {
            guard level.isNamed else { continue }
            let value: MetadataValue?
            if index < folders.count {
                value = level.value(for: folders[folders.startIndex + index]) ?? level.parsedFallback
            } else {
                value = level.parsedFallback
            }
            if let value { result[level.trimmedKey] = value }
        }
        return result
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
        return .routed(CollectionRoute(collectionName: CollectionNaming.sanitize(name)))
    }

    private func unmatched(source: DataSource, fallback: String, path: String) -> RoutingOutcome {
        guard source.ruleUsesFallbackCollection else {
            return .unroutable(reason: String(localized: "путь не подошёл под правило"))
        }
        return .routed(CollectionRoute(collectionName: fallback))
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
