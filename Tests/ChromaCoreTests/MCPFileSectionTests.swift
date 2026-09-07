import XCTest
@testable import ChromaCore

/// Карта файла и чтение по разделу.
///
/// Проверяется одно свойство, из которого растёт всё остальное: **раздел,
/// который карта называет, должен выдаваться целиком**. Иначе на карте есть
/// место, куда сама карта не ведёт, а агент читает раздел и не знает, что
/// часть его потерялась.
final class MCPFileSectionTests: XCTestCase {
    private func chunk(_ index: Int, heading: String?) -> MCPDocumentPayload {
        var metadata: ChromaMetadata = [
            "source_file": .string("папка/тз.md"),
            "file_id": .string("abcdef0123456789"),
            MCPFileChunks.orderKey: .int(index),
        ]
        if let heading { metadata["heading_path"] = .string(heading) }
        return MCPDocumentPayload(id: "c\(index)", text: "кусок \(index)", metadata: metadata)
    }

    /// Кусок без заголовка — таблица или продолжение абзаца — принадлежит
    /// разделу, внутри которого лежит.
    func testAChunkWithoutAHeadingBelongsToTheSectionItSitsIn() {
        let documents = [
            chunk(0, heading: nil),
            chunk(1, heading: "Общие положения"),
            chunk(2, heading: nil),
            chunk(3, heading: "Общие положения > Термины"),
        ]
        XCTAssertEqual(
            MCPToolService.effectiveHeadings(of: documents),
            [
                MCPToolService.beforeFirstHeading,
                "Общие положения",
                "Общие положения",
                "Общие положения > Термины",
            ]
        )
    }

    /// То, что карта посчитала разделом, отбор по «heading» отдаёт целиком:
    /// счёт кусков у карты и у отбора обязан совпадать.
    func testTheOutlineAndTheSelectorCountTheSameChunks() {
        let documents = [
            chunk(0, heading: nil),
            chunk(1, heading: "Требования"),
            chunk(2, heading: nil),
            chunk(3, heading: nil),
            chunk(4, heading: "Приёмка"),
        ]
        let headings = MCPToolService.effectiveHeadings(of: documents)
        let inSection = zip(documents, headings).filter { $0.1 == "Требования" }.count
        XCTAssertEqual(inSection, 3, "два безымянных куска после заголовка принадлежат ему")
        XCTAssertEqual(headings.filter { $0 == MCPToolService.beforeFirstHeading }.count, 1)
    }

    /// Подразделы берутся вместе с разделом, а полный путь — только свои.
    func testAskingForASectionTakesItsSubsections() {
        let documents = [
            chunk(0, heading: "Общие положения"),
            chunk(1, heading: "Общие положения > Термины"),
            chunk(2, heading: "Приёмка"),
        ]
        let headings = MCPToolService.effectiveHeadings(of: documents)
        func matching(_ heading: String) -> Int {
            zip(documents, headings)
                .filter { $0.1 == heading || $0.1.hasPrefix(heading + " > ") }
                .count
        }
        XCTAssertEqual(matching("Общие положения"), 2)
        XCTAssertEqual(matching("Общие положения > Термины"), 1)
        XCTAssertEqual(matching("Приёмка"), 1)
    }

    /// Пустой `heading_path` — это отсутствие заголовка, а не заголовок «».
    func testAnEmptyHeadingPathIsTreatedAsNoHeading() {
        let documents = [chunk(0, heading: "Раздел"), chunk(1, heading: "")]
        XCTAssertEqual(MCPToolService.effectiveHeadings(of: documents), ["Раздел", "Раздел"])
    }

    /// Карта одного раздела: схема обещает «outline вместе с heading», и это
    /// единственный выход, когда карта целого файла не поместилась.
    func testTheOutlineOfOneSectionCoversOnlyThatSection() async throws {
        let documents = [
            chunk(0, heading: "Требования"),
            chunk(1, heading: "Требования > Функциональные"),
            chunk(2, heading: nil),
            chunk(3, heading: "Приёмка"),
        ]
        let service = await service(Backend(chunks: documents))
        let result = try await call(service, [
            "collection": .string("заметки"),
            "file": .string("папка/тз.md"),
            "outline": .bool(true),
            "outline_depth": .int(9),
            "heading": .string("Требования"),
        ])
        guard case .array(let sections)? = result["structuredContent"]?["sections"] else {
            return XCTFail("разделов нет вовсе")
        }
        let names = sections.compactMap { $0["heading"]?.stringValue }
        XCTAssertEqual(names, ["Требования", "Требования > Функциональные"])
        XCTAssertEqual(result["structuredContent"]?["chunksInSection"], .int(3), "безымянный кусок принадлежит разделу")
        XCTAssertEqual(
            result["structuredContent"]?["totalChunks"], .int(4),
            "«всего кусков» — у файла: по этому полю решают, читается ли документ целиком"
        )
        XCTAssertEqual(result["structuredContent"]?["heading"], .string("Требования"))
    }

    /// Карта раздела показывает **его части** — и при умолчании глубины.
    ///
    /// Глубина считалась от корня, а не от спрошенного раздела: «Требования»
    /// с умолчанием 1 сворачивались в одну строку — сам этот раздел. А это
    /// единственный выход из урезанной карты, и пометка об урезании зовёт
    /// ровно сюда: выход был, и не вёл никуда.
    func testTheMapOfOneSectionShowsItsPartsAtTheDefaultDepth() async throws {
        let documents = [
            chunk(0, heading: "Требования"),
            chunk(1, heading: "Требования > Функциональные"),
            chunk(2, heading: "Требования > Приёмка"),
            chunk(3, heading: "Приёмка"),
        ]
        let service = await service(Backend(chunks: documents))
        let result = try await call(service, [
            "collection": .string("заметки"),
            "file": .string("папка/тз.md"),
            "outline": .bool(true),
            "heading": .string("Требования"),
        ])
        guard case .array(let sections)? = result["structuredContent"]?["sections"] else {
            return XCTFail("разделов нет вовсе")
        }
        XCTAssertEqual(
            sections.compactMap { $0["heading"]?.stringValue },
            ["Требования", "Требования > Функциональные", "Требования > Приёмка"]
        )
    }

    /// Вес целого — у файла, даже когда спрошен раздел: пара к `totalChunks`,
    /// и по ней тоже решают, читается ли документ целиком.
    func testTheWeightOfTheWholeStaysTheFilesWhenOneSectionIsAsked() async throws {
        func weighted(_ index: Int, heading: String, tokens: Int) -> MCPDocumentPayload {
            MCPDocumentPayload(
                id: "c\(index)",
                text: "кусок \(index)",
                metadata: [
                    "source_file": .string("папка/тз.md"),
                    "file_id": .string("abcdef0123456789"),
                    MCPFileChunks.orderKey: .int(index),
                    "heading_path": .string(heading),
                    "chunk_estimated_tokens": .int(tokens),
                ]
            )
        }
        let documents = [
            weighted(0, heading: "Требования", tokens: 100),
            weighted(1, heading: "Приёмка", tokens: 200),
            weighted(2, heading: "Приёмка", tokens: 300),
        ]
        let service = await service(Backend(chunks: documents))
        let result = try await call(service, [
            "collection": .string("заметки"),
            "file": .string("папка/тз.md"),
            "outline": .bool(true),
            "heading": .string("Требования"),
        ])
        XCTAssertEqual(result["structuredContent"]?["estimatedTokens"], .int(600), "вес целого файла")
        XCTAssertEqual(result["structuredContent"]?["estimatedTokensInSection"], .int(100), "вес раздела")
    }

    /// Имя раздела с неразрывным пробелом находится обычным пробелом.
    ///
    /// Живой случай: раздел «…Общественного облака и\u{00A0}Частного облака» —
    /// 352 куска, пятая часть ТЗ. Карта его назвала, агент перепечатал имя
    /// обычным пробелом и получил «в файле нет такого раздела». Невидимая
    /// закорючка стоила ста тысяч токенов непрочитанного.
    func testASectionNamedWithANonBreakingSpaceIsFoundByAPlainOne() async throws {
        let hidden = "Требования к услугам Общественного и\u{00A0}Частного облака"
        let documents = (0..<3).map { chunk($0, heading: hidden) }
        let service = await service(Backend(chunks: documents))
        let result = try await call(service, [
            "collection": .string("заметки"),
            "file": .string("папка/тз.md"),
            "heading": .string("Требования к услугам Общественного и Частного облака"),
        ])
        XCTAssertEqual(result["structuredContent"]?["chunksInSection"], .int(3))
        XCTAssertFalse(
            (result["content"]?[0]?["text"]?.stringValue ?? "").contains("has no section"),
            "раздел с карты обязан находиться"
        )
    }

    /// И карта печатает имя, которое можно набрать: перевод строки внутри
    /// заголовка на экране неотличим от пробела.
    func testTheMapPrintsHeadingsThatCanBeTypedBack() async throws {
        let broken = "Приложение 17 Угрозы безопасности\nна вычислительных ресурсах"
        let service = await service(Backend(chunks: (0..<2).map { chunk($0, heading: broken) }))
        let result = try await call(service, [
            "collection": .string("заметки"),
            "file": .string("папка/тз.md"),
            "outline": .bool(true),
        ])
        guard case .array(let sections)? = result["structuredContent"]?["sections"] else {
            return XCTFail("разделов нет вовсе")
        }
        XCTAssertEqual(
            sections.first?["heading"]?.stringValue,
            "Приложение 17 Угрозы безопасности на вычислительных ресурсах"
        )
    }

    /// Промах по имени называет ближайшие разделы, а не отсылает за картой,
    /// из которой имя и взято.
    func testAMissedSectionNamesTheNearestOnes() async throws {
        let documents = [
            chunk(0, heading: "Требования к сопровождению услуг"),
            chunk(1, heading: "Приёмка работ"),
        ]
        let service = await service(Backend(chunks: documents))
        let result = try await call(service, [
            "collection": .string("заметки"),
            "file": .string("папка/тз.md"),
            "heading": .string("Требования к сопровождению"),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("Требования к сопровождению услуг"), text)
        guard case .array(let nearest)? = result["structuredContent"]?["nearestSections"] else {
            return XCTFail("ближайших разделов нет: \(text)")
        }
        XCTAssertEqual(nearest.first?.stringValue, "Требования к сопровождению услуг")
    }

    /// Раздел, который не дочитать за десять вызовов, говорит это **первой
    /// строкой** — как чтение по порядку с.
    func testASectionTooBigForOneAnswerSaysSoInTheFirstLine() async throws {
        let service = await service(Backend(chunks: (0..<47).map { chunk($0, heading: "Общие положения") }))
        let result = try await call(service, [
            "collection": .string("заметки"),
            // Ветка кусков названа явно: умолчание — текст.
            "as": .string("chunks"),
            "file": .string("папка/тз.md"),
            "heading": .string("Общие положения"),
            "limit": .int(4),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.hasPrefix("This section does not fit in one answer"), text)
        // Считается оставшееся: показано 4 из 47, дочитывать 43 — одиннадцать
        // вызовов, а не двенадцать «с начала».
        XCTAssertEqual(result["structuredContent"]?["callsToFinishSection"], .int(11))
        XCTAssertEqual(result["structuredContent"]?["sectionFitsInOneAnswer"], .bool(false))
        // Раздел без подразделов не отсылают к карте: она вернёт его же.
        XCTAssertTrue(text.contains("Or read it on with «offset»"), text)
        XCTAssertFalse(text.contains("take its structure first"), text)
        // И первым называется самый дешёвый маршрут — тот же раздел текстом
        //: до этой правки о нём не говорила ни одна заметка.
        XCTAssertTrue(text.contains("The same section as text costs fewer calls"), text)
    }

    /// На последней странице приговор молчит: «читать целиком — шестнадцать
    /// вызовов» тому, кто дочитал сорок четыре из сорока семи, — неправда
    /// о его положении, да ещё первой строкой.
    func testTheLastPageOfASectionIsNotToldToGiveUp() async throws {
        let service = await service(Backend(chunks: (0..<47).map { chunk($0, heading: "Общие положения") }))
        let result = try await call(service, [
            "collection": .string("заметки"),
            "file": .string("папка/тз.md"),
            "heading": .string("Общие положения"),
            "limit": .int(3),
            "offset": .int(44),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertFalse(text.contains("does not fit in one answer"), text)
        XCTAssertEqual(result["structuredContent"]?["hasMore"], .bool(false))
        XCTAssertNil(result["structuredContent"]?["callsToFinishSection"])
    }

    /// У раздела с подразделами совет другой — и он исполним.
    func testASectionWithSubsectionsIsSentToItsOwnMap() async throws {
        let documents = (0..<47).map { number in
            chunk(number, heading: number < 20 ? "Требования" : "Требования > Приёмка")
        }
        let service = await service(Backend(chunks: documents))
        let result = try await call(service, [
            "collection": .string("заметки"),
            // Ветка кусков названа явно: умолчание — текст.
            "as": .string("chunks"),
            "file": .string("папка/тз.md"),
            "heading": .string("Требования"),
            "limit": .int(4),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("Or take its structure first"), text)
        XCTAssertFalse(text.contains("Or read it on with «offset»"), text)
        XCTAssertTrue(text.contains("The same section as text costs fewer calls"), text)
    }

    /// Ближайшие разделы при равном счёте идут в порядке файла: `sorted`
    /// в Swift не устойчива, и список менялся бы от вызова к вызову.
    func testNearestSectionsKeepFileOrderOnEqualScores() {
        // Больше двадцати кандидатов нарочно: до двадцати Swift сортирует
        // вставками, а они устойчивы, и прежняя проверка на трёх заголовках
        // проходила бы и без закрепления порядка.
        let headings = (0..<30).map { "Требования к оказанию услуг \($0)" } + ["Приёмка"]
        let nearest = MCPToolService.nearestSections(to: "Требования к оказанию услуг", among: headings)
        XCTAssertEqual(nearest, Array(headings.prefix(5)), "порядок — файловый, а не какой придётся")
    }

    /// Промах в имени подраздела предлагает подразделы, а не главу.
    ///
    /// Опечатка в шести кусках отправляла агента читать главу на триста
    /// пятьдесят — девяноста вызовами.
    func testNearestSectionsAnswerAtTheDepthThatWasAsked() {
        let headings = [
            "Требования", "Требования > Приёмка", "Требования > Сроки", "Прочее",
        ]
        let nearest = MCPToolService.nearestSections(to: "Требования > Приёмк", among: headings)
        XCTAssertTrue(
            nearest.contains("Требования > Приёмка"),
            "подраздел, которого хотели, обязан быть в списке: \(nearest)"
        )
        // Совпадение считается по целым словам, поэтому опечатка внутри слова
        // сама по себе не поднимает кандидата — но глубина уже своя, и в
        // списке стоят подразделы, а не одна глава на триста пятьдесят кусков.
        XCTAssertTrue(nearest.contains { $0.contains(" > ") }, nearest.description)
        XCTAssertFalse(nearest.contains("Прочее"), nearest.description)
    }

    /// Ничего похожего — так и сказано, а не выдан титульный лист за близкое.
    func testNothingCloseIsSaidPlainlyInsteadOfOfferingTheFrontMatter() {
        let headings = ["Содержание", "Общие положения", "Приёмка"]
        XCTAssertTrue(
            MCPToolService.nearestSections(to: "гидравлика насосной станции", among: headings).isEmpty
        )
    }

    // MARK: - Документ целиком

    /// Сплошной текст несёт документ, а не список кусков.
    ///
    /// Замер, из-за которого режим и сделан: ответ чтения по разделу на
    /// 19 942 знака нёс 4 590 знаков документа — 23 %. Текст уезжал дважды
    /// (строкой и зеркалом), метаданные — 1 223 знака на кусок против 1 180
    /// знаков текста. Здесь текст уезжает один раз и без обвязки.
    func testTextShapeCarriesTheDocumentAndNotTheScaffolding() async throws {
        let documents = (0..<6).map { chunk($0, heading: "Раздел") }
        let service = await service(Backend(chunks: documents))
        let result = try await call(service, [
            "collection": .string("заметки"),
            "file": .string("папка/тз.md"),
            "as": .string("text"),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        for number in 0..<6 {
            XCTAssertTrue(text.contains("кусок \(number)"), "куска \(number) нет: \(text)")
        }
        // Обвязки нет: ни идентификаторов, ни строки метаданных.
        XCTAssertFalse(text.contains("id «c0»"), text)
        XCTAssertFalse(text.contains("source_file"), text)
        // И зеркала текста нет — ради этого режим и сделан.
        XCTAssertNil(result["structuredContent"]?["documents"])
        XCTAssertEqual(result["structuredContent"]?["as"], .string("text"))
        XCTAssertEqual(result["structuredContent"]?["hasMore"], .bool(false))
    }

    /// Перекрытие кусков не превращается в повторы документа.
    ///
    /// Нарезка по умолчанию перекрывает куски на 15 %: склеенные встык, они
    /// дали бы текст, где каждый шов повторён, — а повторённый пункт ТЗ
    /// читается как отдельный.
    func testOverlappingChunksAreJoinedWithoutTheRepeats() {
        // Доли как у настоящей нарезки: кусок около тысячи знаков,
        // перекрытие около пятнадцати процентов.
        let seam = "коэффициент доступности услуги не ниже 99,5 процента в месяц."
        let head = String(repeating: "Исполнитель оказывает услуги по заказам. ", count: 12)
        let tail = String(repeating: "Плановые перерывы в расчёт не принимаются. ", count: 12)
        let joined = MCPToolService.joinedText([head + seam, seam + tail])
        XCTAssertEqual(joined.text, head + seam + tail)
        XCTAssertEqual(joined.trimmed, seam.count)
    }

    /// Случайное совпадение хвоста и зачина короче зонда не срезается:
    /// лишний срез **удаляет текст документа**, и это дороже повтора.
    func testAShortAccidentalMatchIsNotTrimmed() {
        let joined = MCPToolService.joinedText([
            "Работы принимаются по акту.",
            "по акту. Оплата в течение тридцати дней с даты подписания акта.",
        ])
        XCTAssertEqual(joined.trimmed, 0)
        XCTAssertTrue(joined.text.contains("акту.\nпо акту."), joined.text)
    }

    /// Куски без перекрытия склеиваются переводом строки, а не слипаются.
    func testChunksWithoutOverlapKeepTheirBoundary() {
        let joined = MCPToolService.joinedText(["первый абзац", "второй абзац"])
        XCTAssertEqual(joined.text, "первый абзац\nвторой абзац")
        XCTAssertEqual(joined.trimmed, 0)
    }

    /// Сплошным текстом читается и один раздел.
    func testTextShapeAlsoReadsOneSection() async throws {
        let documents = [
            chunk(0, heading: "Требования"),
            chunk(1, heading: "Требования > Приёмка"),
            chunk(2, heading: "Прочее"),
        ]
        let service = await service(Backend(chunks: documents))
        let result = try await call(service, [
            "collection": .string("заметки"),
            "file": .string("папка/тз.md"),
            "as": .string("text"),
            "heading": .string("Требования"),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("кусок 0") && text.contains("кусок 1"), text)
        XCTAssertFalse(text.contains("кусок 2"), "чужой раздел в выдаче: \(text)")
        XCTAssertEqual(result["structuredContent"]?["chunksInSection"], .int(2))
    }

    /// Незнакомое значение «as» — отказ, а не молчаливое «как было».
    func testAnUnknownShapeIsRefusedInsteadOfIgnored() async throws {
        let service = await service(Backend(chunks: [chunk(0, heading: "Раздел")]))
        let outcome = try await service.call(
            name: "get_file",
            arguments: .object([
                "collection": .string("заметки"),
                "file": .string("папка/тз.md"),
                "as": .string("full"),
            ]),
            key: key
        )
        guard case .failure(let error) = outcome else {
            return XCTFail("незнакомое «as» принято молча")
        }
        XCTAssertTrue(error.message.contains("«text»"), error.message)
    }

    /// Сколько документа несёт ответ — замером, а не на слово (правило 4
    /// приложения 5).
    ///
    /// Замер на живом ответе Hermes: 19 942 знака ответа несли 4 590 знаков
    /// документа. Здесь то же сравнение на своей подложке, с настоящими
    /// длинами куска и метаданных.
    func testTextShapeCarriesSeveralTimesMoreOfTheDocument() async throws {
        // Кусок и метаданные — как в живой коллекции: 1150 знаков текста,
        // около 1200 знаков метаданных.
        let filler = String(repeating: "требование к услуге ", count: 58)
        let documents = (0..<200).map { index in
            MCPDocumentPayload(
                id: "chunk-\(index)-0123456789abcdef",
                text: "\(index). " + filler,
                metadata: [
                    "source_file": .string("Ведомство А/ОРИС/2026/Документ/ТЗ.docx"),
                    "file_id": .string("71cd6b2212be8a4f"),
                    MCPFileChunks.orderKey: .int(index),
                    "heading_path": .string("Требования к оказанию общих услуг"),
                    "chunk_estimated_tokens": .int(814),
                    "content_hash": .string(String(repeating: "a", count: 64)),
                    "extractor_id": .string("docx-structural"),
                    "document_language": .string("ru"),
                    "file_mtime": .string("2026-06-03T10:00:00Z"),
                    "file_size": .int(1_240_238),
                    "keywords": .string(String(repeating: "услуга, облако, ", count: 40)),
                ]
            )
        }
        func answerSize(_ arguments: [String: JSONValue]) async throws -> (answer: Int, document: Int) {
            let service = await service(Backend(chunks: documents))
            let result = try await call(service, arguments)
            let text = result["content"]?[0]?["text"]?.stringValue ?? ""
            let whole = (text.count) + (result["structuredContent"].map { Self.size(of: $0) } ?? 0)
            // Знаков документа: сколько раз встретился кусок-наполнитель.
            let carried = text.components(separatedBy: filler).count - 1
            return (whole, carried * filler.count)

        }
        let chunks = try await answerSize([
            "collection": .string("заметки"), "file": .string("папка/тз.md"), "limit": .int(50),
            // Ветка кусков называется явно: с умолчание — текст, и без
            // этого обе половины замера мерили бы одно и то же.
            "as": .string("chunks"),
        ])
        let plain = try await answerSize([
            "collection": .string("заметки"), "file": .string("папка/тз.md"), "as": .string("text"),
        ])
        // Оба ответа держатся в объявленном потолке.
        XCTAssertLessThanOrEqual(chunks.answer, 30_000, "кусками: \(chunks)")
        XCTAssertLessThanOrEqual(plain.answer, 30_000, "текстом: \(plain)")
        // И текстом документа приходит кратно больше.
        //
        // Разрыв был четырёхкратным (4 640 против 20 880), а стал
        // трёхкратным: вынос повторяющихся метаданных поднял ветку кусков
        // до 6 960. Порог держится вдвое — ниже него правка на любой
        // из двух веток означала бы, что режимы сравнялись, и это надо
        // заметить, а не узнать из журнала полгода спустя.
        XCTAssertGreaterThan(
            plain.document, chunks.document * 2,
            "кусками \(chunks.document) знаков документа, текстом \(plain.document)"
        )
        print("ЗАМЕР/: кусками \(chunks.document) знаков документа из \(chunks.answer); текстом \(plain.document) из \(plain.answer)")
    }

    /// Размер значения так, как его считает бюджет ответа.
    private static func size(of value: JSONValue) -> Int {
        value.deliveredSize
    }

    /// Описание файла — один раз, с первой страницей, и дальше только текст.
    ///
    /// Метаданные лежат у каждого куска: на семидесяти страницах повторённое
    /// описание съело бы больше целого ответа, а нового не сказало бы ничего.
    func testTheDocumentIsDescribedOnceAndOnTheFirstPageOnly() async throws {
        let documents = (0..<6).map { chunk($0, heading: "Раздел") }
        let service = await service(Backend(chunks: documents))
        let first = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("text"),
        ])
        XCTAssertNotNil(first["structuredContent"]?["document"], "описания нет на первой странице")
        XCTAssertTrue((first["content"]?[0]?["text"]?.stringValue ?? "").contains("Document: "))

        let second = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("text"), "offset": .int(3),
        ])
        XCTAssertNil(second["structuredContent"]?["document"], "описание уехало второй раз")
        XCTAssertFalse((second["content"]?[0]?["text"]?.stringValue ?? "").contains("Document: "))
    }

    /// В тексте — метки последовательности: номер куска, и имя раздела там,
    /// где раздел сменился. Без них агент не знает, где он в документе.
    func testTheTextCarriesSequenceMarksAndSectionChanges() async throws {
        let documents = [
            chunk(0, heading: "Общие положения"),
            chunk(1, heading: "Общие положения"),
            chunk(2, heading: "Требования"),
        ]
        let service = await service(Backend(chunks: documents))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("text"),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("[chunk 0 · Общие положения]"), text)
        XCTAssertTrue(text.contains("[chunk 1]"), "у второго куска раздел тот же — имени быть не должно: \(text)")
        XCTAssertTrue(text.contains("[chunk 2 · Требования]"), text)
        XCTAssertTrue(text.contains("[end of document]"), "конец не назван концом: \(text)")
    }

    /// Описание — о **файле**, даже когда спрошен раздел: под словом
    /// «Document» раздел выдавал бы себя за весь документ.
    func testTheDescriptionStaysAboutTheFileWhenASectionIsAsked() async throws {
        let documents = (0..<6).map { chunk($0, heading: $0 < 2 ? "Требования" : "Прочее") }
        let service = await service(Backend(chunks: documents))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("text"), "heading": .string("Требования"),
        ])
        guard case .object(let description)? = result["structuredContent"]?["document"] else {
            return XCTFail("описания нет")
        }
        // Разделов в файле два, в спрошенном — один: описание считает файл.
        XCTAssertEqual(description["sections"], .int(2), "«Document» — это файл, а не спрошенный раздел")
        XCTAssertNil(description["chunks"], "число кусков уезжает полем totalChunks, и только им")
        XCTAssertEqual(result["structuredContent"]?["totalChunks"], .int(6))
        XCTAssertEqual(result["structuredContent"]?["chunksInSection"], .int(2))
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("[end of section «Требования»]"), text)
    }

    /// Границы страницы называются включительно: «0–6 из 6» читается как
    /// семь кусков из шести и расходится с меткой «[chunk 5]».
    func testThePageBoundsAreInclusive() async throws {
        let service = await service(Backend(chunks: (0..<6).map { chunk($0, heading: "Раздел") }))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("text"),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("chunks 0–5 of 6"), text)
    }

    /// Сплошной текст держится в потолке ответа — со всем, что уезжает.
    ///
    /// Метки платят из того же бюджета, что и текст: у заголовка длиной в
    /// девяносто знаков сорок таких меток — это лишние три тысячи знаков.
    /// Описание и пометки — тоже: у `extraction_warnings` длины нет вовсе.
    /// Карта тоже держится под объявленным потолком.
    ///
    /// Пометки уезжают вместе с разделами и платят из того же бюджета —
    /// а вычитались из него только конверт и заголовок. Пока пометок было
    /// две, запас конверта это скрывал; третья (цена чтения целиком)
    /// вынесла ответ за потолок: 24 290 против 24 000 на этой самой подложке.
    func testTheOutlineStaysInsideTheAnswerCeiling() async throws {
        let heading = "Требования к проведению плановых работ на Основном узле и Резервном узле"
        let documents = (0..<400).map { index in
            MCPDocumentPayload(
                id: "chunk-\(index)",
                text: "текст",
                metadata: [
                    "source_file": .string("папка/тз.md"),
                    "file_id": .string("abcdef0123456789"),
                    MCPFileChunks.orderKey: .int(index),
                    // Имя раздела своё у каждого куска — худший случай: карта
                    // тогда длиннее всего, и места пометкам остаётся меньше.
                    "heading_path": .string("\(heading) \(index)"),
                    "chunk_estimated_tokens": .int(300),
                ]
            )
        }
        let result = try await call(await service(Backend(chunks: documents)), [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "outline": .bool(true),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        let mirror = result["structuredContent"].map { $0.deliveredSize } ?? 0
        XCTAssertLessThanOrEqual(
            text.count + mirror, MCPOutputLimits.defaultResponseCharacters,
            "карта вышла за объявленный потолок: текст \(text.count), зеркало \(mirror)"
        )
        // И урезана она не зря: пометка про цену чтения на месте.
        XCTAssertTrue(text.contains("Reading it whole"), text.suffix(400).description)
    }

    func testTextShapeStaysInsideTheAnswerCeiling() async throws {
        let heading = "Требования к проведению плановых работ на Основном узле и Резервном узле"
        let body = String(repeating: "требование к оказанию услуги. ", count: 12)
        let documents = (0..<400).map { index in
            MCPDocumentPayload(
                id: "chunk-\(index)",
                text: "\(index). " + body,
                metadata: [
                    "source_file": .string("папка/тз.md"),
                    "file_id": .string("abcdef0123456789"),
                    MCPFileChunks.orderKey: .int(index),
                    // Раздел меняется у каждого куска: тогда длинное имя
                    // едет в каждой метке, а это худший случай.
                    "heading_path": .string("\(heading) \(index)"),
                    "extraction_warnings": .string(String(repeating: "таблица пришла плоским текстом; ", count: 40)),
                    "file_size": .int(1_240_238),
                    "document_language": .string("ru"),
                ]
            )
        }
        let service = await service(Backend(chunks: documents))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("text"),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        let mirror = result["structuredContent"].map { $0.deliveredSize } ?? 0
        XCTAssertLessThanOrEqual(
            text.count + mirror, MCPOutputLimits.defaultResponseCharacters,
            "ответ вышел за объявленный потолок: текст \(text.count), зеркало \(mirror)"
        )
        XCTAssertTrue(text.contains("[chunk 0 · "), text.prefix(200).description)
    }

    /// Метка называет номер документа и у коллекций без `chunk_index`.
    ///
    /// Пометка обещает агенту, что в метках стоит нумерация документа;
    /// запасной отсчёт по обрезку сделал бы её неправдой у чтения раздела.
    func testMarksNumberTheDocumentEvenWithoutAChunkIndex() async throws {
        let documents = (0..<6).map { index -> MCPDocumentPayload in
            MCPDocumentPayload(
                id: "c\(index)",
                text: "кусок \(index)",
                metadata: [
                    "source_file": .string("папка/тз.md"),
                    "file_id": .string("abcdef0123456789"),
                    "heading_path": .string(index < 4 ? "Начало" : "Требования"),
                ]
            )
        }
        let service = await service(Backend(chunks: documents))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("text"), "heading": .string("Требования"),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("[chunk 4 · Требования]"), "нумерация обрезка вместо документа: \(text)")
        XCTAssertTrue(text.contains("[chunk 5]"), text)
    }

    /// Шов **между страницами** срезается так же, как внутри страницы.
    ///
    /// Внутри повторы убирались, между страницами оставались — а пометка
    /// обещала, что текст читается как документ. На семидесяти страницах это
    /// шестьдесят девять швов и около двенадцати тысяч повторённых знаков.
    func testTheSeamBetweenPagesIsTrimmedToo() async throws {
        let seam = "коэффициент доступности услуги не ниже 99,5 процента в месяц."
        let head = String(repeating: "Исполнитель оказывает услуги по заказам. ", count: 12)
        let tail = String(repeating: "Плановые перерывы в расчёт не принимаются. ", count: 12)
        func overlapping(_ index: Int, text: String) -> MCPDocumentPayload {
            MCPDocumentPayload(
                id: "c\(index)", text: text,
                metadata: [
                    "source_file": .string("папка/тз.md"),
                    "file_id": .string("abcdef0123456789"),
                    MCPFileChunks.orderKey: .int(index),
                    "heading_path": .string("Раздел"),
                ]
            )
        }
        let documents = [
            overlapping(0, text: head + seam),
            overlapping(1, text: seam + tail),
        ]
        let service = await service(Backend(chunks: documents))
        // Вторая страница начинается там, где кончилась первая.
        let second = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("text"), "offset": .int(1),
        ])
        let text = second["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertFalse(text.contains(seam + tail), "шов не срезан: страницы склеятся с повтором")
        XCTAssertTrue(text.contains(tail.prefix(30)), text.prefix(300).description)
    }

    /// Смещение за концом в текстовом режиме говорит то же, что и в двух
    /// других: «hasMore: false» без объяснения читается как «дочитал».
    func testAnOffsetPastTheEndInTextShapeSaysSo() async throws {
        let service = await service(Backend(chunks: (0..<4).map { chunk($0, heading: "Раздел") }))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("text"), "offset": .int(40),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("past its end"), text)
        XCTAssertEqual(result["structuredContent"]?["chunksShown"], .int(0))
        XCTAssertEqual(result["structuredContent"]?["hasMore"], .bool(false))
    }

    /// Путь на диске называется одним именем, а не двумя.
    func testTheDiskPathIsNotRepeatedInsideTheDescription() async throws {
        let service = await service(Backend(chunks: (0..<3).map { chunk($0, heading: "Раздел") }))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("text"),
        ])
        guard case .object(let description)? = result["structuredContent"]?["document"] else {
            return XCTFail("описания нет")
        }
        XCTAssertNil(description["path"], "путь на диске уезжает полем sourcePath, и только им")
    }

    /// Пометка о шве страницы говорит о сделанном, а не о возможном.
    ///
    /// Она стояла на самом факте «есть предыдущая страница» и обещала
    /// срезанный повтор на коллекции, где перекрытия нет вовсе.
    func testThePageSeamNoteOnlySpeaksWhenSomethingWasTrimmed() async throws {
        let service = await service(Backend(chunks: (0..<6).map { chunk($0, heading: "Раздел") }))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("text"), "offset": .int(3),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertFalse(text.contains("at the seam with the previous page"), text)
    }

    /// Переданное и не сработавшее называется вслух (правило 3 приложения 5).
    ///
    /// С в этом списке остался один `fields`: проецировать в сплошном
    /// тексте нечего — метаданных у него нет. А `limit` работает, и работает
    /// он именно потому, что текст стал умолчанием: параметр, переданный в
    /// режим, который человек не выбирал, пропадать не должен.
    func testTextShapeSaysWhichParametersDoNotApply() async throws {
        let service = await service(Backend(chunks: (0..<4).map { chunk($0, heading: "Раздел") }))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("text"), "limit": .int(2),
            "fields": .array([.string("heading_path")]),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("«fields» does not apply"), text)
        XCTAssertFalse(
            text.contains("«limit» and «fields»"), "limit больше не в списке пропущенного: \(text)"
        )
        XCTAssertEqual(
            result["structuredContent"]?["chunksShown"], .int(2), "«limit»: 2 — два куска"
        )
        XCTAssertEqual(result["structuredContent"]?["nextOffset"], .int(2))
    }

    /// Остановка по «limit» отличается от остановки по бюджету — и говорит
    /// об этом. Иначе страница на два куска вместо пятнадцати
    /// читается как «дальше ничего не влезло».
    func testTextShapeSaysItStoppedAtTheAskedLimitAndNotAtTheBudget() async throws {
        let service = await service(Backend(chunks: (0..<9).map { chunk($0, heading: "Раздел") }))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("text"), "limit": .int(3),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("stopped at the 3 chunks you asked for"), text)
    }

    /// Смещение за концом называет и путь на диске: тот, кто промахнулся,
    /// первым и нуждается в способе прочитать файл иначе.
    func testThePastTheEndAnswerStillNamesWhereTheFileIs() async throws {
        struct Located: MCPToolBackend {
            var inner: Backend
            func collections(allowed: [String]) async throws -> [MCPCollectionSummary] {
                try await inner.collections(allowed: allowed)
            }
            func describe(collection: String) async throws -> MCPCollectionDescription {
                try await inner.describe(collection: collection)
            }
            func search(_ request: MCPSearchRequest) async throws -> MCPSearchAnswer {
                try await inner.search(request)
            }
            func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer {
                try await inner.documents(request)
            }
            func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer {
                try await inner.add(request)
            }
            func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer {
                try await inner.delete(request)
            }
            func fileOnDisk(metadata: ChromaMetadata?) async -> MCPFileOnDisk? {
                MCPFileOnDisk(path: "/Источники/Документы/тз.md", bytes: 1234)
            }
        }
        let backend = Located(inner: Backend(chunks: (0..<4).map { chunk($0, heading: "Раздел") }))
        let client = ExternalClient(
            name: "агент", keyHash: ClientKey.hash(key), keyPrefix: String(key.prefix(4)),
            permissions: ClientPermissions(collections: ["заметки"], requestsPerMinute: 600, burst: 600)
        )
        let access = AccessController()
        await access.setClients([client])
        let service = MCPToolService(backend: backend, access: access)
        let result = try await service.call(
            name: "get_file",
            arguments: .object([
                "collection": .string("заметки"), "file": .string("папка/тз.md"),
                "as": .string("text"), "offset": .int(40),
            ]),
            key: key
        ).get()
        XCTAssertEqual(
            result["structuredContent"]?["sourcePath"]?.stringValue,
            "/Источники/Документы/тз.md"
        )
    }

    /// Все пометки сразу — и ответ всё ещё в потолке.
    ///
    /// Сторож запаса под пометки. Прошлый замер делался на шести, и
    /// следующий же коммит добавил седьмую и удлинил другую, не пересчитав
    /// число: константа устаревает молча, и держать её должна проверка,
    /// а не память.
    func testEveryNoteAtOnceStaysInsideTheCeiling() async throws {
        let heading = "Требования к проведению плановых работ на Основном узле и Резервном узле"
        let seam = String(repeating: "перекрытие кусков этой коллекции. ", count: 8)
        let body = String(repeating: "требование к оказанию услуги. ", count: 20)
        // Куски перекрываются, чтобы сработали обе пометки о швах.
        let documents = (0..<400).map { index in
            MCPDocumentPayload(
                id: "chunk-\(index)",
                text: seam + "\(index). " + body + seam,
                metadata: [
                    "source_file": .string(String(repeating: "папка/", count: 60) + "тз.md"),
                    "file_id": .string("abcdef0123456789"),
                    MCPFileChunks.orderKey: .int(index),
                    "heading_path": .string(heading),
                    "extraction_warnings": .string(String(repeating: "таблица пришла плоским текстом; ", count: 40)),
                    "document_language": .string("ru"),
                ]
            )
        }
        let service = await service(Backend(
            chunks: documents, orderUnavailable: true,
            onDisk: MCPFileOnDisk(path: "/Источники/Документы/тз.docx", bytes: 1_240_238)
        ))
        let result = try await call(service, [
            "collection": .string("заметки"),
            "file": .string(String(repeating: "папка/", count: 60) + "тз.md"),
            "as": .string("text"),
            "heading": .string(heading),
            "offset": .int(1),
            "limit": .int(3),
            "fields": .array([.string("heading_path")]),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        let mirror = result["structuredContent"].map { $0.deliveredSize } ?? 0
        guard case .array(let notes)? = result["structuredContent"]?["notes"] else {
            return XCTFail("пометок нет вовсе")
        }
        // Семь — все, какие есть на сегодня. Меньше значит, что пометка
        // перестала срабатывать и запас проверяется не полностью.
        XCTAssertGreaterThanOrEqual(notes.count, 7, "сработали не все пометки: \(notes.count)")
        XCTAssertLessThanOrEqual(
            text.count + mirror, MCPOutputLimits.defaultResponseCharacters,
            "запас под пометки устарел: текст \(text.count), зеркало \(mirror), пометок \(notes.count)"
        )
    }

    /// Карта называет путь на диске: её велено спрашивать первой, и именно
    /// из неё агент должен узнать, что весь документ лежит рядом файлом.
    func testTheOutlineAlsoNamesWhereTheFileIs() async throws {
        let service = await service(Backend(
            chunks: (0..<3).map { chunk($0, heading: "Раздел") },
            onDisk: MCPFileOnDisk(path: "/Источники/Документы/тз.docx", bytes: 1_240_238)
        ))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "outline": .bool(true),
        ])
        XCTAssertEqual(
            result["structuredContent"]?["sourcePath"]?.stringValue,
            "/Источники/Документы/тз.docx"
        )
        XCTAssertEqual(result["structuredContent"]?["sourceBytes"], .int(1_240_238))
    }

    /// «outline» побеждает «as» — и говорит об этом, а не молчит.
    func testTheOutlineSaysThatTextShapeWasIgnored() async throws {
        let service = await service(Backend(chunks: (0..<3).map { chunk($0, heading: "Раздел") }))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "outline": .bool(true), "as": .string("text"),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("does not apply to «outline»: true"), text)
        // И это карта, а не текст: разделы на месте.
        XCTAssertNotNil(result["structuredContent"]?["sections"])
    }

    /// Карта не предлагает фильтр, который сама не может заполнить.
    ///
    /// У коллекций прежних сборок поля `file_id` нет, а совет подставлял
    /// пустую строку: агент звал `search` с `{"file_id": {"$eq": ""}}`,
    /// получал пустоту и решал, что документ о предмете молчит.
    func testTheOutlineDoesNotOfferAFilterItCannotFill() async throws {
        let documents = (0..<3).map { (number: Int) -> MCPDocumentPayload in
            MCPDocumentPayload(
                id: "c\(number)",
                text: "кусок",
                metadata: [
                    "source_file": .string("папка/тз.md"),
                    MCPFileChunks.orderKey: .int(number),
                    "heading_path": .string("Раздел"),
                ]
            )
        }
        let service = await service(Backend(chunks: documents))
        let result = try await call(service, [
            "collection": .string("заметки"),
            "file": .string("папка/тз.md"),
            "outline": .bool(true),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertFalse(text.contains("\"$eq\": \"\""), text)
        XCTAssertTrue(text.contains("source_file"), "вместо отпечатка называется путь: \(text)")
    }

    /// Файл без заголовков — это сказано, а не выдано за документ из одной
    /// главы: `heading_path` пишется не всякому источнику, а карту велено
    /// спрашивать первой.
    func testAFileWithoutHeadingsSaysSoInsteadOfShowingOneMadeUpSection() async throws {
        let documents = (0..<4).map { chunk($0, heading: nil) }
        let service = await service(Backend(chunks: documents))
        let result = try await call(service, [
            "collection": .string("заметки"),
            "file": .string("папка/тз.md"),
            "outline": .bool(true),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("no headings"), text)
    }

    /// Пропавший файл называется пропавшим файлом — и при чтении раздела.
    ///
    /// Раньше отвечали «в файле нет такого раздела», причём имя файла в этой
    /// пометке пустое: взять его неоткуда. Агент шёл искать название раздела,
    /// когда испорчен путь.
    func testASectionOfAMissingFileBlamesThePathAndNotTheSection() async throws {
        let service = await service(Backend(chunks: []))
        let result = try await call(service, [
            "collection": .string("заметки"),
            "file": .string("папка/тз.md"),
            "heading": .string("Требования"),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("no documents of the file"), text)
        XCTAssertFalse(text.contains("has no section"), text)
        XCTAssertFalse(text.contains("«»"), "имени файла в пометке быть не может пустым: \(text)")
    }

    /// И карта промахнувшегося пути объясняется так же: её спрашивают первой,
    /// значит и промахиваются на ней чаще всего.
    func testTheOutlineOfAMissingFileExplainsThePathTheSameWay() async throws {
        let service = await service(Backend(chunks: []))
        let result = try await call(service, [
            "collection": .string("заметки"),
            "file": .string("папка/тз.md"),
            "outline": .bool(true),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("no documents of the file"), text)
        XCTAssertTrue(text.contains("source_file"), "сказано, откуда брать путь: \(text)")
    }

    /// Карте текст не нужен: она строится по заголовкам и номерам, а тянуть
    /// тысячу кусков текста ради их выбрасывания — та самая цена, от которой
    /// оглавление и спасает.
    func testTheOutlineDoesNotAskTheDatabaseForText() async throws {
        let backend = Backend(chunks: (0..<4).map { chunk($0, heading: "Раздел") })
        let service = await service(backend)
        _ = try await call(service, [
            "collection": .string("заметки"),
            "file": .string("папка/тз.md"),
            "outline": .bool(true),
        ])
        XCTAssertEqual(backend.received.documents?.needsText, false)
    }

    /// Чтение раздела берёт тексты **только у своей страницы**.
    ///
    /// Границы раздела ищутся по метаданным всего файла, а текст — дорогой:
    /// тянуть его целиком ради пяти кусков значит платить ровно ту цену,
    /// от которой спасает оглавление.
    func testASectionAsksForTextOnlyForThePageItShows() async throws {
        let backend = Backend(chunks: (0..<6).map { chunk($0, heading: "Раздел") })
        let service = await service(backend)
        let result = try await call(service, [
            "collection": .string("заметки"),
            // Ветка кусков названа явно: умолчание — текст.
            "as": .string("chunks"),
            "file": .string("папка/тз.md"),
            "heading": .string("Раздел"),
            "limit": .int(2),
        ])
        XCTAssertEqual(backend.received.textRequests, [["c0", "c1"]])
        // И порядок страницы не зависит от того, как их вернула база.
        guard case .array(let page)? = result["structuredContent"]?["documents"] else {
            return XCTFail("страницы нет")
        }
        XCTAssertEqual(page.compactMap { $0["id"]?.stringValue }, ["c0", "c1"])
    }

    /// Раздел называет отпечаток файла — как чтение по порядку и как карта.
    ///
    /// Раздел читается страницами, и продолжение спрашивают тем же файлом.
    /// Отдавать отпечаток двум веткам из трёх значит заставлять агента
    /// возвращаться к пути — той самой строке, которую он портит при
    /// перепечатке.
    func testASectionNamesTheFileFingerprint() async throws {
        let service = await service(Backend(chunks: (0..<3).map { chunk($0, heading: "Раздел") }))
        let result = try await call(service, [
            "collection": .string("заметки"),
            "file": .string("папка/тз.md"),
            "heading": .string("Раздел"),
        ])
        XCTAssertEqual(result["structuredContent"]?["fileId"]?.stringValue, "abcdef0123456789")
    }

    /// Потолок ключа урезал просьбу — об этом сказано и при чтении раздела.
    func testASectionSaysWhenTheKeyCeilingCutTheRequest() async throws {
        let backend = Backend(chunks: (0..<9).map { chunk($0, heading: "Раздел") })
        let service = await service(backend, maxResults: 3)
        let result = try await call(service, [
            "collection": .string("заметки"),
            // Ветка кусков названа явно: умолчание — текст.
            "as": .string("chunks"),
            "file": .string("папка/тз.md"),
            "heading": .string("Раздел"),
            "limit": .int(8),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("ceiling") || text.contains("потолок"), text)
    }

    /// Раздел читается страницами: «limit» и «offset» работают парой.
    func testASectionIsReadInPagesByLimitAndOffset() async throws {
        let documents = (0..<6).map { chunk($0, heading: "Раздел") }
        let service = await service(Backend(chunks: documents))
        let first = try await call(service, [
            "collection": .string("заметки"),
            // Ветка кусков названа явно: умолчание — текст.
            "as": .string("chunks"),
            "file": .string("папка/тз.md"),
            "heading": .string("Раздел"),
            "limit": .int(2),
        ])
        XCTAssertEqual(first["structuredContent"]?["hasMore"], .bool(true))
        XCTAssertEqual(first["structuredContent"]?["nextOffset"], .int(2))
        guard case .array(let page)? = first["structuredContent"]?["documents"] else {
            return XCTFail("страницы нет")
        }
        XCTAssertEqual(page.compactMap { $0["id"]?.stringValue }, ["c0", "c1"])

        let second = try await call(service, [
            "collection": .string("заметки"),
            "file": .string("папка/тз.md"),
            "heading": .string("Раздел"),
            "as": .string("chunks"),
            "limit": .int(2),
            "offset": .int(4),
        ])
        guard case .array(let tail)? = second["structuredContent"]?["documents"] else {
            return XCTFail("страницы нет")
        }
        XCTAssertEqual(tail.compactMap { $0["id"]?.stringValue }, ["c4", "c5"])
        XCTAssertEqual(second["structuredContent"]?["hasMore"], .bool(false))
    }

    // MARK: - Подложка

    private let key = "cdbm_проверка_разделов"

    private struct Backend: MCPToolBackend {
        var chunks: [MCPDocumentPayload]
        /// Файл длиннее того, что приложение возвращает по порядку: нужна,
        /// чтобы сработала пометка о непредсказуемом порядке.
        var orderUnavailable = false
        /// Путь на диске — чтобы сработала пометка про файл на машине.
        var onDisk: MCPFileOnDisk?
        final class Received: @unchecked Sendable {
            var documents: MCPDocumentsRequest?
            /// Запросы за текстами — по каким идентификаторам ходили.
            var textRequests: [[String]] = []
        }
        let received = Received()

        func collections(allowed: [String]) async throws -> [MCPCollectionSummary] {
            [MCPCollectionSummary(name: "заметки", documentCount: chunks.count, model: "e5", metric: "cosine", dimension: 8)]
        }
        func describe(collection: String) async throws -> MCPCollectionDescription {
            MCPCollectionDescription(
                summary: try await collections(allowed: [collection])[0],
                fields: [], hasSchema: false, allowsExtraFields: true
            )
        }
        func search(_ request: MCPSearchRequest) async throws -> MCPSearchAnswer {
            MCPSearchAnswer(documents: [], metric: "cosine", model: "e5")
        }
        func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer {
            received.documents = request
            if !request.ids.isEmpty {
                received.textRequests.append(request.ids)
                // Как настоящая база: порядок выдачи по идентификаторам
                // не обещан, поэтому она их перемешивает.
                let found = chunks.filter { request.ids.contains($0.id) }.reversed()
                return MCPDocumentsAnswer(documents: Array(found), hasMore: false)
            }
            let ordered = request.orderedByChunkIndex ? MCPFileChunks.ordered(chunks) : chunks
            let window = MCPFileChunks.page(ordered, offset: request.offset, limit: request.limit)
            // Как настоящая подложка: текста не отдаёт, если его не просили.
            let page = request.needsText ? window.page : window.page.map {
                MCPDocumentPayload(id: $0.id, text: nil, metadata: $0.metadata)
            }
            return MCPDocumentsAnswer(
                documents: page, hasMore: window.hasMore,
                total: ordered.count, orderUnavailable: orderUnavailable
            )
        }

        func fileOnDisk(metadata: ChromaMetadata?) async -> MCPFileOnDisk? { onDisk }
        func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer {
            MCPAddAnswer(ids: [], model: "e5")
        }
        func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer {
            MCPDeleteAnswer(deleted: [], missing: [], keptInTrash: false)
        }
    }

    private func service(_ backend: Backend, maxResults: Int? = nil) async -> MCPToolService {
        let client = ExternalClient(
            name: "агент",
            keyHash: ClientKey.hash(key),
            keyPrefix: String(key.prefix(4)),
            permissions: ClientPermissions(
                collections: ["заметки"], requestsPerMinute: 600, burst: 600,
                maxSearchResults: maxResults
            )
        )
        let access = AccessController()
        await access.setClients([client])
        return MCPToolService(backend: backend, access: access)
    }

    // MARK: - Умолчание: сплошной текст

    /// Замер по журналу: 183 вызова `get_file` живыми агентами, текстом —
    /// ноль. Режим описан в скилле пятью строками и в схеме с замером, и всё
    /// равно не выбирается. Совет исчерпан — остаётся умолчание.
    func testTheDefaultShapeIsText() async throws {
        let service = await service(Backend(chunks: (0..<6).map { chunk($0, heading: "Раздел") }))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
        ])
        XCTAssertEqual(result["structuredContent"]?["as"], .string("text"))
        XCTAssertNil(result["structuredContent"]?["documents"], "кусков в умолчании быть не должно")
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("as text:"), text)
    }

    /// Проекция полей относится к метаданным куска, а у сплошного текста их
    /// нет вовсе. Молча перевести такой вызов в режим, где его параметр не
    /// значит ничего, — хуже, чем оставить как было.
    func testAskingForFieldsSelectsChunks() async throws {
        let service = await service(Backend(chunks: (0..<6).map { chunk($0, heading: "Раздел") }))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "fields": .array([.string("heading_path")]),
        ])
        XCTAssertNotNil(result["structuredContent"]?["documents"], "с «fields» отдаются куски")
        XCTAssertNil(result["structuredContent"]?["as"])
    }

    func testChunksAreStillAvailableWhenAskedFor() async throws {
        let service = await service(Backend(chunks: (0..<6).map { chunk($0, heading: "Раздел") }))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("chunks"),
        ])
        XCTAssertNotNil(result["structuredContent"]?["documents"])
    }

    /// Карта — не форма чтения, и умолчание её не касается.
    func testTheOutlineIsNotAffectedByTheDefault() async throws {
        let service = await service(Backend(chunks: (0..<6).map { chunk($0, heading: "Раздел") }))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "outline": .bool(true),
        ])
        XCTAssertNotNil(result["structuredContent"]?["sections"])
        XCTAssertNil(result["structuredContent"]?["as"])
    }

    // MARK: - Цена маршрута в карте

    /// Кусок с весом: карта считает знаки по оценке токенов, и без неё
    /// считать нечего.
    private func weighty(_ index: Int) -> MCPDocumentPayload {
        let text = String(repeating: "требование к услуге ", count: 60)
        return MCPDocumentPayload(
            id: "w\(index)",
            text: text,
            metadata: [
                "source_file": .string("папка/тз.md"),
                "file_id": .string("abcdef0123456789"),
                MCPFileChunks.orderKey: .int(index),
                "heading_path": .string("Раздел \(index / 5)"),
                "chunk_estimated_tokens": .int(
                    TokenEstimator.estimatedTokens(text, charactersPerToken: TokenEstimator.charactersPerToken)
                ),
            ]
        )
    }

    /// Разбор живого сеанса: агент взял карту, увидел 37 разделов и пошёл
    /// читать их по одному, не зная, что этот маршрут отдаёт четыре куска за
    /// вызов, а соседний пятнадцать. Цена обязана стоять там, где маршрут
    /// выбирают, — в карте.
    func testTheOutlineNamesThePriceOfReadingWhole() async throws {
        let service = await service(Backend(chunks: (0..<40).map { weighty($0) }))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "outline": .bool(true),
        ])
        let structured = result["structuredContent"]
        XCTAssertNotNil(structured?["callsToReadWhole"], "карта обязана назвать цену")
        XCTAssertNotNil(structured?["charactersEstimate"])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("Reading it whole"), text)
    }

    /// И названная цена — та самая, по которой потом и выходит.
    ///
    /// Проверка не на формулу, а на её исполнение: файл дочитывается до
    /// конца страницами, и число ходок сверяется с обещанным. Разойдись
    /// они — карта звала бы в маршрут по цене, которой у него нет.
    func testThePromisedNumberOfCallsIsTheNumberItTakes() async throws {
        let backend = Backend(chunks: (0..<40).map { weighty($0) })
        let service = await service(backend)
        let map = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "outline": .bool(true),
        ])
        let promised = try XCTUnwrap(map["structuredContent"]?["callsToReadWhole"]?.intValue)
        // Иначе проверка выродилась бы: «одна страница» совпадает с «одной
        // страницей» и при неверной формуле.
        XCTAssertGreaterThan(promised, 1, "файл обязан не влезать в одну страницу")

        var calls = 0
        var offset = 0
        while calls < 50 {
            let page = try await call(service, [
                "collection": .string("заметки"), "file": .string("папка/тз.md"),
                "offset": .int(offset),
            ])
            calls += 1
            guard page["structuredContent"]?["hasMore"]?.boolValue == true,
                  let next = page["structuredContent"]?["nextOffset"]?.intValue, next > offset else { break }
            offset = next
        }
        XCTAssertEqual(
            calls, promised,
            "карта обещала \(promised) вызовов, а понадобилось \(calls)"
        )
    }

    /// Разделы считаются одним счётом — картой и описанием файла.
    ///
    /// Живой случай: карта того же файла в том же сеансе говорила
    /// «37 sections», а описание документа в ответе — «571 sections». Слово
    /// одно, числа разные, и агенту неоткуда узнать, какое про что: карта
    /// режет заголовок до верхнего уровня, а описание брало его целиком,
    /// вместе с подразделами.
    func testTheDescriptionCountsSectionsTheSameWayTheOutlineDoes() async throws {
        let nested = (0..<12).map { index -> MCPDocumentPayload in
            MCPDocumentPayload(
                id: "n\(index)",
                text: String(repeating: "требование к услуге ", count: 20),
                metadata: [
                    "source_file": .string("папка/тз.md"),
                    "file_id": .string("abcdef0123456789"),
                    MCPFileChunks.orderKey: .int(index),
                    // Три верхних раздела, у каждого по два подраздела.
                    "heading_path": .string("Раздел \(index / 4) > Пункт \(index % 4 / 2)"),
                ]
            )
        }
        let service = await service(Backend(chunks: nested))
        let map = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "outline": .bool(true),
        ])
        let inMap = try XCTUnwrap(map["structuredContent"]?["totalSections"]?.intValue)
        XCTAssertEqual(inMap, 3, "карта режет до верхнего уровня")

        let read = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
        ])
        let inDescription = try XCTUnwrap(
            read["structuredContent"]?["document"]?["sections"]?.intValue
        )
        XCTAssertEqual(inDescription, inMap, "одно слово — одно число")
    }

    // MARK: - Общий блок метаданных

    /// Замерено на живом ТЗ: 1 158 знаков метаданных на кусок, из них 802
    /// одинаковы у всех 1281 куска. Ответ на четыре куска вёз их четырежды.
    func testMetadataSharedByEveryChunkTravelsOnce() async throws {
        let service = await service(Backend(chunks: (0..<4).map { chunk($0, heading: "Раздел") }))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("chunks"),
        ])
        let shared = result["structuredContent"]?["sharedMetadata"]?.objectValue ?? [:]
        XCTAssertEqual(shared["source_file"], .string("папка/тз.md"), "путь одинаков у всех кусков")
        XCTAssertEqual(shared["file_id"], .string("abcdef0123456789"))
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertEqual(
            text.components(separatedBy: "file_id=abcdef0123456789").count - 1, 0,
            "вынесенное поле не повторяется у кусков: \(text)"
        )
    }

    func testAFieldThatVariesStaysWithItsChunk() async throws {
        let service = await service(Backend(chunks: (0..<4).map { chunk($0, heading: "Раздел \($0)") }))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("chunks"),
        ])
        let shared = result["structuredContent"]?["sharedMetadata"]?.objectValue ?? [:]
        XCTAssertNil(shared["heading_path"], "заголовок у каждого куска свой — выносить нельзя")
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("heading_path=Раздел 0"), text)
        XCTAssertTrue(text.contains("heading_path=Раздел 1"), text)
    }

    /// Спрошенную проекцию не подменяем: агент назвал поля сам.
    func testAnAskedProjectionIsNotReplaced() async throws {
        let service = await service(Backend(chunks: (0..<4).map { chunk($0, heading: "Раздел") }))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("chunks"), "fields": .array([.string("source_file")]),
        ])
        XCTAssertNil(result["structuredContent"]?["sharedMetadata"])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("source_file=папка/тз.md"), text)
    }

    /// На одном куске повторять нечего: вынести его метаданные значило бы
    /// отнять их у единственного куска и ничего не сэкономить.
    func testASingleChunkKeepsItsMetadata() async throws {
        let service = await service(Backend(chunks: [chunk(0, heading: "Раздел")]))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/тз.md"),
            "as": .string("chunks"),
        ])
        XCTAssertNil(result["structuredContent"]?["sharedMetadata"])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("source_file=папка/тз.md"), text)
    }

    private func call(
        _ service: MCPToolService, _ arguments: [String: JSONValue]
    ) async throws -> JSONValue {
        try await service.call(name: "get_file", arguments: .object(arguments), key: key).get()
    }
}

