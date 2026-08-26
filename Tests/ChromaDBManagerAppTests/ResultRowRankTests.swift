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

    // MARK: - Высота панели выдачи

    /// Прогон из одного запроса не занимает весь экран пустотой.
    func testASmallRunGetsASmallPane() {
        let height = EvaluationView.paneHeight(for: EvaluationRunSamples.run(queries: 1, hits: 3, metadata: true), container: 1400)
        XCTAssertEqual(height, 420, "меньше пола панель не бывает")
        let taller = EvaluationView.paneHeight(for: EvaluationRunSamples.run(queries: 1, hits: 10, metadata: true), container: 1400)
        XCTAssertGreaterThan(taller, 420)
        XCTAssertLessThan(taller, 1260, "одному запросу столько не нужно")
    }

    /// А большой — во весь рост видимой части, без запаса сверх полей
    /// карточки и страницы.
    func testABigRunStopsAtTheVisiblePartOfThePage() {
        let height = EvaluationView.paneHeight(for: EvaluationRunSamples.run(queries: 18, hits: 10, metadata: true), container: 900)
        XCTAssertEqual(height, 900 - Theme.Padding.cardVertical - Theme.contentPadding)
    }

    /// В крошечном окне панель всё равно остаётся пригодной для разметки.
    func testTheFloorHoldsInATinyWindow() {
        XCTAssertEqual(EvaluationView.paneHeight(for: EvaluationRunSamples.run(queries: 18, hits: 10, metadata: true), container: 300), 420)
    }

    /// У результата без текста показывается его идентификатор — иначе
    /// карточка пуста и опознать её нечем.
    func testTheIdentifierStandsInForMissingText() {
        let hit = EvaluationHit(id: "d17", text: nil, distance: nil, position: 1)
        XCTAssertEqual(EvaluationPreview.card(for: hit, query: "запрос").snippet, "d17")
    }
}
