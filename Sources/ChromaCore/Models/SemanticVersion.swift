import Foundation

/// Minimal PEP 440 / semver-ish version, good enough to answer
/// "is the installed chromadb older than the one on PyPI?".
public struct SemanticVersion: Comparable, CustomStringConvertible, Equatable {
    public let components: [Int]
    public let suffix: String?
    public let raw: String

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Keep the leading numeric dotted part; remember the rest (rc1, .dev0…).
        var numeric = ""
        var rest = ""
        var stillNumeric = true
        for character in trimmed {
            if stillNumeric, character.isNumber || character == "." {
                numeric.append(character)
            } else {
                stillNumeric = false
                rest.append(character)
            }
        }

        let parts = numeric.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }

        self.components = parts
        self.suffix = rest.isEmpty ? nil : rest
        self.raw = trimmed
    }

    public var description: String { raw }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        // 1.0.0rc1 < 1.0.0
        switch (lhs.suffix, rhs.suffix) {
        case (nil, nil): return false
        case (nil, .some): return false
        case (.some, nil): return true
        case (.some(let a), .some(let b)): return a < b
        }
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
