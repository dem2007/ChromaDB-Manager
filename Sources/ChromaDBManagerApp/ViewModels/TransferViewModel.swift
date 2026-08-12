import Foundation
import SwiftUI
import ChromaCore

/// Перенос коллекции пакетом `.chromaexport`.
///
/// Отдельно от бэкапа (5.3) и от экспорта в JSON (8.7): бэкап копирует
/// директорию базы целиком и только для локального сервера, а этот перенос
/// умеет одну коллекцию — с другого сервера, на другой сервер, подмножеством
/// по фильтру.
@MainActor
final class TransferViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var stage: String?
    @Published var progress: Double?
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    // Экспорт
    @Published var includesEmbeddings = true
    @Published var usesCurrentFilter = false
    @Published var lastExport: CollectionExportManifest?

    // Импорт
    @Published var packageURL: URL?
    @Published var packageManifest: CollectionExportManifest?
    @Published var packageWarnings: [String] = []
    @Published var packageProblem: String?
    @Published var conflictPolicy: ImportConflictPolicy = .skip
    @Published var importsIntoNewCollection = true
    @Published var newCollectionName = ""
    @Published var resumeOffer: ImportCheckpoint?
    @Published var lastImport: ImportReport?

    private let checkpoints = ImportCheckpointStore()
    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        stage = nil
    }

    // MARK: - Экспорт

    func export(collection: ChromaCollection, filter: DocumentFilter?, app: AppEnvironment) {
        guard let client = app.client else {
            errorMessage = String(localized: "Нет подключения к ChromaDB.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(collection.name).chromaexport"
        panel.canCreateDirectories = true
        panel.message = String(localized: "Пакет — это папка: внутри манифест и файл документов по строке на документ.")
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isRunning = true
        errorMessage = nil
        statusMessage = nil
        let options = CollectionExporter.Options(
            includesEmbeddings: includesEmbeddings,
            filter: usesCurrentFilter ? filter : nil
        )
        // Версия сервера-источника уезжает в манифест: по ней потом видно,
        // откуда пакет.
        let serverVersion: String
        if case .connected(_, let version, _, _) = app.connection { serverVersion = version } else { serverVersion = "?" }
        let free = (try? destination.deletingLastPathComponent().resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage).flatMap { $0 }

        task = Task { [weak self] in
            // Одна ссылка на всю задачу вместо «weak self» в каждом вложенном
            // замыкании: перезахват внешней переменной из параллельно
            // исполняемого кода — это гонка (см. InspectorViewModel).
            guard let self else { return }
            do {
                let result = try await app.queue.run(QueueTicket(
                    title: String(localized: "Экспорт «\(collection.name)»"),
                    priority: .manual, group: .database, connectionID: app.connectionID
                )) { context in
                    await app.queue.setCanceller(for: context.id) { [weak self] in
                        Task { @MainActor in self?.cancel() }
                    }
                    return try await CollectionExporter(source: client, log: app.logHandler).export(
                        collection: collection,
                        to: destination,
                        serverVersion: serverVersion,
                        tenant: app.endpoint?.tenant ?? ChromaEndpoint.defaultTenant,
                        database: app.endpoint?.database ?? ChromaEndpoint.defaultDatabase,
                        options: options,
                        freeSpace: free,
                        progress: { update in
                            Task { @MainActor in
                                self.stage = String(localized: "Выгружено \(update.written.plainDigits) из \(update.total.plainDigits)")
                                self.progress = update.total > 0 ? Double(update.written) / Double(update.total) : nil
                            }
                            Task {
                                await context.report(
                                    progress: update.total > 0 ? Double(update.written) / Double(update.total) : nil,
                                    detail: String(localized: "документов \(update.written.plainDigits)")
                                )
                            }
                        }
                    )
                }
                await MainActor.run {
                    self.lastExport = result.manifest
                    let size = ByteCountFormatter.string(fromByteCount: Int64(result.manifest.dataBytes), countStyle: .file)
                    self.statusMessage = String(localized: "Выгружено документов: \(result.manifest.documentCount.plainDigits), \(size). Контрольная сумма записана в манифест.")
                    self.isRunning = false
                    self.stage = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.statusMessage = String(localized: "Экспорт отменён — недописанный пакет удалён.")
                    self.isRunning = false
                    self.stage = nil
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = app.describe(error)
                    self.isRunning = false
                    self.stage = nil
                }
            }
        }
    }

    // MARK: - Импорт

    /// Читает манифест выбранного пакета и проверяет его против цели —
    /// **до** того, как что-то будет записано.
    func choosePackage(target: ChromaCollection?, app: AppEnvironment) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        // Файлы тоже: пакет — обычная папка, и в неё легко зайти двойным
        // щелчком. Оказавшись внутри, человек видит `manifest.json` и не
        // может выбрать ничего — выбирать-то нечего. Пусть выбирает манифест,
        // а пакетом будет его папка.
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Выберите папку .chromaexport (или manifest.json внутри неё)")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        let isDirectory = (try? chosen.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let url = isDirectory ? chosen : chosen.deletingLastPathComponent()

        packageURL = url
        packageWarnings = []
        packageProblem = nil
        resumeOffer = nil
        lastImport = nil
        do {
            let manifest = try CollectionImporter.readManifest(at: url)
            packageManifest = manifest
            newCollectionName = manifest.collectionName
            packageWarnings = try CollectionImporter.problems(
                manifest: manifest, target: importsIntoNewCollection ? nil : target
            )
            resumeOffer = checkpoints.load(checksum: manifest.dataSHA256)
        } catch {
            packageManifest = nil
            packageProblem = app.describe(error)
        }
    }

    func revalidate(target: ChromaCollection?, app: AppEnvironment) {
        guard let manifest = packageManifest else { return }
        do {
            packageWarnings = try CollectionImporter.problems(
                manifest: manifest, target: importsIntoNewCollection ? nil : target
            )
            packageProblem = nil
        } catch {
            packageWarnings = []
            packageProblem = app.describe(error)
        }
    }

    func runImport(target: ChromaCollection?, app: AppEnvironment) {
        guard let client = app.client, let manifest = packageManifest, let package = packageURL else { return }
        guard packageProblem == nil else { return }

        isRunning = true
        errorMessage = nil
        statusMessage = nil
        let policy = conflictPolicy
        let intoNew = importsIntoNewCollection
        let name = intoNew ? CollectionNaming.sanitize(newCollectionName) : (target?.name ?? "")
        let model = app.settings.configuration.defaultEmbeddingModel

        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Сумма сверяется до первой записи: испорченный при переносе
                // пакет не должен попасть в базу наполовину.
                try CollectionImporter.verifyChecksum(at: package, manifest: manifest)

                let collectionID: String
                if intoNew {
                    let created = try await client.createCollection(
                        name: name,
                        metadata: manifest.collectionMetadata,
                        configuration: CollectionConfiguration(
                            metric: DistanceMetric(rawValue: manifest.metric ?? "cosine") ?? .cosine
                        ),
                        getOrCreate: true
                    )
                    collectionID = created.id
                } else {
                    guard let target else { throw TransferError.notAPackage(package.lastPathComponent) }
                    collectionID = target.id
                }

                let lmStudio = try? app.makeLMStudioClient()
                let report = try await app.queue.run(QueueTicket(
                    title: String(localized: "Импорт в «\(name)»"),
                    priority: .manual,
                    // Векторы могут считаться заново — тогда это работа модели,
                    // и очередь обязана знать об этом заранее.
                    group: manifest.includesEmbeddings ? .database : .lmStudio,
                    connectionID: app.connectionID
                )) { context in
                    await app.queue.setCanceller(for: context.id) { [weak self] in
                        Task { @MainActor in self?.cancel() }
                    }
                    return try await CollectionImporter(
                        destination: client, embeddings: lmStudio, log: app.logHandler
                    ).import(
                        package: package, manifest: manifest,
                        into: collectionID, collectionName: name,
                        options: .init(
                            conflictPolicy: policy,
                            resumesFromCheckpoint: true,
                            embeddingModel: manifest.includesEmbeddings ? nil : model
                        ),
                        progress: { update in
                            Task { @MainActor in
                                self.stage = String(localized: "Загружено \(update.processed.plainDigits) из \(update.total.plainDigits)")
                                self.progress = update.total > 0 ? Double(update.processed) / Double(update.total) : nil
                            }
                            Task { await context.report(progress: update.total > 0 ? Double(update.processed) / Double(update.total) : nil, detail: nil) }
                        }
                    )
                }
                await MainActor.run {
                    self.lastImport = report
                    self.statusMessage = report.finished
                        ? String(localized: "Импорт завершён: \(report.line).")
                        : String(localized: "Импорт остановлен: \(report.line). Запустите ещё раз — он продолжится с этого места.")
                    self.isRunning = false
                    self.stage = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.statusMessage = String(localized: "Импорт прерван. Запустите ещё раз — он продолжится с места остановки.")
                    self.isRunning = false
                    self.stage = nil
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = app.describe(error)
                    self.isRunning = false
                    self.stage = nil
                }
            }
        }
    }
}
