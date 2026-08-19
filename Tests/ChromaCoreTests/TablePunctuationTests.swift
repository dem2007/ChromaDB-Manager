import XCTest
import CoreGraphics
@testable import ChromaCore

/// Знаки препинания остаются в своей строке таблицы.
///
/// Геометрия в тестах — замеренная на живой смете, а не выдуманная: цифра
/// ростом 7,3 пункта с базовой линией 710,04; точка ростом 1 пункт на той же
/// базовой линии; запятая ростом 2,4, свисающая под неё. По середине рамки
/// точка отстоит от цифры на три пункта — дальше допуска строки, — и уезжала
/// в соседнюю. Ценой этому «31 585 738,00», пришедшее как «31 585 738 00».
final class TablePunctuationTests: XCTestCase {
    private let height = 5.4

    private func digit(_ text: String, x: Double, baseline: Double = 710.04) -> TableGeometry.Word {
        TableGeometry.Word(box: CGRect(x: x, y: baseline, width: 5, height: 7.28), text: text)
    }
    private func dot(_ text: String, x: Double, baseline: Double = 710.16, height: Double = 1.0) -> TableGeometry.Word {
        TableGeometry.Word(box: CGRect(x: x, y: baseline, width: 2, height: height), text: text)
    }

    /// Точка и запятая возвращаются к своим цифрам.
    func testAPunctuationMarkGoesBackToItsOwnLine() {
        let digits = [digit("3", x: 405), digit("8", x: 449), digit("0", x: 457)]
        let comma = dot(",", x: 455, baseline: 708.75, height: 2.41)
        // Ниже — своя строка: текст, к которому знаки не относятся.
        let below = [
            TableGeometry.Word(box: CGRect(x: 87, y: 703.0, width: 6, height: 7.2), text: "о"),
            TableGeometry.Word(box: CGRect(x: 94, y: 703.0, width: 6, height: 7.2), text: "б"),
        ]

        // Так их разложила сборка по середине рамки: запятая оказалась
        // в строке ниже.
        let split = [digits, [comma] + below]
        let fixed = TableGeometry.returningPunctuation(split, height: height)

        XCTAssertEqual(fixed.count, 2)
        XCTAssertTrue(fixed[0].contains { $0.text == "," }, "запятая обязана вернуться к цифрам")
        XCTAssertFalse(fixed[1].contains { $0.text == "," })
        XCTAssertEqual(fixed[1].map(\.text), ["о", "б"], "чужая строка не должна пострадать")
    }

    /// Знак, оказавшийся в своей строке, остаётся на месте: правило чинит
    /// промах, а не перекладывает знаки без нужды.
    func testAMarkAlreadyInPlaceStaysThere() {
        let line = [digit("1", x: 53), dot(".", x: 63), digit("1", x: 66)]
        let fixed = TableGeometry.returningPunctuation([line], height: height)
        XCTAssertEqual(fixed.count, 1)
        XCTAssertEqual(fixed[0].count, 3)
    }

    /// Далёкий от любой базовой линии знак не переезжает никуда: подчёркивание
    /// под таблицей — не часть строки.
    func testALoneMarkIsNotDraggedIntoAnyLine() {
        let digits = [digit("7", x: 405)]
        let underline = dot("_", x: 100, baseline: 640.0)
        let fixed = TableGeometry.returningPunctuation([digits, [underline]], height: height)
        XCTAssertEqual(fixed.count, 2)
        XCTAssertEqual(fixed[1].map(\.text), ["_"])
    }

    /// Строка из одних знаков препинания исчезает, когда все они разошлись
    /// по своим строкам: пустых строк в таблице оставаться не должно.
    func testALineOfNothingButMarksDisappears() {
        let digits = [digit("5", x: 405), digit("0", x: 412)]
        let marks = [dot(",", x: 410, baseline: 708.75, height: 2.41), dot(".", x: 420)]
        let fixed = TableGeometry.returningPunctuation([digits, marks], height: height)
        XCTAssertEqual(fixed.count, 1, "второй строке взяться неоткуда")
        XCTAssertEqual(fixed[0].count, 4)
    }
}
