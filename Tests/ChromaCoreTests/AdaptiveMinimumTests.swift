import XCTest
@testable import ChromaCore

/// Нижняя граница размера блока у адаптивной нарезки.
final class AdaptiveMinimumTests: XCTestCase {
    private func chunker(minimum: Int, maximum: Int = 2048) -> AdaptiveChunker {
        var configuration = ChunkingConfiguration(strategy: .adaptive)
        configuration.sizeUnit = .characters
        configuration.minChunkSize = minimum
        configuration.maxChunkSize = maximum
        configuration.baseChunkSize = 512
        return AdaptiveChunker(configuration: configuration)
    }

    private func text(_ length: Int, _ word: String = "слово") -> String {
        var result = ""
        while result.count < length { result += word + " " }
        return String(result.prefix(length))
    }

    // MARK: - Правило само по себе

    /// Заголовок — это блок целиком короче минимума, и он открывает то, что
    /// за ним. Значит вперёд.
    func testAWholeShortBlockGoesForward() {
        let merged = AdaptiveChunker.honouringMinimum(
            [["== Боевой бык =="], ["В корриде участвуют быки особой породы."]],
            minimum: 128, maximum: 2048
        )
        XCTAssertEqual(merged, ["== Боевой бык ==\n\nВ корриде участвуют быки особой породы."])
    }

    /// Хвост длинного блока — часть **этого** блока, и приклеивать его
    /// к следующему разделу нельзя: это смешение двух тем в одном векторе.
    func testAShortTailOfALongBlockGoesBackward() {
        let merged = AdaptiveChunker.honouringMinimum(
            [[text(500), "конец абзаца"], [text(400)]],
            minimum: 128, maximum: 2048
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged[0].hasSuffix("конец абзаца"), "хвост обязан вернуться в свой блок")
        XCTAssertEqual(merged[1].count, 400, "следующий блок не тронут")
    }

    /// Несколько коротких блоков подряд — два заголовка, подпись, — собираются
    /// в один, пока не наберут минимум.
    func testShortBlocksChainUntilTheyAreLongEnough() {
        let merged = AdaptiveChunker.honouringMinimum(
            [["== Примечания =="], ["== Ссылки =="], [text(400)]],
            minimum: 128, maximum: 2048
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].hasPrefix("== Примечания ==\n\n== Ссылки =="))
    }

    /// Короткий блок в конце файла: вперёд некуда, и он уходит назад.
    func testATrailingShortBlockGoesBackward() {
        let merged = AdaptiveChunker.honouringMinimum(
            [[text(400)], ["Дата обращения: 8 марта 2017."]],
            minimum: 128, maximum: 2048
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].hasSuffix("Дата обращения: 8 марта 2017."))
    }

    /// Потолок — граница жёсткая: за неё модель может отказаться считать
    /// вектор. Нижняя граница ей уступает.
    func testTheCeilingWins() {
        let merged = AdaptiveChunker.honouringMinimum(
            [["== Заголовок =="], [text(2040)]],
            minimum: 128, maximum: 2048
        )
        XCTAssertEqual(merged.count, 2, "склейка не влезает в потолок — заголовок остаётся один")
        XCTAssertEqual(merged[0], "== Заголовок ==")
    }

    /// Минимум ноль — поведение ровно прежнее: настройка выключает правило.
    func testAZeroMinimumChangesNothing() {
        let blocks = [["== Заголовок =="], ["Текст раздела."], ["Ещё абзац."]]
        XCTAssertEqual(
            AdaptiveChunker.honouringMinimum(blocks, minimum: 0, maximum: 2048),
            blocks.flatMap { $0 }
        )
    }

    // MARK: - Через саму нарезку

    func testTheChunkerNoLongerEmitsALoneHeading() {
        let source = """
        == Боевой бык ==

        \(text(600))

        == Арены для боя быков ==

        \(text(600))
        """
        let lone = chunker(minimum: 128).chunks(from: source).filter { $0.text.count < 128 }
        XCTAssertTrue(lone.isEmpty, "остались короткие: \(lone.map(\.text))")

        // И то же самое до правила — чтобы было видно, что изменилось именно
        // оно, а не текст примера. Через `blocks`, а не через настройку:
        // `minChunkSize` не опускается ниже 32 знаков (`converted`), и нулём
        // правило не выключить.
        let before = chunker(minimum: 128).blocks(from: source).flatMap { $0 }.filter { $0.count < 128 }
        XCTAssertEqual(before.count, 2, "до правила заголовки были отдельными кусками")
    }

    /// Ни одного знака не теряется: документ должен собираться из чанков.
    func testNoTextIsLost() {
        let source = "== Заголовок ==\n\n\(text(300))\n\nХвост."
        let joined = chunker(minimum: 128).chunks(from: source)
            .map(\.text).joined(separator: " ")
        XCTAssertTrue(joined.contains("== Заголовок =="))
        XCTAssertTrue(joined.contains("Хвост."))
    }

    /// Номера идут подряд — разрыв в нумерации это отдельная находка
    /// инспектора, и делать её из починки нельзя.
    func testIndicesStayContiguous() {
        let source = (0..<6).map { _ in "== Раздел ==\n\n\(text(400))" }.joined(separator: "\n\n")
        let chunks = chunker(minimum: 128).chunks(from: source)
        XCTAssertEqual(chunks.map(\.index), Array(0..<chunks.count))
    }
}
