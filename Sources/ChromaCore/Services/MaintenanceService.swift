import Foundation

/// Reclaiming disk space after mass deletions.
///
/// SQLite does not return freed pages to the filesystem on its own: after a
/// re-index or a source cleanup the file stays as large as it ever was. The
/// Chroma CLI has `vacuum` for exactly this — verified present on 1.4.4, with
/// the flags recorded in.
public struct MaintenanceService {
    private let runner: ShellRunner
    private let locator: ToolLocator
    private let log: LogHandler

    public init(
        runner: ShellRunner = ShellRunner(),
        locator: ToolLocator = .shared,
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.runner = runner
        self.locator = locator
        self.log = log
    }

    public struct Result: Hashable, Sendable {
        public let bytesBefore: Int64
        public let bytesAfter: Int64
        public let duration: TimeInterval

        public var reclaimedBytes: Int64 { max(0, bytesBefore - bytesAfter) }

        public var summary: String {
            let before = ByteCountFormatter.string(fromByteCount: bytesBefore, countStyle: .file)
            let after = ByteCountFormatter.string(fromByteCount: bytesAfter, countStyle: .file)
            let freed = ByteCountFormatter.string(fromByteCount: reclaimedBytes, countStyle: .file)
            return String(localized: "Было \(before), стало \(after) — освобождено \(freed).")
        }
    }

    /// Whether the installed CLI knows the command at all.
    ///
    /// A button that explains why it does not work is worse than no button, so
    /// the caller hides it when this is false.
    public func isAvailable() async -> Bool {
        guard let chroma = locator.locate("chroma") else { return false }
        let output = try? await runner.run(chroma, arguments: ["vacuum", "--help"], timeout: 15)
        guard let output, output.isSuccess else { return false }
        return output.standardOutput.contains("--path")
    }

    /// Runs `chroma vacuum` over a database directory.
    ///
    /// The caller stops the server first. Verified on 1.4.4 that the command
    /// also works while a server is running, but a write landing in the middle
    /// of a file rewrite is not a risk worth taking for a few saved seconds
    ///.
    public func vacuum(databaseAt path: URL, timeout: TimeInterval = 900) async throws -> Result {
        guard let chroma = locator.locate("chroma") else {
            throw MaintenanceError.commandUnavailable
        }
        let before = Self.directorySize(path)
        let started = Date()
        log(.info, "Обслуживание", "chroma vacuum \(path.path) — начато")

        let output = try await runner.run(
            chroma,
            arguments: ["vacuum", "--path", path.path, "--force", "--timeout", String(Int(timeout))],
            timeout: timeout + 30
        )
        guard output.isSuccess else {
            throw MaintenanceError.failed(output.standardError.isEmpty ? output.standardOutput : output.standardError)
        }

        // Measured here rather than parsed out of the CLI's own summary: on
        // 1.4.4 it reported «reduced by 21.5MiB (⬇️6%)» for a directory that
        // actually went from 35 MB to 12 MB.
        let result = Result(
            bytesBefore: before,
            bytesAfter: Self.directorySize(path),
            duration: Date().timeIntervalSince(started)
        )
        log(.success, "Обслуживание", "Обслуживание базы завершено. \(result.summary)")
        return result
    }

    static func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        for case let fileURL as URL in enumerator {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

public enum MaintenanceError: LocalizedError {
    case commandUnavailable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .commandUnavailable:
            return String(localized: "Установленная версия Chroma CLI не умеет обслуживать базу.")
        case .failed(let details):
            return String(localized: "Обслуживание базы не удалось: \(details)")
        }
    }
}
