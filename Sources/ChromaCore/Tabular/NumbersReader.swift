import Foundation

/// Asking Numbers to export a `.numbers` file as `.xlsx` (by the
/// mechanism of.
public protocol NumbersExporting: Sendable {
    func exportWorkbook(from url: URL, to destination: URL, timeout: TimeInterval) async throws
}

/// Reads `.numbers` by having Numbers itself convert it.
///
/// The format is closed, as Pages' and Keynote's are, and the same reasoning
/// applies: parsing `Index/*.iwa` blind buys a reader that breaks on the next
/// iWork release. So the application that owns the format converts it to `.xlsx`
/// and the reader from 5.1 takes over.
///
/// It inherits every limitation of along with the mechanism: Numbers has
/// to be installed, macOS has to have granted automation permission, a window
/// comes to the front, and it is therefore **off by default** and separately
/// forbidden during automatic runs.
public struct NumbersReader {
    private let exporter: NumbersExporting

    public init(exporter: NumbersExporting = AppleScriptNumbersExporter()) {
        self.exporter = exporter
    }

    /// `.xls` is here too: Numbers opens the old binary Excel format as an
    /// editor, so the same `open` + `export as Microsoft Excel` converts it —
    /// no BIFF parser of our own.
    public static let supportedExtensions = ["numbers", "xls"]

    /// Exports the file and hands back a reader over the result.
    ///
    /// The caller owns the temporary file and must remove it; the reader keeps
    /// reading from it, so deleting it earlier would pull the ground out.
    public func workbook(
        at url: URL,
        allowApplicationExport: Bool,
        timeout: TimeInterval = 120
    ) async throws -> (reader: XLSXReader, temporary: URL) {
        guard allowApplicationExport else {
            throw ExtractionError.applicationUnavailable(
                String(localized: "экспорт через приложение выключен в настройках источника")
            )
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdbm-numbers-\(UUID().uuidString).xlsx")
        try await exporter.exportWorkbook(from: url, to: destination, timeout: timeout)

        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw ExtractionError.applicationUnavailable(String(localized: "Numbers не создал .xlsx"))
        }
        do {
            return (try XLSXReader(url: destination), destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

/// The real exporter: `osascript` against Numbers' own object model.
public struct AppleScriptNumbersExporter: NumbersExporting {
    public init() {}

    /// Addressed by **Apple's** identifier, never by name.
    ///
    /// The lesson of, and it applies here word for word: on the test
    /// machine `tell application "Numbers"` reaches a third-party «Numbers
    /// Creator Studio», and that app declares `CFBundleIdentifier =
    /// com.apple.Numbers`, so the obvious identifier is no safer than the name.
    /// Apple's own iWork applications use `com.apple.iWork.*`.
    static let bundleIdentifier = "com.apple.iWork.Numbers"

    public func exportWorkbook(from url: URL, to destination: URL, timeout: TimeInterval) async throws {
        let script = """
        set input to POSIX file "\(AppleScriptIWorkExporter.escaped(url.path))"
        set output to POSIX file "\(AppleScriptIWorkExporter.escaped(destination.path))"
        tell application id "\(Self.bundleIdentifier)"
            set doc to open input
            export doc to output as Microsoft Excel
            close doc saving no
        end tell
        """
        try await AppleScriptIWorkExporter.run(script, timeout: timeout, application: "Numbers")
    }
}
