import Foundation

/// Runs a set of queries against a set of variants.
///
/// The two properties the stage stands on are built in here rather than left to
/// the caller:
///
/// * **One vector per (query, model).** A comparison of four chunking strategies
///   on one model is four variants and one embedding call per query, not four.
///   Left to the pipeline, each variant would embed the same words again.
/// * **Cancellation keeps what it has.** A run is minutes long; stopping it must
///   leave the answers already collected, marked as an incomplete run, because
///   half a comparison is still worth reading and re-running is expensive.
public actor EvaluationRunner {
    /// Text and model in, vector out — the app supplies the queue, the binding
    /// check and LM Studio, as everywhere else in the core.
    public typealias Embedder = @Sendable (_ text: String, _ model: String) async throws -> [Double]
    /// One search of one variant. The vector is passed in already computed —
    /// that is where the deduplication lives — and is `nil` for a variant that
    /// needs none.
    public typealias Searcher = @Sendable (
        _ variant: EvaluationVariant, _ query: EvaluationQuery, _ vector: [Double]?
    ) async throws -> RetrievalOutcome

    public struct Progress: Sendable {
        public let done: Int
        public let total: Int
        public let queryText: String
        public let variantName: String

        public var line: String {
            String(localized: "\(done) из \(total): «\(queryText)» — \(variantName)")
        }
    }

    private let embed: Embedder
    private let search: Searcher
    private let log: LogHandler

    public init(
        embed: @escaping Embedder,
        search: @escaping Searcher,
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.embed = embed
        self.search = search
        self.log = log
    }

    /// How many embedding calls this runner actually made — what the test of
    /// 7 counts, and what the app reports beside the estimate.
    public private(set) var embeddingCallCount = 0

    public func run(
        set: QuerySet,
        variants: [EvaluationVariant],
        name: String = "",
        appVersion: String = "dev",
        progress: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async -> EvaluationRun {
        var run = EvaluationRun(
            name: name.isEmpty ? String(localized: "Прогон \(Date().formatted(date: .abbreviated, time: .shortened))") : name,
            querySetID: set.id,
            querySetName: set.name,
            queries: set.queries,
            variants: variants,
            appVersion: appVersion
        )
        embeddingCallCount = 0

        // One vector per (query text, model), for the whole run. Two queries
        // that happen to be the same words share it too — the model would
        // return the same numbers, and paying twice for them is pure loss.
        var vectors: [VectorKey: [Double]] = [:]
        var cancelled = false
        let total = set.queries.count * variants.count
        var done = 0

        queries: for query in set.queries {
            // Query outer, variant inner: the vector is computed once and used
            // immediately by every variant that needs it, so a cancellation
            // leaves whole queries finished rather than a ragged edge.
            for variant in variants {
                if Task.isCancelled { cancelled = true; break queries }
                progress(Progress(
                    done: done, total: total,
                    queryText: query.text, variantName: variant.name
                ))
                done += 1

                var vector: [Double]?
                var embeddingSeconds: TimeInterval?
                var reused = false

                if variant.needsVector {
                    // Приставка входит в ключ, а не только в вызов:
                    // иначе вариант «с приставкой» достал бы из запаса вектор,
                    // посчитанный без неё, и сравнивал бы приставку саму с собой.
                    let asked = variant.profile.embeddedQuery(query.text)
                    let key = VectorKey(text: asked, model: variant.model)
                    if let cached = vectors[key] {
                        vector = cached
                        reused = true
                    } else {
                        let started = Date()
                        do {
                            let computed = try await embed(asked, variant.model)
                            vectors[key] = computed
                            vector = computed
                            embeddingSeconds = Date().timeIntervalSince(started)
                            embeddingCallCount += 1
                        } catch is CancellationError {
                            cancelled = true
                            break queries
                        } catch {
                            run.results.append(EvaluationResult(
                                queryID: query.id, variantID: variant.id,
                                failure: String(localized: "вектор запроса не посчитан: \(error.localizedDescription)")
                            ))
                            continue
                        }
                    }
                }

                let searchStarted = Date()
                do {
                    let outcome = try await search(variant, query, vector)
                    run.results.append(EvaluationResult(
                        queryID: query.id, variantID: variant.id,
                        hits: Self.hits(from: outcome),
                        embeddingSeconds: embeddingSeconds,
                        reusedVector: reused,
                        searchSeconds: Date().timeIntervalSince(searchStarted)
                    ))
                } catch is CancellationError {
                    cancelled = true
                    break queries
                } catch {
                    run.results.append(EvaluationResult(
                        queryID: query.id, variantID: variant.id,
                        embeddingSeconds: embeddingSeconds,
                        reusedVector: reused,
                        searchSeconds: Date().timeIntervalSince(searchStarted),
                        failure: error.localizedDescription
                    ))
                }
            }
        }

        run.finishedAt = Date()
        let failed = run.failedCells
        run.isComplete = !cancelled && run.results.count == total && failed == 0
        if cancelled {
            run.note = String(localized: "Прогон отменён: выполнено \(run.results.count) из \(total). Полученные результаты сохранены.")
        } else if failed > 0 {
            run.note = String(localized: "Не выполнено запросов: \(failed) из \(total) — эти ячейки не считаются пустой выдачей.")
        }
        log(
            cancelled || failed > 0 ? .warning : .info,
            "Оценка",
            "Прогон «\(run.name)»: \(run.results.count) из \(total), вызовов эмбеддинга \(embeddingCallCount)"
        )
        return run
    }

    /// What of the outcome becomes a stored result.
    ///
    /// Only the rows the query actually matched. Context attached by the
    /// pipeline (a parent section, a neighbouring chunk) is text the user reads,
    /// never a result the search returned — counting it would give a variant
    /// with context switched on a longer list to be scored on.
    static func hits(from outcome: RetrievalOutcome) -> [EvaluationHit] {
        outcome.hits
            .filter { $0.role == .match }
            .enumerated()
            .map { position, hit in
                EvaluationHit(
                    id: hit.id, text: hit.document, distance: hit.distance,
                    position: position + 1, metadata: hit.metadata
                )
            }
    }

    private struct VectorKey: Hashable {
        let text: String
        let model: String

        init(text: String, model: String) {
            // Trimmed, because «запрос » and «запрос» are the same words to the
            // model and the same query to the user.
            self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.model = model
        }
    }
}
