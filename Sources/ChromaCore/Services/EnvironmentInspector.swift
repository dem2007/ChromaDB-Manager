import Foundation

/// Reads the local machine: which Chroma engine is installed, and — only as
/// information for install path B — which Python interpreters exist.
///
/// Everything here is read-only; installing lives in `InstallationService`.
public final class EnvironmentInspector {
    private let shell: ShellRunner
    private let locator: ToolLocator
    private let log: LogHandler

    public init(shell: ShellRunner = .shared, locator: ToolLocator = .shared, log: @escaping LogHandler = noopLogHandler) {
        self.shell = shell
        self.locator = locator
        self.log = log
    }

    // MARK: - Full probe

    /// - Parameter checkUpdates: performs a request to GitHub/PyPI. It is an
    /// explicit user action, never a silent call at startup.
    public func probe(preferredPython: String? = nil, checkUpdates: Bool = false) async -> EnvironmentStatus {
        var status = EnvironmentStatus()
        log(.info, "Окружение", "Проверка окружения…")
        locator.forget("chroma")

        if let cli = locator.locate("chroma") {
            status.chromaCLIPath = cli
            status.chromaCLIVersion = await chromaCLIVersion(at: cli)
            status.engineFlavor = Self.flavor(forCLIPath: cli)
        }

        status.interpreters = await discoverInterpreters()
        status.homebrewPath = locator.locate("brew")
        let active = status.interpreters.first { $0.path == preferredPython }
            ?? status.interpreters.first { $0.isManagedVenv }
            ?? status.interpreters.first
        status.activeInterpreter = active

        if let active {
            status.pipVersion = await pipVersion(for: active)
            if active.isManagedVenv {
                status.chromadbPackageVersion = await packageVersion("chromadb", for: active)
            }
        }

        if checkUpdates {
            await checkForUpdates(&status)
        }

        status.checkedAt = Date()
        log(
            status.isEngineInstalled ? .success : .warning,
            "Окружение",
            status.isEngineInstalled
                ? "Движок найден: \(status.chromaCLIVersion ?? "?") (\(status.engineFlavor.title))"
                : "Движок ChromaDB не установлен"
        )
        return status
    }

    /// Update sources differ per install path: GitHub Releases for the
    /// standalone CLI, PyPI for the Python package.
    public func checkForUpdates(_ status: inout EnvironmentStatus) async {
        do {
            status.latestCLIVersion = try await GitHubReleaseClient().latestChromaCLIVersion()
        } catch {
            log(.warning, "Окружение", "Не удалось проверить релизы CLI на GitHub: \(error.localizedDescription)")
        }
        if status.engineFlavor == .venv || status.chromadbPackageVersion != nil {
            do {
                status.latestPyPIVersion = try await PyPIClient().latestVersion(of: "chromadb")
            } catch {
                log(.warning, "Окружение", "Не удалось проверить версию на PyPI: \(error.localizedDescription)")
            }
        }
        status.updateChecked = true
        if let latest = status.latestVersion {
            log(.info, "Окружение", "Последняя доступная версия движка: \(latest)")
        }
    }

    private static func flavor(forCLIPath path: String) -> EngineFlavor {
        if path.hasPrefix(ToolLocator.managedBinDirectory.path) { return .standalone }
        if path.hasPrefix(AppPaths.venvDirectory.path) { return .venv }
        return .unknown
    }

    // MARK: - Engine

    public func chromaCLIVersion(at path: String) async -> String? {
        guard let result = try? await shell.run(path, arguments: ["--version"], timeout: 30) else { return nil }
        let output = result.standardOutput.isEmpty ? result.combinedOutput : result.standardOutput
        return Self.parseCLIVersionOutput(output)
    }

    /// `chroma --version` prints "chroma 1.4.4", but a venv install also emits
    /// Python warnings (urllib3/LibreSSL and friends) that must not end up in
    /// the UI — or, worse, in the version comparison.
    public static func parseCLIVersionOutput(_ output: String) -> String? {
        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        func carriesVersion(_ line: String) -> Bool {
            line.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil
        }
        func isNoise(_ line: String) -> Bool {
            let lower = line.lowercased()
            return lower.contains("warning") || lower.contains("deprecat")
                || line.contains("://") || line.contains(".py:")
        }

        if let named = lines.first(where: { $0.lowercased().contains("chroma") && carriesVersion($0) && !isNoise($0) }) {
            return named
        }
        return lines.first { carriesVersion($0) && !isNoise($0) }
    }

    // MARK: - Python (install path B only)

    public func discoverInterpreters() async -> [PythonInterpreter] {
        var candidates: [String] = []
        if FileManager.default.isExecutableFile(atPath: AppPaths.venvPython.path) {
            candidates.append(AppPaths.venvPython.path)
        }
        for name in ["python3", "python3.13", "python3.12", "python3.11", "python3.10"] {
            if let path = locator.locate(name, useCache: false) { candidates.append(path) }
        }
        candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]

        var seen = Set<String>()
        var result: [PythonInterpreter] = []
        for path in candidates {
            let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)).map { link -> String in
                link.hasPrefix("/") ? link : (path as NSString).deletingLastPathComponent + "/" + link
            } ?? path
            guard seen.insert(resolved).inserted, FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard let version = await pythonVersion(at: path) else { continue }
            let isVenv = path.hasPrefix(AppPaths.venvDirectory.path)
            result.append(PythonInterpreter(
                path: path,
                version: version,
                isManagedVenv: isVenv,
                isExternallyManaged: isVenv ? false : await isExternallyManaged(path)
            ))
        }
        return result
    }

    public func pythonVersion(at path: String) async -> String? {
        guard let result = try? await shell.run(path, arguments: ["--version"], timeout: 20),
              result.isSuccess else { return nil }
        // Same treatment as the CLI: a venv interpreter can print warnings.
        let output = result.standardOutput.isEmpty ? result.combinedOutput : result.standardOutput
        guard let line = Self.parseCLIVersionOutput(output) ?? output.split(separator: "\n").first.map(String.init) else {
            return nil
        }
        return EnvironmentStatus.numericVersion(from: line)
    }

    /// Apple's `/usr/bin/python3` and Homebrew's Python are PEP 668
    /// "externally managed": the app never installs into them.
    public func isExternallyManaged(_ pythonPath: String) async -> Bool {
        let script = "import sysconfig,os;print(os.path.exists(os.path.join(sysconfig.get_paths()['stdlib'],'EXTERNALLY-MANAGED')))"
        guard let result = try? await shell.run(pythonPath, arguments: ["-c", script], timeout: 25) else { return false }
        return result.standardOutput.contains("True")
    }

    public func pipVersion(for interpreter: PythonInterpreter) async -> String? {
        guard let result = try? await shell.run(interpreter.path, arguments: ["-m", "pip", "--version"], timeout: 40),
              result.isSuccess else { return nil }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func packageVersion(_ package: String, for interpreter: PythonInterpreter) async -> String? {
        guard let result = try? await shell.run(
            interpreter.path,
            arguments: ["-m", "pip", "show", package],
            timeout: 60
        ), result.isSuccess else { return nil }
        return Self.parsePipShowVersion(result.standardOutput)
    }

    /// Parses `pip show` output. Split out so tests can feed it fixtures.
    public static func parsePipShowVersion(_ output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix("Version:") {
            return line.replacingOccurrences(of: "Version:", with: "").trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - Database directory

    /// Off-main variant: walking a database directory to add up file sizes is
    /// far too slow to do while a view is being laid out.
    public func databaseDirectoryInfo(_ url: URL) async -> DatabaseDirectoryInfo {
        inspectDatabaseDirectory(url)
    }

    /// Reports whether a directory looks like a Chroma persistence folder.
    public func inspectDatabaseDirectory(_ url: URL) -> DatabaseDirectoryInfo {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        guard exists else { return DatabaseDirectoryInfo(exists: false, looksLikeChroma: false, sizeBytes: 0) }

        let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        let markers = ["chroma.sqlite3", "chroma.sqlite3-wal", "index"]
        let looksLikeChroma = contents.contains { markers.contains($0) }

        var size: Int64 = 0
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                size += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return DatabaseDirectoryInfo(exists: true, looksLikeChroma: looksLikeChroma, sizeBytes: size)
    }
}

public struct DatabaseDirectoryInfo: Equatable {
    public var exists: Bool
    public var looksLikeChroma: Bool
    public var sizeBytes: Int64

    public init(exists: Bool, looksLikeChroma: Bool, sizeBytes: Int64) {
        self.exists = exists
        self.looksLikeChroma = looksLikeChroma
        self.sizeBytes = sizeBytes
    }

    public var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// Single-purpose client for the PyPI JSON API (install path B).
public struct PyPIClient {
    public init() {}

    public func latestVersion(of package: String) async throws -> String {
        guard let url = URL(string: "https://pypi.org/pypi/\(package)/json") else {
            throw ChromaError.decoding("некорректный URL PyPI")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ChromaError.api(status: (response as? HTTPURLResponse)?.statusCode ?? -1, code: nil, message: "PyPI недоступен")
        }
        struct Payload: Decodable {
            struct Info: Decodable { let version: String }
            let info: Info
        }
        return try JSONDecoder().decode(Payload.self, from: data).info.version
    }
}

/// GitHub Releases, used for the standalone CLI (install path A).
public struct GitHubReleaseClient {
    public static let repository = "chroma-core/chroma"
    /// CLI releases are tagged `cli-<version>`, mixed in with engine releases.
    public static let cliTagPrefix = "cli-"

    public init() {}

    public struct Release: Decodable {
        public let tag_name: String
        public let assets: [Asset]

        public struct Asset: Decodable {
            public let name: String
            public let browser_download_url: String
            public let size: Int
        }
    }

    public func releases() async throws -> [Release] {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=30") else {
            throw ChromaError.decoding("некорректный URL GitHub")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ChromaError.api(
                status: (response as? HTTPURLResponse)?.statusCode ?? -1,
                code: nil,
                message: "GitHub API недоступен"
            )
        }
        return try JSONDecoder().decode([Release].self, from: data)
    }

    /// Newest `cli-*` release, parsed out of the mixed release list.
    public func latestCLIRelease() async throws -> Release? {
        Self.newestCLIRelease(in: try await releases())
    }

    public func latestChromaCLIVersion() async throws -> String? {
        try await latestCLIRelease().map { Self.version(fromTag: $0.tag_name) }
    }

    public static func newestCLIRelease(in releases: [Release]) -> Release? {
        releases
            .filter { $0.tag_name.hasPrefix(cliTagPrefix) }
            .max { left, right in
                let a = SemanticVersion(version(fromTag: left.tag_name))
                let b = SemanticVersion(version(fromTag: right.tag_name))
                guard let a, let b else { return left.tag_name < right.tag_name }
                return a < b
            }
    }

    public static func version(fromTag tag: String) -> String {
        tag.hasPrefix(cliTagPrefix) ? String(tag.dropFirst(cliTagPrefix.count)) : tag
    }

    /// Asset name for this Mac, matching what the official installer picks.
    public static var assetNameForCurrentMac: String {
        #if arch(arm64)
        return "chroma-macos-arm64"
        #else
        return "chroma-macos-intel"
        #endif
    }
}
