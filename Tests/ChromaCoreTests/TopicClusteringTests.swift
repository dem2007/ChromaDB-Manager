import XCTest
@testable import ChromaCore

/// §K2 — тематические кластеры.
///
/// Этап реализован после прямого согласия пользователя, полученного в
/// формулировке K2.2. Тесты держат обе половины обещания: список тем считается
/// честно, а графической проекции векторов в этом коде нет и не появляется.
final class TopicClusteringTests: XCTestCase {
    /// База, которая только отвечает. Как у инспектора: методов записи в
    /// протоколе нет вовсе, а обращения за векторами видны по счётчику.
    private final class Reader: InspectionReader, @unchecked Sendable {
        var records: [DocumentRecord] = []
        var vectors: [String: [Double]] = [:]
        private(set) var embeddingReads = 0

        func count(collectionID: String) async throws -> Int { records.count }

        func documents(collectionID: String, limit: Int, offset: Int) async throws -> [DocumentRecord] {
            guard offset < records.count else { return [] }
            return Array(records[offset..<min(offset + limit, records.count)])
        }

        /// Сколько текстов спросили поимённо: тексты выборки в память не
        /// тянутся, читаются только те, что попадут в примеры.
        private(set) var textsReadByID = 0

        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] {
            let wanted = Set(ids)
            textsReadByID += wanted.count
            return records.filter { wanted.contains($0.id) }
        }

        func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] {
            embeddingReads += 1
            return ids.reduce(into: [:]) { result, id in result[id] = vectors[id] }
        }

        func query(collectionID: String, embedding: [Double], nResults: Int) async throws -> [QueryHit] {
            XCTFail("Кластеризация не ищет по базе — ей нужны сами векторы")
            return []
        }
    }

    /// Что модель спросили — из замыкания, которое зовут из чужого контекста.
    private final class Prompts: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ prompt: String) {
            lock.lock(); defer { lock.unlock() }
            storage.append(prompt)
        }

        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    private func collection(dimension: Int = 8) -> ChromaCollection {
        ChromaCollection(
            id: "id", name: "темы",
            metadata: [
                CollectionBindingKeys.model: .string("e5"),
                CollectionBindingKeys.dimension: .int(dimension),
                CollectionBindingKeys.space: .string("cosine"),
            ]
        )
    }

    // MARK: - Данные для опытов

    /// Точка около заданной оси: направление задаёт группу, шум — разброс
    /// внутри неё. Через тот же `SeededRandom`, что и сам k-means, — тест,
    /// который сам по себе не воспроизводится, ничего не проверяет.
    private func point(axis: Int, dimension: Int, noise: Double, random: inout SeededRandom) -> [Double] {
        var vector = [Double](repeating: 0, count: dimension)
        for index in 0..<dimension {
            vector[index] = (random.fraction() - 0.5) * noise
        }
        vector[axis] += 1
        return vector
    }

    private func groups(
        count: Int, perGroup: Int, dimension: Int = 8, noise: Double = 0.15, seed: UInt64 = 7
    ) -> [[Double]] {
        var random = SeededRandom(seed: seed)
        var vectors: [[Double]] = []
        for group in 0..<count {
            for _ in 0..<perGroup {
                vectors.append(point(axis: group, dimension: dimension, noise: noise, random: &random))
            }
        }
        return vectors
    }

    // MARK: - k-means

    func testItSeparatesGroupsThatAreActuallySeparate() {
        let vectors = groups(count: 3, perGroup: 30)
        let points = VectorSet(vectors: vectors, dimension: 8)
        let fit = KMeans.fit(points, k: 3, seed: 42)

        XCTAssertEqual(fit.k, 3)
        // Каждая тридцатка должна оказаться в одном кластере — неважно, с каким
        // номером: номера у k-means произвольны, а вот разрывать группу он не
        // имеет права.
        for group in 0..<3 {
            let assigned = Set(fit.assignments[(group * 30)..<((group + 1) * 30)])
            XCTAssertEqual(assigned.count, 1, "группа \(group) разъехалась по кластерам \(assigned)")
        }
        XCTAssertEqual(Set(fit.assignments).count, 3)
        XCTAssertGreaterThan(fit.silhouette, 0.5)
    }

    /// G4 буквально: тот же вход и то же зерно — тот же ответ.
    func testTheSameSeedGivesExactlyTheSameSplit() {
        let points = VectorSet(vectors: groups(count: 4, perGroup: 20), dimension: 8)
        let first = KMeans.fit(points, k: 4, seed: 42)
        let second = KMeans.fit(points, k: 4, seed: 42)

        XCTAssertEqual(first.assignments, second.assignments)
        XCTAssertEqual(first.distances, second.distances)
        XCTAssertEqual(first.inertia, second.inertia)
    }

    /// Отмена слышна **внутри** счёта, а не только между этапами.
    ///
    /// Разбиение десяти тысяч векторов длиной в тысячу чисел идёт секунды, и
    /// раньше ближайшая проверка отмены была за пределами всей арифметики:
    /// человек нажимал «Отменить» и смотрел на кнопку до конца прогона
    ///.
    func testTheFitStopsBetweenStepsWhenAskedTo() {
        let points = VectorSet(vectors: groups(count: 4, perGroup: 25), dimension: 8)
        let stopped = KMeans.fit(points, k: 4, seed: 42, maxIterations: 60, shouldStop: { true })

        XCTAssertEqual(stopped.iterations, 0, "ни одного шага после просьбы остановиться")
        XCTAssertFalse(stopped.converged, "прерванное разбиение не выдаёт себя за сошедшееся")
        // И результат остаётся связным: номера тем розданы всем точкам, даже
        // если разбиение неполное. Иначе вызывающий получит наполовину
        // заполненный массив и упадёт на нём позже.
        XCTAssertEqual(stopped.assignments.count, points.count)
        XCTAssertEqual(stopped.distances.count, points.count)
    }

    /// Подбор числа тем тоже: он вызывает разбиение трижды.
    func testTheSuggestionStopsToo() {
        let points = VectorSet(vectors: groups(count: 3, perGroup: 30), dimension: 8)
        let selection = KMeans.suggestK(points, seed: 42, shouldStop: { true })

        XCTAssertTrue(selection.scores.isEmpty, "ни одно значение не должно быть посчитано")
        // Число тем всё равно названо: оно — соглашение по размеру выборки,
        // а не результат счёта.
        XCTAssertEqual(selection.k, KMeans.defaultK(for: points.count))
    }

    /// Без просьбы остановиться ничего не меняется.
    func testNothingChangesWhenNobodyAsksToStop() {
        let points = VectorSet(vectors: groups(count: 3, perGroup: 25), dimension: 8)
        let plain = KMeans.fit(points, k: 3, seed: 42)
        let asked = KMeans.fit(points, k: 3, seed: 42, shouldStop: { false })
        XCTAssertEqual(plain.assignments, asked.assignments)
        XCTAssertEqual(plain.iterations, asked.iterations)
    }

    /// А вот на другом зерне разбиение обязано остаться тем же **по составу**:
    /// если группы разделимы, случайный старт на это влиять не должен. Иначе
    /// «темы» — это свойство генератора, а не коллекции.
    func testADifferentSeedFindsTheSameGroups() {
        let points = VectorSet(vectors: groups(count: 3, perGroup: 25), dimension: 8)
        let first = KMeans.fit(points, k: 3, seed: 42)
        let second = KMeans.fit(points, k: 3, seed: 1_000_003)

        func composition(_ fit: KMeans.Fit) -> Set<Set<Int>> {
            var buckets: [Int: Set<Int>] = [:]
            for (index, cluster) in fit.assignments.enumerated() { buckets[cluster, default: []].insert(index) }
            return Set(buckets.values)
        }
        XCTAssertEqual(composition(first), composition(second))
    }

    /// Число тем по умолчанию — соглашение по размеру выборки, и оно должно
    /// быть предсказуемым.
    func testTheDefaultNumberOfTopicsIsAStatedConvention() {
        XCTAssertEqual(KMeans.defaultK(for: 100), 4)
        XCTAssertEqual(KMeans.defaultK(for: 300), 6)
        XCTAssertEqual(KMeans.defaultK(for: 1000), 11)
        XCTAssertEqual(KMeans.defaultK(for: 9771), 24)
        // Границы: и на трёх документах, и на миллионе список должен остаться
        // читаемым.
        XCTAssertEqual(KMeans.defaultK(for: 10), 4)
        XCTAssertEqual(KMeans.defaultK(for: 1_000_000), 24)
    }

    ///, первая половина: мера не должна улучшаться от одного лишь
    /// дробления.
    ///
    /// Упрощённый силуэт (расстояния до центров) этим свойством как раз
    /// обладает — каждый новый центр приближает точку к своему сильнее, чем к
    /// чужому. На настоящих трёх группах он вырос бы при k=12; настоящий
    /// силуэт обязан упасть.
    func testSplittingRealGroupsFurtherMakesTheScoreWorse() {
        let points = VectorSet(vectors: groups(count: 3, perGroup: 40, noise: 0.1), dimension: 8)
        let honest = KMeans.fit(points, k: 3, seed: 42)
        let shredded = KMeans.fit(points, k: 12, seed: 42)
        XCTAssertGreaterThan(honest.silhouette, shredded.silhouette)
    }

    ///, вторая половина: если коллекция делится надвое отчётливее, чем на
    /// выбранное число тем, отчёт обязан это сказать — но не подменять этим
    /// список.
    func testADominantCoarseSplitIsReportedButDoesNotBecomeTheAnswer() {
        // Две настоящие группы: деление надвое здесь заведомо лучше любого
        // дробления.
        let twoGroups = VectorSet(vectors: groups(count: 2, perGroup: 60, noise: 0.1), dimension: 8)
        let selection = KMeans.suggestK(twoGroups, seed: 42)
        XCTAssertTrue(selection.coarseSplitDominates, "силуэты: \(selection.line)")
        XCTAssertGreaterThanOrEqual(selection.k, 4, "и всё же список остаётся списком")

        // Восемь групп: делить надвое здесь нечего.
        let manyGroups = VectorSet(vectors: groups(count: 8, perGroup: 40, noise: 0.1), dimension: 8)
        XCTAssertFalse(KMeans.suggestK(manyGroups, seed: 42).coarseSplitDominates)
    }

    /// Тексты выборки в память не тянутся: поимённо читаются только те
    /// документы, что попадут в примеры тем и в список неотнесённых.
    /// Иначе выборка в десятки тысяч документов держала сотни мегабайт текста
    /// рядом с векторами, и приложение переставало отвечать.
    func testOnlyExampleTextsAreRead() async throws {
        let reader = Reader()
        filled(reader, groups: 4, perGroup: 60)
        let options = TopicClustering.Options(clusterCount: 4, examplesPerTopic: 3, unassignedExamples: 5)
        let report = try await TopicClustering(reader: reader).run(
            collection: collection(), options: options
        )
        XCTAssertEqual(report.examined, 240)
        XCTAssertLessThanOrEqual(
            reader.textsReadByID, 4 * 3 + 5,
            "тексты читаются только у примеров, а не у всей выборки"
        )
        XCTAssertFalse(
            report.topics.contains { $0.examples.contains { $0.excerpt.isEmpty } },
            "у примеров текст всё-таки должен быть"
        )
    }

    func testTheReportSaysWhenTheCollectionSplitsInTwo() async throws {
        let reader = Reader()
        filled(reader, groups: 2, perGroup: 60)
        let report = try await TopicClustering(reader: reader).run(collection: collection())
        XCTAssertTrue(
            report.notes.contains { $0.contains("делится надвое") },
            "оговорки: \(report.notes)"
        )
    }

    /// Пустой кластер не должен молча уменьшать k: отчёт обещает пять тем —
    /// значит, пять центров и есть.
    func testAnEmptyClusterGetsRefilledInsteadOfVanishing() {
        // Три плотные группы и просьба разбить на пять: двум центрам своих
        // точек не достанется, и они обязаны переехать к самым далёким.
        let points = VectorSet(vectors: groups(count: 3, perGroup: 12, noise: 0.05), dimension: 8)
        let fit = KMeans.fit(points, k: 5, seed: 42)
        XCTAssertEqual(fit.centroids.count, 5)
        for centroid in fit.centroids {
            let length = centroid.reduce(0) { $0 + $1 * $1 }.squareRoot()
            XCTAssertEqual(length, 1, accuracy: 1e-9, "центр не единичной длины")
        }
    }

    /// Нулевой вектор направления не имеет — и в кластеризацию не идёт. Важно
    /// не то, что он отброшен, а что набор говорит, кого именно он отбросил:
    /// на этом держится соответствие «точка ↔ документ».
    func testTheSetReportsWhichVectorsItKept() {
        let vectors: [[Double]] = [[1, 0, 0], [0, 0, 0], [0, 1, 0], [0, 0], [0, 0, 1]]
        let points = VectorSet(vectors: vectors, dimension: 3)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.keptIndexes, [0, 2, 4])
    }

    // MARK: - Не отнесённые ни к одной теме

    func testAHomogeneousSetHasNoStrays() {
        // Все расстояния одинаковы: медианное отклонение — ноль, и объявлять
        // выбросом половину коллекции нельзя.
        let threshold = TopicClustering.outlierThreshold([0.2, 0.2, 0.2, 0.2, 0.2])
        XCTAssertEqual(threshold, .greatestFiniteMagnitude)
    }

    func testTheOutlierIsPastTheThresholdAndTheRestIsNot() {
        let distances = [0.10, 0.12, 0.11, 0.13, 0.12, 0.9]
        let threshold = TopicClustering.outlierThreshold(distances)
        XCTAssertLessThan(threshold, 0.9)
        XCTAssertEqual(distances.filter { $0 > threshold }, [0.9])
    }

    // MARK: - Прогон целиком

    private func filled(_ reader: Reader, groups groupCount: Int, perGroup: Int, dimension: Int = 8) {
        let vectors = groups(count: groupCount, perGroup: perGroup, dimension: dimension)
        for (index, vector) in vectors.enumerated() {
            let id = String(format: "doc-%03d", index)
            reader.records.append(DocumentRecord(
                id: id, document: "документ \(index) из группы \(index / perGroup)", metadata: nil
            ))
            reader.vectors[id] = vector
        }
    }

    func testItBuildsAListOfTopicsWithNumbers() async throws {
        let reader = Reader()
        filled(reader, groups: 3, perGroup: 30)

        let report = try await TopicClustering(reader: reader).run(
            collection: collection(), options: .init(clusterCount: 3, seed: 42)
        )

        XCTAssertEqual(report.topics.count, 3)
        XCTAssertEqual(report.clustered, 90)
        XCTAssertEqual(report.examined, 90)
        // Числа обязаны сходиться: сумма тем плюс неотнесённые — это всё, что
        // кластеризовалось, и ни документом больше.
        let counted = report.topics.reduce(0) { $0 + $1.documentCount } + report.unassigned.documentCount
        XCTAssertEqual(counted, report.clustered)
        XCTAssertEqual(report.topics.reduce(0) { $0 + $1.share } + report.unassigned.share, 1, accuracy: 1e-9)
        // Примеры — настоящие документы этой темы, а не чужие строки.
        for topic in report.topics {
            XCTAssertFalse(topic.examples.isEmpty)
            for example in topic.examples {
                XCTAssertTrue(reader.vectors.keys.contains(example.id))
                XCTAssertTrue(example.excerpt.hasPrefix("документ "))
            }
        }
        // Векторы взяты из базы: заново их считать нечем — в протоколе нет
        // эмбеддинга вовсе, — а обращения за ними видны по счётчику.
        XCTAssertGreaterThan(reader.embeddingReads, 0)
    }

    /// Регрессия на самое неприятное, что здесь может произойти: нулевой вектор
    /// в середине выборки сдвигает все последующие документы на один, и тема
    /// получает примеры от чужих строк. Молча и правдоподобно.
    func testAZeroVectorDoesNotShiftTheExamples() async throws {
        let reader = Reader()
        filled(reader, groups: 2, perGroup: 20)
        reader.vectors["doc-005"] = [Double](repeating: 0, count: 8)

        let report = try await TopicClustering(reader: reader).run(
            collection: collection(), options: .init(clusterCount: 2, seed: 42)
        )

        XCTAssertEqual(report.clustered, 39)
        XCTAssertTrue(report.notes.contains { $0.contains("Нулевых векторов") })
        let all = report.topics.flatMap(\.examples) + report.unassigned.examples
        XCTAssertFalse(all.isEmpty)
        for example in all {
            let expected = reader.records.first { $0.id == example.id }?.document
            XCTAssertEqual(example.excerpt, expected, "пример \(example.id) описан чужим текстом")
        }
        XCTAssertFalse(all.contains { $0.id == "doc-005" })
    }

    func testDocumentsWithoutVectorsAreCountedAndExplained() async throws {
        let reader = Reader()
        filled(reader, groups: 2, perGroup: 15)
        reader.vectors["doc-000"] = nil
        reader.vectors["doc-001"] = nil

        let report = try await TopicClustering(reader: reader).run(
            collection: collection(), options: .init(clusterCount: 2, seed: 42)
        )
        XCTAssertEqual(report.examined, 30)
        XCTAssertEqual(report.clustered, 28)
        XCTAssertTrue(report.notes.contains { $0.contains("Без вектора") })
    }

    func testTooFewDocumentsIsAnHonestRefusal() async {
        let reader = Reader()
        reader.records = [DocumentRecord(id: "один", document: "текст", metadata: nil)]
        reader.vectors["один"] = [1, 0, 0, 0, 0, 0, 0, 0]

        do {
            _ = try await TopicClustering(reader: reader).run(collection: collection())
            XCTFail("одна строка — это не коллекция тем")
        } catch let error as ClusteringError {
            XCTAssertEqual(error, .tooFewDocuments(1))
        } catch {
            XCTFail("не та ошибка: \(error)")
        }
    }

    // MARK: - Названия тем

    func testTheModelNamesTheTopics() async throws {
        let reader = Reader()
        filled(reader, groups: 2, perGroup: 20)
        let asked = Prompts()

        let report = try await TopicClustering(reader: reader).run(
            collection: collection(),
            options: .init(clusterCount: 2, seed: 42),
            namer: ("qwen", { prompt, schema in
                asked.append(prompt)
                XCTAssertEqual(schema.name, "topic")
                return #"{"title": "Отчёты по продажам", "summary": "Квартальные сводки."}"#
            })
        )

        XCTAssertEqual(report.namingModel, "qwen")
        XCTAssertEqual(asked.all.count, 2, "по одному вызову на тему")
        for topic in report.topics {
            XCTAssertEqual(topic.title, "Отчёты по продажам")
            XCTAssertEqual(topic.summary, "Квартальные сводки.")
            XCTAssertTrue(topic.isNamed)
        }
        // В промпт уходят отрывки документов, а не идентификаторы.
        XCTAssertTrue(asked.all[0].contains("документ "))
    }

    /// Модель без Structured Output ответит прозой. Тема останется без
    /// названия — и отчёт скажет об этом, а не сделает вид, что всё хорошо.
    func testAnUnparsableAnswerLeavesTheTopicNumbered() async throws {
        let reader = Reader()
        filled(reader, groups: 2, perGroup: 20)

        let report = try await TopicClustering(reader: reader).run(
            collection: collection(),
            options: .init(clusterCount: 2, seed: 42),
            namer: ("qwen", { _, _ in "Ну, тут всё про продажи, наверное." })
        )

        for topic in report.topics {
            XCTAssertFalse(topic.isNamed)
            XCTAssertTrue(topic.title.hasPrefix("Тема "))
        }
        XCTAssertEqual(report.notes.filter { $0.contains("не разобран") }.count, 2)
    }

    func testAModelFailureIsNotedInsteadOfSinkingTheRun() async throws {
        let reader = Reader()
        filled(reader, groups: 2, perGroup: 20)

        let report = try await TopicClustering(reader: reader).run(
            collection: collection(),
            options: .init(clusterCount: 2, seed: 42),
            namer: ("qwen", { _, _ in throw LMStudioError.emptyResponse })
        )
        XCTAssertEqual(report.topics.count, 2)
        XCTAssertEqual(report.notes.filter { $0.contains("не назвала тему") }.count, 2)
    }

    /// У называния тем свой срок ожидания, и он длиннее общего.
    ///
    /// Сторож против «наведения порядка»: общий `timeouts.chat` рассчитан на
    /// чанкинг, где запросов тысячи, а здесь их два десятка и первый уходит в
    /// ещё не загруженную модель. Если override уберут, тест скажет об этом.
    func testNamingWaitsLongerThanAnOrdinaryChatCall() {
        XCTAssertEqual(TopicClustering.namingTimeout, 300)
        XCTAssertGreaterThan(TopicClustering.namingTimeout, TimeoutSettings().chat)
    }

    func testParsingTheAnswer() {
        XCTAssertEqual(
            TopicClustering.parse(#"{"title":"Договоры","summary":"Тексты договоров."}"#)?.title,
            "Договоры"
        )
        // «Думающая» модель обрамляет ответ рассуждением — JSON всё равно
        // должен найтись.
        XCTAssertEqual(
            TopicClustering.parse("Похоже на договоры.\n{\"title\":\"Договоры\",\"summary\":\"\"}")?.summary,
            nil
        )
        XCTAssertNil(TopicClustering.parse("никакого JSON здесь нет"))
        XCTAssertNil(TopicClustering.parse(#"{"title":"   "}"#))
        XCTAssertNil(TopicClustering.parse(#"{"summary":"есть описание, нет названия"}"#))
    }

    // MARK: - Отчёт

    func testTheReportReadsAsATableAndNamesTheUnassigned() async throws {
        let reader = Reader()
        filled(reader, groups: 3, perGroup: 20)
        let report = try await TopicClustering(reader: reader).run(
            collection: collection(), options: .init(clusterCount: 3, seed: 42)
        )

        let markdown = TopicExport.markdown(report)
        XCTAssertTrue(markdown.contains("# Темы коллекции «темы»"))
        XCTAssertTrue(markdown.contains("| Тема | Документов | Доля |"))
        XCTAssertTrue(markdown.contains("Не отнесены ни к одной теме"))
        XCTAssertTrue(markdown.contains("Зерно: 42"))
        XCTAssertTrue(markdown.contains("В метаданные документов номера и названия тем не записывались"))

        let decoded = try TopicExport.decode(try TopicExport.json(report))
        XCTAssertEqual(decoded.topics.count, report.topics.count)
        XCTAssertEqual(decoded.seed, report.seed)
        XCTAssertEqual(decoded.unassigned.documentCount, report.unassigned.documentCount)
    }

    func testTopicsAreListedBiggestFirst() async throws {
        let reader = Reader()
        // Разные по величине группы: 40, 20 и 10.
        var random = SeededRandom(seed: 3)
        var index = 0
        for (axis, size) in [(0, 40), (1, 20), (2, 10)] {
            for _ in 0..<size {
                let id = String(format: "doc-%03d", index)
                reader.records.append(DocumentRecord(id: id, document: "текст \(index)", metadata: nil))
                reader.vectors[id] = point(axis: axis, dimension: 8, noise: 0.1, random: &random)
                index += 1
            }
        }

        let report = try await TopicClustering(reader: reader).run(
            collection: collection(), options: .init(clusterCount: 3, seed: 42)
        )
        XCTAssertEqual(report.topics.map(\.documentCount), report.topics.map(\.documentCount).sorted(by: >))
    }

    func testTheStoreKeepsTheLastRuns() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("topics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TopicReportStore(directory: directory)

        for offset in 0..<(TopicReportStore.historyLimit + 3) {
            store.record(TopicReport(
                collectionName: "темы",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset) * 60),
                topics: [Topic(id: 0, title: "Тема", documentCount: offset + 1, share: 1, averageDistance: 0, examples: [])]
            ))
        }
        let reports = store.reports(for: "темы")
        XCTAssertEqual(reports.count, TopicReportStore.historyLimit)
        // Новые сверху.
        XCTAssertEqual(reports.first?.topics.first?.documentCount, TopicReportStore.historyLimit + 3)
    }

    func testQualityIsSaidInWordsNotInASilhouetteNumber() {
        XCTAssertTrue(TopicReport(collectionName: "x", silhouette: 0.01).quality.contains("почти не отделяются"))
        XCTAssertTrue(TopicReport(collectionName: "x", silhouette: 0.6).quality.contains("чётко"))
    }
}

/// K2 и L5 в виде сторожа по исходникам.
///
/// Согласие пользователя было дано на **список тем с числами и примерами, без
/// какой-либо графической проекции векторов**. Границы этого согласия должен
/// охранять не комментарий, а тест: он читает исходники кластеризации и падает,
/// если в них появится проекция, запись в базу или повторный эмбеддинг.
final class ClusteringStaysWithinItsPermissionTests: XCTestCase {
    private var sources: [URL] {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/ChromaCore/Clustering")
            return try FileManager.default
                .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
        }
    }

    private func code(of file: URL) throws -> [(line: Int, text: String)] {
        try String(contentsOf: file, encoding: .utf8)
            .components(separatedBy: .newlines)
            .enumerated()
            .map { ($0.offset + 1, $0.element.components(separatedBy: "//").first ?? $0.element) }
    }

    /// результат сохраняется как отчёт, в метаданные документов не
    /// записывается. И повторный эмбеддинг не выполняется.
    func testItNeverWritesAndNeverReembeds() throws {
        let forbidden = [
            ".upsert(", ".add(", ".updateDocuments(", ".deleteDocuments(",
            ".createCollection(", ".updateCollection(", ".deleteCollection(",
            ".embed(", ".embedIgnoringCache(",
        ]
        var offenders: [String] = []
        for file in try sources {
            for (number, text) in try code(of: file) {
                for call in forbidden where text.contains(call) {
                    offenders.append("\(file.lastPathComponent):\(number): \(text.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "K2.3 нарушен:\n\(offenders.joined(separator: "\n"))")
    }

    /// L5 и 6.4: ни проекций, ни раскладок, ни диаграмм рассеяния.
    func testItNeverProjectsVectorsOntoAPlane() throws {
        let forbidden = ["PCA", "UMAP", "tSNE", "t-SNE", "TSNE", "scatterPlot", "projection2D", "Chart("]
        var offenders: [String] = []
        for file in try sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in forbidden {
                // Запретные слова в комментариях разрешены — ими как раз и
                // объясняется, чего этот код не делает. Ищем в коде.
                for (number, code) in try code(of: file) where code.contains(word) {
                    offenders.append("\(file.lastPathComponent):\(number): \(word)")
                }
                _ = text
            }
        }
        XCTAssertTrue(offenders.isEmpty, "L5 нарушен:\n\(offenders.joined(separator: "\n"))")
    }

    func testTheGuardActuallyReadsTheClustering() throws {
        let files = try sources
        XCTAssertGreaterThanOrEqual(files.count, 3)
        let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(text.contains("InspectionReader"))
        XCTAssertTrue(text.contains("public static func fit("))
    }
}
