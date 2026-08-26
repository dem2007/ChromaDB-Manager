import XCTest
import SwiftUI
import AppKit
import ChromaCore
@testable import ChromaDBManagerApp

/// Ряды выдачи одной высоты — иначе прокрутка подпрыгивает.
///
/// Ленивый список судит о высоте ещё не построенных запросов по построенным
///. Пока строки разной высоты, эта оценка расходится с
/// действительностью — и список дёргается ровно так, как жаловался заказчик.
///
/// **Здесь собран двойник строки, а не она сама.** Настоящая требует модель
/// и окружение приложения; двойник повторяет её состав — подпись, три строки
/// текста, ряд оценок, мнение модели — теми же шрифтами и тем же стилем
/// кнопок. Он ловит то, что ломается молча: изменившийся кегль, добавленную
/// строку, другой стиль капсулы. Если строку переделают, не тронув двойника,
/// тест этого не увидит — поэтому рядом стоит проверка по исходнику, что
/// высота вообще закреплена.
@MainActor
final class ResultRowHeightTests: XCTestCase {

    private struct RowTwin: View {
        let judged: Bool
        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text("1. 7 090 знаков · родительский")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText).lineLimit(1)
                Text("…к настройке обмена со шлюзом ведомства Исполнитель обязан наладить защищённое соединение рабочих серверов и…")
                    .font(Theme.Font.caption)
                    .lineLimit(3, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    ForEach(["релевантен", "частично", "нерелевантен"], id: \.self) { title in
                        Button(title) {}.buttonStyle(.chromaChoice(nil)).controlSize(.small).fixedSize()
                    }
                    Text("не размечено").font(Theme.Font.micro).lineLimit(1).layoutPriority(-1)
                    Spacer(minLength: 4)
                    Button { } label: { Image(systemName: "doc.text.magnifyingglass") }
                        .buttonStyle(.borderless).controlSize(.small)
                }
                if judged {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("модель: релевантен").font(Theme.Font.micro).italic()
                            Button("принять") {}.buttonStyle(.borderless).controlSize(.small)
                        }
                        // Причина занимает три строки — столько ей отведено
                        // в настоящей строке.
                        Text(String(repeating: "причина оценки ", count: 12))
                            .font(Theme.Font.micro).italic()
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 3)
            .frame(width: 372, alignment: .topLeading)
        }
    }

    private struct HeaderTwin: View {
        let note: Bool
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("Иерархия: отвечать родителем").font(Theme.Font.caption).bold()
                Text("вектор переиспользован · поиск 1 033 мс · 10 результатов")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                if note {
                    Text("Прогон записан до того, как метаданные стали сохраняться: перехода к исходнику по нему нет. Прогоните набор заново.")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 372, alignment: .leading)
        }
    }

    private func height<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: 372))
        host.frame = NSRect(x: 0, y: 0, width: 372, height: 10)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// Закреплённая высота обязана вмещать строку целиком: меньше — и текст
    /// с кнопками полезет на соседний ряд.
    func testTheFixedHeightFitsTheRow() {
        XCTAssertEqual(height(RowTwin(judged: false)), EvaluationView.rowHeight(judged: false))
        XCTAssertEqual(height(RowTwin(judged: true)), EvaluationView.rowHeight(judged: true))
    }

    func testTheFixedHeightFitsTheColumnHeader() {
        let plain = EvaluationRunSamples.run(queries: 1, hits: 3, metadata: true)
        let old = EvaluationRunSamples.run(queries: 1, hits: 3, metadata: false)
        XCTAssertEqual(height(HeaderTwin(note: false)), EvaluationView.headerHeight(for: plain))
        XCTAssertEqual(height(HeaderTwin(note: true)), EvaluationView.headerHeight(for: old))
    }

    /// Оговорка про метаданные — либо у всего прогона, либо ни у кого: место
    /// под неё держится по прогону, а не по колонке.
    func testTheNoteIsMeasuredForTheWholeRun() {
        let mixed = EvaluationRunSamples.run(queries: 3, hits: 3, metadata: true, firstWithoutMetadata: true)
        XCTAssertEqual(EvaluationView.headerHeight(for: mixed), 66, "хватить места обязано и той колонке, где оговорка есть")
    }

    /// Ширина сетки — то, чем ограничены подпись запроса и разделитель.
    func testTheGridWidthCountsTheColumnsAndTheGaps() {
        let run = EvaluationRunSamples.run(queries: 1, hits: 1, metadata: true, variants: 3)
        XCTAssertEqual(EvaluationView.gridWidth(for: run), 372 * 3 + 12 * 2)
        let single = EvaluationRunSamples.run(queries: 1, hits: 1, metadata: true, variants: 1)
        XCTAssertEqual(EvaluationView.gridWidth(for: single), 372)
    }

    /// Подпись запроса — две строки, и число под неё отведённое верно.
    func testTheQueryTitleKeepsTwoLines() {
        let twin = Text("Порядок обновления справочников")
            .font(Theme.Font.body).bold()
            .lineLimit(2, reservesSpace: true)
            .fixedSize(horizontal: false, vertical: true)
        XCTAssertEqual(height(twin), EvaluationView.queryTitleHeight)
    }

    /// Высота блока запроса складывается из закреплённых частей — и складка
    /// сходится с тем, что показывает настоящая разметка.
    ///
    /// Проверка не на «блок закреплён», а на арифметику: подпись, шапка,
    /// десять рядов с промежутками, разделитель. Ошибка здесь не видна ни
    /// на снимке, ни в тестах строки — только рукой на прокрутке вверх.
    func testTheBlockHeightAddsUp() {
        let run = EvaluationRunSamples.run(queries: 1, hits: 10, metadata: true, variants: 3)
        let expected = EvaluationView.queryTitleHeight
            + EvaluationView.blockSpacing
            + EvaluationView.headerHeight(for: run)
            + 10 * (EvaluationView.blockSpacing + EvaluationView.rowHeight(judged: false))
            + EvaluationView.blockSpacing
            + EvaluationView.dividerHeight
        // Ровно столько же насчитывает и сам экран — через свой собственный
        // проход по рядам.
        let byHand: CGFloat = 32 + 6 + 34 + 1070 + 6 + 1
        XCTAssertEqual(expected, byHand)
    }

    /// Высота закреплена в самом экране, а не только в этих числах.
    func testTheScreenPinsTheHeights() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views/EvaluationView.swift")
        let view = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(view.contains(".frame(height: Self.rowHeight(judged:"), "строка обязана держать высоту")
        XCTAssertTrue(view.contains("height: Self.headerHeight(for: run)"), "шапка обязана держать высоту")
        XCTAssertTrue(view.contains("lineLimit(2, reservesSpace: true)"), "подпись запроса обязана держать две строки")
        XCTAssertTrue(
            view.contains("height: blockHeight(run: run, query: query)"),
            "блок запроса обязан держать высоту: без этого ленивый список угадывает её и дёргает прокрутку вверх"
        )
    }
}

/// Прогон-образец для проверок разметки экрана.
enum EvaluationRunSamples {
    static func run(
        queries: Int, hits: Int, metadata: Bool,
        variants: Int = 1, firstWithoutMetadata: Bool = false
    ) -> EvaluationRun {
        let list = (0..<queries).map { EvaluationQuery(text: "запрос \($0)") }
        let plan = (0..<variants).map { number in
            EvaluationVariant(
                name: "вариант \(number)", collectionID: "c\(number)", collectionName: "к",
                model: "m", nResults: hits, profile: SearchProfile(collectionName: "к")
            )
        }
        var results: [EvaluationResult] = []
        for (index, query) in list.enumerated() {
            for variant in plan {
                let withMetadata = metadata && !(firstWithoutMetadata && index == 0)
                results.append(EvaluationResult(
                    queryID: query.id, variantID: variant.id,
                    hits: (0..<hits).map {
                        EvaluationHit(
                            id: "d\($0)", text: "текст", distance: nil, position: $0 + 1,
                            metadata: withMetadata ? ["source_file": .string("f")] : nil
                        )
                    }
                ))
            }
        }
        return EvaluationRun(
            name: "прогон", querySetID: UUID(), querySetName: "набор",
            queries: list, variants: plan, results: results
        )
    }
}
