import Foundation

/// Why the server process died, worked out from what it actually printed.
///
/// Verified on chroma 1.4.4: the server is a Rust binary, and every start-up
/// failure arrives the same way — a panic on stderr followed by exit code 101.
/// The panic text is developer-facing, so it is translated here into something
/// the user can act on, and kept verbatim underneath.
public enum ServerFailure: Equatable {
    case addressInUse(port: Int?)
    case pathNotPermitted(path: String?)
    /// A panic we do not recognise. The reason is shown as the server wrote it.
    case panic(reason: String)
    /// Died without a panic — nothing to translate, only the exit code.
    case exited(code: Int32)

    public var message: String {
        switch self {
        case .addressInUse(let port):
            let where_ = port.map { String(localized: "Порт \($0.plainDigits) уже занят") } ?? String(localized: "Порт уже занят")
            return String(localized: "\(where_) другим процессом.")
        case .pathNotPermitted(let path):
            let target = path.map { " (\($0))" } ?? ""
            return String(localized: "Нет доступа к папке базы данных\(target).")
        case .panic(let reason):
            return String(localized: "Сервер ChromaDB аварийно завершился: \(reason)")
        case .exited(let code):
            return String(localized: "Процесс сервера завершился с кодом \(code.plainDigits).")
        }
    }

    public var suggestion: String? {
        switch self {
        case .addressInUse:
            return String(localized: "Освободите порт или укажите другой в профиле сервера. Занявший его процесс можно найти командой: lsof -nP -iTCP -sTCP:LISTEN")
        case .pathNotPermitted:
            return String(localized: "Выберите папку, в которую приложение может писать — например, внутри вашего домашнего каталога.")
        case .panic, .exited:
            return nil
        }
    }

    /// Reads the tail of the server's own output. `expectedPort` comes from the
    /// launch configuration: the panic itself does not name the port.
    public static func diagnose(output: [String], exitCode: Int32, expectedPort: Int? = nil) -> ServerFailure? {
        if let reason = panicReason(in: output) {
            if reason.contains("AddrInUse") || reason.localizedCaseInsensitiveContains("address already in use") {
                return .addressInUse(port: expectedPort)
            }
            if reason.contains("PermissionDenied") || reason.contains("PathError") {
                return .pathNotPermitted(path: persistPath(in: output))
            }
            return .panic(reason: reason)
        }
        guard exitCode != 0 else { return nil }
        return .exited(code: exitCode)
    }

    /// A Rust panic is two lines: the location, then the reason. The trailing
    /// `note: run with RUST_BACKTRACE` line is noise and is dropped.
    private static func panicReason(in output: [String]) -> String? {
        guard let start = output.lastIndex(where: { $0.contains("panicked at") }) else { return nil }
        let rest = output[output.index(after: start)...]
            .prefix { !$0.hasPrefix("note: run with") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let reason = rest.joined(separator: " ")
        return reason.isEmpty ? output[start].trimmingCharacters(in: .whitespaces) : reason
    }

    private static func persistPath(in output: [String]) -> String? {
        output
            .first { $0.hasPrefix("Saving data to: ") }
            .map { String($0.dropFirst("Saving data to: ".count)).trimmingCharacters(in: .whitespaces) }
    }
}

/// Keeps the server's output — on screen while it runs, and on disk afterwards.
///
/// The on-disk half exists because the interesting output is the last thing a
/// dying server prints, and by the time the user comes to look the in-memory
/// buffer may already belong to the next run.
public final class ServerLogStore {
    public struct Run: Identifiable, Hashable {
        public let url: URL
        public let startedAt: Date
        public let sizeBytes: Int64

        public var id: String { url.path }
        public var name: String { url.lastPathComponent }
        public var sizeText: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
    }

    private let directory: URL
    /// Older run files are deleted; a log nobody will read is just clutter.
    private let keepRuns: Int
    private let queue = DispatchQueue(label: "io.github.chromadbmanager.serverlog")
    private var handle: FileHandle?
    private var currentURL: URL?

    public init(directory: URL = AppPaths.serverLogsDirectory, keepRuns: Int = 5) {
        self.directory = directory
        self.keepRuns = keepRuns
    }

    public var currentRunURL: URL? {
        queue.sync { currentURL }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    @discardableResult
    public func beginRun(label: String, command: String) -> URL? {
        queue.sync {
            closeCurrent()
            _ = try? AppPaths.ensureDirectory(directory)
            let url = directory.appendingPathComponent("server-\(Self.stampFormatter.string(from: Date())).log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            currentURL = url
            handle = try? FileHandle(forWritingTo: url)
            write("=== \(label) ===")
            write("=== \(command) ===")
            pruneLocked()
            return url
        }
    }

    public func append(_ lines: [String]) {
        queue.async { [weak self] in
            for line in lines { self?.write(line) }
        }
    }

    public func endRun(note: String) {
        queue.async { [weak self] in
            self?.write("=== \(note) ===")
            self?.closeCurrent()
        }
    }

    public func runs() -> [Run] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]
        )) ?? []
        return contents
            .filter { $0.pathExtension == "log" }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                return Run(
                    url: url,
                    startedAt: values?.creationDate ?? .distantPast,
                    sizeBytes: Int64(values?.fileSize ?? 0)
                )
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Private (all on `queue`)

    private func write(_ line: String) {
        guard let handle else { return }
        let stamped = "[\(Self.timeFormatter.string(from: Date()))] \(line)\n"
        try? handle.write(contentsOf: Data(stamped.utf8))
    }

    private func closeCurrent() {
        try? handle?.close()
        handle = nil
        currentURL = nil
    }

    private func pruneLocked() {
        let files = runs()
        guard files.count > keepRuns else { return }
        for stale in files.dropFirst(keepRuns) {
            try? FileManager.default.removeItem(at: stale.url)
        }
    }
}
