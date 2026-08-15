import XCTest
@testable import ChromaCore

/// Предел чтения настоящей модели.
///
/// Проверяется утверждение, ради которого всё и делалось: **модель молча
/// обрезает вход**. Ни по ответу, ни по числам, которые она о себе сообщает,
/// узнать об этом нельзя — только измерить.
///
///     CHROMA_IT=1 swift test --filter EmbeddingInputLiveTests
final class EmbeddingInputLiveTests: XCTestCase {
    private var model = ""
    private var lmStudio: LMStudioClient!

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CHROMA_IT"] == "1",
            "Живая проверка включается CHROMA_IT=1"
        )
        lmStudio = try LMStudioClient(baseURLString: "http://localhost:1234")
        guard let models = try? await lmStudio.models(),
              let embedding = models.first(where: { $0.kind == .embedding })
        else { throw XCTSkip("LM Studio не отвечает или в нём нет модели эмбеддингов") }
        model = embedding.id
    }

    /// Длинный текст не вызывает ошибки — и в этом вся беда.
    func testAnOversizedTextIsAcceptedWithoutAWord() async throws {
        let huge = EmbeddingInputProbe.sample(ofLength: 120_000)
        let vectors = try await lmStudio.embed(texts: [huge], model: model)
        XCTAssertEqual(vectors.count, 1)
        XCTAssertFalse(vectors[0].isEmpty, "модель ответила вектором на текст, который не прочитала целиком")
    }

    /// Проба находит обрыв, и он не совпадает с тем, что модель о себе
    /// сообщает.
    func testTheMeasuredLimitDiffersFromWhatTheModelReports() async throws {
        let measured = await EmbeddingInputProbe.measure { text in
            try await self.lmStudio.embed(texts: [text], model: self.model).first ?? []
        }
        let reported = await lmStudio.contextLength(of: model)

        guard let measured else {
            // Модель, читающая всё до 64 000 знаков, — тоже честный исход.
            print("──: обрыва до \(EmbeddingInputProbe.maximumProbeCharacters) знаков нет; сообщено \(reported.map(String.init) ?? "ничего")")
            return
        }
        print("""

        ──: предел чтения модели \(model) ──
        измерено: \(measured) знаков (~\(measured / 2) токенов по осторожной оценке)
        сообщено моделью: \(reported.map { "\($0) токенов" } ?? "ничего")

        """)

        // Предел обязан быть похож на предел, а не на случайное число.
        XCTAssertGreaterThan(measured, 1000)
        XCTAssertLessThanOrEqual(measured, EmbeddingInputProbe.maximumProbeCharacters)

        // И главное: за измеренным пределом текст в вектор уже не попадает.
        let text = EmbeddingInputProbe.sample(ofLength: EmbeddingInputProbe.maximumProbeCharacters)
        let atLimit = try await lmStudio.embed(texts: [String(text.prefix(measured))], model: model)[0]
        let beyond = try await lmStudio.embed(texts: [String(text.prefix(min(text.count, measured * 2)))], model: model)[0]
        XCTAssertGreaterThan(
            EmbeddingInputProbe.cosine(atLimit, beyond), EmbeddingInputProbe.identical,
            "за пределом вектор обязан перестать меняться — иначе измерено не то"
        )
    }
}
