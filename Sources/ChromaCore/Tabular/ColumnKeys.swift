import Foundation

/// What a column is for.
public enum ColumnRole: String, Codable, Sendable, CaseIterable, Identifiable {
    public var id: String { rawValue }

    /// Goes into the document's text — what the search actually matches against.
    case text
    /// Goes into metadata, for `where` filters.
    case metadata
    case ignore

    public var title: String {
        switch self {
        case .text: return String(localized: "Текст")
        case .metadata: return String(localized: "Метаданные")
        case .ignore: return String(localized: "Игнорировать")
        }
    }
}

/// A column title that had to be renamed to become a metadata key, and why.
///
/// Kept and shown rather than resolved quietly: requires collisions to be
/// resolved explicitly, and a rename the user never sees is the same thing as
/// losing the column.
public struct ColumnKeyCollision: Hashable, Sendable, Identifiable {
    public enum Reason: String, Codable, Sendable {
        /// Two columns normalise to the same key.
        case duplicate
        /// The key is one the app writes itself — the dangerous one.
        case reserved
    }

    public var id: String { title }
    public let title: String
    /// What the name would have become on its own.
    public let wanted: String
    /// What it became instead.
    public let key: String
    public let reason: Reason

    public var explanation: String {
        switch reason {
        case .duplicate:
            return String(localized: "«\(title)» → \(key): ключ \(wanted) уже занят другой колонкой")
        case .reserved:
            return String(localized: "«\(title)» → \(key): \(wanted) — служебное поле приложения, колонка получила префикс, чтобы не затереть его")
        }
    }
}

/// Column titles → metadata keys.
public struct ColumnKeyMap: Hashable, Sendable {
    /// Title as written in the sheet → key written into metadata.
    public let keys: [String: String]
    /// Every rename, in column order.
    public let collisions: [ColumnKeyCollision]

    public init(keys: [String: String], collisions: [ColumnKeyCollision]) {
        self.keys = keys
        self.collisions = collisions
    }

    public func key(for title: String) -> String? { keys[title] }
}

/// Turns column titles into metadata keys, resolving both kinds of collision
///.
public enum ColumnKeyNormaliser {
    /// Prefix given to a column whose name collides with one of the app's own
    /// fields.
    public static let reservedPrefix = "col_"

    /// One title, normalised — without knowing about its neighbours.
    ///
    /// Kept conservative on purpose: the user's own words are the best key
    /// there is, so Cyrillic is left alone. What is removed is what would break
    /// a filter — `$` starts a ChromaDB operator, and a dot is a path separator
    /// in many query languages.
    public static func normalise(_ title: String, fallback: String = "column") -> String {
        var result = ""
        for character in title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
            if character.isLetter || character.isNumber {
                result.append(character)
            } else if character == "_" {
                // Written by hand, so it is kept — including a leading one.
                // Dropping it turned a column called `_cdbm_model` into
                // `cdbm_model`, which is no longer a reserved name and so was
                // renamed with nobody told. Found by the test for exactly that.
                if !result.hasSuffix("_") { result.append("_") }
            } else if character.isWhitespace || character == "-" {
                if !result.isEmpty, !result.hasSuffix("_") { result.append("_") }
            }
            // Everything else — `$`, `.`, quotes, punctuation — is dropped.
        }
        while result.count > 1, result.hasSuffix("_") { result.removeLast() }
        return result.isEmpty || result == "_" ? fallback : result
    }

    /// The whole header at once, which is the only way collisions can be seen.
    ///
    /// Two rules, and the second is the one warns is easy to miss:
    /// two columns collapsing into one key lose a column, but a column
    /// collapsing onto a **reserved** key silently overwrites a field the sync
    /// depends on — `source_file` or `row_number` — and breaks synchronisation
    /// rather than merely losing data.
    public static func map(titles: [String]) -> ColumnKeyMap {
        var keys: [String: String] = [:]
        var used: Set<String> = []
        var collisions: [ColumnKeyCollision] = []

        for (index, title) in titles.enumerated() {
            let wanted = normalise(title, fallback: XLSXReader.columnName(index).lowercased())
            var key = wanted
            var reason: ColumnKeyCollision.Reason?

            if MetadataSchema.isTechnicalKey(key) {
                key = reservedPrefix + key
                reason = .reserved
            }
            if used.contains(key) {
                var suffix = 2
                while used.contains("\(key)_\(suffix)") { suffix += 1 }
                key = "\(key)_\(suffix)"
                // A rename forced by a reserved name *and* a duplicate is
                // reported as the duplicate it ended up being.
                reason = .duplicate
            }

            used.insert(key)
            keys[title] = key
            if let reason {
                collisions.append(ColumnKeyCollision(title: title, wanted: wanted, key: key, reason: reason))
            }
        }
        return ColumnKeyMap(keys: keys, collisions: collisions)
    }
}
