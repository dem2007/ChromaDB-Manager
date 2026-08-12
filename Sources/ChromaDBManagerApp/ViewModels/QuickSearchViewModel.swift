import Foundation
import SwiftUI
import ChromaCore

/// Быстрый поиск из строки меню.
///
/// Ищет тем же конвейером, что экран коллекций: настройки профиля,
/// умный поиск и очередь моделей действуют одинаково — иначе «в меню нашлось,
/// а в окне нет» стало бы обычным делом.
@MainActor
final class QuickSearchViewModel: ObservableObject {
    @Published var text: String = ""
    @Published private(set) var hits: [RetrievalHit] = []
    @Published private(set) var isSearching = false
    @Published private(set) var problem: String?
    /// Что искали в последний раз — чтобы не гонять модель на тот же текст.
    private var lastSearched: String?

    /// Коллекции, доступные для быстрого поиска.
    @Published private(set) var collections: [ChromaCollection] = []

    func reloadCollections(_ app: AppEnvironment) async {
        // Неудачный запрос не стирает список: «не смогли спросить» — это
        // не «коллекций нет». Со стиранием выбранная коллекция пропадала
        // из списка выбора, и он оказывался пустым — проверено в окне.
        guard let client = app.client,
              let loaded = try? await client.listCollections()
        else { return }
        collections = loaded
    }

    /// Выбранная коллекция или `nil`, если её нет.
    ///
    /// Коллекция могла быть удалена после того, как её выбрали, — тогда
    /// поиск честно просит выбрать другую, а не ищет в первой попавшейся.
    func collection(_ app: AppEnvironment) -> ChromaCollection? {
        guard let name = app.settings.configuration.menuBar.quickSearchCollection else { return nil }
        return collections.first { $0.name == name }
    }

    func choose(_ name: String?, app: AppEnvironment) {
        app.settings.configuration.menuBar.quickSearchCollection = name
        clear()
    }

    func clear() {
        hits = []
        problem = nil
        lastSearched = nil
    }

    func search(_ app: AppEnvironment) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clear()
            return
        }
        guard query != lastSearched || hits.isEmpty else { return }
        guard let collection = collection(app) else {
            problem = String(localized: "Выберите коллекцию для быстрого поиска.")
            return
        }

        isSearching = true
        problem = nil
        defer { isSearching = false }

        do {
            let prepared = try await app.prepareSearch(for: collection)
            let outcome = try await prepared.pipeline.run(
                RetrievalRequest(
                    text: query,
                    collectionID: collection.id,
                    collectionName: collection.name,
                    nResults: app.settings.configuration.menuBar.quickSearchResultCount,
                    filter: nil,
                    metric: collection.space
                ),
                profile: prepared.profile
            )
            // Векторы нужны были конвейеру для MMR и на экране не нужны.
            hits = outcome.hits.map { hit in
                var stripped = hit
                stripped.embedding = nil
                return stripped
            }
            lastSearched = query
            if hits.isEmpty {
                problem = String(localized: "Ничего не найдено.")
            }
            // В историю поиска это тоже попадает: E6 не делает разницы между
            // тем, откуда запрос пришёл, и «в набор» из меню работать обязано.
            app.queryHistory.record(QueryHistoryEntry(
                text: query,
                collectionName: collection.name,
                profileName: prepared.profile.name,
                profileID: prepared.profile.id,
                filter: nil,
                resultCount: hits.count,
                duration: outcome.diagnostics.totalDuration
            ))
        } catch {
            hits = []
            problem = app.describe(error)
            app.report(error, category: "Быстрый поиск")
        }
    }
}
