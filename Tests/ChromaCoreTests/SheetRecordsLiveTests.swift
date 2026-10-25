import XCTest
@testable import ChromaCore

/// Живая проверка на книгах: какие записи выйдут из листов и какие
/// названия колонок даст шапка в несколько строк.
///
/// `CHROMA_IT=1 CHROMA_BOOKS="a.xlsx|b.xls" [CHROMA_PROFILES=profiles.json]
/// [CHROMA_N=3] swift test --filter SheetRecordsLiveTests` — профили берутся
/// списком `[TableProfile]`, первый считается назначенным.
final class SheetRecordsLiveTests: XCTestCase {
    func testBooks() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CHROMA_IT"] == "1", let list = env["CHROMA_BOOKS"] else { throw XCTSkip("CHROMA_IT") }
        for path in list.split(separator: "|").map(String.init) {
            let (sheets, _, _) = try await TableSyncService.read(url: URL(fileURLWithPath: path))
            let profiles = try env["CHROMA_PROFILES"].map {
                try JSONDecoder().decode([TableProfile].self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
            } ?? []
            for (index, entry) in sheets.enumerated() {
                let (shape, match) = TableSyncService.claim(
                    sheet: entry.sheet, rows: entry.rows, index: index, profiles: profiles, assigned: profiles.first
                )
                guard let mapping = match.mapping, mapping.mode == .dataTable else {
                    print("=== \((path as NSString).lastPathComponent) / \(entry.sheet.name): \(shape.mode), не записями")
                    continue
                }
                let layout = SheetLayout(shape: shape)
                let labelled = mapping.labelled(rows: entry.rows, merges: entry.sheet.merges, layout: layout)
                let plan = TableSyncPlanner.plan(
                    rows: entry.rows, mapping: mapping, layout: layout, manifest: SheetManifest(sheetName: entry.sheet.name),
                    sourceID: UUID(), sourceFile: path, merges: entry.sheet.merges
                )
                print("=== \((path as NSString).lastPathComponent) / \(entry.sheet.name): header \(layout.headerRow ?? -1), merges \(entry.sheet.merges.count), relabelled \(labelled.titles.count - mapping.titles.count), records \(plan.added.count)")
                for column in mapping.columns.prefix(12) where labelled.titles[column] != mapping.titles[column] {
                    print("   \(column) → \(labelled.titles[column] ?? "")")
                }
                for document in plan.added.prefix(Int(env["CHROMA_N"] ?? "3") ?? 3) {
                    print("--- row \(document.metadata["row_number"].map { "\($0)" } ?? "?")\n\(document.text.prefix(600))\n    keys: \(document.metadata.keys.sorted().prefix(10).joined(separator: ", "))")
                }
            }
        }
    }
}

