import Foundation

/// What kind of call this is.
///
/// The class decides two things and nothing else: how long the app is willing
/// to wait, and whether a failed call may be repeated without asking.
/// Both answers are wrong if they are global — three seconds is generous for a
/// healthcheck and absurd for a query over a large collection.
public enum ChromaOperation: String, Codable, Sendable, CaseIterable {
    /// healthcheck, version, heartbeat.
    case liveness
    /// list of collections, count.
    case metadata
    /// a page of documents.
    case fetch
    case query
    /// add / upsert / update / delete — one sub-batch.
    case write
    /// creating and deleting collections.
    case management

    public var title: String {
        switch self {
        case .liveness: return String(localized: "Проверка доступности")
        case .metadata: return String(localized: "Чтение метаданных")
        case .fetch: return String(localized: "Чтение документов")
        case .query: return String(localized: "Поисковый запрос")
        case .write: return String(localized: "Запись")
        case .management: return String(localized: "Управление коллекциями")
        }
    }

    /// A repeat the user did not ask for is only acceptable when repeating
    /// changes nothing. Everything that writes is excluded on purpose — an
    /// `upsert` that timed out may well have been applied, and the honest move
    /// is to say so and let the user decide.
    public var isRetriedAutomatically: Bool {
        switch self {
        case .liveness, .metadata, .fetch, .query: return true
        case .write, .management: return false
        }
    }
}

/// Per-class deadlines, in seconds. Defaults are the table in A8.1.
public struct TimeoutSettings: Codable, Hashable, Sendable {
    public var liveness: TimeInterval
    public var metadata: TimeInterval
    public var fetch: TimeInterval
    public var query: TimeInterval
    public var write: TimeInterval
    /// One batch of texts in LM Studio. A local model on a CPU is slow, and a
    /// short deadline here just breaks indexing.
    public var embedding: TimeInterval
    /// One call to a chat model (LLM-based chunking).
    public var chat: TimeInterval

    public static let allowedRange: ClosedRange<TimeInterval> = 1...3600

    public init(
        liveness: TimeInterval = 3,
        metadata: TimeInterval = 15,
        fetch: TimeInterval = 30,
        query: TimeInterval = 60,
        write: TimeInterval = 120,
        embedding: TimeInterval = 300,
        chat: TimeInterval = 180
    ) {
        self.liveness = liveness
        self.metadata = metadata
        self.fetch = fetch
        self.query = query
        self.write = write
        self.embedding = embedding
        self.chat = chat
    }

    public subscript(operation: ChromaOperation) -> TimeInterval {
        switch operation {
        case .liveness: return clamped(liveness)
        case .metadata, .management: return clamped(metadata)
        case .fetch: return clamped(fetch)
        case .query: return clamped(query)
        case .write: return clamped(write)
        }
    }

    private func clamped(_ value: TimeInterval) -> TimeInterval {
        min(max(value, Self.allowedRange.lowerBound), Self.allowedRange.upperBound)
    }

    /// A hand-edited config with a zero or a missing key must not turn into a
    /// call that never times out.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TimeoutSettings()
        func read(_ key: CodingKeys, _ fallback: TimeInterval) -> TimeInterval {
            guard let stored = ((try? container.decodeIfPresent(TimeInterval.self, forKey: key)) ?? nil),
                  Self.allowedRange.contains(stored) else { return fallback }
            return stored
        }
        liveness = read(.liveness, defaults.liveness)
        metadata = read(.metadata, defaults.metadata)
        fetch = read(.fetch, defaults.fetch)
        query = read(.query, defaults.query)
        write = read(.write, defaults.write)
        embedding = read(.embedding, defaults.embedding)
        chat = read(.chat, defaults.chat)
    }
}

/// How many times a call may be repeated and how long to wait in between.
public struct RetryPolicy: Hashable, Sendable {
    public var maxAttempts: Int
    public var delays: [TimeInterval]

    public init(maxAttempts: Int, delays: [TimeInterval]) {
        self.maxAttempts = max(1, maxAttempts)
        self.delays = delays
    }

    /// Reads: two retries, 0.5 s then 1.5 s.
    public static let reads = RetryPolicy(maxAttempts: 3, delays: [0.5, 1.5])
    public static let never = RetryPolicy(maxAttempts: 1, delays: [])

    /// Jitter spreads retries out when several calls fail at the same moment —
    /// otherwise a server that just came back gets every client at once.
    public func delay(beforeAttempt attempt: Int, jitter: Double = Double.random(in: -0.25...0.25)) -> TimeInterval {
        guard attempt >= 2 else { return 0 }
        let base = delays.indices.contains(attempt - 2) ? delays[attempt - 2] : (delays.last ?? 0)
        return max(0, base * (1 + min(max(jitter, -0.25), 0.25)))
    }
}

/// One HTTP exchange. A protocol so the retry and timeout rules can be tested
/// against a transport that fails on demand — a real server cannot be asked to
/// return 503 twice and then succeed.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        // The real deadline is per request (and, on top of that, an outer
        // clock); the session must not cut a long write short.
        configuration.timeoutIntervalForRequest = TimeoutSettings.allowedRange.upperBound
        configuration.timeoutIntervalForResource = TimeoutSettings.allowedRange.upperBound
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChromaError.decoding("не HTTP-ответ")
        }
        return (data, http)
    }
}

/// Races the work against a clock.
///
/// `URLRequest.timeoutInterval` covers waiting for a response, not a body that
/// trickles in a byte at a time; a hung read can outlive it. So every call also
/// gets an outer deadline that cancels the task.
func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    onExpiry: @escaping @Sendable () -> Error,
    work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw onExpiry()
        }
        guard let result = try await group.next() else {
            throw onExpiry()
        }
        group.cancelAll()
        return result
    }
}
