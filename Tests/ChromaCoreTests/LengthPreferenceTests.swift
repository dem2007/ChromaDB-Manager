import XCTest
@testable import ChromaCore

/// Длина кандидата как часть оценки.
///
/// Числа в тестах — замеренные на живой модели `nomic-embed-text-v1.5`
/// и на базе пользователя: 187 319 чанков, 45% короче ста знаков, самый
/// частый из них — шапка таблицы «КРИТЕРИЙ РЕЗУЛЬТАТ ОЦЕНКИ РИСКИ»,
/// 208 копий. Она даёт 0.701 запросу «сервер», 0.692 — «СКАЛА-Р»
/// и 0.738 — «отпуск сотрудника»: близка ко всему сразу.
final class LengthPreferenceTests: XCTestCase {
    private func hit(_ id: String, text: String, distance: Double) -> RetrievalHit {
        RetrievalHit(id: id, document: text, metadata: nil, distance: distance)
    }

    /// Замеренный случай целиком: мусорная шапка обходит содержательный текст
    /// по схожести — и уступает ему после штрафа.
    func testTheHubChunkLosesToTheAnswer() {
        let garbage = hit("шапка", text: String(repeating: "К", count: 31), distance: 0.299)   // 0.701
        let answer = hit("ответ", text: String(repeating: "т", count: 141), distance: 0.322)   // 0.678

        let before = LengthPreference.applied(
            to: [garbage, answer], minimumCharacters: 0, penalty: false,
            target: 300, power: 0.5, metric: .cosine
        )
        XCTAssertEqual(before.hits.map(\.id), ["шапка", "ответ"], "без штрафа мусор впереди — это и есть жалоба")

        let after = LengthPreference.applied(
            to: [garbage, answer], minimumCharacters: 0, penalty: true,
            target: 300, power: 0.5, metric: .cosine
        )
        XCTAssertEqual(after.hits.map(\.id), ["ответ", "шапка"], "после штрафа впереди тот, в котором есть ответ")
        XCTAssertEqual(after.moved, 2)
        XCTAssertNotNil(after.note)
    }

    /// Текст длиннее цели не штрафуется вовсе: правило про короткие,
    /// а не «чем длиннее, тем лучше».
    func testNothingIsTakenFromTextsAboveTheTarget() {
        XCTAssertEqual(LengthPreference.factor(length: 300, target: 300, power: 0.5), 1, accuracy: 0.0001)
        XCTAssertEqual(LengthPreference.factor(length: 3000, target: 300, power: 0.5), 1, accuracy: 0.0001)
        // А короткому достаётся ровно по формуле: 30/300 = 0.1, корень — 0.316.
        XCTAssertEqual(LengthPreference.factor(length: 30, target: 300, power: 0.5), 0.3162, accuracy: 0.001)
        XCTAssertEqual(LengthPreference.factor(length: 30, target: 300, power: 1), 0.1, accuracy: 0.001)
        // Степень ноль означает «штрафа нет», а не «оценка обнулена».
        XCTAssertEqual(LengthPreference.factor(length: 10, target: 300, power: 0), 1, accuracy: 0.0001)
    }

    /// Порядок при равных оценках остаётся тем, что дала база: два одинаковых
    /// запроса подряд обязаны давать одну и ту же выдачу.
    func testEqualScoresKeepTheOrderOfTheDatabase() {
        let first = hit("первый", text: String(repeating: "а", count: 400), distance: 0.2)
        let second = hit("второй", text: String(repeating: "б", count: 400), distance: 0.2)
        let outcome = LengthPreference.applied(
            to: [first, second], minimumCharacters: 0, penalty: true,
            target: 300, power: 0.5, metric: .cosine
        )
        XCTAssertEqual(outcome.hits.map(\.id), ["первый", "второй"])
        XCTAssertEqual(outcome.moved, 0)
    }

    /// Отсечка выбрасывает короткое и говорит, сколько выбросила.
    func testTheHardCutoffSaysWhatItThrewAway() {
        let outcome = LengthPreference.applied(
            to: [
                hit("короткий", text: "Сервер", distance: 0.0),
                hit("длинный", text: String(repeating: "т", count: 400), distance: 0.3),
            ],
            minimumCharacters: 150, penalty: false, target: 300, power: 0.5, metric: .cosine
        )
        XCTAssertEqual(outcome.hits.map(\.id), ["длинный"])
        XCTAssertEqual(outcome.dropped, 1)
        XCTAssertEqual(outcome.note?.contains("отброшено"), true)
    }

    /// Отсечка съела всё — это ответ, но только вместе с причиной.
    func testAnEmptyResultCarriesItsReason() {
        let outcome = LengthPreference.applied(
            to: [hit("короткий", text: "Сервер", distance: 0.0)],
            minimumCharacters: 150, penalty: true, target: 300, power: 0.5, metric: .cosine
        )
        XCTAssertTrue(outcome.hits.isEmpty)
        XCTAssertEqual(outcome.note?.contains("все кандидаты оказались короче порога"), true)
    }

    /// На метрике без схожести штраф не применяется — и молчать об этом нельзя.
    ///
    /// Домножать на догадку значит выдать ранжирование, которое потом никто
    /// не сможет объяснить, — то же правило, по которому живёт MMR.
    func testWithoutASimilarityTheOrderIsLeftAlone() {
        let hits = [
            hit("короткий", text: "Сервер", distance: 1.2),
            hit("длинный", text: String(repeating: "т", count: 400), distance: 3.5),
        ]
        let outcome = LengthPreference.applied(
            to: hits, minimumCharacters: 0, penalty: true, target: 300, power: 0.5, metric: .l2
        )
        XCTAssertEqual(outcome.hits.map(\.id), ["короткий", "длинный"], "порядок базы остался как был")
        XCTAssertEqual(outcome.moved, 0)
        XCTAssertEqual(outcome.note?.contains("метрика не даёт схожести"), true)
    }

    // MARK: - Пул кандидатов

    /// Главное про пул: стадии, которые отсеивают, обязаны его получать.
    ///
    /// Rerank без пула переставляет те же десять, что вернула база: нужный
    /// чанк, стоявший у вектора на 133-м месте, до чат-модели не доезжает.
    func testStagesThatDiscardGetAPool() {
        var profile = SearchProfile(collectionName: "к")
        profile.rerankEnabled = true
        profile.rerankModel = "модель"
        XCTAssertEqual(profile.poolSize(nResults: 10, stages: profile.requestedStages), 50)

        var byLength = SearchProfile(collectionName: "к")
        byLength.lengthPenaltyEnabled = true
        XCTAssertEqual(byLength.poolSize(nResults: 10, stages: byLength.requestedStages), 50)

        var byCutoff = SearchProfile(collectionName: "к")
        byCutoff.minimumCharacters = 150
        XCTAssertEqual(byCutoff.poolSize(nResults: 10, stages: byCutoff.requestedStages), 50)
    }

    /// И наоборот: пустой конвейер по-прежнему не платит за пул ничего —
    /// «выключённый умный поиск даёт ровно то же, что поиск этапа 2».
    func testAnEmptyPipelineStillAsksForExactlyWhatWasRequested() {
        let plain = SearchProfile.plain(collectionName: "к", name: "обычный")
        XCTAssertEqual(plain.poolSize(nResults: 10, stages: plain.requestedStages), 10)
    }

    /// Профиль, включивший только штраф за длину, не должен объявляться
    /// «ничего не изменившим»: стадии у него нет, а выдачу он двигает.
    func testTheLengthWorkCountsAsAChange() {
        XCTAssertFalse(
            RetrievalPipeline.profileChangedNothing(
                stages: [], requested: [], lengthChangedSomething: true
            )
        )
        XCTAssertTrue(
            RetrievalPipeline.profileChangedNothing(
                stages: [], requested: [], lengthChangedSomething: false
            )
        )
    }
}

/// Штраф и отсечка — **настройка**, а не новое поведение поиска.
///
/// Три вопроса, на которые обязан отвечать код, а не обещание: выключено ли
/// это по умолчанию, возвращается ли всё как было после выключения,
/// переживает ли значение сохранение профиля на диск.
private actor MixedLengthDatabase: RetrievalDatabase {
    private let ranked: [QueryHit]
    private(set) var requestedSizes: [Int] = []

    /// Первый кандидат — короткий и ближе всех: ровно жалоба пользователя.
    init() {
        let texts = [
            ("мусор", "Сервер", 0.0),
            ("шапка", String(repeating: "К", count: 31), 0.30),
            ("ответ", String(repeating: "т", count: 400), 0.33),
            ("ещё", String(repeating: "п", count: 500), 0.40),
        ]
        ranked = texts.map { QueryHit(id: $0.0, document: $0.1, metadata: nil, distance: $0.2) }
    }

    func query(
        collectionID: String, embedding: [Double], nResults: Int, filter: DocumentFilter?,
        includeEmbeddings: Bool
    ) async throws -> [QueryHit] {
        requestedSizes.append(nResults)
        return Array(ranked.prefix(nResults)).enumerated().map { position, hit in
            guard includeEmbeddings else { return hit }
            // Векторы у всех разные — иначе MMR посчитает кандидатов копиями
            // друг друга и выбросит всех, кроме первого.
            let vector: [Double] = (0..<4).map { $0 == position % 4 ? 1.0 : 0.05 }
            return QueryHit(
                id: hit.id, document: hit.document, metadata: hit.metadata,
                distance: hit.distance, embedding: vector
            )
        }
    }
    func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] { [] }
    func documents(collectionID: String, matching filter: DocumentFilter, limit: Int) async throws -> [DocumentRecord] { [] }
    func anyDocument(collectionID: String, matching filter: DocumentFilter) async throws -> Bool { false }
    func sizes() -> [Int] { requestedSizes }
}

final class LengthPreferenceIsASettingTests: XCTestCase {
    private func request() -> RetrievalRequest {
        RetrievalRequest(
            text: "сервер", collectionID: "col", collectionName: "к",
            nResults: 4, metric: .cosine
        )
    }

    /// Выключено по умолчанию: заводской профиль ищет ровно так же, как искал
    /// вчера, и лишнего пула не просит.
    func testOffByDefault() async throws {
        let profile = SearchProfile(collectionName: "к")
        XCTAssertFalse(profile.lengthPenaltyEnabled)
        XCTAssertEqual(profile.minimumCharacters, 0)

        let database = MixedLengthDatabase()
        let pipeline = RetrievalPipeline(database: database, embed: { _ in [1, 0] })
        let outcome = try await pipeline.run(request(), profile: profile)

        XCTAssertEqual(outcome.hits.map(\.id), ["мусор", "шапка", "ответ", "ещё"], "порядок базы не тронут")
        let sizes = await database.sizes()
        XCTAssertEqual(sizes, [4], "пул не расширен: отсеивать нечем")
    }

    /// Включено — работает: короткий уходит вниз, пул расширяется.
    func testOnItReordersAndAsksForAPool() async throws {
        var profile = SearchProfile(collectionName: "к")
        profile.lengthPenaltyEnabled = true

        let database = MixedLengthDatabase()
        let pipeline = RetrievalPipeline(database: database, embed: { _ in [1, 0] })
        let outcome = try await pipeline.run(request(), profile: profile)

        XCTAssertEqual(outcome.hits.first?.id, "ответ", "впереди тот, в котором есть текст")
        XCTAssertEqual(outcome.hits.last?.id, "мусор", "чанк из одного слова — последний")
        let sizes = await database.sizes()
        XCTAssertEqual(sizes, [20], "стадия, которая переставляет, обязана получить пул")
        XCTAssertFalse(outcome.diagnostics.unchangedByProfile, "профиль изменил выдачу, и это признано")
        // Штраф считается после слияния, поэтому и рассказывает
        // о себе стадия слияния — рядом с тем, чью оценку он домножил.
        XCTAssertEqual(
            outcome.diagnostics.stages.first { $0.stage == .fusion }?.note?.contains("штраф за длину"),
            true, "панель обязана сказать, что штраф применён"
        )
    }

    /// Отсечка выбрасывает короткие и говорит об этом в панели.
    func testTheCutoffDropsShortCandidates() async throws {
        var profile = SearchProfile(collectionName: "к")
        profile.minimumCharacters = 100

        let pipeline = RetrievalPipeline(database: MixedLengthDatabase(), embed: { _ in [1, 0] })
        let outcome = try await pipeline.run(request(), profile: profile)

        XCTAssertEqual(outcome.hits.map(\.id), ["ответ", "ещё"])
        XCTAssertEqual(
            outcome.diagnostics.stages.first { $0.stage == .candidates }?.note?.contains("отброшено"),
            true
        )
    }

    /// И главное: выключение возвращает **ровно** прежнюю выдачу.
    func testTurningItOffRestoresTheOldBehaviour() async throws {
        var tuned = SearchProfile(collectionName: "к")
        tuned.lengthPenaltyEnabled = true
        tuned.minimumCharacters = 100

        var back = tuned
        back.lengthPenaltyEnabled = false
        back.minimumCharacters = 0

        let pipeline = RetrievalPipeline(database: MixedLengthDatabase(), embed: { _ in [1, 0] })
        let withSetting = try await pipeline.run(request(), profile: tuned)
        let without = try await pipeline.run(request(), profile: back)
        let untouched = try await pipeline.run(request(), profile: SearchProfile(collectionName: "к"))

        XCTAssertNotEqual(withSetting.hits.map(\.id), without.hits.map(\.id))
        XCTAssertEqual(without.hits.map(\.id), untouched.hits.map(\.id), "выключенная настройка не оставляет следа")
    }

    /// Настройка переживает сохранение профиля: иначе она «есть в форме»
    /// и пропадает при следующем открытии.
    func testTheSettingSurvivesBeingSaved() throws {
        var profile = SearchProfile(collectionName: "к")
        profile.lengthPenaltyEnabled = true
        profile.lengthTarget = 450
        profile.lengthPenaltyPower = 0.75
        profile.minimumCharacters = 120

        let data = try JSONEncoder().encode(profile)
        let restored = try JSONDecoder().decode(SearchProfile.self, from: data)

        XCTAssertTrue(restored.lengthPenaltyEnabled)
        XCTAssertEqual(restored.lengthTarget, 450)
        XCTAssertEqual(restored.lengthPenaltyPower, 0.75, accuracy: 0.0001)
        XCTAssertEqual(restored.minimumCharacters, 120)
    }

    /// Профиль, записанный до, читается как «длина не учитывается»:
    /// молча поменять ранжирование у сохранённого профиля нельзя.
    func testAnOlderProfileReadsAsSwitchedOff() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"старый","collectionName":"к","isDefault":true,
         "candidateMultiplier":5,"minimumCandidates":20,"vectorSearchEnabled":true,
         "textSearchEnabled":false,"vectorWeight":1,"textWeight":1,"fusionK":60,
         "splitQueryIntoWords":false,"searchLevel":"children","collapseByParent":true,
         "promotion":"child","diversityEnabled":false,"diversityLambda":0.7,
         "rerankEnabled":false,"rerankModel":"","rerankMode":"chatSchema",
         "rerankPrompt":"","rerankInstruction":"","marksEnabled":true}
        """
        let restored = try JSONDecoder().decode(SearchProfile.self, from: Data(json.utf8))
        XCTAssertFalse(restored.lengthPenaltyEnabled)
        XCTAssertEqual(restored.minimumCharacters, 0)
        XCTAssertEqual(restored.lengthTarget, 300)
    }

    /// Живая проверка, на которой это и поймали: у профиля с **разнообразием**
    /// штраф не менял ровным счётом ничего.
    ///
    /// Замер пользователя: четыре варианта, из них два со штрафом, — выдача
    /// совпадала до последнего идентификатора, и короткие чанки на 18 и 38
    /// знаков стояли на прежних местах. Причина: штраф двигал только порядок
    /// массива, а MMR считает релевантность сам, из расстояния, и возвращал
    /// всё назад.
    func testThePenaltySurvivesTheDiversityStage() async throws {
        var withPenalty = SearchProfile(collectionName: "к")
        withPenalty.diversityEnabled = true
        withPenalty.lengthPenaltyEnabled = true

        var plain = SearchProfile(collectionName: "к")
        plain.diversityEnabled = true

        let pipeline = RetrievalPipeline(database: MixedLengthDatabase(), embed: { _ in [1, 0, 0, 0] })
        let penalised = try await pipeline.run(request(), profile: withPenalty)
        let untouched = try await pipeline.run(request(), profile: plain)

        XCTAssertNotEqual(
            penalised.hits.map(\.id), untouched.hits.map(\.id),
            "штраф обязан менять выдачу и при включённом разнообразии"
        )
        XCTAssertEqual(penalised.hits.first?.id, "ответ", "впереди тот, в котором есть текст")
        XCTAssertNotEqual(penalised.hits.first?.id, "мусор")
    }

    /// И сама оценка доезжает до стадий: она остаётся при кандидате.
    func testTheAdjustedScoreStaysWithTheCandidate() {
        let hits = [
            RetrievalHit(id: "мусор", document: "Сервер", metadata: nil, distance: 0.0),
            RetrievalHit(id: "ответ", document: String(repeating: "т", count: 600), metadata: nil, distance: 0.4),
        ]
        let outcome = LengthPreference.applied(
            to: hits, minimumCharacters: 0, penalty: true, target: 300, power: 0.5, metric: .cosine
        )
        let byID = Dictionary(uniqueKeysWithValues: outcome.hits.map { ($0.id, $0) })
        XCTAssertEqual(byID["ответ"]?.relevance ?? 0, 0.6, accuracy: 0.001, "длинный не штрафуется")
        // Короткий: схожесть 1.0 × (6/300)^0.5 ≈ 0.141.
        XCTAssertEqual(byID["мусор"]?.relevance ?? 0, 0.141, accuracy: 0.005)
    }
}

/// Штраф за длину достаёт и текстовую половину гибридного поиска.
///
/// Замер на «мусорной» коллекции (187 319 чанков, 45% короче ста знаков):
/// со штрафом и пулом коротких чанков в первой пятёрке было 1.7 из 5,
/// а стоило включить текстовый поиск со словами — снова 4.2. Штраф до
/// текстовой половины не доходил, и она возвращала в верхушку ровно то,
/// что он убирал; спасала только жёсткая отсечка.
final class LengthPenaltyReachesTheTextHalfTests: XCTestCase {
    private func textHit(_ id: String, text: String, relevance: Double) -> RetrievalHit {
        var hit = RetrievalHit(
            id: id, document: text, metadata: nil, distance: nil, sources: [.text]
        )
        hit.relevance = relevance
        return hit
    }

    /// У текстового кандидата расстояния нет — и штраф всё равно считается,
    /// по его собственной оценке.
    func testTheTextHalfIsPenalisedByItsOwnScore() {
        let hits = [
            textHit("короткий", text: "Сервер", relevance: 1.0),
            textHit("длинный", text: String(repeating: "т", count: 600), relevance: 0.8),
        ]
        let outcome = LengthPreference.applied(
            to: hits, minimumCharacters: 0, penalty: true, target: 300, power: 0.5, metric: nil
        )
        XCTAssertEqual(outcome.hits.map(\.id), ["длинный", "короткий"], "содержательный обязан выйти вперёд")
        XCTAssertEqual(outcome.moved, 2)
        XCTAssertEqual(outcome.note?.contains("не применён"), false, "отговорки про метрику здесь не место")
    }

    /// Смешанный список — векторные и текстовые вместе — считается одной
    /// мерой: у каждого берётся его собственная оценка.
    func testAMixedListIsWeighedByOneRule() {
        var vector = RetrievalHit(
            id: "векторный", document: String(repeating: "в", count: 400), metadata: nil, distance: 0.4
        )
        vector.relevance = nil
        let hits = [
            textHit("текстовый короткий", text: "vCPU", relevance: 1.0),
            vector,
        ]
        let outcome = LengthPreference.applied(
            to: hits, minimumCharacters: 0, penalty: true, target: 300, power: 0.5, metric: .cosine
        )
        XCTAssertEqual(outcome.hits.first?.id, "векторный", "0.6 против 1.0 × (4/300)^0.5 ≈ 0.12")
    }

    /// А там, где оценки нет ни у кого — ни своей, ни из расстояния, —
    /// порядок не трогается и об этом говорится вслух.
    func testWithoutAnyScoreTheOrderIsLeftAlone() {
        let hits = [
            RetrievalHit(id: "первый", document: "Сервер", metadata: nil, distance: 1.2),
            RetrievalHit(id: "второй", document: String(repeating: "т", count: 400), metadata: nil, distance: 3.5),
        ]
        let outcome = LengthPreference.applied(
            to: hits, minimumCharacters: 0, penalty: true, target: 300, power: 0.5, metric: .l2
        )
        XCTAssertEqual(outcome.hits.map(\.id), ["первый", "второй"])
        XCTAssertEqual(outcome.note?.contains("метрика не даёт схожести"), true)
    }
}

/// Штраф считается **один раз и после слияния**.
///
/// Замер на живой базе, запрос «сервер»: чанк в 54 знака занимал первые
/// четыре места (дубли), хотя штраф был включён. Он честно опускал его
/// внутри каждого списка, но RRF складывал ранги заново, и документ,
/// найденный обоими источниками, выходил вперёд мимо всякого штрафа.
final class PenaltyAfterFusionTests: XCTestCase {
    /// База, где короткий чанк лежит и в векторной выдаче, и в текстовой.
    private actor BothListsDatabase: RetrievalDatabase {
        private let short = DocumentRecord(id: "короткий", document: "Сервер криптографии КриптоПро", metadata: nil)
        private let long = DocumentRecord(
            id: "длинный",
            document: "Сервер приложений: " + String(repeating: "требования к серверу. ", count: 30),
            metadata: nil
        )

        func query(
            collectionID: String, embedding: [Double], nResults: Int, filter: DocumentFilter?,
            includeEmbeddings: Bool
        ) async throws -> [QueryHit] {
            [
                QueryHit(id: short.id, document: short.document, metadata: nil, distance: 0.28),
                QueryHit(id: long.id, document: long.document, metadata: nil, distance: 0.30),
            ]
        }
        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] { [] }
        /// Текстовый поиск находит оба, короткий — первым.
        func documents(collectionID: String, matching filter: DocumentFilter, limit: Int) async throws -> [DocumentRecord] {
            [short, long]
        }
        func anyDocument(collectionID: String, matching filter: DocumentFilter) async throws -> Bool { false }
    }

    func testAShortChunkInBothListsDoesNotEscapeThePenalty() async throws {
        var profile = SearchProfile(collectionName: "к")
        profile.textSearchEnabled = true
        profile.splitQueryIntoWords = true
        profile.lengthPenaltyEnabled = true

        let pipeline = RetrievalPipeline(database: BothListsDatabase(), embed: { _ in [1, 0] })
        let outcome = try await pipeline.run(
            RetrievalRequest(
                text: "сервер", collectionID: "col", collectionName: "к",
                nResults: 5, metric: .cosine
            ),
            profile: profile
        )

        XCTAssertEqual(
            outcome.hits.first?.id, "длинный",
            "короткий чанк не должен обгонять содержательный только потому, что попал в оба списка"
        )
        XCTAssertEqual(
            outcome.diagnostics.stages.first { $0.stage == .fusion }?.note?.contains("штраф за длину"),
            true, "о штрафе рассказывает та стадия, чью оценку он домножил"
        )
    }
}

/// Слияние, разнообразие и штраф — все три вместе.
///
/// Обзор нашёл то, чего не видел ни один тест: слияние отдавало дальше
/// **сырую** оценку RRF (у первого места 1/(k+1) ≈ 0.016), а стадия
/// разнообразия сравнивает её с косинусной похожестью кандидатов в 0…1.
/// Слагаемое релевантности оказывалось в тридцать раз легче слагаемого
/// повторности, и MMR ранжировал, почти не глядя, о чём документ.
final class FusionDiversityAndPenaltyTests: XCTestCase {
    /// База: два содержательных документа рядом с запросом и один
    /// короткий мусорный, найденный обоими источниками.
    private actor HybridDatabase: RetrievalDatabase {
        private let records: [(id: String, text: String, distance: Double, vector: [Double])] = [
            ("мусор", "Сервер", 0.10, [1, 0, 0]),
            ("ответ", String(repeating: "сервер приложений, требования. ", count: 20), 0.20, [0.9, 0.1, 0]),
            ("другой", String(repeating: "серверная стойка, питание. ", count: 20), 0.30, [0, 1, 0]),
        ]

        func query(
            collectionID: String, embedding: [Double], nResults: Int, filter: DocumentFilter?,
            includeEmbeddings: Bool
        ) async throws -> [QueryHit] {
            records.map {
                QueryHit(
                    id: $0.id, document: $0.text, metadata: nil, distance: $0.distance,
                    embedding: includeEmbeddings ? $0.vector : nil
                )
            }
        }
        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] { [] }
        func documents(collectionID: String, matching filter: DocumentFilter, limit: Int) async throws -> [DocumentRecord] {
            records.map { DocumentRecord(id: $0.id, document: $0.text, metadata: nil) }
        }
        func anyDocument(collectionID: String, matching filter: DocumentFilter) async throws -> Bool { false }
    }

    /// Оценка, доезжающая до разнообразия, обязана быть в той же шкале,
    /// что и похожесть: иначе MMR её попросту не замечает.
    func testTheRelevanceReachingDiversityIsOnTheSameScale() async throws {
        var profile = SearchProfile(collectionName: "к")
        profile.textSearchEnabled = true
        profile.splitQueryIntoWords = true
        profile.diversityEnabled = true
        profile.lengthPenaltyEnabled = true

        let pipeline = RetrievalPipeline(database: HybridDatabase(), embed: { _ in [1, 0, 0] })
        let outcome = try await pipeline.run(
            RetrievalRequest(
                text: "сервер", collectionID: "col", collectionName: "к",
                nResults: 3, metric: .cosine
            ),
            profile: profile
        )

        let best = outcome.hits.first
        XCTAssertNotEqual(best?.id, "мусор", "чанк из одного слова не должен возглавлять выдачу")
        // Шкала: у лучшего кандидата оценка сравнима с единицей, а не с 0.016.
        XCTAssertGreaterThan(
            best?.relevance ?? 0, 0.05,
            "оценка \(best?.relevance ?? 0) слишком мала — MMR сравнивает её с похожестью в 0…1"
        )
    }

    /// И то же самое без штрафа: шкалу задаёт слияние, а не штраф.
    func testTheFusedScoreIsNormalisedEvenWithoutThePenalty() async throws {
        var profile = SearchProfile(collectionName: "к")
        profile.textSearchEnabled = true
        profile.splitQueryIntoWords = true
        profile.diversityEnabled = true

        let pipeline = RetrievalPipeline(database: HybridDatabase(), embed: { _ in [1, 0, 0] })
        let outcome = try await pipeline.run(
            RetrievalRequest(
                text: "сервер", collectionID: "col", collectionName: "к",
                nResults: 3, metric: .cosine
            ),
            profile: profile
        )
        XCTAssertEqual(outcome.hits.first?.relevance, 1, "лучший кандидат слияния — единица шкалы")
    }
}

/// Кандидат без оценки не отменяет штраф остальным.
final class UnscoredCandidateKeepsItsPlaceTests: XCTestCase {
    func testTheRestAreStillPenalised() {
        var withScore = RetrievalHit(
            id: "длинный", document: String(repeating: "т", count: 600), metadata: nil, distance: 0.4
        )
        withScore.relevance = 0.6
        var short = RetrievalHit(id: "короткий", document: "Сервер", metadata: nil, distance: 0.0)
        short.relevance = 1.0
        // Ни своей оценки, ни расстояния — посчитать нечем.
        let unscored = RetrievalHit(id: "без оценки", document: "текст", metadata: nil, distance: nil)

        let outcome = LengthPreference.applied(
            to: [short, unscored, withScore],
            minimumCharacters: 0, penalty: true, target: 300, power: 0.5, metric: .cosine
        )
        let order = outcome.hits.map(\.id)
        XCTAssertEqual(order.first, "длинный", "штраф обязан отработать у тех, у кого оценка есть")
        XCTAssertTrue(order.contains("без оценки"), "кандидат без оценки не теряется: \(order)")
        XCTAssertEqual(outcome.note?.contains("не применён"), false, "отговорки здесь не место")
    }

    /// Пустому списку штраф ничего не делает и ничего о себе не рассказывает.
    func testAnEmptyListGetsNoStory() {
        let outcome = LengthPreference.applied(
            to: [], minimumCharacters: 0, penalty: true, target: 300, power: 0.5, metric: .cosine
        )
        XCTAssertTrue(outcome.hits.isEmpty)
        XCTAssertNil(outcome.note)
    }
}
