import XCTest
@testable import ChromaCore

/// отчёт: таблица «вариант × метрика», детализация по запросам,
/// экспорт и сравнение двух прогонов.
final class EvaluationReportTests: XCTestCase {

    // MARK: - Фикстуры

    private func variant(_ name: String, nResults: Int = 5) -> EvaluationVariant {
        EvaluationVariant(
            name: name, collectionID: "c", collectionName: "коллекция",
            model: "модель", metric: .cosine, nResults: nResults,
            profile: SearchProfile(collectionName: "коллекция")
        )
    }

    private func query(_ text: String, relevant: String) -> EvaluationQuery {
        EvaluationQuery(
            text: text,
            fragments: [ExpectedFragment(fragment: relevant, grade: .relevant)]
        )
    }

    private func hits(_ texts: [String]) -> [EvaluationHit] {
        texts.enumerated().map {
            EvaluationHit(id: "d\($0.offset)", text: $0.element, distance: nil, position: $0.offset + 1)
        }
    }

    /// Запрос, у которого размечено только «нерелевантен», найти нечего —
    /// и «не нашёл» обвиняло бы вариант в том, чего никто не объявлял
    /// находимым. Метрики такой запрос пропускают уже давно; детализация
    /// считала его провалом — найдено на живом прогоне.
    func testAQueryMarkedOnlyIrrelevantIsUnmarkedRatherThanMissed() {
        let hopeless = EvaluationQuery(
            text: "шлюз удалённого доступа",
            fragments: [ExpectedFragment(fragment: "сервисы минцифры", grade: .irrelevant)]
        )
        let a = variant("A")
        let run = EvaluationRun(
            name: "прогон", querySetID: UUID(), querySetName: "набор",
            queries: [hopeless], variants: [a],
            results: [
                EvaluationResult(queryID: hopeless.id, variantID: a.id,
                                 hits: hits(["Сервисы Минцифры России", "мимо"])),
            ],
            isComplete: true
        )
        XCTAssertEqual(EvaluationReport.queryRows(run: run)[0].outcomes[0], .unmarked)
    }

    // MARK: - Настраиваемое k

    /// «Значение k настраивается» — требование ТЗ, которое до сверки DoD
    /// не выполнялось: в коде стояли зашитые 5 и 10.
    func testTheKsAreCleanedUpRatherThanTakenAsTyped() {
        XCTAssertEqual(EvaluationMetrics.sanitisedKs([10, 3, 3, 5]), [3, 5, 10])
        XCTAssertEqual(EvaluationMetrics.sanitisedKs([0, -2, 4]), [4])
        // Пустой список — не пустая таблица: экран без единой метрики
        // выглядит поломкой, а не настройкой.
        XCTAssertEqual(EvaluationMetrics.sanitisedKs([]), EvaluationMetrics.defaultKs)
        XCTAssertEqual(EvaluationMetrics.sanitisedKs([0]), EvaluationMetrics.defaultKs)
    }

    /// Заданные k доходят до таблицы, а не подменяются умолчанием.
    func testTheTableUsesTheKsItWasGiven() {
        let metrics = EvaluationMetrics.compute(run: runWithOneVariant(), set: nil, ks: [3])
        let table = EvaluationReport.table(metrics, ks: [3])
        XCTAssertTrue(table.columns.contains { $0.key == "hit@3" })
        XCTAssertFalse(table.columns.contains { $0.key == "hit@5" })
    }

    // MARK: - Формат сравнения

    /// «0.01 → 0.00 (-0.00)» — это две миллисекунды, но читается как сломанный
    /// ноль. Задержка показывается миллисекундами, и изменение, которого на
    /// этой точности не видно, не показывается вовсе — и не красится.
    func testLatencyDeltasAreShownInMilliseconds() {
        let delta = EvaluationReport.MetricDelta(
            key: "search", title: "поиск", direction: .lowerIsBetter,
            before: 0.0052, after: 0.0031, scale: .seconds
        )
        XCTAssertEqual(delta.beforeText, "5 мс")
        XCTAssertEqual(delta.afterText, "3 мс")
        XCTAssertEqual(delta.changeText, "-2 мс")
        XCTAssertEqual(delta.improved, true)

        // Разряды разделяются так же, как в таблице: «5 473 мс», а не «5473».
        let long = EvaluationReport.MetricDelta(
            key: "search", title: "поиск", direction: .lowerIsBetter,
            before: 2.386, after: 5.473, scale: .seconds
        )
        XCTAssertTrue(long.afterText.contains("473"), long.afterText)
        XCTAssertNotEqual(long.afterText, "5473 мс", "разряды должны разделяться")
        XCTAssertEqual(long.changeText?.first, "+")
        XCTAssertEqual(long.improved, false, "поиск стал медленнее")

        let invisible = EvaluationReport.MetricDelta(
            key: "search", title: "поиск", direction: .lowerIsBetter,
            before: 0.00312, after: 0.00308, scale: .seconds
        )
        XCTAssertNil(invisible.changeText)
        XCTAssertNil(invisible.improved, "изменение, которого не видно, — не вывод")
    }

    /// Доли остаются долями: два знака и знак перед числом.
    func testRatioDeltasKeepTwoDecimals() {
        let delta = EvaluationReport.MetricDelta(
            key: "mrr", title: "MRR", direction: .higherIsBetter,
            before: 0.667, after: 1.0
        )
        XCTAssertEqual(delta.beforeText, "0.67")
        XCTAssertEqual(delta.changeText, "+0.33")
    }

    // MARK: - Оговорка о длине результатов

    /// Вариант, отдающий раздел целиком, содержит любой фрагмент из этого
    /// раздела — его hit rate растёт не от качества поиска, а от размера
    /// ответа. Отчёт обязан это назвать.
    func testVariantsWithVeryDifferentResultLengthsGetACaveat() {
        let long = variant("Иерархическая")
        let short = variant("LLM")
        let q = query("запрос", relevant: "нужный текст")
        let run = EvaluationRun(
            name: "прогон", querySetID: UUID(), querySetName: "набор",
            queries: [q], variants: [long, short],
            results: [
                EvaluationResult(queryID: q.id, variantID: long.id,
                                 hits: hits([String(repeating: "а", count: 7000)])),
                EvaluationResult(queryID: q.id, variantID: short.id,
                                 hits: hits([String(repeating: "б", count: 1700)])),
            ],
            isComplete: true
        )
        let caveat = EvaluationReport.lengthCaveat(run)
        XCTAssertNotNil(caveat)
        XCTAssertTrue(caveat?.contains("Иерархическая") == true)
        XCTAssertTrue(caveat?.contains("LLM") == true)
    }

    /// Варианты сопоставимой длины оговорки не получают: предупреждение,
    /// висящее всегда, читать перестают.
    func testComparableLengthsGetNoCaveat() {
        let a = variant("A")
        let b = variant("B")
        let q = query("запрос", relevant: "нужный текст")
        let run = EvaluationRun(
            name: "прогон", querySetID: UUID(), querySetName: "набор",
            queries: [q], variants: [a, b],
            results: [
                EvaluationResult(queryID: q.id, variantID: a.id,
                                 hits: hits([String(repeating: "а", count: 1000)])),
                EvaluationResult(queryID: q.id, variantID: b.id,
                                 hits: hits([String(repeating: "б", count: 1400)])),
            ],
            isComplete: true
        )
        XCTAssertNil(EvaluationReport.lengthCaveat(run))
    }

    // MARK: - Подсветка лучшего

    /// Задержка — единственный столбец, где лучше меньше. Общее правило
    /// «подсветить наибольшее» хвалило бы самый медленный вариант.
    func testTheFastestWinsTheLatencyColumnAndTheHighestWinsTheRest() {
        XCTAssertEqual(
            EvaluationReport.bestIndices([0.2, 0.9, 0.5], direction: .higherIsBetter, comparable: true),
            [1]
        )
        XCTAssertEqual(
            EvaluationReport.bestIndices([0.2, 0.9, 0.5], direction: .lowerIsBetter, comparable: true),
            [0]
        )
    }

    /// Равенство — не победа. Столбец, в котором все значения одинаковы,
    /// не подсвечивается вовсе: «лучший из одинаковых» человек прочтёт
    /// как вывод, которого нет.
    func testAColumnWhereEverythingIsEqualHighlightsNothing() {
        XCTAssertTrue(
            EvaluationReport.bestIndices([0.5, 0.5, 0.5], direction: .higherIsBetter, comparable: true).isEmpty
        )
    }

    /// При равенстве лучших подсвечиваются оба: выбрать «первого из равных»
    /// значило бы приписать порядку смысл, которого у него нет.
    func testTiedBestValuesAreBothHighlighted() {
        XCTAssertEqual(
            EvaluationReport.bestIndices([0.9, 0.1, 0.9], direction: .higherIsBetter, comparable: true),
            [0, 2]
        )
    }

    /// «Неприменимо» не побеждает и не проигрывает — оно вне сравнения.
    func testAnInapplicableValueNeverWins() {
        XCTAssertEqual(
            EvaluationReport.bestIndices([nil, 0.3], direction: .higherIsBetter, comparable: true),
            []
        )
        XCTAssertEqual(
            EvaluationReport.bestIndices([nil, 0.3, 0.7], direction: .higherIsBetter, comparable: true),
            [2]
        )
    }

    /// Один вариант — это не «лучший», это единственный.
    func testASingleVariantIsNotHighlighted() {
        let metrics = EvaluationMetrics.compute(run: runWithOneVariant(), set: nil)
        let table = EvaluationReport.table(metrics)
        XCTAssertFalse(table.highlightsBest)
        XCTAssertTrue(table.columns.allSatisfy { $0.cells.allSatisfy { !$0.isBest } })
    }

    // MARK: - Детализация по запросам

    /// Четыре исхода, и «не нашёл» с «не размечено» путать нельзя: первое —
    /// вывод о варианте, второе — о том, что вывода пока нет.
    func testTheFourOutcomesAreDistinguished() {
        let good = query("запрос 1", relevant: "нужный текст")
        let unmarkedQuery = EvaluationQuery(text: "запрос 2")
        let a = variant("A")
        let b = variant("B")
        let run = EvaluationRun(
            name: "прогон", querySetID: UUID(), querySetName: "набор",
            queries: [good, unmarkedQuery], variants: [a, b],
            results: [
                // A нашёл нужное вторым, B не нашёл вовсе.
                EvaluationResult(queryID: good.id, variantID: a.id,
                                 hits: hits(["мимо", "вот нужный текст здесь"])),
                EvaluationResult(queryID: good.id, variantID: b.id,
                                 hits: hits(["мимо", "тоже мимо"])),
                // Второй запрос не размечен вовсе; у B ячейка сбойная.
                EvaluationResult(queryID: unmarkedQuery.id, variantID: a.id, hits: hits(["что-то"])),
                EvaluationResult(queryID: unmarkedQuery.id, variantID: b.id,
                                 hits: [], failure: "модель не ответила"),
            ],
            isComplete: true
        )
        let rows = EvaluationReport.queryRows(run: run)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].outcomes[0], .found(rank: 2))
        // «Не нашёл» — среди выдачи есть размеченное, релевантного нет.
        XCTAssertEqual(rows[0].outcomes[1], .missed)
        XCTAssertEqual(rows[1].outcomes[0], .unmarked)
        guard case .failed(let reason) = rows[1].outcomes[1] else {
            return XCTFail("сбой ячейки — не «ничего не нашёл»")
        }
        XCTAssertEqual(reason, "модель не ответила")
    }

    /// Запрос, на котором варианты повели себя одинаково, в список
    /// «разошлись сильнее всего» не попадает: там ничего не видно.
    func testOnlyQueriesWhereVariantsDisagreeAreListed() {
        let same = query("одинаково", relevant: "нужное")
        let differs = query("по-разному", relevant: "нужное")
        let a = variant("A")
        let b = variant("B")
        let run = EvaluationRun(
            name: "прогон", querySetID: UUID(), querySetName: "набор",
            queries: [same, differs], variants: [a, b],
            results: [
                EvaluationResult(queryID: same.id, variantID: a.id, hits: hits(["нужное"])),
                EvaluationResult(queryID: same.id, variantID: b.id, hits: hits(["нужное"])),
                EvaluationResult(queryID: differs.id, variantID: a.id, hits: hits(["нужное"])),
                EvaluationResult(queryID: differs.id, variantID: b.id, hits: hits(["мимо", "мимо"])),
            ],
            isComplete: true
        )
        let rows = EvaluationReport.queryRows(run: run)
        let divergent = EvaluationReport.mostDivergent(rows)
        XCTAssertEqual(divergent.map(\.text), ["по-разному"])
        XCTAssertFalse(rows.first { $0.text == "одинаково" }?.variantsDisagree ?? true)
    }

    // MARK: - Сравнение двух прогонов

    /// Варианты сопоставляются по имени: собранный заново вариант получает
    /// новый UUID, и сравнение по идентификатору показало бы два
    /// непересекающихся набора.
    func testVariantsAreMatchedByNameNotIdentity() {
        let before = runNamed("до", variantName: "A", foundAtRank: 3)
        let after = runNamed("после", variantName: "A", foundAtRank: 1)
        XCTAssertNotEqual(before.variants[0].id, after.variants[0].id)

        let comparison = EvaluationReport.compare(before: before, after: after)
        XCTAssertEqual(comparison.variants.map(\.variantName), ["A"])
        XCTAssertTrue(comparison.onlyInBefore.isEmpty)
        XCTAssertTrue(comparison.onlyInAfter.isEmpty)

        let mrr = comparison.variants[0].deltas.first { $0.key == "mrr" }
        XCTAssertEqual(mrr?.improved, true, "позиция 3 → 1 — это улучшение")
    }

    /// Вариант, исчезнувший во втором прогоне, обязан быть назван: сравнение,
    /// умолчавшее об этом, читается как сравнение равного с равным.
    func testVariantsMissingFromEitherRunAreNamed() {
        let before = runNamed("до", variantName: "старый", foundAtRank: 1)
        let after = runNamed("после", variantName: "новый", foundAtRank: 1)
        let comparison = EvaluationReport.compare(before: before, after: after)
        XCTAssertTrue(comparison.variants.isEmpty)
        XCTAssertEqual(comparison.onlyInBefore, ["старый"])
        XCTAssertEqual(comparison.onlyInAfter, ["новый"])
    }

    /// Ничего не изменилось — это не «стало лучше» и не «стало хуже».
    func testAnUnchangedMetricHasNoVerdict() {
        let before = runNamed("до", variantName: "A", foundAtRank: 1)
        let after = runNamed("после", variantName: "A", foundAtRank: 1)
        let comparison = EvaluationReport.compare(before: before, after: after)
        let mrr = comparison.variants[0].deltas.first { $0.key == "mrr" }
        XCTAssertEqual(mrr?.change, 0)
        XCTAssertNil(mrr?.improved)
    }

    // MARK: - Экспорт

    func testMarkdownCarriesTheVariantParameters() {
        let run = runWithOneVariant()
        let text = EvaluationExport.markdown(run: run)
        XCTAssertTrue(text.contains("# Отчёт прогона"), text)
        XCTAssertTrue(text.contains("## Варианты"), text)
        XCTAssertTrue(text.contains("Коллекция: `коллекция`"), text)
        XCTAssertTrue(text.contains("n_results: 5"), text)
        XCTAssertTrue(text.contains("источники:"), text)
        XCTAssertTrue(text.contains("| Метрика |"), text)
        XCTAssertTrue(text.contains("## Все запросы"), text)
    }

    /// Неполный прогон помечается в самом файле: выгрузка живёт отдельно
    /// от приложения, и предупреждение с экрана с ней не уезжает.
    func testAnIncompleteRunSaysSoInTheFile() {
        var run = runWithOneVariant()
        run.isComplete = false
        run.note = "отменён на середине"
        let text = EvaluationExport.markdown(run: run)
        XCTAssertTrue(text.contains("Прогон неполный"), text)
        XCTAssertTrue(text.contains("отменён на середине"), text)
    }

    /// Вертикальная черта в тексте запроса разломала бы таблицу.
    func testAPipeInAQueryDoesNotBreakTheTable() {
        XCTAssertEqual(EvaluationExport.escaped("a|b"), "a\\|b")
        XCTAssertEqual(EvaluationExport.escaped("две\nстроки"), "две строки")
    }

    /// В JSON «неприменимо» обязано остаться `null`, а не стать нулём:
    /// иначе чужой скрипт прочитает «вариант ничего не нашёл».
    func testJSONKeepsInapplicableAsNull() throws {
        let data = try EvaluationExport.json(run: runWithOneVariant())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let metrics = try XCTUnwrap(object["metrics"] as? [[String: Any]])
        let recall = try XCTUnwrap(metrics.first { ($0["key"] as? String) == "recall@5" })
        let values = try XCTUnwrap(recall["values"] as? [[String: Any]])
        // Эталон задан фрагментом, а не списком id — полного множества
        // релевантных нет, и recall честно неприменим.
        XCTAssertTrue(values[0]["value"] is NSNull, "\(values[0])")
        XCTAssertEqual(values[0]["text"] as? String, "—")
    }

    func testJSONNamesTheDirectionOfEachMetric() throws {
        let data = try EvaluationExport.json(run: runWithOneVariant())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metrics = try XCTUnwrap(object["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.first { ($0["key"] as? String) == "mrr" }?["betterIs"] as? String, "higher")
        XCTAssertEqual(metrics.first { ($0["key"] as? String) == "search" }?["betterIs"] as? String, "lower")
    }

    // MARK: - Общие фикстуры

    private func runWithOneVariant() -> EvaluationRun {
        let q = query("запрос", relevant: "нужный текст")
        let a = variant("A")
        return EvaluationRun(
            name: "прогон", querySetID: UUID(), querySetName: "набор",
            queries: [q], variants: [a],
            results: [
                EvaluationResult(
                    queryID: q.id, variantID: a.id,
                    hits: hits(["вот нужный текст"]), searchSeconds: 0.1
                ),
            ],
            isComplete: true
        )
    }

    private func runNamed(_ name: String, variantName: String, foundAtRank rank: Int) -> EvaluationRun {
        let q = query("запрос", relevant: "нужный текст")
        let a = variant(variantName)
        var texts = Array(repeating: "мимо", count: rank - 1)
        texts.append("вот нужный текст")
        return EvaluationRun(
            name: name, querySetID: UUID(), querySetName: "набор",
            queries: [q], variants: [a],
            results: [
                EvaluationResult(queryID: q.id, variantID: a.id, hits: hits(texts), searchSeconds: 0.1),
            ],
            isComplete: true
        )
    }
}
