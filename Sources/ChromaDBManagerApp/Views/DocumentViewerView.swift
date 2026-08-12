import SwiftUI
import PDFKit
import ChromaCore

/// Панель просмотра исходного документа.
///
/// Показывается листом поверх экрана, с которого её открыли: и с «Коллекций»,
/// и со стенда оценки нужен один и тот же просмотр, а лист не заставляет
/// заводить для него отдельный раздел меню.
struct DocumentViewerSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @ObservedObject var model: DocumentViewerViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let note {
                Divider()
                Text(note)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.attention)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 520, idealHeight: 760)
    }

    /// Оговорка о точности — под документом, а не поверх него.
    ///
    /// «Точное место не определено» и «совпали только края» — это уровни
    /// уверенности, и человек должен видеть их до того, как решит, что
    /// приложение показало не то.
    private var note: String? {
        switch model.state {
        case .pdf(_, let location, _):
            return location.note
        case .plainText(_, let placement, _), .richText(_, let placement, _),
             .epub(_, let placement, _):
            guard let placement else {
                return String(localized: "Точное место в документе определить не удалось — документ открыт целиком.")
            }
            return placement.note
        case .table(let window, _) where window.targetRow == nil:
            return String(localized: "Строку, из которой сделан фрагмент, в листе найти не удалось — показано начало листа.")
        default:
            return nil
        }
    }

    /// Строка «строка N» в шапке — только когда место известно.
    private var placementLine: String? {
        switch model.state {
        case .plainText(_, let placement, _):
            return placement.map { String(localized: "строка \($0.line)") }
        case .richText:
            // Номер строки в вёрстке не значит ничего: в Word такой строки
            // нет. Раз колонку номеров мы для `.docx` не показываем, то и
            // в шапке её называть нечестно.
            return nil
        case .pdf(_, let location, _):
            return String(localized: "страница \(location.pageIndex + 1)")
        case .epub(let chapter, _, _):
            return chapter.line
        case .table(let window, _):
            return window.line
        default:
            return nil
        }
    }

    private var title: String {
        model.fileURL?.lastPathComponent
            ?? model.documentName
            ?? model.request?.title
            ?? String(localized: "Документ")
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                // Панель называется тем файлом, который открыла, а не тем,
                // откуда её позвали: у результата стенда «заголовок» — это
                // идентификатор чанка, и человеку он ничего не говорит.
                Text(title)
                    .font(Theme.Font.objectTitle)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    // Место в документе — первым и целиком: оно короткое и
                    // это главное, что человек ищет глазами. Ужимается путь:
                    // он длинный, и середина в нём не нужна.
                    if let placementLine {
                        Text(placementLine)
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                            .fixedSize()
                    }
                    if let url = model.fileURL {
                        Text(url.path)
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                            .lineLimit(1).truncationMode(.middle)
                            .copyable(url.path)
                    }
                }
            }
            Spacer(minLength: 12)

            if model.fileURL != nil {
                Button(String(localized: "Показать в Finder")) { model.revealInFinder() }
                    .buttonStyle(.chromaNormal)
                // Кнопка «во внешнем приложении» доступна всегда, когда файл
                // найден, — для любого формата.
                Button(String(localized: "Открыть во внешнем")) { model.openExternally() }
                    .buttonStyle(.chromaNormal)
            }
            Button(String(localized: "Закрыть")) { model.close() }
                .buttonStyle(.chromaPrimary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Theme.Padding.cardHorizontal)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            Color.clear
        case .loading:
            ProgressView().controlSize(.small)
        case .problem(let text, let reference):
            problemView(text, reference: reference)
        case .pdf(let document, let location, _):
            PDFViewer(document: document, location: location)
        case .plainText(let text, let placement, _):
            TextViewer(text: text, placement: placement, showsLineNumbers: true)
        case .richText(let text, let placement, _):
            // Форматированный документ рисуется так, как его сделала система:
            // свои шрифты поверх чужой вёрстки — это уже не «исходник».
            TextViewer(text: text, placement: placement, showsLineNumbers: false)
        case .epub(let chapter, let placement, _):
            TextViewer(text: chapter.text, placement: placement, showsLineNumbers: false)
        case .table(let window, _):
            TableWindowView(window: window)
        case .externalOnly(let url):
            externalOnlyView(url)
        }
    }

    /// Файл не найден, источник не зарегистрирован или документ добавлен
    /// руками — три разных случая, и каждый чинится по-своему.
    private func problemView(_ text: String, reference: SourceReference?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 32)).foregroundStyle(Theme.Palette.captionText)
            Text(text)
                .font(Theme.Font.body).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
            if let reference, let target = reference.target.line {
                Text(String(localized: "При индексации фрагмент был здесь: \(target)."))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func externalOnlyView(_ url: URL) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 32)).foregroundStyle(Theme.Palette.captionText)
            // Две разные причины, и путать их нельзя: формат не поддержан —
            // это про приложение, а «не открылся» — про конкретный файл,
            // и во втором случае человеку нужна сама причина.
            if let failure = model.showFailure {
                Text(String(localized: "Показать внутри приложения не вышло."))
                    .font(Theme.Font.body)
                Text(failure)
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
            } else {
                Text(String(localized: "Этот формат панель пока не показывает — \(DocumentLocator.kind(of: url).title)."))
                    .font(Theme.Font.body)
                Text(String(localized: "Файл найден и цел; откройте его тем, чем открывает система."))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            }
            Button(String(localized: "Открыть во внешнем приложении")) { model.openExternally() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `PDFView` из PDFKit.
///
/// Через `NSViewRepresentable`, а не своей отрисовкой: постраничная загрузка,
/// поиск, копирование и масштаб уже написаны в системе, и переписывать их
/// ради подсветки одного фрагмента незачем.
private struct PDFViewer: NSViewRepresentable {
    let document: PDFDocument
    let location: PDFFragmentFinder.Location

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        apply(to: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: PDFView) {
        if view.document !== document { view.document = document }
        guard let page = document.page(at: location.pageIndex) else { return }
        view.go(to: page)

        // Только подсветка, без `setCurrentSelection`: выделение рисуется
        // **поверх** подсветки своим синим, и жёлтого тогда не видно вовсе —
        // проверено в окне. А человек ищет глазами именно жёлтое.
        if let selection = PDFFragmentFinder.selection(for: location, in: document) {
            selection.color = .systemYellow
            view.setCurrentSelection(nil, animate: false)
            view.highlightedSelections = [selection]
            // Прокрутка к самому фрагменту, а не к началу страницы: на
            // странице А4 «нашли внизу» и «открыли сверху» — разные вещи.
            view.go(to: selection)
        } else {
            view.highlightedSelections = nil
            view.setCurrentSelection(nil, animate: false)
        }
    }
}

/// Текст и форматированный документ в `NSTextView`.
///
/// Своей отрисовкой это не делается: перенос строк, выделение, копирование
/// и поиск по ⌘F в `NSTextView` уже есть. Здесь добавляются ровно две вещи,
/// которых нет: подсветка найденного диапазона и линейка номеров строк.
private struct TextViewer: NSViewRepresentable {
    let text: NSAttributedString
    let placement: TextFragmentPlacement?
    /// 1 требует номера строк для текста и кода. Для `.docx` они бессмысленны:
    /// строки там — результат вёрстки, а не свойство документа.
    let showsLineNumbers: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Помнит, что уже показано.
    ///
    /// Без этого каждая перерисовка SwiftUI заново красила бы текст и
    /// **возвращала прокрутку к фрагменту** — человек не смог бы отлистать
    /// от него ни строки.
    final class Coordinator {
        var shownText: NSAttributedString?
        var shownRange: NSRange?
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Текстовый стек собирается руками, а не через `scrollableTextView()`:
        // нужен свой подкласс вида и гарантированный TextKit 1 — расчёт места
        // строки идёт через `NSLayoutManager`, которого в TextKit 2 нет.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = LineNumberTextView(frame: .zero, textContainer: container)
        textView.showsLineNumbers = showsLineNumbers
        // Просмотрщик не изменяет файл ни при каких условиях, поэтому
        // правка выключена. Выделение и копирование — остаются.
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = NSView.AutoresizingMask.width
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // Слева — место под номера строк. Отступ именно у текстового вида:
        // так колонка не может наехать на текст в принципе, чем бы её ни
        // рисовали. `NSRulerView` этого не гарантирует — проверено в окне.
        textView.textContainerInset = NSSize(
            width: showsLineNumbers ? LineNumberTextView.gutter : 8, height: 10
        )

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.documentView = textView
        apply(to: textView, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        apply(to: textView, coordinator: context.coordinator)
    }

    private func apply(to textView: NSTextView, coordinator: Coordinator) {
        let range = placement.map {
            NSRange(location: $0.characterRange.lowerBound, length: $0.characterRange.count)
        }
        // Тот же документ и то же место — делать нечего. Повторное применение
        // сбрасывало бы прокрутку человеку под руку.
        guard coordinator.shownText !== text || coordinator.shownRange != range else { return }
        let isNewText = coordinator.shownText !== text
        coordinator.shownText = text
        coordinator.shownRange = range

        if isNewText { textView.textStorage?.setAttributedString(text) }
        guard let range, NSMaxRange(range) <= textView.string.utf16.count else { return }
        // Только жёлтый фон, без `setSelectedRange`: выделение рисуется поверх
        // фона своим синим и полностью его закрывает — проверено в окне.
        textView.textStorage?.addAttribute(
            .backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.45), range: range
        )
        scroll(textView, to: range)
    }

    /// Прокрутка к **началу** фрагмента.
    ///
    /// `scrollRangeToVisible` подтягивает диапазон минимальным движением, и на
    /// фрагменте выше экрана это показывает его конец: начало остаётся сверху
    /// за краем, и человек видит текст, который ничем не выделен.
    ///
    /// Считается не сразу: пока вид не получил ширину, перенос строк не
    /// посчитан, и место строки — выдумка. На листе это видно сразу: панель
    /// открывается на 33-й строке вместо 150-й.
    private func scroll(_ textView: NSTextView, to range: NSRange, attempt: Int = 0) {
        guard textView.bounds.width > 1 else {
            guard attempt < 10 else { return }
            DispatchQueue.main.async { scroll(textView, to: range, attempt: attempt + 1) }
            return
        }
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return textView.scrollRangeToVisible(range) }

        // Раскладка ленивая: до неё прямоугольник строки — нули.
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(range)))
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let first = NSRange(location: glyphs.location, length: min(1, glyphs.length))
        var rect = layoutManager.boundingRect(forGlyphRange: first, in: container)
        rect.origin.y += textView.textContainerInset.height
        // Немного текста над фрагментом: строка, начатая ровно у верхнего
        // края, читается как обрезанная.
        textView.scroll(NSPoint(x: 0, y: max(0, rect.minY - 48)))
    }
}

/// Текстовый вид, который сам рисует номера строк в своём левом отступе.
///
/// Не `NSRulerView`: линейка — отдельный вид рядом с содержимым, её ширину
/// `NSScrollView` считает по-своему, и номера оказывались то под текстом, то
/// за краем. Отступ текстового контейнера таких вопросов не оставляет: место
/// под колонку вычтено из области текста, и наехать на строки нечему.
private final class LineNumberTextView: NSTextView {
    /// Ширина колонки с номерами.
    static let gutter: CGFloat = 46
    var showsLineNumbers = false

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard showsLineNumbers,
              let layoutManager,
              let container = textContainer
        else { return }

        // Волосяная линия отделяет колонку от текста: без неё номера читаются
        // как часть строки, особенно на файлах, начинающихся с цифр.
        NSColor.separatorColor.setFill()
        NSRect(x: Self.gutter - 10, y: rect.minY, width: 1, height: rect.height).fill()

        let text = string as NSString
        let glyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Номер первой нарисованной строки считается от начала текста один
        // раз, а дальше наращивается: перебирать весь файл на каждую строку —
        // это квадрат от его длины, и на большом логе прокрутка встала бы.
        var line = 1
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: characterRange.location),
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in line += 1 }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        var index = characterRange.location
        while index < NSMaxRange(characterRange) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphs = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var fragment = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            fragment.origin.y += textContainerInset.height

            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: Self.gutter - 18 - size.width, y: fragment.minY),
                withAttributes: attributes
            )

            line += 1
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
    }
}

/// Лист таблицы: заголовки и окно строк вокруг найденной.
private struct TableWindowView: View {
    let window: TableRowLoader.Window

    private var columnWidths: [CGFloat] {
        let count = max(window.header?.count ?? 0, window.rows.map(\.values.count).max() ?? 0)
        return Array(repeating: 180, count: count)
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                if let header = window.header {
                    row(number: nil, values: header, isHeader: true, isTarget: false)
                    Divider()
                }
                ForEach(window.rows) { item in
                    // Найденная строка — жёлтым, как подсветка в тексте:
                    // человек ищет глазами один и тот же цвет во всех форматах.
                    row(
                        number: item.number, values: item.values,
                        isHeader: false, isTarget: item.isTarget
                    )
                    Divider().opacity(0.3)
                }
            }
            .padding(10)
        }
    }

    private func row(number: Int?, values: [String], isHeader: Bool, isTarget: Bool) -> some View {
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(Theme.Font.mono)
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
                .padding(.trailing, 8)
            ForEach(Array(columnWidths.enumerated()), id: \.offset) { index, width in
                Text(index < values.count ? values[index] : "")
                    .font(Theme.Font.caption)
                    .fontWeight(isHeader ? .semibold : .regular)
                    .lineLimit(2)
                    .frame(width: width, alignment: .leading)
                    .padding(.trailing, 10)
            }
        }
        .padding(.vertical, 3)
        .background(isTarget ? Color.yellow.opacity(0.35) : Color.clear)
    }
}
