import Foundation
import SwiftUI
import AppKit
import PDFKit
import ChromaCore

/// Просмотр исходного документа с подсветкой найденного фрагмента.
///
/// Открывается по действию у результата поиска и у результата стенда оценки:
/// при разметке посмотреть исходник нужно особенно.
@MainActor
final class DocumentViewerViewModel: ObservableObject {

    /// Что открыто сейчас. `nil` — панель закрыта.
    @Published var request: Request?
    @Published private(set) var state: State = .idle

    struct Request: Identifiable {
        let id = UUID()
        /// Текст чанка — то, что ищем в документе.
        let chunk: String
        let metadata: ChromaMetadata?
        /// Откуда открыли — для заголовка панели.
        let title: String
    }

    enum State {
        case idle
        case loading
        /// Показать нечего, и вот почему.
        case problem(String, reference: SourceReference?)
        case pdf(document: PDFDocument, location: PDFFragmentFinder.Location, url: URL)
        /// Простой текст, Markdown, код, CSV: моноширинный шрифт и номера
        /// строк обязательны.
        ///
        /// Оформленный текст готовится здесь, а не в `body`: иначе на каждую
        /// перерисовку получался бы новый объект, а просмотрщик отличает
        /// «тот же документ» от «другого» именно по нему.
        case plainText(text: NSAttributedString, placement: TextFragmentPlacement?, url: URL)
        /// `.docx`, `.rtf`, `.odt` — как их рисует система.
        case richText(text: NSAttributedString, placement: TextFragmentPlacement?, url: URL)
        /// Глава EPUB — одна, а не книга целиком.
        case epub(chapter: EPUBChapterLoader.Chapter, placement: TextFragmentPlacement?, url: URL)
        /// Лист таблицы: окно строк вокруг найденной, с заголовками.
        case table(window: TableRowLoader.Window, url: URL)
        /// Формат, который внутри не показывается, — только системе.
        case externalOnly(url: URL)
    }

    /// Файл открытого документа, если он есть, — для «Открыть во внешнем
    /// приложении». Кнопка доступна всегда, когда файл найден.
    var fileURL: URL? {
        switch state {
        case .pdf(_, _, let url), .externalOnly(let url),
             .plainText(_, _, let url), .richText(_, _, let url),
             .epub(_, _, let url), .table(_, let url):
            return url
        default:
            return nil
        }
    }

    func open(chunk: String, metadata: ChromaMetadata?, title: String, app: AppEnvironment) {
        request = Request(chunk: chunk, metadata: metadata, title: title)
        load(app)
    }

    func close() {
        request = nil
        state = .idle
        showFailure = nil
        documentName = nil
    }

    /// Имя файла по метаданным — даже когда самого файла уже нет.
    ///
    /// Панель обязана назваться документом и в этом случае: «файл не найден»
    /// под заголовком с идентификатором чанка не говорит человеку ничего.
    @Published private(set) var documentName: String?

    private func load(_ app: AppEnvironment) {
        guard let request else { return }
        state = .loading
        showFailure = nil
        documentName = DocumentLocator.reference(metadata: request.metadata).fileName

        let resolution = DocumentLocator.resolve(
            metadata: request.metadata,
            sources: app.settings.configuration.dataSources
        )
        guard case .found(let url, let kind, let target) = resolution else {
            let reference = DocumentLocator.reference(metadata: request.metadata)
            state = .problem(
                resolution.problem ?? String(localized: "Показать документ не удалось."),
                reference: resolution == .notFromFile ? nil : reference
            )
            return
        }

        switch kind {
        case .pdf:
            openPDF(at: url, chunk: request.chunk, target: target)
        case .plainText:
            openPlainText(at: url, chunk: request.chunk)
        case .richText:
            openRichText(at: url, chunk: request.chunk)
        case .epub:
            openEPUB(at: url, chunk: request.chunk, target: target)
        case .table:
            openTable(at: url, target: target)
        case .externalOnly:
            // Keynote и Pages внутри не показываются: ТЗ разрешает слайд по
            // сохранённому экспорту в PDF, а приложение его не хранит.
            state = .externalOnly(url: url)
        }
    }

    private func openPDF(at url: URL, chunk: String, target: ViewerTarget) {
        // Крупные PDF не читаются в память целиком: `PDFDocument(url:)`
        // работает постранично, и это единственная причина открывать его
        // именно так.
        guard let document = PDFDocument(url: url) else {
            state = .problem(
                String(localized: "Файл «\(url.lastPathComponent)» не открылся как PDF. Возможно, он повреждён или защищён паролем."),
                reference: nil
            )
            return
        }
        let page: Int? = if case .page(let number) = target { number } else { nil }
        guard let location = PDFFragmentFinder.locate(
            chunk: chunk, in: document, startingAt: page
        ) else {
            state = .problem(String(localized: "В документе нет ни одной страницы."), reference: nil)
            return
        }
        state = .pdf(document: document, location: location, url: url)
    }

    private func openPlainText(at url: URL, chunk: String) {
        do {
            let text = try TextDocumentLoader.plainText(at: url)
            state = .plainText(
                text: NSAttributedString(string: text, attributes: [
                    // моноширинный шрифт и нумерация строк обязательны.
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.textColor,
                ]),
                placement: TextFragmentPlacement.locate(chunk: chunk, in: text),
                url: url
            )
        } catch {
            // Файл найден и цел — просто показать внутри не выходит.
            // «Открыть во внешнем» при этом обязано остаться доступным,
            // поэтому это не `.problem`, а состояние с файлом.
            failedToShow(url: url, reason: error.localizedDescription)
        }
    }

    private func openRichText(at url: URL, chunk: String) {
        do {
            let attributed = try TextDocumentLoader.richText(at: url)
            state = .richText(
                text: attributed,
                placement: TextFragmentPlacement.locate(chunk: chunk, in: attributed.string),
                url: url
            )
        } catch {
            failedToShow(url: url, reason: error.localizedDescription)
        }
    }

    private func openEPUB(at url: URL, chunk: String, target: ViewerTarget) {
        var chapterID: String?
        var spineIndex: Int?
        if case .chapter(let id, let index) = target {
            chapterID = id
            spineIndex = index
        }
        do {
            let chapter = try EPUBChapterLoader.chapter(
                at: url, chapterID: chapterID, spineIndex: spineIndex
            )
            state = .epub(
                chapter: chapter,
                placement: TextFragmentPlacement.locate(chunk: chunk, in: chapter.text.string),
                url: url
            )
        } catch {
            failedToShow(url: url, reason: error.localizedDescription)
        }
    }

    private func openTable(at url: URL, target: ViewerTarget) {
        var sheet: String?
        var row: Int?
        if case .tableRow(let name, let number) = target {
            sheet = name
            row = number
        }
        do {
            state = .table(
                window: try TableRowLoader.window(at: url, sheetName: sheet, row: row),
                url: url
            )
        } catch {
            failedToShow(url: url, reason: error.localizedDescription)
        }
    }

    /// Показать не вышло, но файл на месте.
    @Published private(set) var showFailure: String?

    private func failedToShow(url: URL, reason: String) {
        showFailure = reason
        state = .externalOnly(url: url)
    }

    /// Открыть в том, чем система открывает такие файлы. Доступно всегда,
    /// когда файл найден, — включая форматы, которые панель показать не умеет.
    func openExternally() {
        guard let fileURL else { return }
        NSWorkspace.shared.open(fileURL)
    }

    func revealInFinder() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
