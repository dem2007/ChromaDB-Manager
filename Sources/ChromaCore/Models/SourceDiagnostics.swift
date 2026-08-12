import Foundation

/// What the user can do about a file that did not produce text.
///
/// The *suggested* action, not the only one: the diagnostics screen always
/// offers «повторить» and «исключить», because a file can fail for a reason the
/// app classified wrongly. This says which action is worth trying first, and it
/// is derived from the error rather than guessed in the view.
public enum FileRemedy: String, Codable, Sendable, CaseIterable {
    /// A scan. Turning recognition on for the source is the fix.
    case enableOCR
    /// Locked. A password, kept in the Keychain, is the fix.
    case password
    /// Something that may well work next time: a timeout, an application that
    /// was busy. Nothing to change first.
    case retry
    /// Nothing to try. DRM, an unsupported format, a file with no text in it —
    /// the honest offer is to stop asking about it.
    case exclude

    public var title: String {
        switch self {
        case .enableOCR: return String(localized: "Включить распознавание")
        case .password: return String(localized: "Ввести пароль")
        case .retry: return String(localized: "Повторить")
        case .exclude: return String(localized: "Исключить из источника")
        }
    }
}

/// One file that needs a decision, with the reason it needs one.
///
/// Persisted in the manifest so the diagnostics screen shows the state after the
/// last run instead of re-reading a folder of documents to find out what already
/// failed once.
public struct FileProblem: Codable, Hashable, Identifiable, Sendable {
    public var id: String { relativePath }
    public var relativePath: String
    /// The wording the run put in the report — the same string, so the screen
    /// and the log cannot disagree.
    public var reason: String
    public var remedy: FileRemedy
    public var noticedAt: Date

    public init(relativePath: String, reason: String, remedy: FileRemedy, noticedAt: Date = Date()) {
        self.relativePath = relativePath
        self.reason = reason
        self.remedy = remedy
        self.noticedAt = noticedAt
    }

    /// Which action to suggest for an error.
    ///
    /// `wrongPassword` maps to `.password` as well: the fix is still a password,
    /// just not the one already stored, and the reason text says so.
    public static func remedy(for error: Error) -> FileRemedy {
        guard let extraction = error as? ExtractionError else { return .retry }
        switch extraction {
        case .noTextLayer(let looksLikeScan):
            // A PDF with no text and no sign of being a scan has nothing to
            // recognise — offering OCR there would waste minutes per file.
            return looksLikeScan ? .enableOCR : .exclude
        case .passwordProtected, .wrongPassword:
            return .password
        case .timedOut, .applicationUnavailable:
            return .retry
        case .drmProtected, .unsupportedFormat, .corrupted, .empty, .tooLarge:
            return .exclude
        }
    }
}
