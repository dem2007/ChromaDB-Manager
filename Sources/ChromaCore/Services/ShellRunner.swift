import Foundation

/// Result of a finished external process.
public struct ProcessResult {
    public let command: String
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public var isSuccess: Bool { exitCode == 0 }

    public var combinedOutput: String {
        [standardOutput, standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    public init(command: String, exitCode: Int32, standardOutput: String, standardError: String) {
        self.command = command
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum ShellError: LocalizedError {
    case executableNotFound(String)
    case launchFailed(command: String, reason: String)
    case commandFailed(ProcessResult)
    case cancelled(command: String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let tool):
            return "Не найден исполняемый файл «\(tool)». Проверьте, установлен ли он и доступен ли в PATH."
        case .launchFailed(let command, let reason):
            return "Не удалось запустить «\(command)»: \(reason)"
        case .commandFailed(let result):
            let tail = result.combinedOutput.suffix(1200)
            return "Команда завершилась с кодом \(result.exitCode):\n\(result.command)\n\n\(tail)"
        case .cancelled(let command):
            return "Операция отменена: \(command)"
        }
    }
}

/// Thread-safe accumulator used while streaming process output.
private final class OutputBuffer {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock(); storage.append(data); lock.unlock()
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: storage, encoding: .utf8) ?? ""
    }
}

/// Splits a byte stream into whole lines as chunks arrive.
private final class LineSplitter {
    private let lock = NSLock()
    private var pending = ""
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        pending += text
        var lines: [String] = []
        while let range = pending.range(of: "\n") {
            lines.append(String(pending[pending.startIndex..<range.lowerBound]))
            pending = String(pending[range.upperBound...])
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func flush() {
        lock.lock()
        let rest = pending
        pending = ""
        lock.unlock()
        if !rest.isEmpty { onLine(rest) }
    }
}

/// Runs shell commands (`pip`, `python3`, `chroma`, …) on behalf of the app.
///
/// Everything the app does with the outside world through processes goes
/// through here, so that PATH handling, cancellation and output streaming are
/// implemented once. Nothing is executed implicitly: every call site is a user
/// action (check environment, install, start server).
/// `@unchecked Sendable`: собственного изменяемого состояния у бегунка нет —
/// только ссылка на `ToolLocator`, который сам защищает свой кэш путей. Через
/// этот тип идут все обращения к внешним программам, и они идут из фоновых
/// задач.
public final class ShellRunner: @unchecked Sendable {
    public static let shared = ShellRunner()

    private let locator: ToolLocator

    public init(locator: ToolLocator = .shared) {
        self.locator = locator
    }

    // MARK: - Tool resolution

    /// PATH handed to child processes (see `ToolLocator`).
    public func searchPath() -> String { locator.childProcessPath() }

    public func invalidatePathCache() { locator.forget() }

    /// Absolute path of a tool, or `nil` when it is not installed.
    public func which(_ tool: String) -> String? { locator.locate(tool) }

    // MARK: - Running

    /// Runs a command and returns once it exits. Non-zero exit codes are
    /// returned, not thrown — callers decide what an error means.
    @discardableResult
    public func run(
        _ executable: String,
        arguments: [String] = [],
        environment extraEnvironment: [String: String] = [:],
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = 180
    ) async throws -> ProcessResult {
        try await stream(
            executable,
            arguments: arguments,
            environment: extraEnvironment,
            currentDirectory: currentDirectory,
            timeout: timeout,
            onOutput: nil
        )
    }

    /// Same as `run`, but every output line is delivered while the process is
    /// still running — used for `pip install` progress in the UI.
    @discardableResult
    public func stream(
        _ executable: String,
        arguments: [String] = [],
        environment extraEnvironment: [String: String] = [:],
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil,
        onOutput: ((String) -> Void)?
    ) async throws -> ProcessResult {
        guard let resolved = which(executable) else {
            throw ShellError.executableNotFound(executable)
        }

        let displayCommand = ([resolved] + arguments).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath()
        env["PYTHONUNBUFFERED"] = "1"
        env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        for (key, value) in extraEnvironment { env[key] = value }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()
        let stdoutSplitter = onOutput.map { LineSplitter(onLine: $0) }
        let stderrSplitter = onOutput.map { LineSplitter(onLine: $0) }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutBuffer.append(data)
            stdoutSplitter?.feed(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBuffer.append(data)
            stderrSplitter?.feed(data)
        }

        // Boxed so the termination handler can cancel it without capturing a var.
        final class TimeoutBox { var item: DispatchWorkItem? }
        let timeoutBox = TimeoutBox()

        let result: ProcessResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { finished in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    // Drain whatever is still buffered in the pipes.
                    if let rest = try? stdoutPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                        stdoutBuffer.append(rest); stdoutSplitter?.feed(rest)
                    }
                    if let rest = try? stderrPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                        stderrBuffer.append(rest); stderrSplitter?.feed(rest)
                    }
                    stdoutSplitter?.flush()
                    stderrSplitter?.flush()
                    timeoutBox.item?.cancel()

                    continuation.resume(returning: ProcessResult(
                        command: displayCommand,
                        exitCode: finished.terminationStatus,
                        standardOutput: stdoutBuffer.string,
                        standardError: stderrBuffer.string
                    ))
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: ShellError.launchFailed(
                        command: displayCommand,
                        reason: error.localizedDescription
                    ))
                    return
                }

                if let timeout {
                    let item = DispatchWorkItem {
                        if process.isRunning { process.terminate() }
                    }
                    timeoutBox.item = item
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        if Task.isCancelled { throw ShellError.cancelled(command: displayCommand) }
        return result
    }
}
