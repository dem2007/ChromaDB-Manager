import XCTest
import ChromaCore
@testable import ChromaDBManagerApp

/// Номер позиции в карточке результата — всегда.
///
/// Сравнение вариантов держится на том, что номера стоят друг напротив друга
///. Номер переехал в строку с длиной куска, а её у результата без
/// текста нет — и колонка осталась бы без нумерации вовсе.
final class ResultRowRankTests: XCTestCase {

    func testTheRankIsShownEvenWithoutText() {
        let hit = EvaluationHit(id: "d17", text: nil, distance: nil, position: 4)
        let card = EvaluationPreview.card(for: hit, query: "порядок лицензирования")
        XCTAssertNil(card.shape, "сказать о куске без текста нечего")
        XCTAssertEqual(EvaluationView.rankLine(hit, card), "4.")
    }

    func testTheRankCarriesTheShapeWhenThereIsOne() {
        let hit = EvaluationHit(
            id: "d17", text: String(repeating: "а", count: 503), distance: nil, position: 4,
            metadata: ["chunk_level": .int(0), "parent_chunk_id": .string("p1")]
        )
        let card = EvaluationPreview.card(for: hit, query: "порядок")
        XCTAssertEqual(EvaluationView.rankLine(hit, card), "4. 503 знака · дочерний")
    }

    // Высота панели выдачи больше не считается: разметка — своя
    // часть вкладки «Прогоны» и занимает всё место под шапкой. Сторож этого —
    // `ComparisonAlignmentTests.testTheResultsScrollInTheirOwnPane`.

    /// У результата без текста показывается его идентификатор — иначе
    /// карточка пуста и опознать её нечем.
    func testTheIdentifierStandsInForMissingText() {
        let hit = EvaluationHit(id: "d17", text: nil, distance: nil, position: 1)
        XCTAssertEqual(EvaluationPreview.card(for: hit, query: "запрос").snippet, "d17")
    }
}
