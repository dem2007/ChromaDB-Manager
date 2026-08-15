import XCTest
@testable import ChromaCore

/// Измеренный предел чтения модели эмбеддинга.
final class EmbeddingInputProbeTests: XCTestCase {
    /// Модель, которая молча читает только первые `limit` знаков — ровно так
    /// ведёт себя настоящая: отказа нет, вектор нормальной длины, а хвост
    /// не закодирован.
    private func truncating(at limit: Int?) -> (String) async throws -> [Double] {
        { text in
            let seen = limit.map { String(text.prefix($0)) } ?? text
            // Вектор — псевдослучайная функция **всего прочитанного текста**:
            // изменился вход хоть на знак — вектор другой, совпал вход —
            // вектор тот же. Ровно это свойство проба и ищет.
            //
            // Не гистограмма символов: у неё вектор префикса сходится
            // с вектором целого задолго до обрыва — просто потому, что
            // распределение букв в длинном тексте стабилизируется. Настоящая
            // модель ведёт себя резко (замер: 0.5158 на префиксе, 1.0000
            // после обрыва), и фейк обязан быть таким же, иначе он проверяет
            // не то.
            var state = UInt64(2_166_136_261)
            for byte in seen.utf8 {
                state = (state ^ UInt64(byte)) &* 1_099_511_628_211
            }
            return (0..<64).map { index in
                var local = state &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15
                local ^= local >> 30
                local = local &* 0xBF58_476D_1CE4_E5B9
                local ^= local >> 27
                return Double(local % 2000) / 1000 - 1
            }
        }
    }

    func testTheProbeFindsWhereTheModelStopsReading() async {
        for limit in [8000, 12_000, 21_400] {
            let measured = await EmbeddingInputProbe.measure(embed: truncating(at: limit))
            guard let measured else {
                XCTFail("предел \(limit) не найден вовсе")
                continue
            }
            // Проба ищет с точностью до пятисот знаков — этого хватает,
            // чтобы решать «влезет или нет», и не стоит лишних вызовов.
            XCTAssertLessThanOrEqual(
                abs(measured - limit), 600,
                "предел \(limit): измерено \(measured)"
            )
        }
    }

    /// Модель читает всё — обрыва нет, и выдумывать его нельзя.
    func testAModelThatReadsEverythingHasNoLimit() async {
        let measured = await EmbeddingInputProbe.measure(embed: truncating(at: nil))
        XCTAssertNil(measured)
    }

    /// Модель молчит — проба не возвращает выдуманное число.
    func testASilentModelYieldsNothing() async {
        struct Refusal: Error {}
        let measured = await EmbeddingInputProbe.measure(embed: { _ in throw Refusal() })
        XCTAssertNil(measured)
    }

    /// Сбой **посреди** бисекции — это «не измерилось», а не «предел равен
    /// тому, где мы сейчас находимся».
    ///
    /// Вернуть текущее `high` значило бы записать в файл завышенное число
    /// и пропускать в базу ровно те чанки, ради которых проверка заводилась.
    func testAFailureMidwayYieldsNothingRatherThanAGuess() async {
        struct Refusal: Error {}
        let calls = Counter()
        let truncate = truncating(at: 8000)
        let measured = await EmbeddingInputProbe.measure { text in
            // Первые три вызова честные — на них проба сужает диапазон,
            // — а дальше модель замолкает.
            if await calls.bump() > 3 { throw Refusal() }
            return try await truncate(text)
        }
        XCTAssertNil(measured, "на сбое посреди замера предел выдумывать нельзя")
    }

    private actor Counter {
        private var value = 0
        func bump() -> Int { value += 1; return value }
    }

    /// Текст пробы обязан быть разным от абзаца к абзацу: на однородном
    /// повторе вектор префикса совпадает с вектором целого просто так,
    /// и проба объявила бы обрывом первую тысячу знаков.
    func testTheSampleIsNotOneRepeatedPhrase() {
        let sample = EmbeddingInputProbe.sample(ofLength: 20_000)
        XCTAssertEqual(sample.count, 20_000)
        let paragraphs = sample.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        XCTAssertGreaterThan(paragraphs.count, 50)
        XCTAssertEqual(Set(paragraphs).count, paragraphs.count, "абзацы повторяются дословно")
    }

    /// Предел ищется только у длинного текста: короткие чанки не должны
    /// стоить ни одного лишнего вызова модели.
    func testShortTextsAreBelowTheSuspiciousThreshold() {
        // Заводской максимум чанка — 2048 «токенов» по оценке приложения,
        // это 7168 знаков; порог обязан быть ниже, иначе проверка не сработает
        // там, где настройки её и требуют.
        XCTAssertLessThan(EmbeddingInputProbe.suspiciousCharacters, 7168)
    }
}

/// разбор — исходы пробы и признак свежести измеренного.
final class EmbeddingLimitFreshnessTests: XCTestCase {
    /// Вектор — псевдослучайная функция всего прочитанного текста, как
    /// у фейка выше: совпал вход — совпал вектор.
    static func vector(of text: String, limit: Int?) -> [Double] {
        let seen = limit.map { String(text.prefix($0)) } ?? text
        var state = UInt64(2_166_136_261)
        for byte in seen.utf8 {
            state = (state ^ UInt64(byte)) &* 16_777_619
        }
        var values: [Double] = []
        for _ in 0..<8 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            values.append(Double(state % 1000) / 1000)
        }
        return values
    }

    /// «Не ответила» и «предела не нашлось» — разные исходы, и по первому
    /// пробовать надо снова, а по второму нет.
    func testFailureAndNoLimitAreDifferentOutcomes() async {
        struct Refusal: Error {}
        let failed = await EmbeddingInputProbe.measureOutcome { _ in throw Refusal() }
        XCTAssertEqual(failed, .failed)

        // Модель читает всё: вектор половины отличается от вектора целого.
        let noLimit = await EmbeddingInputProbe.measureOutcome { text in
            Self.vector(of: text, limit: nil)
        }
        XCTAssertEqual(noLimit, .noLimitFound)
    }

    /// Сорвавшаяся проба не помечает модель как измеренную: как только
    /// LM Studio отвечает снова, предел меряется, а не считается неизвестным
    /// до перезапуска приложения.
    func testAFailedProbeIsRetriedRatherThanRemembered() async {
        let embeddings = FlakyEmbeddings(limit: 8000)
        let binding = ModelBindingService()

        let first = await binding.measuredInputLimit(of: "e5", embeddings: embeddings)
        XCTAssertNil(first, "пока модель молчит, предела нет")

        await embeddings.recover()
        let second = await binding.measuredInputLimit(of: "e5", embeddings: embeddings)
        XCTAssertNotNil(second, "ответившая модель обязана быть измерена")
        XCTAssertEqual(second.map { abs($0 - 8000) < 600 }, true, "предел около 8000, получено \(second ?? -1)")
    }
}

/// Молчит, пока её не починят.
private actor FlakyEmbeddings: EmbeddingProvider {
    private var answers = false
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func recover() { answers = true }

    func embed(texts: [String], model: String) async throws -> [[Double]] {
        struct Silence: Error {}
        guard answers else { throw Silence() }
        return texts.map { EmbeddingLimitFreshnessTests.vector(of: $0, limit: limit) }
    }
}
