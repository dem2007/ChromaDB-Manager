import Foundation

public enum InstallationError: LocalizedError {
    case failed(hint: String, output: String)
    case noReleaseAsset(String)
    case pythonMissing

    public var errorDescription: String? {
        switch self {
        case .failed(let hint, _): return hint
        case .noReleaseAsset(let name):
            return String(localized: "В последнем релизе Chroma CLI нет файла \(name) для этого Mac.")
        case .pythonMissing:
            return String(localized: "Для установки Python-пакетом нужен Python 3. Установите его или выберите автономный CLI.")
        }
    }

    public var rawOutput: String {
        switch self {
        case .failed(_, let output): return output
        default: return ""
        }
    }
}

/// What the app is about to download, shown to the user before anything runs.
public struct StandaloneInstallPlan {
    public let version: String
    public let assetName: String
    public let downloadURL: URL
    public let sizeBytes: Int
    public let destination: URL

    public var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    /// The equivalent terminal command, so the user can see exactly what happens.
    public var equivalentCommand: String {
        "curl -L \(downloadURL.absoluteString) -o \(destination.path) && chmod +x \(destination.path)"
    }
}

/// Installs and upgrades the ChromaDB engine.
///
/// Path A (default): the standalone Chroma CLI binary from the project's
/// official GitHub release — no Python involved. The app downloads the same
/// asset the upstream install script picks, but into its own directory instead
/// of `/usr/local/bin`, because that path needs `sudo` and a GUI app has no
/// terminal to ask in.
///
/// Path B: `pip install chromadb` into `~/Library/Application Support/
/// ChromaDBManager/venv`. The system and Homebrew interpreters are never
/// written to (PEP 668); `--break-system-packages` is never used.
public final class InstallationService {
    private let shell: ShellRunner
    private let locator: ToolLocator
    private let log: LogHandler

    public init(shell: ShellRunner = .shared, locator: ToolLocator = .shared, log: @escaping LogHandler = noopLogHandler) {
        self.shell = shell
        self.locator = locator
        self.log = log
    }

    /// Reference published by the Chroma project; shown in the UI so the user
    /// can verify where the binary comes from.
    public static let officialInstallScriptURL = URL(
        string: "https://raw.githubusercontent.com/chroma-core/chroma/main/rust/cli/install/install.sh"
    )!

    // MARK: - Diagnostics

    /// Turns a raw pip failure into something a human can act on.
    public static func diagnose(_ output: String) -> String? {
        let lower = output.lowercased()
        if lower.contains("externally-managed-environment") || lower.contains("externally managed") {
            return String(localized: "Этот интерпретатор Python защищён от установки пакетов (PEP 668). Приложение ставит пакеты только в собственное виртуальное окружение — пересоздайте venv и повторите.")
        }
        if lower.contains("permission denied") || lower.contains("errno 13") {
            return String(localized: "Недостаточно прав для записи. Установка идёт в каталог приложения — проверьте права на ~/Library/Application Support/ChromaDBManager.")
        }
        if lower.contains("temporary failure in name resolution")
            || lower.contains("network is unreachable")
            || lower.contains("failed to establish a new connection")
            || lower.contains("retrying (retry(total=") {
            return String(localized: "Похоже, нет доступа в интернет: pip не может достучаться до pypi.org.")
        }
        if lower.contains("no matching distribution") || lower.contains("requires a different python") {
            return String(localized: "Версия Python не поддерживается пакетом chromadb. Нужен Python 3.10 или новее.")
        }
        if lower.contains("conflict") && lower.contains("dependenc") {
            return String(localized: "Конфликт зависимостей в этом окружении. Пересоздайте venv приложения и повторите установку.")
        }
        if lower.contains("no module named pip") {
            return String(localized: "В этом интерпретаторе нет pip. Выполните: python3 -m ensurepip --upgrade.")
        }
        if lower.contains("no module named venv") {
            return String(localized: "В этом интерпретаторе нет модуля venv — обычно он ставится вместе с Python из python.org.")
        }
        return nil
    }

    // MARK: - Path A: standalone CLI

    /// Resolves what would be downloaded, without downloading it.
    public func planStandaloneInstall() async throws -> StandaloneInstallPlan {
        let client = GitHubReleaseClient()
        guard let release = try await client.latestCLIRelease() else {
            throw InstallationError.noReleaseAsset(GitHubReleaseClient.assetNameForCurrentMac)
        }
        let assetName = GitHubReleaseClient.assetNameForCurrentMac
        guard let asset = release.assets.first(where: { $0.name == assetName }),
              let url = URL(string: asset.browser_download_url) else {
            throw InstallationError.noReleaseAsset(assetName)
        }
        return StandaloneInstallPlan(
            version: GitHubReleaseClient.version(fromTag: release.tag_name),
            assetName: assetName,
            downloadURL: url,
            sizeBytes: asset.size,
            destination: ToolLocator.managedBinDirectory.appendingPathComponent("chroma")
        )
    }

    /// Downloads and installs the binary. Call only after the user confirmed
    /// the plan returned by `planStandaloneInstall()`.
    public func installStandalone(
        plan: StandaloneInstallPlan,
        onOutput: @escaping (String) -> Void
    ) async throws {
        onOutput("$ \(plan.equivalentCommand)")
        log(.info, "Установка", "Загрузка Chroma CLI \(plan.version) (\(plan.sizeText)) из \(plan.downloadURL.absoluteString)")

        try AppPaths.ensureDirectory(ToolLocator.managedBinDirectory)

        let (temporaryURL, response) = try await URLSession.shared.download(from: plan.downloadURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallationError.failed(
                hint: String(localized: "GitHub вернул код \(http.statusCode) при загрузке бинарника."),
                output: ""
            )
        }
        onOutput("Загружено, устанавливаем в \(plan.destination.path)")

        if FileManager.default.fileExists(atPath: plan.destination.path) {
            try FileManager.default.removeItem(at: plan.destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: plan.destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plan.destination.path)

        locator.forget("chroma")
        guard let resolved = locator.locate("chroma") else {
            throw InstallationError.failed(
                hint: String(localized: "Бинарник установлен, но не запускается. Проверьте \(plan.destination.path)."),
                output: ""
            )
        }
        let check = try await shell.run(resolved, arguments: ["--version"], timeout: 30)
        onOutput(check.combinedOutput)
        guard check.isSuccess else {
            throw InstallationError.failed(
                hint: String(localized: "Установленный бинарник не отвечает на --version."),
                output: check.combinedOutput
            )
        }
        log(.success, "Установка", "Chroma CLI \(plan.version) установлен: \(resolved)")
    }

    // MARK: - Path B: managed venv

    /// Creates the app-managed virtual environment. Any base interpreter works,
    /// including an externally-managed one — PEP 668 blocks installing into it,
    /// not creating a venv from it.
    public func createVirtualEnvironment(
        using interpreter: PythonInterpreter,
        onOutput: @escaping (String) -> Void
    ) async throws -> PythonInterpreter {
        try AppPaths.ensureSupportDirectory()
        let venvPath = AppPaths.venvDirectory

        if FileManager.default.fileExists(atPath: venvPath.path) {
            onOutput("Каталог venv уже существует, пересоздаём: \(venvPath.path)")
            try FileManager.default.removeItem(at: venvPath)
        }

        onOutput("$ \(interpreter.path) -m venv \(venvPath.path)")
        let result = try await shell.stream(
            interpreter.path,
            arguments: ["-m", "venv", venvPath.path],
            timeout: 600,
            onOutput: onOutput
        )
        guard result.isSuccess else {
            if let hint = Self.diagnose(result.combinedOutput) {
                throw InstallationError.failed(hint: hint, output: result.combinedOutput)
            }
            throw ShellError.commandFailed(result)
        }
        guard FileManager.default.isExecutableFile(atPath: AppPaths.venvPython.path) else {
            throw ShellError.executableNotFound(AppPaths.venvPython.path)
        }

        let version = await EnvironmentInspector(shell: shell, locator: locator, log: log)
            .pythonVersion(at: AppPaths.venvPython.path) ?? interpreter.version
        locator.forget()
        log(.success, "Установка", "Виртуальное окружение создано: \(venvPath.path)")
        return PythonInterpreter(path: AppPaths.venvPython.path, version: version, isManagedVenv: true)
    }

    /// `pip install [--upgrade] chromadb` — venv only.
    public func installIntoVenv(
        upgrade: Bool,
        baseInterpreter: PythonInterpreter?,
        onOutput: @escaping (String) -> Void
    ) async throws {
        var venv = PythonInterpreter(path: AppPaths.venvPython.path, version: "", isManagedVenv: true)
        if !FileManager.default.isExecutableFile(atPath: venv.path) {
            guard let base = baseInterpreter else { throw InstallationError.pythonMissing }
            onOutput("Виртуальное окружение ещё не создано — создаём его.")
            venv = try await createVirtualEnvironment(using: base, onOutput: onOutput)
        }

        var arguments = ["-m", "pip", "install"]
        if upgrade { arguments.append("--upgrade") }
        arguments.append("chromadb")

        let command = ([venv.path] + arguments).joined(separator: " ")
        onOutput("$ \(command)")
        log(.info, "Установка", "Запуск: \(command)")

        let result = try await shell.stream(venv.path, arguments: arguments, timeout: 3600, onOutput: onOutput)
        guard result.isSuccess else {
            let hint = Self.diagnose(result.combinedOutput)
            log(.error, "Установка", "pip завершился с кодом \(result.exitCode). \(hint ?? "")")
            if let hint {
                onOutput("⚠️ \(hint)")
                throw InstallationError.failed(hint: hint, output: result.combinedOutput)
            }
            throw ShellError.commandFailed(result)
        }

        locator.forget()
        log(.success, "Установка", upgrade ? "Обновление chromadb завершено" : "Установка chromadb завершена")
    }

    public func bootstrapPip(
        using interpreter: PythonInterpreter,
        onOutput: @escaping (String) -> Void
    ) async throws {
        onOutput("$ \(interpreter.path) -m ensurepip --upgrade")
        let result = try await shell.stream(
            interpreter.path,
            arguments: ["-m", "ensurepip", "--upgrade"],
            timeout: 600,
            onOutput: onOutput
        )
        guard result.isSuccess else { throw ShellError.commandFailed(result) }
        log(.success, "Установка", "pip восстановлен для \(interpreter.path)")
    }

    // MARK: - Python itself

    /// May ask the login shell, so it must not be called from a view body —
    /// the screen reads `EnvironmentStatus.homebrewPath` instead, which the
    /// probe fills in on a background thread.
    public func isHomebrewAvailable() async -> Bool { await locator.locateAsync("brew") != nil }

    public func installPythonViaHomebrew(onOutput: @escaping (String) -> Void) async throws {
        guard let brew = locator.locate("brew") else {
            throw InstallationError.failed(
                hint: String(localized: "Homebrew не установлен. Воспользуйтесь установщиком с python.org."),
                output: ""
            )
        }
        onOutput("$ \(brew) install python@3.12")
        log(.info, "Установка", "Запуск: brew install python@3.12")
        let result = try await shell.stream(brew, arguments: ["install", "python@3.12"], timeout: 3600, onOutput: onOutput)
        guard result.isSuccess else {
            throw InstallationError.failed(
                hint: String(localized: "Homebrew не смог установить Python. Подробности в логе."),
                output: result.combinedOutput
            )
        }
        locator.forget()
        log(.success, "Установка", "Python установлен через Homebrew")
    }

    /// Official installer page — the app only opens it; downloading and running
    /// the .pkg stays a conscious user action.
    public static let pythonDownloadURL = URL(string: "https://www.python.org/downloads/macos/")!
}
