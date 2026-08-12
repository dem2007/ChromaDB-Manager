import Foundation

/// Where a document came from (Приложение 4).
///
/// A document added by hand belongs to no source: it has no `source_id`, no
/// `source_file` and no `chunk_index`. Without a field saying so, everything
/// downstream has to guess — the health inspector would count such documents as
/// orphans, and the facet overview could not show their share.
public enum DocumentOrigin: String, CaseIterable, Sendable, Hashable {
    /// Typed into the single-document form.
    case manual
    /// Brought in by the CSV/JSON import wizard.
    case imported = "import"
    /// Written by a folder source during synchronisation.
    case source
    /// Added through the MCP server (stage 7).
    case mcp
    /// Created outside this app. Recorded when we first write such a document,
    /// never back-filled: a collection someone else made stays as it is.
    case external

    public static let metadataKey = "origin"

    public var title: String {
        switch self {
        case .manual: return String(localized: "вручную")
        case .imported: return String(localized: "импорт")
        case .source: return String(localized: "источник")
        case .mcp: return String(localized: "MCP")
        case .external: return String(localized: "не этим приложением")
        }
    }

    public var value: MetadataValue { .string(rawValue) }

    /// The origin recorded in a document, if any. A document without the field
    /// predates it or was written by something else; that is a normal state and
    /// deliberately not reported as `.external` here — absence is not evidence,
    /// and callers that need to say so choose the wording themselves.
    public static func of(_ metadata: ChromaMetadata?) -> DocumentOrigin? {
        guard case .string(let raw)? = metadata?[metadataKey] else { return nil }
        return DocumentOrigin(rawValue: raw)
    }
}

public extension Dictionary where Key == String, Value == MetadataValue {
    /// Stamps the field on a document this app is creating.
    mutating func stamp(origin: DocumentOrigin) {
        self[DocumentOrigin.metadataKey] = origin.value
    }

    /// Carries provenance across a rewrite. A document that reaches us without
    /// the field was created outside this app, and this is the one moment we may
    /// say so: we are writing it anyway, so nothing is rewritten for the sake of
    /// the label alone.
    mutating func carryOrigin(from existing: ChromaMetadata?) {
        if let known = DocumentOrigin.of(existing) {
            stamp(origin: known)
        } else {
            stamp(origin: .external)
        }
    }
}
