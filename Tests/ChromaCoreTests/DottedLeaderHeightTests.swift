import XCTest
import CoreGraphics
@testable import ChromaCore

/// Отточие оглавления не должно задавать рост знака.
///
/// Геометрия замерена на ТЗ ГО 10 (467 страниц, оглавление на четыре
/// страницы): буква ростом 5,19 пункта, точка отточия — 1,20. На странице
/// оглавления точек 5209, букв 803, поэтому медиана роста по **всем** знакам
/// давала 1,2 — вчетверо меньше настоящего кегля. От этого допуск строки
/// становился меньше полупункта, строки рассыпались, и «Содержание» уходило
/// в базу как «С о е жание д р», а страница — markdown-таблицей из слогов.
final class DottedLeaderHeightTests: XCTestCase {
    private func letter(_ text: String, x: Double, y: Double = 700) -> TableGeometry.Word {
        TableGeometry.Word(box: CGRect(x: x, y: y, width: 5, height: 5.19), text: text)
    }

    private func leaderDot(x: Double, y: Double = 700) -> TableGeometry.Word {
        TableGeometry.Word(box: CGRect(x: x, y: y, width: 2, height: 1.20), text: ".")
    }

    /// Страница, где точек в шесть раз больше, чем букв: рост берётся по буквам.
    func testLeadersDoNotDragTheMedianDown() {
        var words = (0..<20).map { letter("а", x: Double($0) * 6) }
        words += (0..<120).map { leaderDot(x: 200 + Double($0) * 3) }

        let height = TableGeometry.medianHeight(of: words)
        XCTAssertEqual(height, 5.19, accuracy: 0.01, "рост знака — по буквам, а не по отточию")
    }

    /// Обычная страница без отточия не меняется: правило чинит промах,
    /// а не двигает порог там, где он и так верен.
    func testAnOrdinaryPageKeepsItsHeight() {
        let words = (0..<40).map { letter("б", x: Double($0) * 6) }
        XCTAssertEqual(TableGeometry.medianHeight(of: words), 5.19, accuracy: 0.01)
    }

    /// Смешанный кегль: крупный заголовок не задирает рост знака.
    ///
    /// Ради этого случая буквы отбираются по самому знаку, а не по доле от
    /// верхнего процентиля роста: на титуле, слайде или первой полосе
    /// крупного набора бывает треть страницы, и отсечение «ниже 0,6 от
    /// девяностого процентиля» выбрасывало основной текст целиком. Пороги
    /// удваивались, и таблица на такой странице переставала собираться.
    func testALargeHeadingDoesNotRaiseTheHeight() {
        var words = (0..<30).map { index in
            TableGeometry.Word(
                box: CGRect(x: Double(index) * 14, y: 760, width: 12, height: 12),
                text: "З"
            )
        }
        words += (0..<70).map { letter("т", x: Double($0) * 6, y: 700) }

        XCTAssertEqual(
            TableGeometry.medianHeight(of: words), 5.19, accuracy: 0.01,
            "рост знака берётся у основного набора, а не у заголовка"
        )
    }

    /// Страница без единой буквы мерится тем, что есть: разбор не обязан
    /// работать на чертеже, но и падать на нём не должен.
    func testAPageWithoutLettersFallsBackToEveryGlyph() {
        let words = (0..<30).map { leaderDot(x: Double($0) * 3) }
        XCTAssertEqual(TableGeometry.medianHeight(of: words), 1.20, accuracy: 0.01)
    }

    /// Строка оглавления остаётся одной строкой и одной ячейкой.
    ///
    /// Проверяется то, ради чего правка и сделана: при вырожденном росте
    /// допуск строки становится меньше расхождения рамок соседних букв, и
    /// слово распадается на ячейки.
    func testATableOfContentsLineStaysWhole() {
        // «Содержание»: у букв с выносными элементами середина рамки ниже.
        var words: [TableGeometry.Word] = []
        let word = "Содержание"
        for (index, character) in word.enumerated() {
            let descends = "друц".contains(character)
            words.append(TableGeometry.Word(
                box: CGRect(
                    x: Double(index) * 6, y: descends ? 698.8 : 700,
                    width: 5, height: 5.19
                ),
                text: String(character)
            ))
        }
        // …и отточие до номера страницы, которого на строке втрое больше.
        words += (0..<60).map { leaderDot(x: 70 + Double($0) * 3) }
        words.append(letter("2", x: 260))

        let height = TableGeometry.medianHeight(of: words)
        let lines = TableGeometry.lines(from: words, height: height)

        XCTAssertEqual(lines.count, 1, "строка оглавления — одна строка")
        XCTAssertTrue(
            lines[0].cells.contains { $0.text.hasPrefix("Содержание") },
            "слово обязано остаться целым, а вышло: \(lines[0].cells.map(\.text))"
        )
    }
}
