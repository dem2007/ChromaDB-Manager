import Foundation
import ChromaCore

/// Проверка подключения через тот же транспорт, которым пойдёт агент.
///
/// Приложение запускает **свой же** вспомогательный файл и говорит с ним по
/// stdin/stdout, как агентское приложение. Проверять сокет напрямую было бы
/// проще и бесполезнее: сломаться может именно мост — не тот путь, не те права
/// на файл, не переданная переменная окружения, — и тогда «у меня всё
/// работает» отладке ничем не помогает.
enum MCPConnectionTester {
    /// Путь к мосту внутри бандла приложения.
    static var helperPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/chromadb-mcp")
            .path
    }

    /// Сколько ждать ответа. Дольше человека у экрана держать нельзя, а
    /// поднятие соединения занимает миллисекунды.
    static let timeout: TimeInterval = 15

    static func run(key: String?) async -> MCPConnectionCheck {
        var steps: [MCPConnectionCheck.Step] = []
        let version = await MainActor.run { SettingsTransferViewModel.appVersion }

        let path = helperPath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            steps.append(.init(
                title: String(localized: "Вспомогательный файл"),
                outcome: .failed,
                detail: String(localized: "Не найден или не запускается: \(path). Так бывает у сборки, собранной не скриптом, — переустановите приложение.")
            ))
            return MCPConnectionCheck(steps: steps)
        }
        steps.append(.init(
            title: String(localized: "Вспомогательный файл"),
            outcome: .ok,
            detail: path
        ))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        var environment = ProcessInfo.processInfo.environment
        if let key, !key.isEmpty {
            environment["CHROMADB_MCP_KEY"] = key
        } else {
            environment.removeValue(forKey: "CHROMADB_MCP_KEY")
        }
        process.environment = environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            steps.append(.init(
                title: String(localized: "Запуск моста"),
                outcome: .failed,
                detail: error.localizedDescription
            ))
            return MCPConnectionCheck(steps: steps)
        }
        defer {
            if process.isRunning {
                try? input.fileHandleForWriting.close()
                process.terminate()
            }
        }

        let reader = LineReader(handle: output.fileHandleForReading)

        func ask(_ id: Int, _ method: String, _ params: [String: JSONValue]) async -> JSONValue? {
            var body = params
            body[MCPProtocol.metaKey] = .object([
                MCPProtocol.metaProtocolVersion: .string(MCPProtocol.version),
                MCPProtocol.metaClientInfo: .object([
                    "name": .string("ChromaDB Manager"),
                    "version": .string(version),
                ]),
            ])
            let request = JSONValue.object([
                "jsonrpc": .string("2.0"),
                "id": .int(id),
                "method": .string(method),
                "params": .object(body),
            ])
            guard let data = try? JSONEncoder().encode(request) else { return nil }
            input.fileHandleForWriting.write(data + Data("\n".utf8))
            return await reader.next(timeout: timeout)
        }

        // 1. Сервер отвечает и объявляет возможности.
        if let discovered = await ask(1, MCPProtocol.discoverMethod, [:]),
           let result = discovered["result"] {
            let hasTools = result["capabilities"]?["tools"] != nil
            steps.append(.init(
                title: String(localized: "Связь с приложением"),
                outcome: hasTools ? .ok : .failed,
                detail: hasTools
                    ? String(localized: "Сервер отвечает и объявляет инструменты.")
                    : String(localized: "Сервер ответил, но инструментов не объявил — этого быть не должно, сообщите о дефекте.")
            ))
        } else {
            let stderr = String(
                data: errors.fileHandleForReading.availableData, encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            steps.append(.init(
                title: String(localized: "Связь с приложением"),
                outcome: .failed,
                detail: stderr?.isEmpty == false
                    ? stderr!
                    : String(localized: "Ответа нет \(Int(timeout).plainDigits) с. Обычно это значит, что ChromaDB Manager не запущен — но сейчас он запущен, так что дело в сокете: посмотрите журнал приложения.")
            ))
            return MCPConnectionCheck(steps: steps)
        }

        // 2. Список инструментов — то, что агент покажет человеку первым.
        if let listed = await ask(2, MCPProtocol.listToolsMethod, [:]),
           case .array(let tools)? = listed["result"]?["tools"] {
            let names = tools.compactMap { $0["name"]?.stringValue }
            steps.append(.init(
                title: String(localized: "Инструменты"),
                outcome: names.isEmpty ? .failed : .ok,
                detail: names.isEmpty
                    ? String(localized: "Список пуст.")
                    : names.joined(separator: ", ")
            ))
        } else {
            steps.append(.init(
                title: String(localized: "Инструменты"),
                outcome: .failed,
                detail: String(localized: "Сервер не вернул список инструментов.")
            ))
            return MCPConnectionCheck(steps: steps)
        }

        // 3. Настоящий вызов: он и проверяет права ключа, а не только транспорт.
        guard key?.isEmpty == false else {
            steps.append(.init(
                title: String(localized: "Права ключа"),
                // Не зелёный: проверено не то, ради чего кнопку нажимали.
                outcome: .warning,
                detail: String(localized: "не проверены — ключа у приложения нет. Транспорт работает, но что увидит именно этот клиент, так не узнать: ключ показывается один раз при создании, поэтому проверяйте подключение сразу или перевыпустите ключ.")
            ))
            return MCPConnectionCheck(steps: steps)
        }

        if let called = await ask(3, MCPProtocol.callToolMethod, [
            "name": .string(MCPToolCatalogue.listCollections.name),
            "arguments": .object([:]),
        ]), let result = called["result"] {
            let isError = result["isError"]?.boolValue ?? false
            let text = result["content"]?[0]?["text"]?.stringValue ?? ""
            let count = result["structuredContent"]?["collections"]?.arrayValue?.count ?? 0
            steps.append(.init(
                title: String(localized: "Права ключа"),
                outcome: isError ? .failed : (count == 0 ? .warning : .ok),
                detail: isError
                    ? text
                    : (count == 0
                       ? String(localized: "Ключ принят, но ему не открыта ни одна коллекция — отметьте нужные в правах ниже.")
                       : String(localized: "Ключ принят, коллекций доступно: \(count.plainDigits)."))
            ))
        } else {
            steps.append(.init(
                title: String(localized: "Права ключа"),
                outcome: .failed,
                detail: String(localized: "Вызов инструмента остался без ответа.")
            ))
        }

        return MCPConnectionCheck(steps: steps)
    }
}

/// Чтение ответов по строкам с ожиданием.
///
/// Отдельным типом, потому что `readLine` у `FileHandle` нет, а блокирующее
/// чтение без предела превратило бы кнопку проверки в зависание — то самое,
/// от чего она должна избавить.
private final class LineReader: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func next(timeout: TimeInterval) async -> JSONValue? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = takeLine() {
                return try? JSONDecoder().decode(JSONValue.self, from: line)
            }
            let chunk = await read()
            if chunk.isEmpty {
                try? await Task.sleep(nanoseconds: 50_000_000)
            } else {
                buffer.append(chunk)
            }
        }
        return nil
    }

    private func takeLine() -> Data? {
        guard let index = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let line = buffer[buffer.startIndex..<index]
        buffer.removeSubrange(buffer.startIndex...index)
        return line.isEmpty ? takeLine() : Data(line)
    }

    private func read() async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [handle] in
                continuation.resume(returning: handle.availableData)
            }
        }
    }
}
