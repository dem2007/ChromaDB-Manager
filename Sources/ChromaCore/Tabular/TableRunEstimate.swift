import Foundation

/// What a run over a sheet will cost, before it starts.
///
/// 7 is unusually blunt about this: starting on a big sheet without the
/// warning is «дефект, а не мелочь». Fifty thousand rows is fifty thousand calls
/// to a local model — hours during which nothing else can use it — and the user
/// finds out only when the machine is already busy.
public struct TableRunEstimate: Hashable, Sendable {
    /// Rows that will be sent to the model.
    public let embeddings: Int
    /// Rows that will be written without being embedded (metadata only).
    public let metadataWrites: Int
    /// `nil` when nothing has been measured yet — never a guess.
    public let seconds: Double?
    /// Where the speed came from, so the number can be judged.
    public let basis: Basis

    public enum Basis: String, Hashable, Sendable {
        /// Measured on this user's own texts, on this machine.
        case measuredWork
        /// The controlled benchmark — what makes an estimate possible before the
        /// first run at all.
        case benchmark
        case unknown

        public var title: String {
            switch self {
            case .measuredWork: return String(localized: "по фактической скорости на ваших текстах")
            case .benchmark: return String(localized: "по замеру скорости модели")
            case .unknown: return String(localized: "скорость модели ещё не измерялась")
            }
        }
    }

    public init(embeddings: Int, metadataWrites: Int, seconds: Double?, basis: Basis) {
        self.embeddings = embeddings
        self.metadataWrites = metadataWrites
        self.seconds = seconds
        self.basis = basis
    }

    /// Above this many rows the warning is not optional (Definition of Done,
    /// этап 5).
    public static let warningThreshold = 5_000

    public var needsConfirmation: Bool { embeddings > Self.warningThreshold }

    public var durationText: String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds < 90 { return String(localized: "около \(Int(seconds.rounded())) с") }
        if seconds < 5_400 { return String(localized: "около \(Int((seconds / 60).rounded())) мин") }
        let hours = seconds / 3_600
        return String(localized: "около \(String(format: "%.1f", hours)) ч")
    }

    public var line: String {
        var parts = [String(localized: "строк к эмбеддингу: \(embeddings)")]
        if metadataWrites > 0 {
            parts.append(String(localized: "обновить метаданные без пересчёта: \(metadataWrites)"))
        }
        if let durationText {
            parts.append(String(localized: "\(durationText) — \(basis.title)"))
        } else {
            parts.append(basis.title)
        }
        return parts.joined(separator: " · ")
    }
}

extension SheetSyncPlan {
    /// The cost of this plan, from what has actually been measured.
    ///
    /// The same two sources as J2's estimate and in the same order: real work
    /// beats the benchmark, because the benchmark's corpus is representative
    /// while the user's own texts are the truth. Neither available means `nil`
    /// seconds — a made-up number is worse than «неизвестно», because it will be
    /// believed.
    public func estimate(
        embeddingModel: String,
        metrics: MetricsSnapshot,
        benchmarks: [ModelBenchmark] = []
    ) -> TableRunEstimate {
        var secondsPerText: Double?
        var basis = TableRunEstimate.Basis.unknown

        if let measured = metrics.models.first(where: { $0.model == embeddingModel }), measured.averageSeconds > 0 {
            secondsPerText = measured.averageSeconds
            basis = .measuredWork
        } else if let benchmark = benchmarks.first(where: { $0.model == embeddingModel }), benchmark.secondsPerText > 0 {
            secondsPerText = benchmark.secondsPerText
            basis = .benchmark
        }

        return TableRunEstimate(
            embeddings: embeddings,
            metadataWrites: metadataOnly.count,
            seconds: secondsPerText.map { $0 * Double(embeddings) },
            basis: basis
        )
    }

    /// The plan cut down to the first `count` rows of the sheet.
    ///
    /// «Попробовать на выборке» has to mean the *first* rows rather than an
    /// arbitrary subset: the user is checking whether the template and the
    /// column roles produce sensible documents, and they can only judge that
    /// against rows they can find in the file.
    public func limitedToFirstRows(_ count: Int) -> SheetSyncPlan {
        guard count > 0 else { return SheetSyncPlan() }

        func number(_ document: TableRowDocument) -> Int {
            if case .int(let value)? = document.metadata["row_number"] { return value }
            return .max
        }
        // The cut is by row number, so «первые 200 строк» means the first two
        // hundred of the sheet — not the first two hundred of whatever the plan
        // happened to put in front.
        let ordered = (added.map { ($0, nil as String?) }
            + reembedded.map { ($0.document, $0.previousID) }
            + metadataOnly.map { ($0.document, $0.previousID) })
            .sorted { number($0.0) < number($1.0) }
        let kept = ordered.prefix(count)
        let keptIDs = Set(kept.map(\.0.id))

        var result = SheetSyncPlan()
        result.added = added.filter { keptIDs.contains($0.id) }
        result.reembedded = reembedded.filter { keptIDs.contains($0.document.id) }
        result.metadataOnly = metadataOnly.filter { keptIDs.contains($0.document.id) }
        result.unchanged = unchanged
        result.empty = empty
        result.mappingChanged = mappingChanged
        // Rows that vanished are **not** carried into a sample run: a decision
        // about deleting documents must not be taken on the strength of a
        // partial read of the file.
        result.disappeared = []
        return result
    }
}
