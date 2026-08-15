import XCTest
@testable import ChromaCore

/// Чанк без слов на живой модели.
///
/// Проверяются два утверждения, ради которых всё и делалось, и оба нельзя
/// проверить рассуждением:
///
/// 1. Кусок текста без единого слова ближе к произвольному запросу, чем
///    предложение ровно по теме запроса. То есть это не «бесполезный чанк»,
///    а чанк, всплывающий в **любой** выдаче.
/// 2. Семантическая нарезка настоящего файла больше не оставляет такой кусок
///    отдельным чанком.
///
///     CHROMA_IT=1 swift test --filter WordlessChunkLiveTests
final class WordlessChunkLiveTests: XCTestCase {
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

    private func distance(_ left: [Double], _ right: [Double]) -> Double {
        let dot = zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
        let leftLength = sqrt(left.reduce(0) { $0 + $1 * $1 })
        let rightLength = sqrt(right.reduce(0) { $0 + $1 * $1 })
        guard leftLength > 0, rightLength > 0 else { return 1 }
        return 1 - dot / (leftLength * rightLength)
    }

    /// Скобка обыгрывает ответ по теме — и делает это на любом запросе.
    func testAWordlessChunkOutranksAnOnTopicSentence() async throws {
        let queries = [
            "услуги связи",
            "квантовая запутанность",
            "договор аренды помещения",
        ]
        let wordless = ")"
        let onTopic = "Оператор предоставляет услуги мобильной связи и широкополосного доступа в интернет."

        let vectors = try await lmStudio.embed(texts: queries + [wordless, onTopic], model: model)
        let junk = vectors[queries.count]
        let real = vectors[queries.count + 1]

        for (index, query) in queries.enumerated() {
            let toJunk = distance(vectors[index], junk)
            let toReal = distance(vectors[index], real)
            // Ко всякому запросу скобка ближе половины шкалы — то есть она
            // не «где-то далеко», а в первых строках выдачи.
            XCTAssertLessThan(
                toJunk, 0.7,
                "«\(query)»: до «\(wordless)» \(toJunk), а это должно быть близко — в этом и беда"
            )
            if query == queries[0] {
                // Запрос ровно про то, о чём предложение, — и скобка всё равно
                // впереди. Это и есть цена одного такого чанка в коллекции.
                XCTAssertLessThan(
                    toJunk, toReal,
                    "«\(query)»: до скобки \(toJunk), до предложения по теме \(toReal)"
                )
            }
        }
    }

    /// Настоящий файл из набора: он кончается на «(25 января 2013 г.)», и
    /// разбиение на предложения отрезает `)` в отдельное — оно и становилось
    /// последним чанком.
    func testTheRealFileNoLongerEndsWithAWordlessChunk() async throws {
        let path = "/Users/USER/Downloads/ru_rag_test_dataset-main/files_2/157308.txt"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw XCTSkip("Файла набора нет на этой машине: \(path)")
        }

        var configuration = ChunkingConfiguration(strategy: .semantic)
        configuration.sentenceEmbeddingModel = model
        let chunks = try await ChunkingPipeline(
            configuration: configuration, embeddings: lmStudio, embeddingModel: model
        ).chunks(from: text)

        XCTAssertFalse(chunks.isEmpty)
        let wordless = chunks.filter { !ChunkHygiene.carriesMeaning($0.text) }
        XCTAssertTrue(
            wordless.isEmpty,
            "чанков без слов: \(wordless.count), номера \(wordless.map(\.index))"
        )
        // Номера идут подряд: склейка не должна оставлять дыр в нумерации.
        XCTAssertEqual(chunks.map(\.index), Array(0..<chunks.count))
    }
}
