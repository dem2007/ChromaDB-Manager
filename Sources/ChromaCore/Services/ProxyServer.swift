import Foundation
import Network

/// One request read off a client connection.
public struct ProxiedRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [(name: String, value: String)]
    public var body: Data

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var route: ChromaRoute { ChromaRoute.parse(method: method, path: path) }

    public var accessKey: String? {
        ClientKey.extract(authorization: header("Authorization"), chromaToken: header("X-Chroma-Token"))
    }

    /// Where a browser page says it is calling from.
    public var origin: String? { header("Origin") }
}

/// Reads HTTP/1.1 requests out of a byte stream.
///
/// The proxy used to relay bytes blindly; from the moment it started deciding
/// what to allow it has to understand whole requests — permissions depend on
/// the body (how many documents, how big, what vector size).
struct HTTPRequestParser {
    enum Failure: Error, Equatable {
        case malformed(String)
    }

    private var buffer = Data()
    private static let separator = Data("\r\n\r\n".utf8)
    private static let maximumHeadBytes = 64 * 1024
    /// A single request bigger than this is refused rather than buffered: the
    /// proxy must not be a way to make the app run out of memory.
    static let maximumBodyBytes = 64 * 1024 * 1024

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete request, or `nil` while more bytes are needed.
    mutating func next() throws -> ProxiedRequest? {
        guard let range = buffer.range(of: Self.separator) else {
            if buffer.count > Self.maximumHeadBytes {
                throw Failure.malformed("заголовок длиннее \(Self.maximumHeadBytes.plainDigits) байт")
            }
            return nil
        }

        let headData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        guard let text = String(data: headData, encoding: .utf8) ?? String(data: headData, encoding: .isoLatin1) else {
            throw Failure.malformed("заголовок не читается")
        }

        var lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw Failure.malformed("пустой запрос") }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { throw Failure.malformed("некорректная строка запроса") }

        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append((
                String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces),
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            ))
        }

        func header(_ name: String) -> String? {
            headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
        }
        if let encoding = header("Transfer-Encoding"), encoding.localizedCaseInsensitiveContains("chunked") {
            // Verified on chroma 1.4.4 and its client: everything carries
            // Content-Length. Refusing is honest; guessing at chunk framing in
            // a permission check is not.
            throw Failure.malformed("chunked-тело не поддерживается прокси")
        }
        let length = header("Content-Length").flatMap { Int($0) } ?? 0
        guard length <= Self.maximumBodyBytes else {
            throw Failure.malformed("тело запроса больше \(Self.maximumBodyBytes.plainDigits) байт")
        }

        let bodyStart = range.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        buffer.removeSubrange(buffer.startIndex..<(bodyStart + length))

        return ProxiedRequest(method: parts[0], path: parts[1], headers: headers, body: body)
    }
}

/// A local reverse proxy in front of ChromaDB — the part the screen talks to.
///
/// ChromaDB has no per-collection permissions and no read-only mode: its own
/// authentication is one token for the whole server. Everything the spec
/// asks for therefore has to live here.
///
/// Listening and forwarding live in `ProxyCore`, on a queue of its own. That
/// separation is not tidiness: accepting connections on the main actor means a
/// busy interface stalls the proxy, and a proxy that stops answering because a
/// window is redrawing is not a proxy.
@MainActor
public final class ProxyServer: ObservableObject {
    public enum State: Equatable {
        case stopped
        case running(address: String, port: Int)
        case failed(String)

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        public var title: String {
            switch self {
            case .stopped: return String(localized: "Остановлен")
            case .running(let address, let port): return String(localized: "Слушает \(address):\(port.plainDigits)")
            case .failed(let reason): return String(localized: "Ошибка: \(reason)")
            }
        }
    }

    @Published public private(set) var state: State = .stopped
    @Published public private(set) var upstreamDescription: String?
    @Published public private(set) var activeConnections = 0
    @Published public private(set) var totalRequests = 0
    @Published public private(set) var rejectedRequests = 0
    /// What the running listener is bound to. Not the setting — the fact.
    @Published public private(set) var exposure: NetworkExposure = .loopback
    /// When the listener came up, and whether anything from outside this
    /// machine has reached it since.
    @Published public private(set) var startedAt: Date?
    @Published public private(set) var sawExternalRequest = false

    public let access: AccessController

    private let core: ProxyCore
    private let log: LogHandler

    public init(
        audit: AuditLog,
        access: AccessController = AccessController(),
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.access = access
        self.core = ProxyCore(audit: audit, access: access)
        self.log = log

        core.onReady = { [weak self] address, port, upstream in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state = .running(address: address, port: port)
                self.startedAt = Date()
                self.sawExternalRequest = false
                self.log(.success, "Прокси", "Прокси слушает \(address):\(port.plainDigits) → \(upstream)")
            }
        }
        core.onFailure = { [weak self] reason in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state = .failed(reason)
                self.log(.error, "Прокси", "Прокси остановлен: \(reason)")
            }
        }
        core.onStats = { [weak self] stats in
            Task { @MainActor [weak self] in
                self?.activeConnections = stats.active
                self?.totalRequests = stats.total
                self?.rejectedRequests = stats.rejected
                if stats.sawExternalPeer { self?.sawExternalRequest = true }
            }
        }
    }

    /// Called when a registered client is seen, so «последняя активность» in the
    /// list means something.
    public var onClientSeen: (@Sendable (UUID) -> Void)? {
        get { core.onClientSeen }
        set { core.onClientSeen = newValue }
    }

    /// Called for every refused request — the event the user is notified about.
    public var onRejection: (@Sendable (_ client: String, _ reason: String) -> Void)? {
        get { core.onRejection }
        set { core.onRejection = newValue }
    }

    /// Starts listening. `exposure` decides whether the listener is bound to
    /// loopback or to every interface; the upstream ChromaDB is
    /// never the thing exposed.
    public func start(
        upstreamHost: String,
        upstreamPort: Int,
        listenPort: Int,
        exposure: NetworkExposure = .loopback
    ) throws {
        stop()
        do {
            // Refusing here rather than in the interface: whatever path leads to
            // this call, forwarding network traffic into a ChromaDB that is
            // itself on the network would defeat the whole proxy.
            if exposure.isExposed && !SecurityAssessment.isLoopback(upstreamHost) {
                throw ProxyError.upstreamNotLoopback(upstreamHost)
            }
            try core.start(
                upstreamHost: upstreamHost,
                upstreamPort: upstreamPort,
                listenPort: listenPort,
                bindHost: exposure.bindHost
            )
            self.exposure = exposure
            upstreamDescription = "\(upstreamHost):\(upstreamPort.plainDigits)"
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            throw error
        }
    }

    public func stop() {
        let wasRunning = state.isRunning
        core.stop()
        activeConnections = 0
        state = .stopped
        startedAt = nil
        upstreamDescription = nil
        if wasRunning { log(.info, "Прокси", "Прокси остановлен") }
    }

    public enum ProxyError: LocalizedError {
        case portBusy(Int)
        case invalidPort(Int)
        case listenFailed(String)
        case notConnected
        case upstreamNotLoopback(String)

        public var errorDescription: String? {
            switch self {
            case .portBusy(let port):
                return String(localized: "Порт \(port.plainDigits) уже занят — прокси не запущен.")
            case .invalidPort(let port):
                return String(localized: "Недопустимый порт: \(port.plainDigits).")
            case .listenFailed(let reason):
                return String(localized: "Не удалось открыть порт: \(reason)")
            case .notConnected:
                return String(localized: "Прокси нечего проксировать: приложение не подключено к ChromaDB.")
            case .upstreamNotLoopback(let host):
                return String(localized: "Нельзя открыть прокси наружу: сам ChromaDB работает на \(host), а не на 127.0.0.1.")
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .upstreamNotLoopback:
                return String(localized: "Наружу открывается только прокси — он проверяет права. Сервер должен оставаться на локальном адресе.")
            default:
                return nil
            }
        }
    }
}

/// Owns the listener and the live connections. Nothing here touches the main
/// actor, so traffic keeps flowing while the interface is busy.
final class ProxyCore {
    struct Stats: Sendable {
        var active = 0
        var total = 0
        var rejected = 0
        /// Something connected from beyond this machine. Without it, silence on
        /// an open port is ambiguous: nobody tried, or the firewall ate it.
        var sawExternalPeer = false
    }

    var onReady: ((String, Int, String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onStats: ((Stats) -> Void)?
    var onClientSeen: (@Sendable (UUID) -> Void)?
    var onRejection: (@Sendable (String, String) -> Void)?

    private let audit: AuditLog
    private let access: AccessController
    private let queue = DispatchQueue(label: "io.github.chromadbmanager.proxy")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ProxyConnection] = [:]
    private var stats = Stats()

    init(audit: AuditLog, access: AccessController) {
        self.audit = audit
        self.access = access
    }

    func start(upstreamHost: String, upstreamPort: Int, listenPort: Int, bindHost: String) throws {
        guard PortUtility.isAvailable(host: bindHost, port: listenPort) else {
            throw ProxyServer.ProxyError.portBusy(listenPort)
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(exactly: listenPort) ?? 0) else {
            throw ProxyServer.ProxyError.invalidPort(listenPort)
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Pinning the local endpoint is what keeps the listener off the network;
        // for `0.0.0.0` the endpoint is left unset, which is how `NWListener`
        // spells «every interface».
        if bindHost != "0.0.0.0" {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(bindHost), port: port)
        }

        let listener: NWListener
        do {
            // With a pinned endpoint the port comes from it; without one it has
            // to be given, or `NWListener` picks a free port of its own.
            listener = parameters.requiredLocalEndpoint == nil
                ? try NWListener(using: parameters, on: port)
                : try NWListener(using: parameters)
        } catch {
            throw ProxyServer.ProxyError.listenFailed(error.localizedDescription)
        }

        guard let upstream = URL(string: "http://\(upstreamHost):\(upstreamPort)") else {
            throw ProxyServer.ProxyError.listenFailed("некорректный адрес сервера")
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, upstream: upstream)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onReady?(bindHost, listenPort, "\(upstreamHost):\(upstreamPort)")
            case .failed(let error):
                self?.onFailure?(error.localizedDescription)
                self?.stop()
            default:
                break
            }
        }

        lock.lock()
        self.listener = listener
        lock.unlock()
        listener.start(queue: queue)
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        let live = Array(connections.values)
        self.listener = nil
        connections.removeAll()
        stats.active = 0
        let snapshot = stats
        lock.unlock()

        listener?.cancel()
        for connection in live { connection.cancel() }
        onStats?(snapshot)
    }

    private func accept(_ connection: NWConnection, upstream: URL) {
        if ProxyConnection.isExternalPeer(connection.endpoint) {
            lock.lock()
            stats.sawExternalPeer = true
            let snapshot = stats
            lock.unlock()
            onStats?(snapshot)
        }
        let proxied = ProxyConnection(
            client: connection,
            upstream: upstream,
            queue: queue,
            audit: audit,
            access: access,
            onRejected: { [weak self] client, reason in
                self?.onRejection?(client, reason)
            },
            onFinished: { [weak self] wasRejected, clientID in
                guard let self else { return }
                self.lock.lock()
                self.stats.total += 1
                if wasRejected { self.stats.rejected += 1 }
                let snapshot = self.stats
                self.lock.unlock()
                if let clientID { self.onClientSeen?(clientID) }
                self.onStats?(snapshot)
            },
            onClose: { [weak self] identifier in
                guard let self else { return }
                self.lock.lock()
                self.connections[identifier] = nil
                self.stats.active = self.connections.count
                let snapshot = self.stats
                self.lock.unlock()
                self.onStats?(snapshot)
            }
        )
        lock.lock()
        connections[ObjectIdentifier(proxied)] = proxied
        stats.active = connections.count
        let snapshot = stats
        lock.unlock()
        onStats?(snapshot)
        proxied.start()
    }
}

/// One client connection: reads requests, asks `AccessController` what to do
/// with each, and either forwards it or answers the refusal itself.
///
/// `@unchecked Sendable`: every mutable field is touched only on `queue`, and
/// the handling `Task` hops back onto it before touching anything.
final class ProxyConnection: @unchecked Sendable {
    private let client: NWConnection
    private let upstream: URL
    private let queue: DispatchQueue
    private let audit: AuditLog
    private let access: AccessController
    private let onRejected: (String, String) -> Void
    private let onFinished: (Bool, UUID?) -> Void
    private let onClose: (ObjectIdentifier) -> Void
    private let peer: String
    private let session: URLSession

    private var parser = HTTPRequestParser()
    private var isHandling = false
    private var isClosed = false

    init(
        client: NWConnection,
        upstream: URL,
        queue: DispatchQueue,
        audit: AuditLog,
        access: AccessController,
        onRejected: @escaping (String, String) -> Void,
        onFinished: @escaping (Bool, UUID?) -> Void,
        onClose: @escaping (ObjectIdentifier) -> Void
    ) {
        self.client = client
        self.upstream = upstream
        self.queue = queue
        self.audit = audit
        self.access = access
        self.onRejected = onRejected
        self.onFinished = onFinished
        self.onClose = onClose
        self.peer = Self.describe(client.endpoint)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: configuration)
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.cancel()
            default: break
            }
        }
        client.start(queue: queue)
        pump()
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.isClosed = true
            self.client.cancel()
            self.session.invalidateAndCancel()
            self.onClose(ObjectIdentifier(self))
        }
    }

    // MARK: - Reading

    private func pump() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.parser.append(data)
                self.drain()
            }
            if isComplete || error != nil {
                self.cancel()
                return
            }
            self.pump()
        }
    }

    /// One request at a time: HTTP/1.1 answers in order, and a permission check
    /// that overtook its own request would answer the wrong one.
    private func drain() {
        guard !isHandling, !isClosed else { return }
        let request: ProxiedRequest?
        do {
            request = try parser.next()
        } catch {
            let reason = (error as? HTTPRequestParser.Failure).map { failure -> String in
                if case .malformed(let text) = failure { return text }
                return "\(failure)"
            } ?? error.localizedDescription
            respond(status: 400, message: reason)
            audit.record(AuditEntry(
                client: peer, method: "?", path: "?", operation: "unparseable", access: .write,
                collection: nil, requestBytes: 0, responseStatus: 400, responseBytes: 0,
                durationSeconds: 0, note: reason
            ))
            cancel()
            return
        }
        guard let request else { return }

        isHandling = true
        Task { [weak self] in
            await self?.handle(request)
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.isHandling = false
                self.drain()
            }
        }
    }

    // MARK: - Handling

    private func handle(_ request: ProxiedRequest) async {
        let started = Date()
        let route = request.route

        // A browser sends OPTIONS before the real request, and that preflight
        // carries no key by definition. It is answered here and never
        // forwarded: the upstream server has nothing to say about it.
        if request.method.uppercased() == "OPTIONS" {
            await answerPreflight(request, started: started)
            return
        }

        let decision = await access.decide(key: request.accessKey, route: route, body: request.body)
        let corsHeaders = await corsHeaders(for: request)
        // A creation names its collection in the body, not in the path.
        let collection = route.collectionReference
            ?? (route.operation == "create_collection" ? AccessController.collectionName(inCreateBody: request.body) : nil)

        switch decision {
        case .reject(let status, let message, let clientName, let retryAfter):
            var headers = corsHeaders
            // A client that is being throttled has to be told when to come
            // back, or it will simply retry immediately.
            if let retryAfter { headers.append(("retry-after", String(retryAfter))) }
            respond(status: status, message: message, extraHeaders: headers)
            audit.record(AuditEntry(
                client: clientName ?? peer,
                method: request.method,
                path: request.path,
                operation: route.operation,
                access: route.access,
                collection: collection,
                requestBytes: request.body.count,
                responseStatus: status,
                responseBytes: 0,
                durationSeconds: Date().timeIntervalSince(started),
                note: message
            ))
            onRejected(clientName ?? peer, message)
            onFinished(true, nil)

        case .allow(let clientID, let clientName, let filter):
            do {
                var (status, headers, body) = try await forward(request)
                if case .collectionList(let allowed) = filter {
                    body = Self.filterCollectionList(body, allowed: allowed)
                }
                headers.append(contentsOf: corsHeaders)
                respond(status: status, headers: headers, body: body)
                audit.record(AuditEntry(
                    client: clientName,
                    method: request.method,
                    path: request.path,
                    operation: route.operation,
                    access: route.access,
                    collection: collection,
                    requestBytes: request.body.count,
                    responseStatus: status,
                    responseBytes: body.count,
                    durationSeconds: Date().timeIntervalSince(started)
                ))
            } catch {
                let message = String(localized: "Сервер ChromaDB не ответил: \(error.localizedDescription)")
                respond(status: 502, message: message, extraHeaders: corsHeaders)
                audit.record(AuditEntry(
                    client: clientName,
                    method: request.method,
                    path: request.path,
                    operation: route.operation,
                    access: route.access,
                    collection: collection,
                    requestBytes: request.body.count,
                    responseStatus: 502,
                    responseBytes: 0,
                    durationSeconds: Date().timeIntervalSince(started),
                    note: message
                ))
            }
            onFinished(false, clientID)
        }
    }

    private func forward(_ request: ProxiedRequest) async throws -> (Int, [(String, String)], Data) {
        guard let url = URL(string: request.path, relativeTo: upstream) else {
            throw URLError(.badURL)
        }
        var outgoing = URLRequest(url: url)
        outgoing.httpMethod = request.method
        if !request.body.isEmpty { outgoing.httpBody = request.body }
        for (name, value) in request.headers where !Self.droppedHeaders.contains(name.lowercased()) {
            outgoing.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: outgoing)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let headers = http.allHeaderFields.compactMap { key, value -> (String, String)? in
            guard let name = key as? String, !Self.droppedHeaders.contains(name.lowercased()) else { return nil }
            return (name, String(describing: value))
        }
        return (http.statusCode, headers, data)
    }

    /// Hop-by-hop headers and anything we recompute ourselves.
    private static let droppedHeaders: Set<String> = [
        "host", "connection", "content-length", "transfer-encoding",
        "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "upgrade",
        "accept-encoding", "content-encoding",
    ]

    /// Trims the list of collections to the ones this client may see.
    static func filterCollectionList(_ body: Data, allowed: [String]) -> Data {
        guard let array = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else { return body }
        let permitted = Set(allowed)
        let kept = array.filter { item in
            guard let name = item["name"] as? String else { return false }
            return permitted.contains(name)
        }
        return (try? JSONSerialization.data(withJSONObject: kept)) ?? Data("[]".utf8)
    }

    // MARK: - Answering

    private func respond(status: Int, message: String, extraHeaders: [(String, String)] = []) {
        let payload: [String: Any] = ["error": "ChromaDBManagerProxy", "message": message]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        respond(status: status, headers: [("content-type", "application/json")] + extraHeaders, body: body)
    }

    // MARK: - CORS

    /// Headers for an ordinary request, once the key is known.
    ///
    /// Empty unless this client listed the origin: CORS is off by default, and
    /// «off» means no headers at all rather than headers that deny.
    private func corsHeaders(for request: ProxiedRequest) async -> [(String, String)] {
        guard let origin = request.origin, !origin.isEmpty else { return [] }
        guard let client = await access.client(withKey: request.accessKey),
              client.isEnabled, client.permissions.allowsOrigin(origin) else { return [] }
        return Self.corsHeaderList(origin: origin)
    }

    private static func corsHeaderList(origin: String) -> [(String, String)] {
        [
            // The concrete origin, never `*`, even when the client allowed any:
            // echoing the request's own origin is what lets a browser send
            // credentials at all, and it keeps the answer specific.
            ("access-control-allow-origin", origin),
            ("access-control-allow-headers", "authorization, x-chroma-token, content-type"),
            ("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS"),
            ("access-control-max-age", "600"),
            ("vary", "origin"),
        ]
    }

    private func answerPreflight(_ request: ProxiedRequest, started: Date) async {
        let origin = request.origin ?? ""
        var allowed = false
        if !origin.isEmpty {
            allowed = await access.originIsAllowedByAnyClient(origin)
        }
        let status = allowed ? 204 : 403
        respond(
            status: status,
            headers: allowed ? Self.corsHeaderList(origin: origin) : [],
            body: Data()
        )
        audit.record(AuditEntry(
            client: origin.isEmpty ? peer : origin,
            method: request.method,
            path: request.path,
            operation: "cors_preflight",
            access: .service,
            collection: nil,
            requestBytes: 0,
            responseStatus: status,
            responseBytes: 0,
            durationSeconds: Date().timeIntervalSince(started),
            note: allowed ? nil : String(localized: "origin не разрешён ни одному клиенту")
        ))
        onFinished(!allowed, nil)
    }

    private func respond(status: Int, headers: [(String, String)], body: Data) {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "content-length: \(body.count)\r\n"
        head += "connection: keep-alive\r\n\r\n"

        var data = Data(head.utf8)
        data.append(body)
        client.send(content: data, completion: .contentProcessed { _ in })
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 502: return "Bad Gateway"
        default: return status < 400 ? "OK" : "Error"
        }
    }

    /// Whether the other end is on another machine.
    static func isExternalPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let text = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
        return !SecurityAssessment.isLoopback(text)
    }

    private static func describe(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, let port) = endpoint {
            return "\(host):\(port.rawValue.plainDigits)"
        }
        return String(describing: endpoint)
    }
}
