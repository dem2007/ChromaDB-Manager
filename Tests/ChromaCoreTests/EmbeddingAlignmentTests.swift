import XCTest
@testable import ChromaCore

/// Выравнивание вектора с текстом — самое дорогое место подсистемы
/// эмбеддинга: перепутанные местами векторы дают полностью неверную базу,
/// и заметить это по одному запросу невозможно.
final class EmbeddingAlignmentTests: XCTestCase {

    private func response(_ items: [(index: Int?, first: Double)]) -> Data {
        let objects: [[String: Any]] = items.map { item in
            var object: [String: Any] = ["embedding": [item.first, 0.0, 0.0]]
            if let index = item.index { object["index"] = index }
            return object
        }
        return try! JSONSerialization.data(withJSONObject: ["data": objects, "model": "m"])
    }

    private func vectors(_ data: Data, sent: Int) throws -> [Double] {
        try LMStudioClient.orderedEmbeddings(from: data, sent: sent, model: "m").map { $0[0] }
    }

    // MARK: - Порядок

    func testAnswersOutOfOrderArePutBackByIndex() throws {
        // Так отвечает сервер, считавший пакет параллельно.
        let data = response([(2, 0.3), (0, 0.1), (1, 0.2)])
        XCTAssertEqual(try vectors(data, sent: 3), [0.1, 0.2, 0.3])
    }

    /// Ответ без `index` обязан остаться в том порядке, в котором пришёл.
    ///
    /// Раньше он сортировался по `index ?? 0`, то есть по константе, и
    /// полагался на устойчивость `sorted` — а Swift её не гарантирует.
    func testAnswerWithoutIndexKeepsTheOrderItArrivedIn() throws {
        let data = response([(nil, 0.1), (nil, 0.2), (nil, 0.3)])
        XCTAssertEqual(try vectors(data, sent: 3), [0.1, 0.2, 0.3])
    }

    func testAPartiallyIndexedAnswerIsNotReorderedOnAGuess() throws {
        // Половина с `index`, половина без — сортировать такое нельзя:
        // отсутствующий индекс не значит «нулевой».
        let data = response([(nil, 0.1), (5, 0.2), (nil, 0.3)])
        XCTAssertEqual(try vectors(data, sent: 3), [0.1, 0.2, 0.3])
    }

    // MARK: - Количество

    /// Короткий ответ опаснее пустого: он выравнивается по первым позициям
    /// и выглядит удачным, пока не выяснится, что хвост в базу не попал.
    func testFewerVectorsThanTextsIsRefused() {
        let data = response([(0, 0.1), (1, 0.2)])
        XCTAssertThrowsError(try vectors(data, sent: 5)) { error in
            guard case LMStudioError.embeddingCountMismatch(let sent, let received) = error else {
                return XCTFail("ожидалось несовпадение количества, получено \(error)")
            }
            XCTAssertEqual(sent, 5)
            XCTAssertEqual(received, 2)
            XCTAssertTrue(
                error.localizedDescription.contains("остановлена"),
                "человеку надо сказать, что операция остановлена: \(error.localizedDescription)"
            )
        }
    }

    func testMoreVectorsThanTextsIsRefusedToo() {
        // Лишний вектор — тоже рассинхронизация, просто с другой стороны.
        let data = response([(0, 0.1), (1, 0.2), (2, 0.3)])
        XCTAssertThrowsError(try vectors(data, sent: 2))
    }

    func testAnEmptyAnswerIsReportedAsANonEmbeddingModel() {
        let data = try! JSONSerialization.data(withJSONObject: ["data": [], "model": "m"])
        XCTAssertThrowsError(try vectors(data, sent: 1)) { error in
            guard case LMStudioError.modelNotEmbedding = error else {
                return XCTFail("пустой ответ — это не та модель, а не несовпадение количества")
            }
        }
    }

    func testAMatchingAnswerPassesThrough() throws {
        let data = response([(0, 0.1), (1, 0.2)])
        XCTAssertEqual(try vectors(data, sent: 2), [0.1, 0.2])
    }
}
