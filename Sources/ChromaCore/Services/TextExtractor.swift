import Foundation

/// What the source card offers and refuses, by file extension.
///
/// Reading files is the extraction subsystem's job now: the registry
/// picks an extractor by `UTType` and each format brings its own structure,
/// warnings and fallbacks. What is left here is the small amount the *interface*
/// needs before any file has been opened — which extensions to suggest on the
/// card, which to warn about, and how big is too big.
public enum TextExtractor {
    /// Formats this build does not read.
    ///
    /// Spreadsheets left this list when stage 5 arrived: `.xlsx`, `.ods` and
    /// `.numbers` are read now — by the table pipeline rather than by the text
    /// extractors, which is why they were listed here in the first place. `.xls`
    /// followed when Numbers turned out to open it; `.xlsb` did not,
    /// because Numbers does not open that one either.
    public static let unsupportedExtensions: Set<String> = [
        "xlsb", "pptx", "ppt", "mobi",
    ]

    /// Everything this build can read, as file extensions.
    ///
    /// The extractors themselves match by `UTType` and have no list to consult,
    /// so this one is written by hand — and it is the only one: a new source
    /// starts from it, and it is what «поддерживается» means on the card.
    ///
    /// Deliberately wide. A folder is added to be indexed, and a default that
    /// covers two extensions out of twenty silently leaves everything else out
    /// of the collection — the user has to notice the omission to fix it, which
    /// is the wrong way round for a list they can see and trim in one field.
    public static var supportedExtensions: [String] {
        documentExtensions + TabularFormat.allExtensions.filter { !unsupportedExtensions.contains($0) }
    }

    /// What the text extractors handle: prose, markup and code.
    ///
    /// `.pages` and `.key` are here because the app does read them — through
    /// the programs themselves, and only when the source's own switch is on.
    /// A file it cannot export names its reason in diagnostics rather than
    /// disappearing, so listing them by default costs nothing but explains.
    public static let documentExtensions = [
        "md", "markdown", "txt", "rtf", "json", "xml", "yaml", "yml", "html", "htm",
        "pdf", "docx", "doc", "odt", "epub", "pages", "key",
        "swift", "py", "js", "ts", "sh", "sql",
    ]

    /// Bigger files are skipped: they are almost never prose worth embedding
    /// whole, and reading them would stall the run.
    public static let maxFileSize: Int64 = 5 * 1024 * 1024
}
