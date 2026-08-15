import Foundation
import PDFKit

/// Таблицы PDF — по координатам знаков, а не по тексту.
///
/// **Почему по координатам.** В PDF таблицы нет: есть знаки, расставленные
/// по странице. Текст, который отдаёт PDFKit, эту расстановку теряет, причём
/// двумя разными способами, и оба видели на файлах заказчика:
///
/// * строка ведомости приходит **восемью отдельными строками** — по одной
///   на ячейку, и связи «это одна строка таблицы» в тексте не остаётся;
/// * либо, наоборот, вся строка приходит одной строкой, а колонки в ней
///   разделены **одним пробелом** — от слов неотличимы.
///
/// Координаты знаков (`characterBounds`) знают правду: знаки одной строки
/// таблицы стоят на одной высоте, а между колонками остаётся промежуток
/// в разы шире межбуквенного.
///
/// Здесь — только добыча координат. Сборка строк и колонок общая для PDF
/// и распознанного скана и живёт в `TableGeometry`: у одного разбора
/// не должно быть двух подобий.
enum PDFPageTables {
    /// Дальше этого знаки не разбираются: страница такого размера — уже
    /// не таблица, а выгрузка, и обходить её по знаку слишком дорого.
    static let maximumCharacters = 30_000

    /// Страница, собранная по координатам. `nil` — таблиц на ней нет,
    /// и тогда всё остаётся как было: текст PDFKit и сшивка абзацев.
    static func page(_ page: PDFPage) -> String? {
        guard let words = words(of: page) else { return nil }
        let height = TableGeometry.medianHeight(of: words)
        guard height > 0 else { return nil }
        return TableGeometry.text(of: TableGeometry.lines(from: words, height: height))
    }

    /// Знаки страницы с их рамками. Каждый знак — отдельный кусок: в слова
    /// их соберёт `TableGeometry` по тем же промежуткам, что и ячейки.
    static func words(of page: PDFPage) -> [TableGeometry.Word]? {
        guard let text = page.string, text.count >= 40, text.count <= maximumCharacters else { return nil }
        // Смещения знаков PDFKit считает по UTF-16. Пока в тексте нет знаков
        // за пределами основной плоскости, это то же самое, что и по символам;
        // если есть — разбор по координатам не делается вовсе, вместо того
        // чтобы прикладывать рамки к чужим знакам.
        guard text.utf16.count == text.count else { return nil }

        // Смещение знака в рамках — **не** его номер в строке: переводы строки
        // PDFKit вставляет в текст сам, а в нумерации рамок их нет. Разница
        // копится по странице: к третьей строке рамки уезжают на три знака,
        // и «Кабель» приходит как «Кабел», а его «ь» — в соседнюю строку
        // (проверено на собранном файле).
        var result: [TableGeometry.Word] = []
        result.reserveCapacity(text.count)
        var offset = 0
        for character in text {
            defer { if !character.isNewline { offset += 1 } }
            guard !character.isWhitespace else { continue }
            let box = page.characterBounds(at: offset)
            guard box.width > 0, box.height > 0, box.width < 200 else { continue }
            result.append(TableGeometry.Word(box: box, text: String(character)))
        }
        return result.count >= 20 ? result : nil
    }
}
