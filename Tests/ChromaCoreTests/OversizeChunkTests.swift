import XCTest
@testable import ChromaCore

/// Чанк длиннее контекста модели дорезается, а не отменяет файл.
///
/// Живой случай: документ на шестьдесят страниц не попал в базу целиком
/// из-за пятнадцатого чанка в 2036 токенов при контексте модели 2048.
final class OversizeChunkTests: XCTestCase {
    /// Текст, заведомо длиннее предела: считается пессимистично, два знака
    /// на токен, поэтому 200 предложений по ~40 знаков — это ~4000 токенов.
    private func longText(sentences: Int) -> String {
        (1...sentences).map { "Предложение номер \($0) про работы и сроки." }.joined(separator: " ")
    }

    func testAFittingChunkIsLeftAlone() {
        let chunks = [TextChunk(index: 0, text: "Короткий текст."), TextChunk(index: 1, text: "И второй.")]
        let result = OversizeChunks.fitted(chunks, contextLength: 2048)
        XCTAssertEqual(result.split, 0)
        XCTAssertEqual(result.chunks.map(\.text), chunks.map(\.text))
        XCTAssertEqual(result.chunks.map(\.index), [0, 1])
    }

    /// Каждый кусок влезает, а текст не потерян.
    func testAnOversizeChunkIsSplitAndNothingIsLost() {
        let text = longText(sentences: 200)
        let result = OversizeChunks.fitted([TextChunk(index: 0, text: text)], contextLength: 2048)

        XCTAssertEqual(result.split, 1)
        XCTAssertGreaterThan(result.chunks.count, 1, "один чанк обязан был разойтись на несколько")
        for chunk in result.chunks {
            XCTAssertFalse(
                OversizeChunks.doesNotFit(chunk.text, limit: 2048),
                "кусок всё ещё длиннее контекста: ≈\(TokenEstimator.estimatedTokens(chunk.text)) токенов"
            )
        }
        // Склейка кусков возвращает исходный текст: дорезка не выбрасывает
        // ни слова — иначе это молча обрезанный хвост, ради запрета которого
        // файл раньше и пропускали.
        XCTAssertEqual(
            result.chunks.map(\.text).joined(separator: " ").split(separator: " ").count,
            text.split(separator: " ").count
        )
    }

    /// Номера идут подряд, а ссылка на родителя переезжает вместе с ним.
    func testNumbersStayContinuousAndParentsFollow() {
        let chunks = [
            TextChunk(index: 0, text: longText(sentences: 200), level: 1),
            TextChunk(index: 1, text: "Дочерний кусок.", level: 0, parentIndex: 0),
        ]
        let result = OversizeChunks.fitted(chunks, contextLength: 2048)

        XCTAssertEqual(result.chunks.map(\.index), Array(0..<result.chunks.count), "дырка в нумерации читается как след сбоя")
        let child = try? XCTUnwrap(result.chunks.last)
        XCTAssertEqual(child?.text, "Дочерний кусок.")
        XCTAssertEqual(child?.parentIndex, 0, "родитель остался первым куском разрезанного чанка")
    }

    /// Предложение, которое само не влезает, режется по словам.
    func testASentenceLongerThanTheContextIsSplitByWords() {
        let text = (1...900).map { "слово\($0)" }.joined(separator: " ")
        let result = OversizeChunks.fitted([TextChunk(index: 0, text: text)], contextLength: 512)
        XCTAssertGreaterThan(result.chunks.count, 1)
        for chunk in result.chunks {
            XCTAssertFalse(OversizeChunks.doesNotFit(chunk.text, limit: 512))
        }
    }

    /// Контекст неизвестен — резать не по чему, и выдумывать предел нельзя.
    func testWithoutAKnownContextNothingIsTouched() {
        let chunks = [TextChunk(index: 0, text: longText(sentences: 200))]
        XCTAssertEqual(OversizeChunks.fitted(chunks, contextLength: nil).split, 0)
    }
}
