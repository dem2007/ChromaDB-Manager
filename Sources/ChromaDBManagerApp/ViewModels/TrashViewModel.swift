import Foundation
import ChromaCore

/// «Корзина»: documents and collections deleted from the UI, kept locally
/// so a manual delete is reversible without a re-embed.
@MainActor
final class TrashViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var collectionFilter: String?
    @Published var selectedIDs: Set<UUID> = []
    @Published var isRestoring = false
    @Published var showEmptyConfirmation = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    func entries(_ app: AppEnvironment) -> [TrashEntry] {
        app.trash.entries.filter { entry in
            (collectionFilter == nil || entry.collectionName == collectionFilter)
                && (searchText.isEmpty
                    || entry.documentID.localizedCaseInsensitiveContains(searchText)
                    || (entry.document ?? "").localizedCaseInsensitiveContains(searchText))
        }
    }

    func toggle(_ entry: TrashEntry) {
        if selectedIDs.contains(entry.id) {
            selectedIDs.remove(entry.id)
        } else {
            selectedIDs.insert(entry.id)
        }
    }

    // MARK: - Restore

    func restoreSelected(_ app: AppEnvironment) async {
        await restore(app.trash.entries(withIDs: selectedIDs), app: app)
        selectedIDs.removeAll()
    }

    func restoreAll(_ app: AppEnvironment) async {
        await restore(entries(app), app: app)
        selectedIDs.removeAll()
    }

    /// Recreates a deleted collection's binding (model + dimension + metric)
    /// before restoring into it, since none of that survives on the server
    /// once the collection itself is gone — grouped by collection because
    /// creating (or just resolving) it once per group is enough.
    private func restore(_ entries: [TrashEntry], app: AppEnvironment) async {
        guard let client = app.client, !entries.isEmpty else { return }
        isRestoring = true
        errorMessage = nil
        defer { isRestoring = false }

        var restoredIDs: Set<UUID> = []
        var skipped = 0
        var restoredCount = 0
        let byCollection = Dictionary(grouping: entries, by: \.collectionName)

        for (collectionName, group) in byCollection {
            let restorable = group.filter { $0.document != nil && $0.embedding != nil }
            skipped += group.count - restorable.count
            guard !restorable.isEmpty else { continue }

            do {
                let collectionID = try await resolveOrRecreate(
                    named: collectionName,
                    model: restorable.first?.collectionModel,
                    dimension: restorable.first?.collectionDimension,
                    metric: restorable.first?.collectionMetric,
                    client: client
                )
                let records = restorable.map { entry in
                    EmbeddedRecord(
                        id: entry.documentID,
                        document: entry.document!,
                        embedding: entry.embedding!,
                        metadata: entry.metadata ?? [:]
                    )
                }
                try await client.upsert(collectionID: collectionID, records: records)
                restoredIDs.formUnion(restorable.map(\.id))
                restoredCount += restorable.count
            } catch {
                errorMessage = app.describe(error)
                app.report(error, category: "Корзина")
            }
        }

        if !restoredIDs.isEmpty {
            app.trash.forget(ids: restoredIDs)
            app.log.record(.success, "Корзина", "Восстановлено документов: \(restoredCount.plainDigits)")
        }
        if skipped > 0 {
            app.log.record(.warning, "Корзина", "Пропущено при восстановлении (нет текста или вектора): \(skipped.plainDigits)")
        }
        statusMessage = restoredCount > 0
            ? String(localized: "Восстановлено документов: \(restoredCount.plainDigits).")
            : nil
    }

    private func resolveOrRecreate(
        named name: String,
        model: String?,
        dimension: Int?,
        metric: DistanceMetric?,
        client: ChromaClient
    ) async throws -> String {
        if let existing = try? await client.collection(named: name) {
            return existing.id
        }
        var metadata: ChromaMetadata = [:]
        if let model, let dimension {
            metadata[CollectionBindingKeys.model] = .string(model)
            metadata[CollectionBindingKeys.dimension] = .int(dimension)
        }
        let configuration = CollectionConfiguration(metric: metric ?? .cosine)
        let created = try await client.createCollection(
            name: name,
            metadata: metadata,
            configuration: configuration,
            getOrCreate: true
        )
        return created.id
    }

    // MARK: - Empty

    func emptyTrash(_ app: AppEnvironment) {
        app.trash.emptyTrash()
        selectedIDs.removeAll()
        showEmptyConfirmation = false
    }

    // MARK: - Settings

    func setTrashEnabled(_ enabled: Bool, app: AppEnvironment) {
        app.settings.configuration.trashEnabled = enabled
    }

    func applyRetention(days: Int, app: AppEnvironment) {
        app.settings.configuration.trashRetentionDays = days
        app.trash.updateRetention(days: days, limitBytes: app.settings.configuration.trashLimitBytes)
    }

    func applyLimit(gigabytes: Double, app: AppEnvironment) {
        let bytes = Int64(gigabytes * 1_073_741_824)
        app.settings.configuration.trashLimitBytes = bytes
        app.trash.updateRetention(days: app.settings.configuration.trashRetentionDays, limitBytes: bytes)
    }
}
