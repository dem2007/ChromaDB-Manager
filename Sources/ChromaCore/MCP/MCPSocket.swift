import Foundation
import Network

/// Канал «вспомогательный файл ↔ приложение» поверх сокета Unix.
///
/// На Network framework: поддержка сокетов Unix на macOS 14 проверена делом —
/// слушатель, подключение и переданные байты, — а не вычитана. Кадрирование
/// то же самое, что у stdio (`LineFramer`), потому что спецификация прямо это
/// и предписывает произвольным транспортам поверх потока.
public final class MCPChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var framer = LineFramer()
    private let lock = NSLock()

    /// Пришло целое сообщение.
    public var onMessage: (@Sendable (Data) -> Void)?
    /// Канал закрылся — по-хорошему или нет.
    public var onClose: (@Sendable (Error?) -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.ready.signal()
            case .failed(let error):
                self?.failure = error
                self?.ready.signal()
                self?.finish(error)
            case .cancelled:
                self?.ready.signal()
                self?.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private let ready = DispatchSemaphore(value: 0)
    private var failure: Error?

    /// Ждёт, пока соединение действительно установится.
    ///
    /// Существование файла сокета ничего не доказывает: он остаётся на диске
    /// после закрытия приложения, и подключение к нему отвергается — но
    /// **асинхронно**. Без этого ожидания отправленное сообщение уходило
    /// в мёртвый канал, и агент ждал ответа, которого не будет.
    @discardableResult
    public func waitUntilReady(timeout: TimeInterval) -> Bool {
        guard ready.wait(timeout: .now() + timeout) == .success else { return false }
        return failure == nil && !lock.withLock { finished }
    }

    public func send(_ message: Data) {
        connection.send(content: LineFraming.frame(message), completion: .contentProcessed { _ in })
    }

    public func close() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    // Кадрирование общее с stdio: одна строка — одно сообщение.
                    let messages = try self.lock.withLock { try self.framer.consume(data) }
                    for message in messages { self.onMessage?(message) }
                } catch {
                    self.finish(error)
                    self.connection.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                // Хвост без перевода строки — тоже сообщение, и терять его
                // на закрытии нельзя.
                if let tail = self.lock.withLock({ self.framer.flush() }) { self.onMessage?(tail) }
                self.finish(error)
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    private var finished = false
    private func finish(_ error: Error?) {
        let shouldReport: Bool = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        if shouldReport { onClose?(error) }
    }
}

/// Параметры слушателя: адрес сокета задаётся как локальный конец.
private func listenerParameters(path: String) -> NWParameters {
    let parameters = NWParameters()
    parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
    parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
    return parameters
}

/// Параметры подключения.
///
/// Локальный конец здесь **не** задаётся: у клиента путь сокета — это адрес
/// назначения, а `requiredLocalEndpoint` привязал бы его к тому же файлу.
private func clientParameters() -> NWParameters {
    let parameters = NWParameters()
    parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
    return parameters
}

/// Слушатель на стороне приложения.
public final class MCPListener: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "chromadb.mcp.listener")
    private let path: String

    /// Подключился клиент.
    public var onConnection: (@Sendable (MCPChannel) -> Void)?

    public enum ListenError: LocalizedError {
        case notReady

        public var errorDescription: String? {
            String(localized: "Не удалось открыть сокет MCP — агенты не смогут подключиться.")
        }
    }

    public init(path: String = AppPaths.mcpSocketFile.path) {
        self.path = path
    }

    /// Поднимает слушателя и **дожидается готовности**.
    ///
    /// Ждать обязательно: `NWListener.start` возвращается раньше, чем файл
    /// сокета появляется на диске, и клиент, подключившийся сразу после
    /// запуска приложения, не нашёл бы его и решил, что приложение не
    /// запущено. Найдено сквозным тестом, не рассуждением.
    public func start() throws {
        // Каталог именно того сокета, который слушаем: путь может быть
        // переопределён, и создавать вместо него рабочий каталог — значит
        // делать не то, о чём попросили.
        try AppPaths.ensureDirectory(URL(fileURLWithPath: path).deletingLastPathComponent())
        // Файл сокета переживает падение процесса, и оставшийся от прошлого
        // запуска намертво занял бы адрес. Удаляется именно сокет: если по
        // этому пути лежит что-то другое, это не наш файл и трогать его нельзя.
        removeStaleSocket()

        let listener = try NWListener(using: listenerParameters(path: path))
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let channel = MCPChannel(connection: connection, queue: self.queue)
            self.onConnection?(channel)
            channel.start()
        }

        let ready = DispatchSemaphore(value: 0)
        let failure = UnfairBox<Error?>(nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failure.value = error
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)

        // Очередь слушателя — своя, поэтому ожидание здесь никого не блокирует
        // по кругу. Пять секунд с запасом: открытие сокета Unix либо
        // происходит сразу, либо не происходит вовсе.
        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw ListenError.notReady
        }
        if let error = failure.value {
            listener.cancel()
            throw error
        }

        // Права на файл сокета — 0600, а не то, что оставит umask.
        // Подключиться к сокету Unix может тот, у кого есть право записи;
        // с обычным umask это «все в системе», а на другом конце — доступ
        // к базе документов. Ставится после готовности слушателя: раньше
        // файла ещё нет.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        removeStaleSocket()
    }

    private func removeStaleSocket() {
        var status = stat()
        guard lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFSOCK else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Значение, которое пишет обработчик, а читает вызывающая сторона.
private final class UnfairBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Подключение на стороне вспомогательного файла.
public enum MCPConnector {
    public enum ConnectError: LocalizedError {
        case appNotRunning

        public var errorDescription: String? {
            // Текст читает не программист, а человек, у которого агент
            // отказался работать. Он должен узнать, что делать.
            String(
                localized: "Приложение ChromaDB Manager не запущено. Запустите его — MCP-сервер работает только вместе с ним."
            )
        }
    }

    /// Сколько ждать установления связи. Локальный сокет отвечает мгновенно
    /// или не отвечает вовсе; секунда — с запасом на занятое приложение.
    public static let connectTimeout: TimeInterval = 2

    /// Подключается к приложению.
    ///
    /// Если сокета нет, приложение не запущено — и это не «ошибка соединения»,
    /// а самое частое штатное состояние. По D2.2 оно обязано превратиться
    /// во внятный ответ агенту, а не в молчание.
    ///
    /// Проверки существования файла **недостаточно**: он остаётся на диске
    /// после закрытия приложения. Поэтому связь ещё и дожидается — иначе
    /// сообщение уходит в мёртвый канал и агент ждёт ответа, которого не будет
    /// (найдено живой сверкой с DoD этапа 7).
    public static func connect(
        path: String = AppPaths.mcpSocketFile.path,
        queue: DispatchQueue
    ) throws -> MCPChannel {
        var status = stat()
        guard lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFSOCK else {
            throw ConnectError.appNotRunning
        }
        let connection = NWConnection(to: .unix(path: path), using: clientParameters())
        let channel = MCPChannel(connection: connection, queue: queue)
        channel.start()
        guard channel.waitUntilReady(timeout: connectTimeout) else {
            channel.close()
            throw ConnectError.appNotRunning
        }
        return channel
    }
}
