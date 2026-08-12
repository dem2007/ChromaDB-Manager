import Foundation
import SwiftUI
import ChromaCore

/// «Тестовый стенд»: try an embedding, preview chunking, compare
/// models and measure how close two texts are — all without writing anything to
/// the database.
@MainActor
final class TestBenchViewModel: ObservableObject {
    // Embedding probe
    @Published var probeText = "Договор оказания услуг вступает в силу с момента подписания."
    @Published var probeResult: EmbeddingProbe?

    // Chunking preview
    @Published var previewText = ""
    @Published var previewFileName: String?
    /// Everything the extractor said about the loaded file — kept whole
    /// rather than reduced to its text, because the text alone is exactly what
    /// makes extraction quality impossible to debug.
    @Published var previewDocument: ExtractedDocument?
    /// Whose settings the preview reads the file with. A preview taken with
    /// default options would report «нет текстового слоя» for a scan the user's
    /// source recognises perfectly well.
    @Published var previewSourceID: UUID?
    /// Where each previewed chunk landed in the document.
    @Published var previewPlacements: [Int: ChunkPlacement] = [:]
    /// Why the chosen file produced nothing, and what is worth doing about it.
    @Published var previewFailure: (reason: String, remedy: FileRemedy)?
    @Published var configuration = ChunkingConfiguration()
    @Published var previewChunks: [TextChunk] = []
    /// Context of the model the preview is measured against, when known.
    /// Chunks past it are highlighted **before** a sync is started.
    @Published var previewContextLimit: Int?

    func exceedsContext(_ chunk: TextChunk) -> Bool {
        ContextBudget.check(chunk.text, contextLength: previewContextLimit).blocksSending
    }

    var oversizedChunkCount: Int {
        previewChunks.filter(exceedsContext).count
    }
    @Published var previewDuration: TimeInterval?

    // Model comparison
    @Published var comparisonModels: Set<String> = []
    @Published var comparison: [ModelMeasurement] = []

    // Similarity
    @Published var firstText = "Как расторгнуть договор?"
    @Published var secondText = "Порядок прекращения договора."
    @Published var similarity: Double?

    @Published var isBusy = false
    @Published var errorMessage: String?

    struct EmbeddingProbe {
        let model: String
        let dimension: Int
        let duration: TimeInterval
        let head: [Double]
    }

    struct ModelMeasurement: Identifiable {
        var id: String { model }
        let model: String
        let dimension: Int?
        let duration: TimeInterval?
        let error: String?
    }

    // MARK: - Embedding probe

    func probe(_ app: AppEnvironment) async {
        guard let model = app.settings.configuration.defaultEmbeddingModel else {
            errorMessage = "Не выбрана модель по умолчанию — выберите её в списке моделей выше."
            return
        }
        let text = probeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isBusy = true
        errorMessage = nil
        probeResult = nil
        defer { isBusy = false }

        do {
            let client = try app.makeLMStudioClient()
            let started = Date()
            // Interactive: the bench is the user asking, so it goes in front of
            // background work — but still through the queue.
            let vector = try await app.queue.run(QueueTicket(
                title: String(localized: "Тестовый эмбеддинг"),
                priority: .interactive,
                group: .lmStudio,
                connectionID: app.connectionID
            )) { _ in
                try await client.embed(text: text, model: model)
            }
            probeResult = EmbeddingProbe(
                model: model,
                dimension: vector.count,
                duration: Date().timeIntervalSince(started),
                head: Array(vector.prefix(12))
            )
        } catch {
            errorMessage = app.describe(error)
        }
    }

    // MARK: - Chunking preview

    func loadFileForPreview(_ app: AppEnvironment) {
        guard let url = ConnectionViewModel.chooseFile(
            title: "Файл для предпросмотра извлечения",
            message: "Файл только читается: ничего не индексируется и не записывается."
        ) else { return }

        Task {
            isBusy = true
            defer { isBusy = false }
            previewDocument = nil
            previewFailure = nil
            previewChunks = []
            previewPlacements = [:]
            previewFileName = url.lastPathComponent

            // The options of the source the user picked, so the preview and the
            // sync see the same file. `nil` means «настройки по умолчанию».
            let source = previewSource(app)
            var options = source.map {
                SourceSyncService.extractionOptions(for: $0, password: nil)
            } ?? ExtractionOptions()
            options.maxFileSize = TextExtractor.maxFileSize
            if let source, let relative = Self.relativePath(of: url, in: source) {
                options.password = app.documentPasswords.password(sourceID: source.id, relativePath: relative)
            }

            do {
                previewDocument = try await ExtractorRegistry.standard(log: app.logHandler)
                    .extract(from: url, options: options)
                previewText = previewDocument?.plainText ?? ""
            } catch {
                previewText = ""
                previewFailure = (SourceSyncService.reason(for: error), FileProblem.remedy(for: error))
            }
        }
    }

    func previewSource(_ app: AppEnvironment) -> DataSource? {
        guard let previewSourceID else { return nil }
        return app.settings.configuration.dataSources.first { $0.id == previewSourceID }
    }

    /// The file's path inside the source, when it is inside it at all — the
    /// preview is allowed to open any file, not only ones the source covers.
    static func relativePath(of url: URL, in source: DataSource) -> String? {
        let root = source.url.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    /// Runs the same pipeline a real sync would run, so the preview cannot
    /// disagree with what ends up in the collection.
    func preview(_ app: AppEnvironment) async {
        let text = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let problem = configuration.problem {
            errorMessage = problem
            return
        }

        isBusy = true
        errorMessage = nil
        previewChunks = []
        previewPlacements = [:]
        previewDuration = nil
        defer { isBusy = false }

        do {
            let client = try app.makeLMStudioClient()
            let pipeline = ChunkingPipeline(
                configuration: configuration,
                embeddings: client,
                chat: client,
                embeddingModel: app.settings.configuration.defaultEmbeddingModel,
                log: app.logHandler
            )
            // Recognised text falls back to Recursive with the user's own sizes,
            // exactly as it does during a sync.
            let ocrPipeline = ChunkingPipeline(
                configuration: SourceSyncService.recursiveEquivalent(of: configuration),
                embeddings: client,
                chat: client,
                embeddingModel: app.settings.configuration.defaultEmbeddingModel,
                log: app.logHandler
            )
            let started = Date()
            let extension_ = previewFileName.map { ($0 as NSString).pathExtension }
            // Edited by hand in the field, so it is no longer that document: the
            // offsets, pages and slides of the extraction no longer describe it.
            let document = previewDocument?.plainText == previewText ? previewDocument : nil
            previewChunks = try await app.queue.run(QueueTicket(
                title: String(localized: "Предпросмотр чанков"),
                priority: .interactive,
                group: .lmStudio,
                connectionID: app.connectionID
            )) { _ in
                // A file goes through the sync's own rule — slides stay slides,
                // а структурная стратегия без структуры уступает Recursive.
                // Text typed into the field has no extraction behind it, so it
                // goes through the strategy plain.
                if let document {
                    return try await SourceSyncService.plannedChunks(
                        of: document, fileExtension: extension_,
                        pipeline: pipeline, ocrPipeline: ocrPipeline,
                        configuration: configuration
                    )
                }
                return try await pipeline.chunks(from: text, fileExtension: extension_)
            }
            previewDuration = Date().timeIntervalSince(started)
            if let document {
                previewPlacements = ChunkLocator.placements(of: previewChunks, in: document)
            }
            if let model = app.settings.configuration.defaultEmbeddingModel {
                previewContextLimit = await app.bindingService.contextLength(of: model, lmStudio: client)
            }
        } catch {
            errorMessage = app.describe(error)
        }
    }

    /// What a chunk's placement will look like in its metadata.
    func placementText(_ placement: ChunkPlacement) -> String {
        var parts: [String] = []
        if let page = placement.pageNumber { parts.append(String(localized: "с. \(page)")) }
        switch placement.part?.kind {
        case .slide: parts.append(String(localized: "слайд \(( placement.part?.index ?? 0) + 1)"))
        case .spine: parts.append(String(localized: "часть \((placement.part?.index ?? 0) + 1)"))
        case nil: break
        }
        if let path = placement.headingPath { parts.append(path) }
        return parts.joined(separator: " · ")
    }

    var previewStats: String? {
        guard !previewChunks.isEmpty else { return nil }
        let sizes = previewChunks.map(\.text.count)
        let average = sizes.reduce(0, +) / sizes.count
        let parents = previewChunks.filter { $0.level > 0 }.count
        var text = "чанков: \(previewChunks.count) · символов в среднем \(average) (от \(sizes.min() ?? 0) до \(sizes.max() ?? 0))"
        if parents > 0 { text += " · родительских \(parents), дочерних \(previewChunks.count - parents)" }
        if let duration = previewDuration { text += " · чанкинг занял \(String(format: "%.2f", duration)) с" }
        return text
    }

    // MARK: - Model comparison

    func compare(_ app: AppEnvironment) async {
        let text = probeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !comparisonModels.isEmpty else { return }

        isBusy = true
        errorMessage = nil
        comparison = []
        defer { isBusy = false }

        for model in comparisonModels.sorted() {
            do {
                let client = try app.makeLMStudioClient()
                let started = Date()
                let vector = try await app.queue.run(QueueTicket(
                    title: String(localized: "Сравнение моделей: \(model)"),
                    priority: .interactive,
                    group: .lmStudio,
                    connectionID: app.connectionID
                )) { _ in
                    try await client.embed(text: text, model: model)
                }
                comparison.append(ModelMeasurement(
                    model: model,
                    dimension: vector.count,
                    duration: Date().timeIntervalSince(started),
                    error: nil
                ))
            } catch {
                comparison.append(ModelMeasurement(
                    model: model,
                    dimension: nil,
                    duration: nil,
                    error: app.describe(error)
                ))
            }
        }
    }

    // MARK: - Similarity

    func measureSimilarity(_ app: AppEnvironment) async {
        guard let model = app.settings.configuration.defaultEmbeddingModel else {
            errorMessage = "Не выбрана модель по умолчанию."
            return
        }
        let first = firstText.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = secondText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty, !second.isEmpty else { return }

        isBusy = true
        errorMessage = nil
        similarity = nil
        defer { isBusy = false }

        do {
            let client = try app.makeLMStudioClient()
            let vectors = try await app.queue.run(QueueTicket(
                title: String(localized: "Схожесть двух текстов"),
                priority: .interactive,
                group: .lmStudio,
                connectionID: app.connectionID
            )) { _ in
                try await client.embed(texts: [first, second], model: model)
            }
            guard vectors.count == 2 else { throw LMStudioError.emptyResponse }
            similarity = VectorMath.cosineSimilarity(vectors[0], vectors[1])
        } catch {
            errorMessage = app.describe(error)
        }
    }
}
