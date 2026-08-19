import XCTest
@testable import ChromaCore

/// Подмена модели в ответе LM Studio.
///
/// Замер на живой LM Studio 0.3.x: `/v1/embeddings` не загружает модель по
/// имени из запроса. Названной модели среди загруженных нет — ответ придёт
/// от той, что загружена, без единой жалобы. Просили `bge-m3-mlx` — пришёл
/// вектор `text-embedding-qwen3-embedding-0.6b`.
///
/// Защита по размерности такое не ловит: обе эти модели дают 1024. Ловит
/// только поле `model` в ответе, и вот оно и проверяется.
final class ModelSubstitutionTests: XCTestCase {

    private func response(model: String?, count: Int = 1) -> Data {
        var object: [String: Any] = [
            "data": (0..<count).map { ["embedding": [0.1, 0.2], "index": $0] }
        ]
        if let model { object["model"] = model }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func vectors(_ data: Data, asked: String, sent: Int = 1) throws -> [[Double]] {
        try LMStudioClient.orderedEmbeddings(from: data, sent: sent, model: asked)
    }

    // MARK: - Подмену видно

    /// Главный случай: две модели **одной размерности**, и защита по
    /// размерности бессильна по построению.
    func testAnAnswerFromAnotherModelStopsTheOperation() {
        let data = response(model: "text-embedding-qwen3-embedding-0.6b")
        XCTAssertThrowsError(try vectors(data, asked: "bge-m3-mlx")) { error in
            guard case LMStudioError.modelSubstituted(let requested, let returned) = error else {
                return XCTFail("ожидалась подмена модели, пришло \(error)")
            }
            XCTAssertEqual(requested, "bge-m3-mlx")
            XCTAssertEqual(returned, "text-embedding-qwen3-embedding-0.6b")
        }
    }

    /// Соседи по семейству — тоже разные модели.
    func testTwoSizesOfOneFamilyAreDifferentModels() {
        let data = response(model: "text-embedding-qwen3-embedding-4b")
        XCTAssertThrowsError(try vectors(data, asked: "text-embedding-qwen3-embedding-0.6b"))
    }

    /// Ошибка называет обе стороны: без этого человек не поймёт, что чинить.
    func testTheMessageNamesBothModels() {
        let error = LMStudioError.modelSubstituted(
            requested: "bge-m3-mlx", returned: "text-embedding-qwen3-embedding-0.6b"
        )
        let text = error.errorDescription ?? ""
        XCTAssertTrue(text.contains("bge-m3-mlx"), text)
        XCTAssertTrue(text.contains("text-embedding-qwen3-embedding-0.6b"), text)
    }

    // MARK: - Ложных тревог нет

    /// Все четыре расхождения ниже сняты с живой LM Studio и подменой не
    /// являются: ложная остановка индексации стоит дороже пропущенной.
    func testDifferencesThatAreNotSubstitutions() {
        let pairs = [
            ("TEXT-EMBEDDING-QWEN3-EMBEDDING-4B", "text-embedding-qwen3-embedding-4b"),
            ("google/gemma-4-e2b", "gemma-4-e2b"),
            ("gemma-4-e2b", "google/gemma-4-e2b"),
            ("qwen3.8-27b-mlx@4bit", "qwen3.8-27b-mlx"),
            ("qwen3-embedding-4b", "text-embedding-qwen3-embedding-4b"),
        ]
        for (asked, answered) in pairs {
            XCTAssertFalse(
                LMStudioClient.substituted(requested: asked, returned: answered),
                "«\(asked)» и «\(answered)» — одна модель, а посчитаны разными"
            )
        }
    }

    /// Сборка LM Studio, не присылающая `model`, обязана работать как прежде.
    func testAnAnswerWithoutTheFieldIsNotJudged() throws {
        XCTAssertEqual(try vectors(response(model: nil), asked: "любая").count, 1)
    }

    /// Пустое имя ничего не доказывает — по нему нельзя ни обвинить, ни
    /// оправдать.
    func testEmptyNamesAreNotJudged() {
        XCTAssertFalse(LMStudioClient.substituted(requested: "", returned: "qwen"))
        XCTAssertFalse(LMStudioClient.substituted(requested: "qwen", returned: ""))
    }

    /// Проверка не должна съесть сверку количества: она идёт раньше и о
    /// пропавших векторах говорит именно она.
    func testTheCountCheckStillComesFirst() {
        let data = response(model: "чужая-модель", count: 1)
        XCTAssertThrowsError(try vectors(data, asked: "своя-модель", sent: 3)) { error in
            guard case LMStudioError.embeddingCountMismatch = error else {
                return XCTFail("ожидалось несовпадение количества, пришло \(error)")
            }
        }
    }
}
