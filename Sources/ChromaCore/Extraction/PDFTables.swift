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
        assess(page).blocks.map { TableGeometry.render($0, vocabulary: .empty) }
    }

    /// То же, но со вторым ответом: была ли на странице таблица, которую
    /// собрать не удалось. Такая страница уходит к агенту сеткой
    /// чисел без названий колонок, и об этом он должен знать.
    ///
    /// Сначала — таблицы по рамке: где рамка нарисована, она знает
    /// границы ячеек точнее любой догадки по тексту. Остальное — по
    /// координатам знаков, как раньше.
    ///
    /// Третий ответ — строки у верхнего и нижнего края листа: среди них
    /// ищется оформление, повторяющееся по документу. У собранной
    /// страницы порядок строк — по месту, и штамп внизу листа не обязательно
    /// последний в тексте.
    /// - Parameter scan: разбор линий и картинок страницы; вызывающий может
    ///   отдать свой, чтобы не разбирать страницу ещё раз.
    static func assess(
        _ page: PDFPage, scan: (PDFPage) -> PDFRulings = PDFRulings.scan
    ) -> (blocks: [TableGeometry.PageBlock]?, unassembledTable: Bool, margins: [String]) {
        guard let words = words(of: page) else { return (nil, false, []) }
        let height = TableGeometry.medianHeight(of: words)
        guard height > 0 else { return (nil, false, []) }
        let grids = TableLattice.grids(from: scan(page).rulings, tolerance: latticeTolerance)
        let assessed = TableGeometry.page(words: words, grids: grids, height: height)
        guard assessed.blocks != nil, page.rotation % 180 == 0 else { return (assessed.blocks, assessed.unassembledTable, []) }
        let box = page.bounds(for: .mediaBox)
        let margin = Double(box.height) * furnitureMargin
        let edge = words.filter { Double($0.box.midY) < Double(box.minY) + margin || Double($0.box.midY) > Double(box.maxY) - margin }
        let margins = TableGeometry.lines(from: edge, height: height).map(\.text)
        return (assessed.blocks, assessed.unassembledTable, margins)
    }

    /// Край листа, где ищется оформление: десятая доля высоты сверху и снизу.
    static let furnitureMargin = 0.1

    /// Допуск рамки в пунктах: соседние ячейки Word рисуют свои стороны
    /// отдельно, со сдвигом на толщину линии.
    static let latticeTolerance = 2.5

    /// Сколько знаков сверять с выделением PDFKit.
    static let alignmentSample = 24

    /// Совпадают ли рамки знаков с текстом страницы.
    ///
    /// **Что было.** Номер рамки в `characterBounds` и номер знака в тексте
    /// страницы обычно совпадают с точностью до переводов строки (их рамок
    /// нет). Но не всегда: у письма со скрытым слоем распознанного текста
    /// рамки шли со сдвигом на пять знаков, каждой букве доставалась рамка
    /// соседней, и шапка «ООО «Пример Софт»» уходила в базу как
    /// «Сист мный», «соф »». Выделение PDFKit (`selection(for:)`) места
    /// знаков знает верно — по нему и проверка: два десятка знаков,
    /// равномерно по странице. Не сошлись — координат у страницы нет,
    /// и она идёт обычным текстом PDFKit.
    static func boundsMatchText(_ page: PDFPage, text: String) -> Bool {
        let characters = Array(text)
        let step = max(1, characters.count / alignmentSample)
        var offset = 0
        var checked = 0
        var matched = 0
        for (index, character) in characters.enumerated() {
            defer { if !character.isNewline { offset += 1 } }
            guard index % step == 0, !character.isWhitespace, character.isLetter || character.isNumber,
                  let selection = page.selection(for: NSRange(location: index, length: 1)),
                  selection.string == String(character) else { continue }
            let expected = selection.bounds(for: page)
            let actual = page.characterBounds(at: offset)
            checked += 1
            if abs(expected.midX - actual.midX) < 2 { matched += 1 }
        }
        guard checked >= 8 else { return true }
        return Double(matched) / Double(checked) >= 0.7
    }

    /// Рамка пробела ниже этой высоты — пробел самого документа: у знака без
    /// начертания высоты нет. Вставленный PDFKit пробел — высотой
    /// со строку.
    static let drawnSpaceHeight: CGFloat = 0.01

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
        // Пробел текста страницы — граница слова, даже когда промежутка между
        // знаками не видно. Но только пробел самого документа: у
        // этого знака нет начертания, и рамка у него нулевой высоты. Пробел,
        // который PDFKit вставил от себя — на стыке кусков, набранных разными
        // шрифтами, «АРТ» и «-1001», — высотой со строку, и ему не верим.
        // Перевод строки — не граница слова: строки и так разводит высота.
        var spaceBefore = false
        // Знаки нормализуются здесь же, по одному: текст страницы
        // нормализован до сшивки, а собранная по координатам
        // страница брала знаки сырыми — маркер `\u{F0B7}` в тексте вокруг
        // таблицы не узнавался маркером, и пункты сливались в абзац.
        // Смещение в UTF-16 здесь — номер знака: страницы с иными знаками
        // отсеяны выше.
        let fonts = PDFExtractor.symbolFonts(of: page, string: text)
        for (index, character) in text.enumerated() {
            defer { if !character.isNewline { offset += 1 } }
            if character.isNewline {
                spaceBefore = false
                continue
            }
            guard !character.isWhitespace else {
                if page.characterBounds(at: offset).height < Self.drawnSpaceHeight { spaceBefore = true }
                continue
            }
            let box = page.characterBounds(at: offset)
            guard box.width > 0, box.height > 0, box.width < 200,
                  let normalized = TextNormalization.replacement(for: character, font: fonts[index])
            else { continue }
            result.append(TableGeometry.Word(box: box, text: String(normalized), spaceBefore: spaceBefore))
            spaceBefore = false
        }
        guard result.count >= 20, boundsMatchText(page, text: text) else { return nil }
        return result
    }
}
