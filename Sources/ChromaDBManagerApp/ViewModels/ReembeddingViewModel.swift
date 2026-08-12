import Foundation
import SwiftUI
import ChromaCore

/// «Re-embedding»: pick a collection, a target model and/or chunking,
/// choose one of the two scenarios, confirm — and only then does anything happen.
@MainActor
final class ReembeddingViewModel: ObservableObject {
    /// The form being filled in. Cleared the moment the run starts: the backup
    /// stops and restarts the local server, and doing that under an open sheet
    /// leaves the window blank (verified on macOS 15). Progress belongs on the
    /// screen anyway — a long operation should not sit behind a modal.
    @Published var request: ReembeddingRequest?
    /// What is being run right now, for the progress card on the screen.
    @Published var runningRequest: ReembeddingRequest?
    @Published var isRunning = false
    @Published var isPaused = false
    /// One line for the queue panel: progress lives there now.
    static func progressLine(_ update: ReembeddingProgress) -> String {
        var line = "\(update.stage): обработано \(update.processed) из \(update.total), записано \(update.written)"
        if update.isPaused { line += " · пауза" }
        return line
    }

    @Published var report: ReembeddingReport?
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published var journal: [ReembeddingJournalEntry] = []
    /// An interrupted in-place run for the collection being set up, if any.
    @Published var resumable: ReembeddingCheckpoint?
    @Published var confirmationText = ""
    /// Vector size of the chosen model, probed as soon as it is chosen.
    @Published var targetDimension: Int?
    @Published var dimensionNote: String?

    private var task: Task<Void, Never>?

    /// Typing the collection name is the confirmation for the destructive
    /// scenario: it is the one operation here that overwrites existing vectors.
    var confirmationSatisfied: Bool {
        guard let request else { return false }
        guard request.scenario == .inPlace else { return true }
        return confirmationText.trimmingCharacters(in: .whitespaces) == request.collection.name
    }

    // MARK: - Setup

    func begin(collection: ChromaCollection, app: AppEnvironment) {
        var draft = ReembeddingRequest(
            collection: collection,
            targetModel: app.settings.configuration.defaultEmbeddingModel ?? collection.boundModel ?? "",
            scenario: .clone
        )
        draft.newCollectionName = ReembeddingRequest.suggestedName(for: collection, model: draft.targetModel)
        draft.chunking = ChunkingConfiguration()
        request = draft
        confirmationText = ""
        targetDimension = nil
        dimensionNote = nil
        report = nil
        errorMessage = nil
        infoMessage = nil

        Task { [weak self] in
            let checkpoint = await app.reembeddingService.checkpoint(for: collection.id)
            await MainActor.run { self?.resumable = checkpoint }
        }
        probeDimension(app)
    }

    func cancelSetup() {
        request = nil
        resumable = nil
        confirmationText = ""
    }

    func modelChanged(_ model: String, app: AppEnvironment) {
        guard var draft = request else { return }
        draft.targetModel = model
        draft.newCollectionName = ReembeddingRequest.suggestedName(for: draft.collection, model: model)
        request = draft
        probeDimension(app)
    }

    /// ChromaDB fixes a collection's vector size for good, so a model of another
    /// size can only go into a clone. Better to say that while the scenario is
    /// being chosen than after the backup has been made.
    private func probeDimension(_ app: AppEnvironment) {
        guard let draft = request, !draft.targetModel.isEmpty else {
            targetDimension = nil
            dimensionNote = nil
            return
        }
        let stored = draft.collection.effectiveDimension

        Task { [weak self] in
            do {
                let client = try app.makeLMStudioClient()
                let dimension = try await app.bindingService.dimension(of: draft.targetModel, lmStudio: client)
                await MainActor.run {
                    self?.targetDimension = dimension
                    guard let stored, stored != dimension else {
                        self?.dimensionNote = nil
                        return
                    }
                    self?.dimensionNote = "Коллекция хранит векторы размерности \(stored), а модель даёт \(dimension). ChromaDB фиксирует размерность коллекции навсегда, поэтому пересчёт на месте невозможен — доступно только клонирование."
                    // Silently leaving the impossible scenario selected would only
                    // let the user hit the wall a minute later.
                    self?.request?.scenario = .clone
                }
            } catch {
                await MainActor.run { self?.targetDimension = nil }
            }
        }
    }

    /// In-place is impossible when the dimensions differ (see `probeDimension`).
    var inPlaceAvailable: Bool {
        guard let stored = request?.collection.effectiveDimension, let target = targetDimension else { return true }
        return stored == target
    }

    func refreshJournal(_ app: AppEnvironment) {
        Task { [weak self] in
            let entries = await app.reembeddingService.journalEntries()
            await MainActor.run { self?.journal = entries }
        }
    }

    func discardCheckpoint(_ app: AppEnvironment) {
        guard let collectionID = request?.collection.id else { return }
        Task { [weak self] in
            await app.reembeddingService.discardCheckpoint(for: collectionID)
            await MainActor.run {
                self?.resumable = nil
                self?.infoMessage = "Незавершённый пересчёт забыт — следующий запуск начнётся с начала."
            }
        }
    }

    // MARK: - Running

    func start(_ app: AppEnvironment, collectionsModel: CollectionsViewModel, resume: Bool = false) {
        guard let request, !isRunning else { return }
        guard let chroma = app.client else {
            errorMessage = "Нет подключения к ChromaDB."
            return
        }
        if let problem = request.problem {
            errorMessage = problem
            return
        }

        isRunning = true
        isPaused = false
        errorMessage = nil
        infoMessage = nil
        report = nil
        // Close the sheet before touching the server (see `request`).
        runningRequest = request
        self.request = nil
        confirmationText = ""

        let ticket = QueueTicket(
            title: String(localized: "Пересчёт коллекции «\(request.collection.name)»"),
            priority: .manual,
            group: .lmStudio,
            connectionID: app.connectionID,
            resumable: ResumableRequest(
                kind: .reembedding,
                subject: request.collection.name,
                title: String(localized: "Пересчёт коллекции «\(request.collection.name)»")
            )
        )
        task = Task { [weak self] in
            // Одна ссылка на всю задачу вместо «weak self» в каждом вложенном
            // замыкании: перезахват внешней переменной из параллельно
            // исполняемого кода — это гонка (см. InspectorViewModel).
            guard let self else { return }
            do {
                // The backup comes first and is not optional: `run` cannot even be
                // called without the evidence it returns.
                let backup = try await self.makeBackup(request, app: app)
                guard let client = app.client else { throw ChromaError.notConfigured }

                let lmStudio = try app.makeLMStudioClient()
                let result = try await app.queue.run(ticket) { context in
                    // Отменялку очередь хранит у себя, и она может пережить
                    // саму задачу — поэтому здесь ссылка слабая.
                    await app.queue.setCanceller(for: context.id) { [weak self] in
                        Task { @MainActor in self?.cancel() }
                    }
                    return try await app.reembeddingService.run(
                        request,
                        backup: backup,
                        chroma: client,
                        embeddings: lmStudio,
                        chat: lmStudio,
                        binding: app.bindingService,
                        resumeFromCheckpoint: resume,
                        yield: { await context.yieldToHigherPriority() }
                    ) { update in
                        Task {
                            await context.report(
                                progress: update.fraction,
                                detail: Self.progressLine(update)
                            )
                        }
                        Task { @MainActor in self.isPaused = update.isPaused }
                    }
                }
                await MainActor.run {
                    self.report = result
                    self.resumable = nil
                    app.notify(result.notice)
                }
                await collectionsModel.refresh(app)
            } catch is CancellationError {
                // Сообщение называет то, что произошло с клоном, а не то, что
                // задумывалось: удаление могло и не пройти.
                let cleanup = await app.reembeddingService.lastCloneCleanup
                await MainActor.run {
                    if request.scenario == .clone {
                        self.infoMessage = cleanup?.message
                            ?? "Операция отменена: незавершённый клон удалён."
                    } else {
                        self.infoMessage = "Операция отменена: место остановки сохранено, пересчёт можно продолжить."
                    }
                }
                // Обновление списка — **вне** этой задачи. Она уже отменена,
                // а запрос из отменённого контекста отклоняется, не дойдя до
                // сервера: список оставался прежним, и удалённый клон
                // продолжал висеть на экране со своими 38 записями, пока
                // сообщение рядом говорило, что его удалили.
                await Task { await collectionsModel.refresh(app) }.value
            } catch {
                await MainActor.run {
                    self.errorMessage = app.describe(error)
                    app.notify(.failure(
                        kind: .reembedding,
                        subject: request.collection.name,
                        reason: app.describe(error)
                    ))
                }
                app.report(error, category: "Re-embedding")
            }
            await MainActor.run {
                self.isRunning = false
                self.isPaused = false
                self.runningRequest = nil
            }
            self.refreshJournal(app)
        }
        _ = chroma
    }

    /// Local database: stop the server, copy the folder, start it again.
    /// External server: export documents and metadata to JSON.
    private func makeBackup(_ request: ReembeddingRequest, app: AppEnvironment) async throws -> BackupEvidence {
        switch app.settings.configuration.mode {
        case .localDatabase:
            // Copying SQLite files under a running server produces a backup that
            // restores into a corrupt database, so the server goes down first.
            let path = app.localDatabaseURL
            app.log.record(.info, "Re-embedding", "Останавливаем локальный сервер, чтобы скопировать папку базы")
            await app.disconnect()
            do {
                let evidence = try app.backupService.backupLocalDatabase(
                    at: path,
                    note: "перед re-embedding коллекции \(request.collection.name) → \(request.targetModel)"
                )
                await app.connect()
                return evidence
            } catch {
                // The server must come back whether the copy worked or not.
                await app.connect()
                throw error
            }

        case .server:
            guard let chroma = app.client else { throw ChromaError.notConfigured }
            return try await app.backupService.exportCollection(
                request.collection,
                from: chroma,
                note: "перед re-embedding → \(request.targetModel)"
            )
        }
    }

    func pause(_ app: AppEnvironment) {
        Task { await app.reembeddingService.pause() }
    }

    func resumeRun(_ app: AppEnvironment) {
        Task { await app.reembeddingService.resume() }
    }

    func cancel() {
        task?.cancel()
    }
}
