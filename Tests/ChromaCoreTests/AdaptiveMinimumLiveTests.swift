import XCTest
@testable import ChromaCore

/// Нижняя граница размера чанка у адаптивной нарезки — замер на настоящем
/// наборе.
///
/// Отвечает на единственный вопрос, ради которого правка и делалась:
/// **находится ли ответ чаще**, если короткий блок приклеен к соседу.
/// Рассуждением на него ответить нельзя, поэтому здесь весь корпус целиком,
/// настоящая модель и настоящие вопросы с ответами.
///
/// Набор: `ru_rag_test_dataset` (страницы русской Википедии) плюс RuBQ 2.0,
/// откуда он собран, — в нём у вопроса есть текст ответа. Правильным считается
/// чанк, в котором ответ **есть дословно**: это то же, что делает стенд оценки
/// приложения с «фрагментами», и то же, что нужно агенту — получить
/// кусок, где ответ действительно написан.
///
///     CHROMA_IT=1 CHROMA_CORPUS=/путь/к/ru_rag_test_dataset-main \
///       swift test --filter AdaptiveMinimumLiveTests
final class AdaptiveMinimumLiveTests: XCTestCase {
    private var corpus = ""
    private var model = ""
    private var lmStudio: LMStudioClient!

    /// Сколько вопросов брать. Прогон — это два индекса корпуса целиком,
    /// то есть десятки тысяч векторов; предел держит проверку в разумных
    /// минутах, а не часах.
    private let questionLimit = 120

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CHROMA_IT"] == "1",
            "Живая проверка включается CHROMA_IT=1"
        )
        corpus = ProcessInfo.processInfo.environment["CHROMA_CORPUS"] ?? ""
        try XCTSkipUnless(!corpus.isEmpty, "Путь к набору задаётся CHROMA_CORPUS")
        lmStudio = try LMStudioClient(baseURLString: "http://localhost:1234")
        guard let models = try? await lmStudio.models(),
              let embedding = models.first(where: { $0.kind == .embedding })
        else { throw XCTSkip("LM Studio не отвечает или в нём нет модели эмбеддингов") }
        model = embedding.id
    }

    // MARK: - Набор

    private struct Question {
        let text: String
        let answer: String
        /// Файл, в котором ответ есть. Нужен, чтобы отбросить вопросы,
        /// ответ на которые лежит в нескольких статьях: у таких «правильный
        /// чанк» неоднозначен, и метрика по ним ничего не значит.
        let file: String
    }

    /// Вопросы, ответ на которые дословно есть ровно в одном файле корпуса.
    private func questions(files: [String: String]) throws -> [Question] {
        let url = URL(fileURLWithPath: corpus).appendingPathComponent("raw/RuBQ_2.0_test.json")
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw XCTSkip("Не читается \(url.path)") }

        var result: [Question] = []
        for item in raw {
            guard let text = item["question_text"] as? String,
                  let answer = (item["answer_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  // Короткий ответ («да», «1») совпадёт где угодно и измерит
                  // не поиск, а частоту слова.
                  answer.count >= 5
            else { continue }

            let matching = files.filter { $0.value.localizedCaseInsensitiveContains(answer) }
            guard matching.count == 1, let file = matching.first?.key else { continue }
            result.append(Question(text: text, answer: answer, file: file))
            if result.count >= questionLimit { break }
        }
        return result
    }

    private func corpusFiles() throws -> [String: String] {
        let folder = URL(fileURLWithPath: corpus).appendingPathComponent("files_2")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".txt") }
            .sorted()
        var result: [String: String] = [:]
        for name in names {
            guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            else { continue }
            result[name] = text
        }
        return result
    }

    // MARK: - Индекс

    private struct Indexed {
        var texts: [String] = []
        var files: [String] = []
        var vectors: [[Double]] = []
    }

    /// - Parameter rule: включено ли правило нижней границы. «Выключено» —
    /// это куски по блокам, как их отдавала нарезка до; настройкой
    ///   этого не изобразить, потому что `minChunkSize` не опускается ниже
    ///   тридцати двух знаков.
    private func index(
        files: [String: String], rule: Bool
    ) async throws -> Indexed {
        var configuration = ChunkingConfiguration(strategy: .adaptive)
        configuration.sizeUnit = .characters
        configuration.minChunkSize = 128
        let chunker = AdaptiveChunker(configuration: configuration)

        var indexed = Indexed()
        for (name, text) in files.sorted(by: { $0.key < $1.key }) {
            let texts = rule
                ? chunker.chunks(from: text).map(\.text)
                : chunker.blocks(from: text).flatMap { $0 }
            for piece in texts {
                indexed.texts.append(piece)
                indexed.files.append(name)
            }
        }
        // Пакетами: тысячи текстов одним запросом модель не берёт.
        for start in stride(from: 0, to: indexed.texts.count, by: 256) {
            let slice = Array(indexed.texts[start..<min(start + 256, indexed.texts.count)])
            indexed.vectors += try await lmStudio.embed(texts: slice, model: model)
        }
        return indexed
    }

    /// Векторы приводятся к единичной длине **один раз**, дальше похожесть —
    /// это скалярное произведение.
    ///
    /// Не микрооптимизация: сравнений здесь сто двадцать запросов на десять
    /// тысяч чанков, то есть больше миллиарда умножений на индекс. Считать
    /// при каждом из них ещё и две длины значит утроить работу — первая
    /// редакция стенда на этом и встала.
    private func normalised(_ vectors: [[Double]]) -> [[Double]] {
        vectors.map { vector in
            let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
            guard length > 0 else { return vector }
            return vector.map { $0 / length }
        }
    }

    private func dot(_ left: [Double], _ right: [Double]) -> Double {
        var sum = 0.0
        for index in left.indices where index < right.count { sum += left[index] * right[index] }
        return sum
    }

    private struct Score {
        var atOne = 0, atThree = 0, atFive = 0, atTen = 0
        var reciprocal = 0.0
        var asked = 0

        func line(_ title: String) -> String {
            let total = Double(max(1, asked))
            return String(
                format: "%@  R@1 %.3f  R@3 %.3f  R@5 %.3f  R@10 %.3f  MRR %.3f",
                title, Double(atOne) / total, Double(atThree) / total,
                Double(atFive) / total, Double(atTen) / total, reciprocal / total
            )
        }
    }

    private func score(
        _ indexed: Indexed, questions: [Question], queries: [[Double]]
    ) -> Score {
        var score = Score()
        let chunks = normalised(indexed.vectors)
        for (position, question) in questions.enumerated() {
            score.asked += 1
            let query = queries[position]
            let ranked = chunks.indices
                .map { (index: $0, similarity: dot(query, chunks[$0])) }
                .sorted { $0.similarity > $1.similarity }
                .prefix(10)

            for (rank, candidate) in ranked.enumerated() {
                guard indexed.files[candidate.index] == question.file,
                      indexed.texts[candidate.index].localizedCaseInsensitiveContains(question.answer)
                else { continue }
                if rank == 0 { score.atOne += 1 }
                if rank < 3 { score.atThree += 1 }
                if rank < 5 { score.atFive += 1 }
                score.atTen += 1
                score.reciprocal += 1.0 / Double(rank + 1)
                break
            }
        }
        return score
    }

    // MARK: - Прогон

    func testTheMinimumBlockRuleIsMeasuredOnTheWholeCorpus() async throws {
        let files = try corpusFiles()
        try XCTSkipUnless(files.count > 100, "В корпусе всего \(files.count) файлов")
        let asked = try questions(files: files)
        try XCTSkipUnless(asked.count >= 30, "Вопросов с однозначным ответом: \(asked.count)")

        let queries = normalised(try await lmStudio.embed(texts: asked.map(\.text), model: model))

        // «Было» — правило выключено, ровно как до.
        let before = try await index(files: files, rule: false)
        // «Стало» — заводские 128 знаков.
        let after = try await index(files: files, rule: true)

        // Считается **по разу**: каждый прогон — это больше миллиарда
        // умножений, и лишний вызов ради красивой строки стоит минут.
        let old = score(before, questions: asked, queries: queries)
        let new = score(after, questions: asked, queries: queries)

        let short = { (indexed: Indexed) in indexed.texts.filter { $0.count < 128 }.count }
        print("""

        ──: нижняя граница блока у адаптивной нарезки ──
        файлов \(files.count), вопросов \(asked.count), модель \(model)
        чанков было \(before.texts.count) (короче 128: \(short(before)))
        чанков стало \(after.texts.count) (короче 128: \(short(after)))
        \(old.line("было "))
        \(new.line("стало"))

        """)

        // Коротких чанков обязано стать заметно меньше — это прямое следствие
        // правки, и если его нет, правка не сработала вовсе.
        XCTAssertLessThan(short(after), short(before) / 2)
        // А качество — не упасть. Порог с запасом на шум выборки: измеряется
        // сотня вопросов, и требовать строгого роста от одной правки нарезки
        // значило бы требовать от неё невозможного.
        XCTAssertGreaterThanOrEqual(
            new.reciprocal, old.reciprocal - 0.02 * Double(old.asked),
            "MRR просел: было \(old.line("")), стало \(new.line(""))"
        )
    }
}
