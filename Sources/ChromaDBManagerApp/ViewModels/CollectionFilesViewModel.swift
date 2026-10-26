import AppKit
import Foundation
import ChromaCore
import UniformTypeIdentifiers

/// Раздел «Файлы» на вкладке «Обзор» коллекции.
///
/// Список собирается по кнопке: это обход всех кусков коллекции, на
/// девяноста тысячах — десятки секунд работы базы. Собранный список
/// помнится для каждой коллекции, пока окно открыто, и устаревшим считается,
/// когда в коллекции стало другое число записей.
@MainActor
final class CollectionFilesViewModel: ObservableObject {
    enum Sort: String, CaseIterable, Identifiable {
        case path, name, chunks, modified, size
        var id: String { rawValue }

        var title: String {
            switch self {
            case .path: return String(localized: "По папке")
            case .name: return String(localized: "По имени")
            case .chunks: return String(localized: "По числу кусков")
            case .modified: return String(localized: "По дате")
            case .size: return String(localized: "По размеру")
            }
        }
    }

    /// Сколько строк показывается: тысячи строк в форме вкладки тормозят
    /// прокрутку всего «Обзора». Остальное — поиском или выгрузкой.
    static let shownLimit = 200

    @Published private(set) var list: CollectionFileList?
    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double?
    @Published private(set) var progressText: String?
    @Published var errorMessage: String?
    @Published var query = ""
    @Published var sort: Sort = .path
    /// Какой ID только что скопирован — для отметки «Скопировано» в строке.
    @Published private(set) var copiedID: String?

    private var lists: [String: CollectionFileList] = [:]
    /// Два числа на момент сборки: сколько записей знал экран и сколько
    /// насчитал сам обход. Список устарел, только если нынешнее число не
    /// совпадает ни с одним: число на экране бывает старше обхода, и когда
    /// экран его догоняет, список не устаревает.
    private var countsAtBuild: [String: (known: Int?, fresh: Int)] = [:]
    private var shownCollectionID: String?
    /// Чей список собирается: ход и «Остановить» — только у этой коллекции,
    /// на соседней они выглядели бы её собственными.
    @Published private(set) var loadingCollectionID: String?
    private var task: Task<Void, Never>?

    func prepare(for collection: ChromaCollection) {
        guard shownCollectionID != collection.id else { return }
        shownCollectionID = collection.id
        list = lists[collection.id]
        query = ""
        copiedID = nil
        errorMessage = nil
    }

    /// Число записей на экране изменилось с тех пор, как список собрали, —
    /// то, что в нём, могло уйти.
    func isStale(_ collection: ChromaCollection) -> Bool {
        guard list != nil, let then = countsAtBuild[collection.id], let now = collection.documentCount else { return false }
        return now != then.fresh && now != (then.known ?? then.fresh)
    }

    func isLoading(_ collection: ChromaCollection) -> Bool {
        isRunning && loadingCollectionID == collection.id
    }

    func load(collection: ChromaCollection, app: AppEnvironment) {
        guard let client = app.client else {
            errorMessage = String(localized: "Нет подключения к ChromaDB.")
            return
        }
        guard !isRunning else { return }
        isRunning = true
        loadingCollectionID = collection.id
        errorMessage = nil
        progress = nil
        progressText = nil
        let knownCount = collection.documentCount
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Через общую очередь, как и обзор: обход видно на экране
                // «Задачи», и отменить его можно и оттуда.
                let built = try await app.queue.run(QueueTicket(
                    title: String(localized: "Файлы «\(collection.name)»"),
                    priority: .manual,
                    group: .database,
                    connectionID: app.connectionID
                )) { queueContext in
                    await app.queue.setCanceller(for: queueContext.id) { [weak self] in
                        Task { @MainActor in self?.cancel() }
                    }
                    return try await CollectionFiles.build(
                        reader: client, collectionID: collection.id,
                        progress: { done, total in
                            Task { @MainActor in
                                self.progress = total > 0 ? Double(done) / Double(total) : nil
                                self.progressText = String(localized: "прочитано \(done.plainDigits) из \(total.plainDigits)")
                            }
                            Task {
                                await queueContext.report(
                                    progress: total > 0 ? Double(done) / Double(total) : nil,
                                    detail: String(localized: "записей \(done.plainDigits)")
                                )
                            }
                        }
                    )
                }
                self.lists[collection.id] = built
                self.countsAtBuild[collection.id] = (knownCount, built.documentCount)
                if self.shownCollectionID == collection.id { self.list = built }
                self.finish()
            } catch let error where AppEnvironment.isCancellation(error) {
                self.finish()
            } catch {
                self.errorMessage = app.describe(error)
                self.finish()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        finish()
    }

    private func finish() {
        isRunning = false
        loadingCollectionID = nil
        progress = nil
        progressText = nil
    }

    /// Что видно сейчас: поиск, затем сортировка.
    var matching: [CollectionFile] {
        guard let list else { return [] }
        let found = list.files.filter { CollectionFiles.matches($0, query: query) }
        switch sort {
        case .path: return found
        case .name:
            return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .chunks: return found.sorted { $0.chunks > $1.chunks }
        case .modified: return found.sorted { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
        case .size: return found.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        }
    }

    // MARK: - Действия

    func copy(_ text: String, marking file: CollectionFile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedID = file.id
        let marked = file.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.copiedID == marked { self?.copiedID = nil }
        }
    }

    /// Показать файл в Finder. Где он лежит, выясняется по щелчку, а не при
    /// каждой перерисовке: меню строки строится вместе с ней, и двести строк
    /// списка — это двести проверок диска на каждую набранную букву поиска.
    func revealInFinder(_ file: CollectionFile, app: AppEnvironment) {
        let resolution = DocumentLocator.resolve(metadata: file.sample, sources: app.settings.configuration.dataSources)
        guard let url = resolution.url else {
            errorMessage = resolution.problem ?? String(localized: "Файл «\(file.name)» на диске не найден.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Метаданные для просмотрщика — файл целиком, с начала: место
    /// куска-образца (его страница, раздел) здесь ни при чём.
    static func wholeFileMetadata(_ file: CollectionFile) -> ChromaMetadata {
        var metadata = file.sample ?? [:]
        for key in ["page_number", "slide_number", "chapter_id", "spine_index", "sheet_name", "row_number", "heading_path"] {
            metadata.removeValue(forKey: key)
        }
        return metadata
    }

    func exportCSV(collection: ChromaCollection) {
        guard let list else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(collection.name)-files.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CollectionFiles.csv(list).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = String(localized: "Не удалось сохранить список: \(error.localizedDescription)")
        }
    }
}
