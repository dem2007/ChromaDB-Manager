import XCTest
@testable import ChromaCore

/// Имена файлов, привезённые из архива в чужой кодировке.
///
/// Все три испорченных имени — настоящие, из коллекции `base_adaptive_geaorge_4b`:
/// zip без флага UTF-8 хранил их байтами CP866, распаковщик прочитал как
/// MacCyrillic. Здоровые имена в тесте не для полноты: перекодировка проходит
/// и на них, и без правила «кириллицы должно стать больше» она бы молча
/// испортила каждое русское имя в базе.
final class FileNameEncodingTests: XCTestCase {

    func testMangledNamesAreRestored() {
        let cases = [
            "20250822_12673_Рг°®в•е_ѓа®Ђ.pdf": "20250822_12673_Рубитех_прил.pdf",
            "20250820_12512_КП_С®бв•ђ≠л© бЃдв.pdf": "20250820_12512_КП_Системный софт.pdf",
            "20250821_12522_Л†°Ѓа†вЃа®п ВС.pdf": "20250821_12522_Лаборатория ВС.pdf",
        ]
        for (broken, expected) in cases {
            XCTAssertEqual(FileNameEncoding.repaired(broken), expected, "имя не восстановилось")
        }
    }

    /// Главная опасность правки: испортить то, что было цело.
    func testHealthyNamesAreLeftAlone() {
        let names = [
            "Приложение.docx",
            "ГО 10_ТЗ к ГК.pdf",
            "2. ТЗ_ГЕОП_2027-2028.docx",
            "9. Положение_о_ЕТП_.docx",
            "Rubitech report.pdf",
            "отчёт за 2026 год.xlsx",
            "",
        ]
        for name in names {
            XCTAssertEqual(FileNameEncoding.repaired(name), name, "здоровое имя изменено")
        }
    }

    /// Имя с диска приходит разложенным (NFD) — на нём перекодировка
    /// отказывала, и починка молча не срабатывала именно там, где нужна.
    func testDecomposedNameFromDiskIsRestoredToo() {
        let fromDisk = "20250821_12522_Л†°Ѓа†вЃа®п ВС.pdf".decomposedStringWithCanonicalMapping
        XCTAssertEqual(FileNameEncoding.repaired(fromDisk), "20250821_12522_Лаборатория ВС.pdf")
    }

    /// Кириллицы больше не стало — значит чинить было нечего.
    func testLatinNameWithHighBytesIsNotTouched() {
        XCTAssertEqual(FileNameEncoding.repaired("caf\u{00E9}-menu.pdf"), "caf\u{00E9}-menu.pdf")
    }

    /// Одного значка мало, и это не придирка: «®» переходит в букву «и», от
    /// чего кириллицы становится на одну больше, — правила «стало больше»
    /// хватило бы, чтобы испортить целое здоровое имя.
    func testHealthyNameWithASingleSymbolIsNotTouched() {
        let names = [
            "Договор ® 2026.pdf",       // ® → «и»: кириллицы 7 → 8
            "Прайс № 5 • копия.docx",
            "Смета† итог.docx",
            "Отчёт 20°.pdf",
        ]
        for name in names {
            XCTAssertEqual(FileNameEncoding.repaired(name), name, "здоровое имя со значком изменено")
        }
    }

    /// Примета порчи считается по самим кодировкам, а не выписана руками:
    /// в ней те знаки, за которыми в CP866 стоит буква, а в MacCyrillic — нет.
    func testMojibakeMarkersAreDerivedFromTheCodePages() {
        XCTAssertTrue(FileNameEncoding.mojibakeMarkers.contains("®"))
        XCTAssertTrue(FileNameEncoding.mojibakeMarkers.contains("°"))
        XCTAssertTrue(FileNameEncoding.mojibakeMarkers.contains("†"))
        XCTAssertFalse(FileNameEncoding.mojibakeMarkers.contains("А"), "буква приметой быть не может")
        XCTAssertFalse(FileNameEncoding.mojibakeMarkers.contains("a"))
        // У живых испорченных имён примет по шесть — с запасом над порогом.
        let broken = "20250820_12512_КП_С®бв•ђ≠л© бЃдв.pdf"
        XCTAssertGreaterThanOrEqual(broken.filter(FileNameEncoding.mojibakeMarkers.contains).count, 2)
    }

    // MARK: - Имена записей внутри zip

    /// Без флага UTF-8 имя в кодовой странице, и для русских архивов это
    /// CP866. Прежде оно читалось как Latin-1 — молча и неверно.
    func testZipEntryWithoutUTF8FlagIsReadAsCP866() throws {
        let cp866 = try XCTUnwrap("Отчёт/данные.txt".data(using: FileNameEncoding.dosRussian))
        XCTAssertEqual(ZIPContainerReader.entryName(cp866, declaresUTF8: false), "Отчёт/данные.txt")
    }

    /// С флагом читается как UTF-8 — и это не меняется.
    func testZipEntryWithUTF8FlagIsReadAsUTF8() throws {
        let utf8 = try XCTUnwrap("Отчёт/данные.txt".data(using: .utf8))
        XCTAssertEqual(ZIPContainerReader.entryName(utf8, declaresUTF8: true), "Отчёт/данные.txt")
    }

    /// Флаг обещал UTF-8, а байты не разбираются: запись пропускается, а не
    /// угадывается. Поведение прежнее, и тест держит его на месте.
    func testZipEntryLyingAboutUTF8IsSkipped() throws {
        let cp866 = try XCTUnwrap("Отчёт.txt".data(using: FileNameEncoding.dosRussian))
        XCTAssertNil(ZIPContainerReader.entryName(cp866, declaresUTF8: true))
    }

    /// Латиница одинакова во всех этих кодировках — самый частый случай не
    /// должен зависеть ни от флага, ни от догадок.
    func testAsciiEntryNameIsTheSameEitherWay() throws {
        let ascii = try XCTUnwrap("word/document.xml".data(using: .utf8))
        XCTAssertEqual(ZIPContainerReader.entryName(ascii, declaresUTF8: false), "word/document.xml")
        XCTAssertEqual(ZIPContainerReader.entryName(ascii, declaresUTF8: true), "word/document.xml")
    }
}
