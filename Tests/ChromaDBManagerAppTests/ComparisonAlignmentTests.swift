import XCTest
import SwiftUI
import AppKit

/// Сравнение вариантов стоит строками, а не стопкой независимых колонок.
///
/// Сторож по исходникам, как `ChosenStateIsVisibleTests`: разъехавшиеся
/// колонки компилируются, проходят все прочие тесты и видны только глазами —
/// а сравнивать по ним нельзя, потому что четвёртая строка одного варианта
/// стоит напротив шестой у соседнего.
final class ComparisonAlignmentTests: XCTestCase {
    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views/EvaluationView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("исходники экрана не найдены рядом с тестами")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Строки одного номера — в одном ряду сетки.
    func testTheVariantsAreComparedInAGrid() throws {
        let view = try source()
        XCTAssertTrue(view.contains("Grid(alignment: .topLeading"), "выдачи вариантов обязаны стоять сеткой")
        XCTAssertTrue(view.contains("GridRow {"), "у каждого номера результата — свой ряд")
    }

    /// Горизонтальная прокрутка одна на карточку, а не своя у каждого запроса:
    /// вложенных прокруток было столько же, сколько запросов, и колесо
    /// трекпада металось между ними.
    func testThereIsOneHorizontalScrollForTheWholeCard() throws {
        let view = try source()
        let occurrences = view.components(separatedBy: "ScrollView(.horizontal").count - 1
            + view.components(separatedBy: "ScrollView([.horizontal").count - 1
        XCTAssertLessThanOrEqual(occurrences, 2, "лишние вложенные прокрутки: \(occurrences)")
    }

    /// Выдача листается в собственной панели с заданной высотой.
    ///
    /// Без своей высоты ленивый стек не ленив: горизонтальная прокрутка
    /// внутри страничной не ограничивает высоту, стек обязан назвать полную
    /// и потому строит все строки разом. Замерено: 18 запросов по три
    /// варианта — 1200 мс раскладки против 105 мс, и второе не растёт.
    /// Сломать это можно молча — убрав одну строку с высотой, — а видно
    /// будет только по тому, что окно «подлагивает».
    func testTheResultsScrollInTheirOwnPane() throws {
        let view = try source()
        XCTAssertTrue(
            view.contains("ScrollView([.horizontal, .vertical])"),
            "панель выдачи обязана листаться по обеим осям"
        )
        // Панель разметки — отдельная часть вкладки «Прогоны» и занимает всё
        // место под своей шапкой: высота у неё своя, от окна, а не от
        // содержимого, — иначе ленивый стек снова строит всё разом.
        XCTAssertTrue(
            view.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"),
            "у панели обязана быть своя высота — всё место под шапкой"
        )
        XCTAssertTrue(view.contains("LazyVStack"), "список запросов обязан быть ленивым")
    }

    /// Полосе прокрутки отведено своё место.
    ///
    /// Накладная полоса рисуется поверх содержимого, а значок «показать
    /// в источнике» стоит вплотную к правому краю колонки: без
    /// отступа полоса накрывала его целиком, и нажать было не на что.
    /// Видно это только глазами и только долистав панель до правого края,
    /// поэтому — тест.
    func testTheScrollersHaveRoomOfTheirOwn() throws {
        let view = try source()
        XCTAssertTrue(
            view.contains("padding(.trailing, Self.scrollerClearance)"),
            "содержимому панели нужен отступ справа под полосу прокрутки"
        )
        XCTAssertTrue(
            view.contains("padding(.bottom, Self.scrollerClearance)"),
            "и снизу — под горизонтальную полосу"
        )
        let clearance = try XCTUnwrap(
            Self.number(after: "static let scrollerClearance: CGFloat = ", in: view),
            "не нашлось место под полосу прокрутки"
        )
        // Накладная полоса macOS — 15 pt вместе с отбивкой.
        XCTAssertGreaterThanOrEqual(clearance, 15, "полоса шире отведённого места")
    }

    /// Высота строки не пляшет: место под пять строк текста отведено всегда.
    func testTheRowKeepsItsHeight() throws {
        let view = try source()
        XCTAssertTrue(
            view.contains("lineLimit(5, reservesSpace: true)"),
            "плавающая высота строки — это и есть «скачет при прокрутке»"
        )
    }

    /// Строка разметки помещается в колонку целиком — со значком «показать
    /// в источнике».
    ///
    /// Ширина колонки — число в исходнике, а ширина трёх капсул — метрики
    /// шрифта: они не совпадают сами по себе, и разошлись молча. Значок стоял
    /// последним, поэтому за край уезжал именно он: половина видна, нажать
    /// нельзя. Глазами это ловится только если прокрутить сравнение до правого
    /// края колонки, поэтому — тест.
    /// Строка разметки — три оценки и значок «показать в источнике» —
    /// помещается в колонку целиком.
    ///
    /// Меряется настоящая разметка, а не сумма выдуманных чисел: строка
    /// собирается теми же системными кнопками и тем же размером, что
    /// на экране, и её ширина сравнивается с шириной колонки. Если значок не
    /// помещается, он уезжает за край колонки — видна половина, нажать не на что.
    @MainActor
    func testTheMarkingRowFitsTheColumnTogetherWithTheSourceButton() throws {
        let view = try source()
        let column = try XCTUnwrap(
            Self.number(after: "private static let columnWidth: CGFloat = ", in: view),
            "не нашлась ширина колонки"
        )
        let row = HStack(spacing: 4) {
            ForEach(["релевантен", "частично", "нерелевантен"], id: \.self) { title in
                if title == "нерелевантен" {
                    Button(title) {}.controlSize(.small).fixedSize()
                        .buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button(title) {}.controlSize(.small).fixedSize().buttonStyle(.bordered)
                }
            }
            Spacer(minLength: 4)
            Button { } label: { Image(systemName: "doc.text.magnifyingglass") }
                .buttonStyle(.borderless).controlSize(.small)
        }
        .fixedSize()
        let host = NSHostingView(rootView: row)
        host.layoutSubtreeIfNeeded()
        let needed = host.fittingSize.width
        XCTAssertGreaterThanOrEqual(
            column, needed,
            "строка разметки шире колонки — значок «показать в источнике» уедет за край: "
                + "нужно \(String(format: "%.1f", needed)) pt, в колонке \(String(format: "%.1f", column)) pt"
        )
    }

    private static func number(after marker: String, in text: String) -> CGFloat? {
        guard let range = text.range(of: marker) else { return nil }
        let tail = text[range.upperBound...].prefix(12)
        let digits = tail.prefix { $0.isNumber || $0 == "." }
        return Double(digits).map { CGFloat($0) }
    }
}
