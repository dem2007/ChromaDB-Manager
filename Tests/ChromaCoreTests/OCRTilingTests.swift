import XCTest
import CoreGraphics
@testable import ChromaCore

/// Большая страница распознаётся плитками.
///
/// Из живого разбора: схема архитектуры на листе 1649×1040 мм приходила
/// в базу пустой. Замер до правки — страница целиком при двукратном
/// увеличении даёт ноль распознанных строк, четверть при четырёхкратном —
/// сорок две; после правки тот же файл даёт 373 строки за 4,3 секунды.
final class OCRTilingTests: XCTestCase {
    /// Обычный лист режется не должен: двадцать запросов к Vision вместо
    /// одного — это двадцатикратная цена там, где хватало одного.
    func testAnOrdinaryPageIsNotTiled() {
        let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)
        XCTAssertLessThan(max(a4.width, a4.height), VisionOCRExtractor.tileThreshold)
        XCTAssertEqual(VisionOCRExtractor.tiles(of: a4).count, 1, "лист А4 — одна плитка")
    }

    /// Плитки покрывают страницу целиком: пропущенный угол — это потерянный
    /// текст, которого никто не хватится.
    func testTilesCoverTheWholePage() {
        let poster = CGRect(x: 0, y: 0, width: 4677, height: 2950)
        let tiles = VisionOCRExtractor.tiles(of: poster)
        XCTAssertGreaterThan(tiles.count, 1)

        for tile in tiles {
            XCTAssertTrue(poster.contains(tile), "плитка вышла за страницу: \(tile)")
        }
        // Каждая точка сетки попадает хотя бы в одну плитку.
        for x in stride(from: poster.minX, to: poster.maxX, by: 137) {
            for y in stride(from: poster.minY, to: poster.maxY, by: 149) {
                let point = CGPoint(x: x, y: y)
                XCTAssertTrue(
                    tiles.contains { $0.contains(point) },
                    "точка \(point) не попала ни в одну плитку"
                )
            }
        }
    }

    /// Плитки перекрываются: строка на стыке должна целиком войти хотя бы
    /// в одну из них.
    func testTilesOverlap() {
        let poster = CGRect(x: 0, y: 0, width: 4677, height: 2950)
        let tiles = VisionOCRExtractor.tiles(of: poster)
        let topRow = tiles.filter { abs($0.maxY - poster.maxY) < 1 }.sorted { $0.minX < $1.minX }
        XCTAssertGreaterThan(topRow.count, 1)
        let first = topRow[0], second = topRow[1]
        XCTAssertGreaterThan(first.maxX - second.minX, 0, "плитки обязаны заходить друг на друга")
        XCTAssertEqual(first.maxX - second.minX, VisionOCRExtractor.tileOverlap, accuracy: 1)
    }

    /// Плитка рисуется крупнее страницы: в этом весь смысл — буква должна
    /// стать больше, а не картинка.
    func testATileIsDrawnLargerThanAWholePage() {
        XCTAssertGreaterThan(VisionOCRExtractor.tileScale, VisionOCRExtractor.renderScale)
    }
}
