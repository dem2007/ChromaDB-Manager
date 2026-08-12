import Foundation

/// Turns a whole sheet into text for «документ» mode.
///
/// The output is a Markdown table rather than tab-separated lines: a chunk of it
/// still reads as a table to a person and to a model, and the header can be
/// repeated at the top of every chunk in a form that means something.
public enum SheetRenderer {
    /// A rendered sheet, with its header kept separate — the header is needed
    /// again once the text is cut into chunks.
    public struct Rendered: Hashable, Sendable {
        public let text: String
        /// The header lines (title row plus the Markdown separator), or `nil`
        /// for a sheet rendered as plain lines.
        public let header: String?

        public init(text: String, header: String?) {
            self.text = text
            self.header = header
        }
    }

    public static func render(rows: [SheetRow], headerRow: Int?) -> Rendered {
        let filled = rows.filter { !$0.isEmpty }
        guard !filled.isEmpty else { return Rendered(text: "", header: nil) }

        let width = filled.map { $0.lastColumn + 1 }.max() ?? 0
        // One column is a list of lines, not a table. A one-column Markdown
        // table is noise around the text.
        guard width > 1 else {
            let lines = filled.map { $0.value(at: 0).displayText }
            return Rendered(text: lines.joined(separator: "\n"), header: nil)
        }

        let headerIndex = headerRow.flatMap { number in filled.firstIndex { $0.number == number } }
        var lines: [String] = []
        var header: String?

        if let headerIndex {
            let titles = SheetModeDetector.headerTitles(filled[headerIndex], width: width)
            header = row(titles) + "\n" + separator(width: width)
            lines.append(header!)
        }

        for (index, sheetRow) in filled.enumerated() where index != headerIndex {
            lines.append(row(sheetRow.values(width: width).map(\.displayText)))
        }
        return Rendered(text: lines.joined(separator: "\n"), header: header)
    }

    /// 1, and it is not optional: **the header row repeats in every chunk.**
    ///
    /// Without it the second and every later chunk is a grid of values with no
    /// column names — rows of numbers that mean nothing on their own, which is
    /// exactly the failure this whole stage exists to avoid.
    public static func repeatingHeader(_ header: String?, in chunks: [TextChunk]) -> [TextChunk] {
        guard let header, !header.isEmpty else { return chunks }
        return chunks.map { chunk in
            guard !chunk.text.hasPrefix(header) else { return chunk }
            return TextChunk(
                index: chunk.index,
                text: header + "\n" + chunk.text,
                level: chunk.level,
                parentIndex: chunk.parentIndex,
                note: chunk.note ?? String(localized: "строка заголовков повторена — без неё чанк таблицы не читается")
            )
        }
    }

    // MARK: - Markdown

    static func row(_ values: [String]) -> String {
        "| " + values.map(escape).joined(separator: " | ") + " |"
    }

    static func separator(width: Int) -> String {
        "|" + String(repeating: " --- |", count: max(1, width))
    }

    /// A pipe inside a cell would end the column early; a newline would end the
    /// row. Both are escaped rather than dropped — the value is the user's.
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
