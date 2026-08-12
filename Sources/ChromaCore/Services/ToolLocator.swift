import Foundation

/// Finds external tools by absolute path.
///
/// An app launched from Finder inherits a stripped `PATH` without
/// `/opt/homebrew/bin`, `/usr/local/bin` or pyenv shims — the classic
/// "works in my terminal, not in the app". So the locator checks an explicit
/// candidate list first and then asks the login shell, caches the resolved
/// absolute path, and the app never launches a bare command name.
///
/// Asking the login shell means spawning a process and waiting for it. That
/// must never happen on the main thread: blocking the run loop inside a view
/// update crashed the app. `locate` therefore refuses
/// to do it, and main-actor callers use `locateAsync`.
public final class ToolLocator {
    public static let shared = ToolLocator()

    private let lock = NSLock()
    private var cache: [String: String] = [:]
    /// Tools a full lookup has already failed to find; keeps the app from
    /// spawning a login shell over and over for something that is not there.
    private var missingTools: Set<String> = []
    /// Incremented on every login-shell probe. Tests assert it stays at zero
    /// for main-thread lookups.
    private var shellProbes = 0
    private let fileManager = FileManager.default

    public init() {}

    /// Directory the app installs the standalone Chroma CLI into.
    public static var managedBinDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent("bin", isDirectory: true)
    }

    /// Checked in order; the app's own directory wins over system copies.
    public static var candidateDirectories: [String] {
        [
            managedBinDirectory.path,
            AppPaths.venvDirectory.appendingPathComponent("bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            NSHomeDirectory() + "/.local/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    }

    public var loginShellProbeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return shellProbes
    }

    /// Resolves a tool. Never blocks the main thread: if the cheap lookup misses
    /// there, it gives up instead of spawning a login shell.
    public func locate(_ tool: String, useCache: Bool = true) -> String? {
        if tool.hasPrefix("/") {
            return fileManager.isExecutableFile(atPath: tool) ? tool : nil
        }

        if useCache, let cached = cachedPath(tool) { return cached }
        if let found = scanCandidates(tool) {
            lock.lock(); cache[tool] = found; missingTools.remove(tool); lock.unlock()
            return found
        }

        lock.lock()
        let alreadyMissing = missingTools.contains(tool)
        lock.unlock()
        if alreadyMissing { return nil }

        guard !Thread.isMainThread else {
            // A shell probe here would block the run loop mid-render.
            return nil
        }

        lock.lock(); shellProbes += 1; lock.unlock()
        guard let found = askLoginShell(for: tool) else {
            lock.lock(); missingTools.insert(tool); lock.unlock()
            return nil
        }
        lock.lock(); cache[tool] = found; lock.unlock()
        return found
    }

    /// Full lookup for main-actor callers: the shell probe runs off the main
    /// thread and the result comes back asynchronously.
    public func locateAsync(_ tool: String, useCache: Bool = true) async -> String? {
        if useCache, let cached = cachedPath(tool) { return cached }
        return await Task.detached(priority: .userInitiated) { [self] in
            locate(tool, useCache: useCache)
        }.value
    }

    public func forget(_ tool: String? = nil) {
        lock.lock()
        if let tool {
            cache.removeValue(forKey: tool)
            missingTools.remove(tool)
        } else {
            cache.removeAll()
            missingTools.removeAll()
        }
        lock.unlock()
    }

    private func cachedPath(_ tool: String) -> String? {
        lock.lock()
        let cached = cache[tool]
        lock.unlock()
        guard let cached, fileManager.isExecutableFile(atPath: cached) else { return nil }
        return cached
    }

    private func scanCandidates(_ tool: String) -> String? {
        for directory in Self.candidateDirectories {
            let candidate = (directory as NSString).appendingPathComponent(tool)
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// `/bin/zsh -lc 'command -v <tool>'` — picks up pyenv, asdf, mise and
    /// anything else configured in the user's shell profile. Times out so a
    /// slow or wedged profile cannot hold the app up.
    private func askLoginShell(for tool: String, timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(tool)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty,
            fileManager.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// PATH handed to child processes: candidates first, then whatever the app
    /// inherited, so tools that shell out themselves still work.
    public func childProcessPath() -> String {
        var entries = Self.candidateDirectories
        if let inherited = ProcessInfo.processInfo.environment["PATH"] {
            entries += inherited.split(separator: ":").map(String.init)
        }
        var seen = Set<String>()
        return entries.filter { seen.insert($0).inserted && !$0.isEmpty }.joined(separator: ":")
    }
}
