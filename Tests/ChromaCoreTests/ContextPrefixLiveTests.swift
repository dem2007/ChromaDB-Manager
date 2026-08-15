import XCTest
@testable import ChromaCore

/// Контекстный префикс на живой модели.
///
/// Проверяется не то, что строка склеилась, а то, ради чего всё делалось:
/// находится ли фрагмент, в котором **нет ни одного слова из запроса**, если
/// перед ним в модель ушло «Документ → Раздел». Ответить на это может только
/// настоящая модель эмбеддингов.
///
///     CHROMA_IT=1 swift test --filter ContextPrefixLiveTests
final class ContextPrefixLiveTests: XCTestCase {
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

    private func cosine(_ left: [Double], _ right: [Double]) -> Double {
        let dot = zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
        let leftLength = sqrt(left.reduce(0) { $0 + $1 * $1 })
        let rightLength = sqrt(right.reduce(0) { $0 + $1 * $1 })
        guard leftLength > 0, rightLength > 0 else { return 0 }
        return dot / (leftLength * rightLength)
    }

    /// Фрагмент из середины регламента: без контекста он не о чём.
    func testAContextFreeFragmentIsFoundOnlyWithItsHeadings() async throws {
        let query = "что происходит при превышении давления на входе насоса"

        // Целевой фрагмент: ни «насоса», ни «давления» в нём нет.
        let target = (
            text: "Превышение допустимого значения приводит к отказу и автоматической остановке.",
            title: "Регламент эксплуатации насосной станции",
            heading: "Контроль параметров > Давление на входе"
        )
        // Соперники подобраны **против** префикса: в них есть слова запроса,
        // а смысла нет. Без контекста цель обязана им проиграть — иначе
        // проверка ничего не измеряет.
        let distractors: [(text: String, title: String, heading: String)] = [
            (
                "Насосы и датчики давления поставляются в комплекте; давление на входе проверяется при приёмке оборудования на складе.",
                "Инструкция по приёмке оборудования", "Комплектность > Насосы и датчики"
            ),
            (
                "При отказе входного насоса составляется акт; давление фиксируется в акте по показаниям манометра.",
                "Положение об актах", "Оформление актов > Отказ оборудования"
            ),
            (
                "Журнал заполняется ежедневно, записи хранятся три года.",
                "Регламент эксплуатации насосной станции", "Документооборот > Журналы"
            ),
        ]

        let documents = [target] + distractors
        func rank(withPrefix: Bool) async throws -> (position: Int, best: Double) {
            let texts = documents.map { document -> String in
                guard withPrefix,
                      let prefix = SourceSyncService.contextPrefix(
                          title: document.title, headingPath: document.heading
                      )
                else { return document.text }
                return prefix + "\n\n" + document.text
            }
            let vectors = try await lmStudio.embed(texts: texts, model: model)
            let queryVector = try await lmStudio.embed(text: query, model: model)
            let scored = vectors.map { cosine(queryVector, $0) }
            let order = scored.enumerated().sorted { $0.element > $1.element }
            let position = (order.firstIndex { $0.offset == 0 } ?? 0) + 1
            return (position, scored[0])
        }

        let plain = try await rank(withPrefix: false)
        let prefixed = try await rank(withPrefix: true)

        print("""
        контекстный префикс на модели \(model):
          без префикса: целевой фрагмент на месте \(plain.position), близость \(String(format: "%.3f", plain.best))
          с префиксом:  целевой фрагмент на месте \(prefixed.position), близость \(String(format: "%.3f", prefixed.best))
        """)

        XCTAssertLessThan(
            prefixed.position, plain.position,
            "фрагмент без слов запроса обязан подняться, когда перед ним ушёл его раздел"
        )
        XCTAssertGreaterThan(
            prefixed.best, plain.best,
            "близость к запросу обязана вырасти — ради этого префикс и добавляется"
        )
    }
}
