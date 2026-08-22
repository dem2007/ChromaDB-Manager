import XCTest
@testable import ChromaCore

/// §E5 — a chat model reorders the final list.
final class RerankerTests: XCTestCase {
    // MARK: - The prompt

    func testThePromptNumbersTheFragmentsFromOne() {
        let prompt = Reranker.prompt(
            template: "", query: "как настроить насос",
            documents: ["первый фрагмент", "второй фрагмент"]
        )
        XCTAssertTrue(prompt.contains("1. первый фрагмент"), prompt)
        XCTAssertTrue(prompt.contains("2. второй фрагмент"), prompt)
        XCTAssertTrue(prompt.contains("как настроить насос"))
    }

    func testNewlinesInsideAFragmentDoNotBreakTheNumbering() {
        let prompt = Reranker.prompt(
            template: "", query: "з", documents: ["строка\nещё строка", "второй"]
        )
        XCTAssertTrue(prompt.contains("1. строка ещё строка"), prompt)
        XCTAssertTrue(prompt.contains("2. второй"), prompt)
    }

    func testAnEmptyTemplateFallsBackToTheDefault() {
        let blank = Reranker.prompt(template: "   \n ", query: "з", documents: ["а"])
        let none = Reranker.prompt(template: "", query: "з", documents: ["а"])
        XCTAssertEqual(blank, none)
        XCTAssertTrue(blank.contains("оценку от 0 до 1"))
    }

    func testACustomTemplateIsUsedAsWritten() {
        let prompt = Reranker.prompt(
            template: "ЗАПРОС={query} СПИСОК={documents}", query: "кран", documents: ["текст"]
        )
        XCTAssertEqual(prompt, "ЗАПРОС=кран СПИСОК=1. текст")
    }

    // MARK: - Reading the answer

    func testAWellFormedAnswerIsRead() throws {
        let verdicts = try Reranker.verdicts(
            from: #"{"ranking":[{"index":2,"score":0.9},{"index":1,"score":0.2}]}"#, count: 2
        )
        XCTAssertEqual(verdicts.map(\.index), [2, 1])
        XCTAssertEqual(verdicts.first?.score, 0.9)
    }

    /// A schema guarantees the shape of the answer, not that the numbers in it
    /// are the ones we asked about.
    func testInventedRepeatedAndOutOfRangeIndicesAreDropped() throws {
        let verdicts = try Reranker.verdicts(
            from: #"{"ranking":[{"index":99,"score":1},{"index":2,"score":0.8},{"index":2,"score":0.1},{"index":0,"score":0.5}]}"#,
            count: 3
        )
        XCTAssertEqual(verdicts.map(\.index), [2])
    }

    func testAnIntegerScoreIsAccepted() throws {
        let verdicts = try Reranker.verdicts(from: #"{"ranking":[{"index":1,"score":1}]}"#, count: 1)
        XCTAssertEqual(verdicts.first?.score, 1)
    }

    func testProseInsteadOfJSONIsAnError() {
        XCTAssertThrowsError(try Reranker.verdicts(from: "Первый фрагмент лучше.", count: 2))
    }

    func testAnAnswerAboutNothingWeAskedIsAnError() {
        XCTAssertThrowsError(
            try Reranker.verdicts(from: #"{"ranking":[{"index":42,"score":1}]}"#, count: 3)
        ) { error in
            XCTAssertEqual(error as? RerankError, .nothingUsable)
        }
    }

    // MARK: - Applying the order

    func testTheListIsReorderedByScore() {
        let items = ["а", "б", "в"]
        let order = Reranker.reordered(items, by: [
            .init(index: 1, score: 0.1), .init(index: 2, score: 0.9), .init(index: 3, score: 0.5),
        ])
        XCTAssertEqual(order, ["б", "в", "а"])
    }

    /// A model that answered about three of twenty has not said the other
    /// seventeen are irrelevant — it has said nothing about them.
    func testWhatTheModelDidNotMentionKeepsItsPlaceAtTheEnd() {
        let items = ["а", "б", "в", "г"]
        let order = Reranker.reordered(items, by: [.init(index: 3, score: 0.9)])
        XCTAssertEqual(order, ["в", "а", "б", "г"])
    }

    func testEqualScoresKeepTheOrderTheModelWasGiven() {
        let items = ["а", "б", "в"]
        let order = Reranker.reordered(items, by: [
            .init(index: 3, score: 0.5), .init(index: 1, score: 0.5), .init(index: 2, score: 0.5),
        ])
        XCTAssertEqual(order, ["а", "б", "в"])
    }

    func testAnEmptyVerdictListLeavesTheOrderAlone() {
        XCTAssertEqual(Reranker.reordered(["а", "б"], by: []), ["а", "б"])
    }

    // MARK: - The schema and the cap

    func testTheSchemaDemandsIndexAndScore() {
        let value = Reranker.schema.requestValue()
        let json = value["json_schema"] as? [String: Any]
        XCTAssertEqual(json?["strict"] as? Bool, true)
        let schema = json?["schema"] as? [String: Any]
        let ranking = (schema?["properties"] as? [String: Any])?["ranking"] as? [String: Any]
        let item = ranking?["items"] as? [String: Any]
        XCTAssertEqual(item?["required"] as? [String], ["index", "score"])
    }

    func testTheCapIsTheOneTheSectionFixes() {
        XCTAssertEqual(Reranker.maximumCandidates, 20)
    }

    // MARK: - Бюджет промпта

    /// Ничего не известно про контекст — ничего и не выдумываем.
    func testWithoutAKnownContextNothingIsCut() {
        let documents = [String(repeating: "а", count: 100_000), "коротко"]
        let fitted = Reranker.fit(
            documents: documents, query: "з", template: "", contextTokens: nil
        )
        XCTAssertEqual(fitted.documents, documents)
        XCTAssertTrue(fitted.isUnchanged)
        XCTAssertNil(fitted.note)
    }

    func testWhatAlreadyFitsIsLeftAlone() {
        let documents = ["первый фрагмент", "второй фрагмент", "третий"]
        let fitted = Reranker.fit(
            documents: documents, query: "з", template: "", contextTokens: 8_192
        )
        XCTAssertEqual(fitted.documents, documents)
        XCTAssertTrue(fitted.isUnchanged)
    }

    /// Тот самый случай из лога: двадцать кандидатов на модели, загруженной
    /// с контекстом 8192, давали 14 105 токенов.
    func testTwentyLongCandidatesAreMadeToFitAContextOf8192() {
        let documents = (0..<20).map { _ in String(repeating: "я", count: 2_500) }
        let fitted = Reranker.fit(
            documents: documents, query: "как настроить резервное копирование",
            template: "", contextTokens: 8_192
        )
        XCTAssertFalse(fitted.isUnchanged)
        let prompt = Reranker.prompt(template: "", query: "как настроить резервное копирование", documents: fitted.documents)
        // Считаем тем же пессимистичным соотношением, каким считал бюджет:
        // мерить результат другой линейкой — значит не проверить ничего.
        let total = TokenEstimator.estimatedTokens(
            prompt, charactersPerToken: TokenEstimator.pessimisticCharactersPerToken
        ) + Reranker.answerReserve(for: fitted.documents.count)
        XCTAssertLessThanOrEqual(total, 8_192, "промпт вместе с ответом обязан влезать")
        XCTAssertNotNil(fitted.note)
        // Строка обязана называть и соотношение, и его происхождение: без
        // этого «укорочено 18» не объясняет, почему именно столько.
        XCTAssertTrue(fitted.note?.contains("симв/токен") ?? false, fitted.note ?? "")
        XCTAssertTrue(fitted.note?.contains("оценка по умолчанию") ?? false, fitted.note ?? "")

        let measured = Reranker.fit(
            documents: documents, query: "как настроить резервное копирование",
            template: "", contextTokens: 8_192, charactersPerToken: 2.8, ratioWasMeasured: true
        )
        XCTAssertTrue(measured.note?.contains("измерено") ?? false, measured.note ?? "")
        // Два знака после запятой, а не шесть: интерполяция `Double`
        // в локализованную строку печатает «2,770000».
        XCTAssertTrue(measured.note?.contains("2.80") ?? false, measured.note ?? "")
    }

    /// Место делится поровну, но не впустую: короткому фрагменту его доля
    /// не нужна целиком, и остаток достаётся длинному.
    func testAShortFragmentGivesItsUnusedShareAway() {
        XCTAssertEqual(Reranker.share(100, among: [10, 10, 500]), [10, 10, 80])
        XCTAssertEqual(Reranker.share(90, among: [30, 30, 30]), [30, 30, 30])
        // Всем не хватает — делится поровну.
        XCTAssertEqual(Reranker.share(30, among: [100, 100, 100]), [10, 10, 10])
    }

    func testAShortFragmentSurvivesWhileALongOneIsCut() {
        let short = "короткий фрагмент"
        let long = String(repeating: "я", count: 30_000)
        let fitted = Reranker.fit(
            documents: [short, long], query: "з", template: "", contextTokens: 8_192
        )
        XCTAssertEqual(fitted.documents.first, short, "короткому резать нечего")
        XCTAssertLessThan(fitted.documents[1].count, long.count)
        XCTAssertEqual(fitted.truncatedCount, 1)
        XCTAssertEqual(fitted.droppedCount, 0)
    }

    /// Судить по огрызку в три строки — не переранжирование: лучше спросить
    /// про меньшее число кандидатов, но целиком.
    func testWhenTheShareGetsTooThinTheCandidateCountDropsInstead() {
        let documents = (0..<20).map { _ in String(repeating: "я", count: 4_000) }
        let fitted = Reranker.fit(
            documents: documents, query: "з", template: "", contextTokens: 1_024
        )
        XCTAssertGreaterThan(fitted.droppedCount, 0)
        XCTAssertEqual(fitted.documents.count + fitted.droppedCount, 20)
        for document in fitted.documents {
            XCTAssertGreaterThanOrEqual(
                TokenEstimator.estimatedTokens(
                    document, charactersPerToken: TokenEstimator.pessimisticCharactersPerToken
                ),
                Reranker.minimumTokensPerDocument
            )
        }
    }

    /// Контекста нет вовсе — стадия обязана сказать это, а не отправить запрос
    /// и получить 400.
    func testAContextTooSmallForAnyPairIsRefusedNotSent() {
        let fitted = Reranker.fit(
            documents: ["раз", "два", "три"], query: "з", template: "", contextTokens: 200
        )
        XCTAssertTrue(fitted.documents.isEmpty)
        XCTAssertEqual(fitted.droppedCount, 3)
    }

    func testTheCostIsStatedBeforeItIsTurnedOn() {
        XCTAssertTrue(Reranker.costWarning.contains("один вызов чат-модели"))
    }
}

/// §E5 — the stage inside the pipeline.
final class RerankStageTests: XCTestCase {
    private actor SimpleDatabase: RetrievalDatabase {
        private let hits: [QueryHit]
        init(hits: [QueryHit]) { self.hits = hits }
        func query(
            collectionID: String, embedding: [Double], nResults: Int,
            filter: DocumentFilter?, includeEmbeddings: Bool
        ) async throws -> [QueryHit] { Array(hits.prefix(nResults)) }
        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] { [] }
        func documents(
            collectionID: String, matching filter: DocumentFilter, limit: Int
        ) async throws -> [DocumentRecord] { [] }
        func anyDocument(collectionID: String, matching filter: DocumentFilter) async throws -> Bool {
            let clause = ((try? filter.whereClause()) ?? nil)?["chunk_level"] as? [String: Any] ?? [:]
            return clause["$eq"] != nil
        }
    }

    private func hits(_ count: Int) -> [QueryHit] {
        (0..<count).map {
            QueryHit(id: "d\($0)", document: "документ \($0)", metadata: nil, distance: Double($0) / 100)
        }
    }

    private func profile(model: String = "чат") -> SearchProfile {
        var profile = SearchProfile(collectionName: "к")
        profile.rerankEnabled = true
        profile.rerankModel = model
        return profile
    }

    private func request() -> RetrievalRequest {
        RetrievalRequest(text: "запрос", collectionID: "col", collectionName: "к", nResults: 3)
    }

    func testTheModelsOrderIsApplied() async throws {
        let pipeline = RetrievalPipeline(
            database: SimpleDatabase(hits: hits(3)),
            embed: { _ in [1] },
            complete: { _, _, _ in #"{"ranking":[{"index":3,"score":0.9},{"index":1,"score":0.4}]}"# }
        )
        let outcome = try await pipeline.run(request(), profile: profile())
        XCTAssertEqual(outcome.hits.map(\.id), ["d2", "d0", "d1"])
        let report = outcome.diagnostics.stages.first { $0.stage == .rerank }
        XCTAssertEqual(report?.ran, true)
        XCTAssertEqual(report?.note?.contains("модель чат"), true)
    }

    /// The stage is the expensive one and the most likely to fail. It must not
    /// take the search down with it.
    func testAFailedRerankLeavesTheListAsItWas() async throws {
        let pipeline = RetrievalPipeline(
            database: SimpleDatabase(hits: hits(3)),
            embed: { _ in [1] },
            complete: { _, _, _ in throw LMStudioError.emptyResponse }
        )
        let outcome = try await pipeline.run(request(), profile: profile())
        XCTAssertEqual(outcome.hits.map(\.id), ["d0", "d1", "d2"])
        let report = outcome.diagnostics.stages.first { $0.stage == .rerank }
        XCTAssertEqual(report?.ran, false)
        // Упавшая стадия и выключенная больше не выглядят одинаково: настроенное
        // переранжирование, споткнувшееся об ответ модели, показывалось словом
        // «выключено» — и жалоба «настройка не сработала» становилась
        // неразрешимой.
        XCTAssertEqual(report?.failed, true)
        XCTAssertEqual(report?.outcome.title, "не выполнено")
        XCTAssertTrue(report?.line.contains("не выполнено") ?? false, report?.line ?? "")
    }

    func testProseFromTheModelIsAFailureNotAReordering() async throws {
        let pipeline = RetrievalPipeline(
            database: SimpleDatabase(hits: hits(3)),
            embed: { _ in [1] },
            complete: { _, _, _ in "Мне кажется, второй лучше." }
        )
        let outcome = try await pipeline.run(request(), profile: profile())
        XCTAssertEqual(outcome.hits.map(\.id), ["d0", "d1", "d2"])
    }

    func testEnabledWithoutAModelSaysSoRatherThanRunning() async throws {
        var called = false
        let pipeline = RetrievalPipeline(
            database: SimpleDatabase(hits: hits(3)),
            embed: { _ in [1] },
            complete: { _, _, _ in called = true; return "{}" }
        )
        let outcome = try await pipeline.run(request(), profile: profile(model: ""))
        XCTAssertFalse(called)
        let report = outcome.diagnostics.stages.first { $0.stage == .rerank }
        XCTAssertEqual(report?.note, "включено, но модель не выбрана")
    }

    func testWithoutAChatModelWiredInTheStageSaysThatToo() async throws {
        let pipeline = RetrievalPipeline(
            database: SimpleDatabase(hits: hits(3)), embed: { _ in [1] }, complete: nil
        )
        let outcome = try await pipeline.run(request(), profile: profile())
        let report = outcome.diagnostics.stages.first { $0.stage == .rerank }
        XCTAssertEqual(report?.note, "чат-модель этому конвейеру не передана")
    }

    func testOnlyTheHeadOfTheListIsSentToTheModel() async throws {
        var seenPrompt = ""
        let pipeline = RetrievalPipeline(
            database: SimpleDatabase(hits: hits(30)),
            embed: { _ in [1] },
            complete: { prompt, _, _ in
                seenPrompt = prompt
                return #"{"ranking":[{"index":1,"score":1}]}"#
            }
        )
        var profile = self.profile()
        profile.diversityEnabled = false
        _ = try await pipeline.run(
            RetrievalRequest(text: "з", collectionID: "col", collectionName: "к", nResults: 30),
            profile: profile
        )
        XCTAssertTrue(seenPrompt.contains("20. документ 19"), "должно уйти ровно двадцать")
        XCTAssertFalse(seenPrompt.contains("21. документ 20"))
    }
}

/// §E5 — the profile switch.
final class RerankProfileTests: XCTestCase {
    func testANewProfileHasItOff() {
        let profile = SearchProfile(collectionName: "к")
        XCTAssertFalse(profile.rerankEnabled)
        XCTAssertTrue(profile.rerankModel.isEmpty)
        XCTAssertFalse(profile.requestedStages.contains(.rerank))
    }

    /// «Включено, но без модели» is a setting that pretends to work.
    func testWithoutAModelTheStageIsNotRequested() {
        var profile = SearchProfile(collectionName: "к")
        profile.rerankEnabled = true
        XCTAssertFalse(profile.requestedStages.contains(.rerank))
        profile.rerankModel = "какая-то"
        XCTAssertTrue(profile.requestedStages.contains(.rerank))
    }

    func testTheSettingsSurviveTheFile() throws {
        var profile = SearchProfile(collectionName: "к")
        profile.rerankEnabled = true
        profile.rerankModel = "qwen3-4b"
        profile.rerankPrompt = "свой промпт {query} {documents}"
        let restored = try JSONDecoder().decode(
            SearchProfile.self, from: JSONEncoder().encode(profile)
        )
        XCTAssertEqual(restored, profile)
    }
}

/// §E5, — переранжировщик как отдельный путь.
final class CrossEncoderRerankTests: XCTestCase {
    func testThePromptCarriesTheQueryAndTheDocument() {
        let prompt = CrossEncoderReranker.prompt(query: "срок лицензии", document: "Лицензия бессрочная")
        XCTAssertTrue(prompt.contains("<Query>: срок лицензии"), prompt)
        XCTAssertTrue(prompt.contains("<Document>: Лицензия бессрочная"), prompt)
        // Разметка, которую ждёт сама модель: без неё она отвечает не то.
        XCTAssertTrue(prompt.contains("<|im_start|>system"), prompt)
        XCTAssertTrue(prompt.hasSuffix("\n\n"), "промпт заканчивается там, где модель должна начать отвечать")
    }

    func testALongDocumentIsCutBeforeItIsSent() {
        let long = String(repeating: "слово ", count: 5_000)
        let prompt = CrossEncoderReranker.prompt(query: "q", document: long)
        XCTAssertLessThan(prompt.count, CrossEncoderReranker.documentLimit + 600)
    }

    /// Обрезка не должна срабатывать на том, ради чего стадия и существует, —
    /// на обычном чанке. Размеры взяты из умолчаний самого приложения.
    func testAChunkOfTheAppsOwnDefaultSizeIsSentWhole() {
        for tokens in [512, 1_024] {
            let size = TokenEstimator.characters(forTokens: tokens)
            let chunk = String(repeating: "я", count: size)
            let prompt = CrossEncoderReranker.prompt(query: "q", document: chunk)
            XCTAssertTrue(
                prompt.contains(chunk),
                "чанк в \(tokens) токенов (\(size) символов) обязан уйти целиком"
            )
        }
    }

    /// Цена режима — вызов на кандидат, а не один на запрос: общая
    /// формулировка занижала бы её в двадцать раз.
    func testTheCostOfThisModeIsStatedInItsOwnTerms() {
        XCTAssertNotEqual(CrossEncoderReranker.costWarning, Reranker.costWarning)
        XCTAssertTrue(
            CrossEncoderReranker.costWarning.contains("\(Reranker.maximumCandidates) вызов"),
            CrossEncoderReranker.costWarning
        )
    }

    func testAnEmptyInstructionMeansTheStandardOne() {
        XCTAssertEqual(CrossEncoderReranker.instruction(from: ""), CrossEncoderReranker.defaultInstruction)
        XCTAssertEqual(CrossEncoderReranker.instruction(from: "  \n "), CrossEncoderReranker.defaultInstruction)
    }

    /// `<Instruct>:` — одна строка чужой разметки: перенос внутри неё сдвинул бы
    /// остаток промпта в тело инструкции.
    func testAMultilineInstructionIsFlattenedIntoOneLine() {
        let instruction = CrossEncoderReranker.instruction(from: " найди\nчто отвечает\r\nна вопрос ")
        XCTAssertEqual(instruction, "найди что отвечает на вопрос")
        let prompt = CrossEncoderReranker.prompt(query: "q", document: "d", instruction: instruction)
        XCTAssertTrue(prompt.contains("<Instruct>: найди что отвечает на вопрос\n<Query>: q"), prompt)
    }

    func testTheAnswerIsReadInTheFormsModelsActuallyGive() {
        XCTAssertEqual(CrossEncoderReranker.score("Yes"), 1)
        XCTAssertEqual(CrossEncoderReranker.score("yes\n\nYes"), 1)
        XCTAssertEqual(CrossEncoderReranker.score(" NO."), 0)
        XCTAssertEqual(CrossEncoderReranker.score("нет"), 0)
        // Непонятый ответ — не «нет»: считать его отказом значило бы молча
        // выбросить фрагмент.
        XCTAssertNil(CrossEncoderReranker.score("Мне кажется, это подходит"))
        XCTAssertNil(CrossEncoderReranker.score(""))
    }

    /// Ответ «да/нет» не даёт градаций, поэтому стадия вправе только поднять
    /// подошедшие — не трогая порядок, который нашли предыдущие стадии.
    func testAcceptedRiseAndTheOrderInsideTheGroupsIsKept() {
        let items = ["a", "b", "c", "d"]
        let reordered = CrossEncoderReranker.reordered(items, scores: [0, 1, nil, 1])
        XCTAssertEqual(reordered, ["b", "d", "a", "c"])
    }

    func testAShortVerdictListDoesNotLoseTheTail() {
        let items = ["a", "b", "c"]
        XCTAssertEqual(CrossEncoderReranker.reordered(items, scores: [1]), ["a", "b", "c"])
    }

    /// Конвейер целиком: модель отвечает «yes» только про нужный фрагмент, и он
    /// поднимается наверх.
    func testThePipelineUsesTheCrossEncoderWhenTheProfileSaysSo() async throws {
        let database = PlainDatabase(hits: [
            QueryHit(id: "d0", document: "Погода в Москве", metadata: nil, distance: 0.1),
            QueryHit(id: "d1", document: "Срок действия лицензии: бессрочная", metadata: nil, distance: 0.2),
            QueryHit(id: "d2", document: "Порядок приёмки", metadata: nil, distance: 0.3),
        ])
        var profile = SearchProfile(collectionName: "к")
        profile.rerankEnabled = true
        profile.rerankModel = "qwen3-reranker-0.6b"
        profile.rerankMode = .crossEncoder

        let calls = CallCounter()
        let pipeline = RetrievalPipeline(
            database: database,
            embed: { _ in [1] },
            completePlain: { prompt, _ in
                await calls.record()
                // Проверяем по тексту документа, а не по запросу: запрос есть в
                // каждом промпте.
                return prompt.contains("бессрочная") ? "yes" : "no"
            }
        )
        let outcome = try await pipeline.run(
            RetrievalRequest(text: "срок лицензии", collectionID: "c", collectionName: "к", nResults: 3),
            profile: profile
        )

        XCTAssertEqual(outcome.hits.first?.id, "d1", "подошедший фрагмент обязан подняться")
        let count = await calls.value
        XCTAssertEqual(count, 3, "вызов на фрагмент — это и есть цена режима")
        let report = outcome.diagnostics.stages.first { $0.stage == RetrievalStage.rerank }
        XCTAssertTrue(report?.ran ?? false)
        // Заметка говорит про шкалу, а не про «подошло»: у «да/нет» это 1 и 0,
        // у балльной модели — 5 и 1, и одно слово на обе не годится.
        XCTAssertTrue(report?.note?.contains("вызовов 3") ?? false, report?.note ?? "")
        XCTAssertTrue(report?.note?.contains("баллы от 0 до 1") ?? false, report?.note ?? "")
    }

    /// Поле, которое видно в форме, обязано доходить до модели. Оно было
    /// объявлено, показано и не прочитано ни разу — человек правил текст,
    /// до которого выполнение не доходило.
    func testTheInstructionFromTheProfileReachesTheModel() async throws {
        var profile = SearchProfile(collectionName: "к")
        profile.rerankEnabled = true
        profile.rerankModel = "qwen3-reranker-0.6b"
        profile.rerankMode = .crossEncoder
        profile.rerankInstruction = "Найди фрагменты про сроки"

        let seen = PromptRecorder()
        let pipeline = RetrievalPipeline(
            database: PlainDatabase(hits: [
                QueryHit(id: "d0", document: "раз", metadata: nil, distance: 0.1),
                QueryHit(id: "d1", document: "два", metadata: nil, distance: 0.2),
            ]),
            embed: { _ in [1] },
            completePlain: { prompt, _ in await seen.record(prompt); return "no" }
        )
        _ = try await pipeline.run(
            RetrievalRequest(text: "q", collectionID: "c", collectionName: "к", nResults: 2),
            profile: profile
        )
        let prompts = await seen.prompts
        XCTAssertEqual(prompts.count, 2)
        for prompt in prompts {
            XCTAssertTrue(prompt.contains("<Instruct>: Найди фрагменты про сроки"), prompt)
            XCTAssertFalse(prompt.contains(CrossEncoderReranker.defaultInstruction), prompt)
        }
    }

    /// Шаблон чат-схемы не должен утекать в `<Instruct>`: у полей разный формат,
    /// и подстановки `{documents}` в чужой разметке — мусор.
    func testTheChatTemplateIsNotUsedAsAnInstruction() async throws {
        var profile = SearchProfile(collectionName: "к")
        profile.rerankEnabled = true
        profile.rerankModel = "qwen3-reranker-0.6b"
        profile.rerankMode = .crossEncoder
        profile.rerankPrompt = Reranker.defaultPrompt

        let seen = PromptRecorder()
        let pipeline = RetrievalPipeline(
            database: PlainDatabase(hits: [
                QueryHit(id: "d0", document: "раз", metadata: nil, distance: 0.1),
                QueryHit(id: "d1", document: "два", metadata: nil, distance: 0.2),
            ]),
            embed: { _ in [1] },
            completePlain: { prompt, _ in await seen.record(prompt); return "no" }
        )
        _ = try await pipeline.run(
            RetrievalRequest(text: "q", collectionID: "c", collectionName: "к", nResults: 2),
            profile: profile
        )
        for prompt in await seen.prompts {
            XCTAssertFalse(prompt.contains("{documents}"), prompt)
            XCTAssertTrue(prompt.contains("<Instruct>: \(CrossEncoderReranker.defaultInstruction)"), prompt)
        }
    }

    /// Профиль, записанный до появления поля, читается — и читается пустым,
    /// то есть со стандартной инструкцией.
    func testAProfileWrittenBeforeTheFieldExistedStillReads() throws {
        var profile = SearchProfile(collectionName: "к")
        profile.rerankEnabled = true
        profile.rerankModel = "м"
        profile.rerankMode = .crossEncoder
        profile.rerankInstruction = "своя строка"

        let restored = try JSONDecoder().decode(
            SearchProfile.self, from: JSONEncoder().encode(profile)
        )
        XCTAssertEqual(restored.rerankInstruction, "своя строка")

        var stripped = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]
        )
        stripped.removeValue(forKey: "rerankInstruction")
        let old = try JSONDecoder().decode(
            SearchProfile.self, from: JSONSerialization.data(withJSONObject: stripped)
        )
        XCTAssertEqual(old.rerankInstruction, "")
        XCTAssertEqual(
            CrossEncoderReranker.instruction(from: old.rerankInstruction),
            CrossEncoderReranker.defaultInstruction
        )
    }

    /// Модель, отвечающая прозой на каждый вопрос, — это сбой стадии, а не
    /// «всё нерелевантно».
    func testProseFromEveryAnswerIsAFailure() async throws {
        var profile = SearchProfile(collectionName: "к")
        profile.rerankEnabled = true
        profile.rerankModel = "какая-то"
        profile.rerankMode = .crossEncoder

        let pipeline = RetrievalPipeline(
            database: PlainDatabase(hits: [
                QueryHit(id: "d0", document: "раз", metadata: nil, distance: 0.1),
                QueryHit(id: "d1", document: "два", metadata: nil, distance: 0.2),
            ]),
            embed: { _ in [1] },
            completePlain: { _, _ in "Затрудняюсь ответить" }
        )
        let outcome = try await pipeline.run(
            RetrievalRequest(text: "q", collectionID: "c", collectionName: "к", nResults: 2),
            profile: profile
        )
        let report = outcome.diagnostics.stages.first { $0.stage == RetrievalStage.rerank }
        XCTAssertEqual(report?.failed, true)
        XCTAssertEqual(outcome.hits.map { $0.id }, ["d0", "d1"], "порядок остаётся прежним")
    }
}

private actor PlainDatabase: RetrievalDatabase {
    private let hits: [QueryHit]
    init(hits: [QueryHit]) { self.hits = hits }
    func query(
        collectionID: String, embedding: [Double], nResults: Int,
        filter: DocumentFilter?, includeEmbeddings: Bool
    ) async throws -> [QueryHit] { Array(hits.prefix(nResults)) }
    func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] { [] }
    func documents(
        collectionID: String, matching filter: DocumentFilter, limit: Int
    ) async throws -> [DocumentRecord] { [] }
    func anyDocument(collectionID: String, matching filter: DocumentFilter) async throws -> Bool { false }
}

private actor CallCounter {
    private(set) var value = 0
    func record() { value += 1 }
}

private actor PromptRecorder {
    private(set) var prompts: [String] = []
    func record(_ prompt: String) { prompts.append(prompt) }
}

/// Переранжировщики говорят на двух языках.
///
/// `qwen3-reranker-0.6b` отвечает «yes»/«no». `jina-reranker-v3.5-mlx` на тот
/// же промпт отвечает баллом в скобках — проверено на живой LM Studio: «[5]»
/// ближайшему фрагменту, «[2]» отдалённому, «[1]» постороннему. Прежний разбор
/// знал, что «1» значит «да», и потому ставил посторонние фрагменты первыми:
/// на стенде это выглядело как «переранжировщик хуже опорного».
final class CrossEncoderScoreTests: XCTestCase {

    func testABracketedScoreIsRead() {
        XCTAssertEqual(CrossEncoderReranker.score("[5]"), 5)
        XCTAssertEqual(CrossEncoderReranker.score("[1]"), 1)
        XCTAssertEqual(CrossEncoderReranker.score("(3)"), 3)
        XCTAssertEqual(CrossEncoderReranker.score("\"4\""), 4)
    }

    /// Самый низкий балл — это «плохо», а не «да».
    func testTheLowestScoreIsNotAgreement() {
        let items = ["первый", "второй", "третий"]
        let order = CrossEncoderReranker.reordered(items, scores: [1, 5, 2])
        XCTAssertEqual(order, ["второй", "третий", "первый"])
    }

    /// Модель «да/нет» ведёт себя ровно как прежде: два балла, подошедшие
    /// впереди, внутри групп прежний порядок.
    func testAYesNoModelBehavesAsBefore() {
        let items = ["a", "b", "c", "d"]
        XCTAssertEqual(
            CrossEncoderReranker.reordered(items, scores: [0, 1, nil, 1]),
            ["b", "d", "a", "c"]
        )
    }

    /// Непонятый ответ уходит в хвост, но не выбрасывается: «не ответила» —
    /// не то же, что «сказала нет».
    func testAnUnreadAnswerGoesLastAndSurvives() {
        let items = ["a", "b", "c"]
        let order = CrossEncoderReranker.reordered(items, scores: [nil, 0, 5])
        XCTAssertEqual(order, ["c", "b", "a"])
    }

    func testADecimalScoreIsRead() {
        XCTAssertEqual(CrossEncoderReranker.score("0.87"), 0.87)
        XCTAssertEqual(CrossEncoderReranker.score("0,87"), 0.87)
    }

    /// Балл сам по себе ничего не значит: сравниваются только баллы одной
    /// модели, поэтому шкалу приложение не нормализует и не выдумывает.
    func testScoresAreComparedOnlyWithinOneAnswerSet() {
        let items = ["a", "b"]
        XCTAssertEqual(CrossEncoderReranker.reordered(items, scores: [5, 100]), ["b", "a"])
        XCTAssertEqual(CrossEncoderReranker.reordered(items, scores: [0.9, 0.1]), ["a", "b"])
    }
}
