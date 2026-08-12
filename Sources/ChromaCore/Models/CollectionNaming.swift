import Foundation

/// Everything ChromaDB refuses in a collection name, and why.
///
/// The rules were taken off a live 1.4.4 server by creating collections with
/// boundary names and reading the errors back — see. They are repeated
/// here to make the answer instant and specific; the server still checks,
/// because this list can fall behind a future version.
public enum CollectionNameRule: String, CaseIterable, Sendable {
    case tooShort
    case tooLong
    case illegalCharacters
    case badFirstCharacter
    case badLastCharacter
    case consecutivePeriods
    case looksLikeIPAddress

    public var message: String {
        switch self {
        case .tooShort:
            return String(localized: "Имя короче трёх символов.")
        case .tooLong:
            return String(localized: "Имя длиннее 512 символов.")
        case .illegalCharacters:
            return String(localized: "Допустимы только латинские буквы, цифры, точка, дефис и подчёркивание — без пробелов и кириллицы.")
        case .badFirstCharacter:
            return String(localized: "Имя должно начинаться с латинской буквы или цифры.")
        case .badLastCharacter:
            return String(localized: "Имя должно заканчиваться латинской буквой или цифрой.")
        case .consecutivePeriods:
            return String(localized: "Две точки подряд запрещены.")
        case .looksLikeIPAddress:
            return String(localized: "Имя не должно выглядеть как IP-адрес.")
        }
    }
}

/// ChromaDB validates collection names server-side. The exact rules, verified
/// on 1.4.4:
///
///     Expected a name containing 3-512 characters from [a-zA-Z0-9._-],
///     starting and ending with a character in [a-zA-Z0-9]
///     Expected a name that does not contains two consecutive periods (..)
///     Expected a name that is not a valid ip address
///
/// Note that this is **ASCII only** — a folder named "Мои заметки 2024" is
/// rejected outright, so names derived from folders are normalised first.
public enum CollectionNaming {
    public static let minimumLength = 3
    public static let maximumLength = 512

    private static let asciiAlphanumerics = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static var allowed: CharacterSet { asciiAlphanumerics.union(CharacterSet(charactersIn: "._-")) }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1 && asciiAlphanumerics.contains(character.unicodeScalars.first!)
    }

    public static func sanitize(_ raw: String) -> String {
        var name = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        while name.contains("..") { name = name.replacingOccurrences(of: "..", with: ".") }

        while let first = name.first, !isASCIIAlphanumeric(first) { name.removeFirst() }
        while let last = name.last, !isASCIIAlphanumeric(last) { name.removeLast() }

        if name.isEmpty { name = "collection" }
        if name.count < minimumLength { name += "_col" }
        // A sanitised name that happens to read as an IP would be refused by
        // the server just the same.
        if looksLikeIPv4(name) { name += "_col" }
        return String(name.prefix(60))
    }

    /// Every rule the name breaks, in the order a reader would notice them.
    public static func violations(of name: String) -> [CollectionNameRule] {
        var found: [CollectionNameRule] = []
        if name.count < minimumLength { found.append(.tooShort) }
        if name.count > maximumLength { found.append(.tooLong) }
        if !name.unicodeScalars.allSatisfy({ allowed.contains($0) }) { found.append(.illegalCharacters) }
        if let first = name.first, !isASCIIAlphanumeric(first) { found.append(.badFirstCharacter) }
        if let last = name.last, !isASCIIAlphanumeric(last) { found.append(.badLastCharacter) }
        if name.contains("..") { found.append(.consecutivePeriods) }
        if looksLikeIPv4(name) { found.append(.looksLikeIPAddress) }
        return found
    }

    public static func isValid(_ name: String) -> Bool {
        violations(of: name).isEmpty
    }

    /// What the form shows under the field: the first thing to fix, not a list.
    public static func firstProblem(with name: String) -> String? {
        violations(of: name).first?.message
    }

    /// Matches what the server accepts as an address, which is stricter than
    /// «four numbers with dots»: `256.1.1.1` and `01.2.3.4` are fine as names
    /// precisely because they are not addresses.
    static func looksLikeIPv4(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard (1...3).contains(part.count), part.allSatisfy(\.isNumber) else { return false }
            if part.count > 1, part.first == "0" { return false }
            guard let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }
}
