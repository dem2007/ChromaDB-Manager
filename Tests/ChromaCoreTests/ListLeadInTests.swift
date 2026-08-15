import XCTest
@testable import ChromaCore

/// Вводная фраза списка в строке контекста.
final class ListLeadInTests: XCTestCase {
    private let regulation = """
    Настоящий регламент определяет порядок оказания услуг связи заказчику.

    Исполнитель обязан обеспечить:

    ● круглосуточный мониторинг доступности всех компонентов системы

    ● восстановление работоспособности в течение четырёх часов

    ● ежемесячный отчёт о качестве оказанных услуг

    Оплата производится ежеквартально по факту оказания услуг.
    """

    func testTheLeadInCoversEveryItemOfItsList() {
        let leadIns = ListLeadIns.leadIns(in: regulation)
        XCTAssertEqual(leadIns.count, 1)
        XCTAssertEqual(leadIns.first?.text, "Исполнитель обязан обеспечить:")

        // Каждый пункт — внутри участка, а текст до и после списка — нет.
        for item in ["● круглосуточный", "● восстановление", "● ежемесячный"] {
            let offset = try? XCTUnwrap(regulation.range(of: item))
                .map { regulation.distance(from: regulation.startIndex, to: $0.lowerBound) }
            XCTAssertEqual(
                ListLeadIns.leadIn(at: offset ?? -1, in: leadIns),
                "Исполнитель обязан обеспечить:",
                "пункт «\(item)» остался без вводной фразы"
            )
        }

        let afterwards = regulation.distance(
            from: regulation.startIndex,
            to: regulation.range(of: "Оплата производится")!.lowerBound
        )
        XCTAssertNil(ListLeadIns.leadIn(at: afterwards, in: leadIns), "список кончился")
        XCTAssertNil(ListLeadIns.leadIn(at: 0, in: leadIns), "до списка вводной фразы нет")
    }

    /// Главное ограничение, ради которого замер и делался: нумерованные пункты
    /// постановления — не подпункты друг друга.
    ///
    /// На корпусе пользователя таких 783 из 907 «оторванных» чанков. Правило
    /// «брать предыдущий блок» объявило бы пункт 11 подчинённым пункту 10
    /// и испортило бы в шесть раз больше, чем починило.
    func testNumberedClausesDoNotAdoptEachOther() {
        let decree = """
        10. Оператор государственной информационной системы обеспечивает её работу.

        11. Наборы данных официальной статистической информации могут публиковаться.

        12. Паспорт формируется на основе сведений о статистическом показателе.
        """
        XCTAssertTrue(ListLeadIns.leadIns(in: decree).isEmpty, "у нумерованных пунктов вводной фразы нет")
    }

    /// Абзац, кончившийся двоеточием, но без списка за ним, вводной фразой
    /// не является: приписывать его некуда.
    func testAColonWithoutAListLeadsNowhere() {
        let text = """
        Стороны согласовали следующее условие: оплата производится ежеквартально.

        Настоящий пункт вступает в силу с момента подписания договора сторонами.
        """
        XCTAssertTrue(ListLeadIns.leadIns(in: text).isEmpty)
    }

    /// Слишком длинный абзац — это абзац, кончившийся двоеточием случайно,
    /// и в вектор пункта он принесёт больше своего смысла, чем чужого.
    func testAnOverlongParagraphIsNotALeadIn() {
        let long = String(repeating: "очень длинное вступление, ", count: 20) + ":"
        XCTAssertGreaterThan(long.count, ListLeadIns.maximumLength)
        XCTAssertFalse(ListLeadIns.isLeadIn(long))
        XCTAssertTrue(ListLeadIns.isLeadIn("Исполнитель обязан обеспечить:"))
        XCTAssertFalse(ListLeadIns.isLeadIn("Итого:"), "обрывок вводной фразой не считается")
    }

    /// Второй список в том же документе получает свою вводную фразу,
    /// а не фразу первого.
    func testEachListKeepsItsOwnLeadIn() {
        let text = """
        Заказчик предоставляет:

        ● доступ к помещениям в рабочее время по предварительной заявке

        Исполнитель предоставляет:

        ● квалифицированный персонал для выполнения работ по договору
        """
        let leadIns = ListLeadIns.leadIns(in: text)
        XCTAssertEqual(leadIns.map(\.text), ["Заказчик предоставляет:", "Исполнитель предоставляет:"])

        let second = text.distance(
            from: text.startIndex, to: text.range(of: "● квалифицированный")!.lowerBound
        )
        XCTAssertEqual(ListLeadIns.leadIn(at: second, in: leadIns), "Исполнитель предоставляет:")
    }

    // MARK: - Один и тот же список, в чём бы он ни был записан

    /// Маркеры Markdown: `- пункт` и `+ пункт` — самый частый вид списка
    /// в простом тексте, и до правило их не узнавало вовсе.
    func testMarkdownBulletsAreListItems() {
        for marker in ["-", "+", "*"] {
            XCTAssertTrue(
                ListLeadIns.isListItem("\(marker) круглосуточный мониторинг"),
                "«\(marker) » должен быть маркером списка"
            )
        }
    }

    /// Но только с пробелом за собой: иначе дефисом начинались бы
    /// отрицательные числа, а звёздочкой — выделение Markdown.
    func testAmbiguousMarkersNeedASpace() {
        XCTAssertFalse(ListLeadIns.isListItem("-5 градусов по Цельсию"))
        XCTAssertFalse(ListLeadIns.isListItem("*важно* — читать полностью"))
        XCTAssertFalse(ListLeadIns.isListItem("+7 495 000-00-00"))
    }

    /// Маркер Word для маркированного списка — «—», и он остаётся маркером.
    func testWordAndHTMLBulletsAgree() {
        XCTAssertTrue(ListLeadIns.isListItem("— восстановление работоспособности"))
        XCTAssertTrue(ListLeadIns.isListItem("1. Ежемесячный отчёт"))
        XCTAssertTrue(ListLeadIns.isListItem("• доступ к помещениям"))
    }

    /// Тот же список, записанный простым текстом и HTML, даёт одну и ту же
    /// вводную фразу: правило одно на оба вида содержимого.
    func testTheSameListWorksInPlainTextAndHTML() throws {
        let plain = """
        Исполнитель обязан обеспечить:

        - круглосуточный мониторинг доступности компонентов
        - восстановление работоспособности в течение четырёх часов
        """
        XCTAssertEqual(
            ListLeadIns.leadIns(in: plain).map(\.text), ["Исполнитель обязан обеспечить:"]
        )

        let page = try HTMLParser.parse(Data("""
        <html><body><p>Исполнитель обязан обеспечить:</p>
        <ul><li>круглосуточный мониторинг доступности компонентов</li>
        <li>восстановление работоспособности в течение четырёх часов</li></ul>
        </body></html>
        """.utf8), contentType: nil, baseURL: nil)
        XCTAssertEqual(
            ListLeadIns.leadIns(in: page.plainText).map(\.text),
            ["Исполнитель обязан обеспечить:"],
            page.plainText
        )
    }

    /// Нумерованный список HTML считает сам себя, а вложенный не сбивает
    /// счёт внешнему.
    func testHTMLOrderedListsAreNumbered() throws {
        let page = try HTMLParser.parse(Data("""
        <html><body><ol><li>первый пункт перечня</li>
        <li>второй пункт перечня</li></ol></body></html>
        """.utf8), contentType: nil, baseURL: nil)
        XCTAssertTrue(page.plainText.contains("1. первый пункт"), page.plainText)
        XCTAssertTrue(page.plainText.contains("2. второй пункт"), page.plainText)
    }

    // MARK: - Строка контекста

    /// Вводная фраза идёт отдельной строкой, а не ещё одной стрелкой:
    /// заголовки — это адрес, а фраза — предложение.
    func testTheLeadInGoesOnItsOwnLine() {
        XCTAssertEqual(
            SourceSyncService.contextPrefix(
                title: "Регламент услуг", headingPath: "Раздел 5 > 5.2",
                listLeadIn: "Исполнитель обязан обеспечить:"
            ),
            "Регламент услуг → Раздел 5 → 5.2\nИсполнитель обязан обеспечить:"
        )
    }

    func testTheLeadInAloneStillMakesAPrefix() {
        XCTAssertEqual(
            SourceSyncService.contextPrefix(
                title: nil, headingPath: nil, listLeadIn: "Заказчик предоставляет:"
            ),
            "Заказчик предоставляет:"
        )
    }

    /// Прежнее поведение без вводной фразы не изменилось.
    func testTheAddressAloneIsUnchanged() {
        XCTAssertEqual(
            SourceSyncService.contextPrefix(title: "Регламент", headingPath: "Раздел 5"),
            "Регламент → Раздел 5"
        )
        XCTAssertNil(SourceSyncService.contextPrefix(title: nil, headingPath: nil))
        XCTAssertNil(SourceSyncService.contextPrefix(title: "  ", headingPath: "", listLeadIn: "  "))
    }

    /// Размещение, у которого есть только вводная фраза, пустым не считается:
    /// в метаданные писать нечего, а строку контекста оно даёт.
    func testAPlacementWithOnlyALeadInIsNotEmpty() {
        XCTAssertTrue(ChunkPlacement(start: 0).isEmpty)
        XCTAssertFalse(ChunkPlacement(start: 0, listLeadIn: "Исполнитель обязан:").isEmpty)
    }

    /// Сквозная проверка: чанк, начинающийся пунктом, получает вводную фразу
    /// через размещение — то есть механизм собран целиком, а не по частям.
    func testAChunkInsideAListGetsTheLeadInThroughItsPlacement() {
        let document = ExtractedDocument(
            plainText: regulation, containerFormat: "txt",
            extractorID: "test", extractorVersion: 1
        )
        let chunks = regulation.components(separatedBy: "\n\n").enumerated().map {
            TextChunk(index: $0.offset, text: $0.element)
        }
        let placements = ChunkLocator.placements(of: chunks, in: document)

        let item = try? XCTUnwrap(chunks.first { $0.text.hasPrefix("● восстановление") })
        XCTAssertEqual(
            placements[item?.index ?? -1]?.listLeadIn, "Исполнитель обязан обеспечить:"
        )
        let tail = try? XCTUnwrap(chunks.first { $0.text.hasPrefix("Оплата") })
        XCTAssertNil(placements[tail?.index ?? -1]?.listLeadIn)
    }
}
