import XCTest
@testable import ChromaCore
@testable import ChromaDBManagerApp

/// Заметки, которые слой приложения дописывает к ответу MCP, — по-английски.
///
/// Это ровно те строки, что чинил, и до сих пор их не проверял **никто**:
/// сторож ответов из живёт в тестах ядра с заглушкой вместо бэкенда,
/// поэтому код приложения в нём не исполняется вовсе. Ошибка повторилась
/// дважды подряд — сперва переоценил охват своего сторожа, потом
/// переоценил свой.
final class MCPAnswerLanguageTests: XCTestCase {

    private func cyrillic(_ text: String) -> String {
        String(text.filter {
            ("а"..."я").contains($0) || ("А"..."Я").contains($0) || $0 == "ё" || $0 == "Ё"
        })
    }

    /// Ярлык контекстного результата: модель по нему понимает, что строка не
    /// занимает место среди запрошенных.
    func testContextMarkersAreEnglish() {
        for kind in [ContextKind.parent, .neighbour] {
            let note = AppMCPBackend.contextNote(kind) ?? ""
            XCTAssertFalse(note.isEmpty, "ярлык \(kind) пуст")
            XCTAssertTrue(cyrillic(note).isEmpty, "русский ярлык контекста: \(note)")
        }
        XCTAssertNil(AppMCPBackend.contextNote(nil), "у обычного результата ярлыка быть не должно")
    }

    /// Умный поиск выключен — модель обязана узнать об этом по-английски.
    func testSmartSearchOffNoteIsEnglish() {
        for byKey in [true, false] {
            let note = AppMCPBackend.pipelineNote(
                RetrievalDiagnostics(), smartSearch: false, decidedByKey: byKey
            ) ?? ""
            XCTAssertFalse(note.isEmpty, "причина отключения не названа")
            XCTAssertTrue(cyrillic(note).isEmpty, "русская причина: \(note)")
        }
    }

    /// «Как искали» и «не отработало» — обе ветки заметки о конвейере.
    func testPipelineNoteIsEnglish() {
        var diagnostics = RetrievalDiagnostics()
        diagnostics.stages = [
            .init(stage: .fusion, outcome: .ran, inputCount: 10, outputCount: 8),
            .init(stage: .rerank, outcome: .failed, inputCount: 8, outputCount: 8),
        ]
        let note = AppMCPBackend.pipelineNote(
            diagnostics, smartSearch: true, decidedByKey: false
        ) ?? ""
        XCTAssertTrue(note.contains("fusion"), "стадия названа по-английски: \(note)")
        XCTAssertTrue(note.contains("reranking"), "упавшая стадия названа: \(note)")
        XCTAssertTrue(cyrillic(note).isEmpty, "русский текст в заметке о конвейере: \(note)")
    }
}
