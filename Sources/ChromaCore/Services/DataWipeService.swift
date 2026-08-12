import Foundation

/// Removing everything the app has written.
///
/// The list is built from the same constants the app writes through, so it
/// cannot drift out of date the next time a new file appears — a wipe that
/// misses half of what it promised is worse than no wipe at all.
public struct DataWipeService {
    private let log: LogHandler
    private let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore(), log: @escaping LogHandler = noopLogHandler) {
        self.keychain = keychain
        self.log = log
    }

    public struct Item: Identifiable, Hashable, Sendable {
        public var id: String { title }
        public let title: String
        public let detail: String
        public let url: URL?
        /// Backups are opt-in — the one thing here that may be irreplaceable.
        public let isOptional: Bool
        public let bytes: Int64
        /// Consequence the path alone does not convey, shown as a warning
        /// rather than as one more grey line.
        public var note: String?

        public init(
            title: String,
            detail: String,
            url: URL?,
            isOptional: Bool,
            bytes: Int64,
            note: String? = nil
        ) {
            self.title = title
            self.detail = detail
            self.url = url
            self.isOptional = isOptional
            self.bytes = bytes
            self.note = note
        }

        public var sizeText: String? {
            bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : nil
        }
    }

    /// Exactly what would be deleted, with sizes, for the confirmation dialog.
    public func plan() -> [Item] {
        var items: [Item] = [
            Item(
                title: String(localized: "Данные приложения"),
                detail: AppPaths.supportDirectory.path,
                url: AppPaths.supportDirectory,
                isOptional: false,
                bytes: Self.size(of: AppPaths.supportDirectory, excluding: [AppPaths.backupsDirectory]),
                note: Self.engineNote()
            ),
            Item(
                title: String(localized: "Логи"),
                detail: AppPaths.logsDirectory.path,
                url: AppPaths.logsDirectory,
                isOptional: false,
                bytes: Self.size(of: AppPaths.logsDirectory, excluding: [])
            ),
            Item(
                title: String(localized: "Настройки macOS (UserDefaults)"),
                detail: Self.defaultsDomain,
                url: nil,
                isOptional: false,
                bytes: 0
            ),
            Item(
                title: String(localized: "Токены и ключи в Keychain"),
                detail: String(localized: "все записи приложения"),
                url: nil,
                isOptional: false,
                bytes: 0
            ),
        ]
        items.append(Item(
            title: String(localized: "Резервные копии"),
            detail: AppPaths.backupsDirectory.path,
            url: AppPaths.backupsDirectory,
            isOptional: true,
            bytes: Self.size(of: AppPaths.backupsDirectory, excluding: [])
        ))
        return items
    }

    /// Both ways of installing the engine (2.4) put it inside the app's own
    /// directory: path A drops the standalone CLI into `bin/`, path B builds a
    /// `venv/`. Wiping the directory therefore uninstalls ChromaDB — which the
    /// user has to learn from this dialog rather than from an app that stops
    /// finding the engine after the next launch.
    static func engineNote() -> String? {
        let manager = FileManager.default
        let standalone = ToolLocator.managedBinDirectory.appendingPathComponent("chroma")
        return engineNote(
            hasStandalone: manager.isExecutableFile(atPath: standalone.path),
            hasVenv: manager.fileExists(atPath: AppPaths.venvPython.path)
        )
    }

    /// Split out so the wording can be tested without an installed engine.
    static func engineNote(hasStandalone: Bool, hasVenv: Bool) -> String? {
        switch (hasStandalone, hasVenv) {
        case (false, false):
            // Engine installed elsewhere (Homebrew, pipx) or not at all: the
            // wipe does not touch it, so there is nothing to warn about.
            return nil
        case (true, false):
            return String(localized: "Вместе с ними удалится установленный движок ChromaDB (bin/chroma) — его придётся установить заново.")
        case (false, true):
            return String(localized: "Вместе с ними удалится установленное окружение ChromaDB (venv) — движок придётся установить заново.")
        case (true, true):
            return String(localized: "Вместе с ними удалятся обе установки движка ChromaDB (bin/chroma и venv) — движок придётся установить заново.")
        }
    }

    /// What is deliberately left alone. Shown in the dialog, because the one
    /// thing a user fears here is losing their databases.
    public func untouched(localDatabasePath: URL?, profilePaths: [URL]) -> [String] {
        var paths = profilePaths.map(\.path)
        if let localDatabasePath { paths.insert(localDatabasePath.path, at: 0) }
        return Array(Set(paths)).sorted()
    }

    public static let defaultsDomain = "io.github.chromadbmanager"

    /// Deletes everything in `plan()`, optionally including backups.
    ///
    /// Processes must already be stopped by the caller: files of a running
    /// server would come back the moment it flushes.
    @discardableResult
    public func wipe(includingBackups: Bool) -> [String] {
        var removed: [String] = []
        let manager = FileManager.default

        for item in plan() where !item.isOptional || includingBackups {
            guard let url = item.url else { continue }
            if url == AppPaths.supportDirectory, !includingBackups {
                // Everything inside except the backups folder.
                let contents = (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                for child in contents where child.standardizedFileURL != AppPaths.backupsDirectory.standardizedFileURL {
                    if (try? manager.removeItem(at: child)) != nil { removed.append(child.path) }
                }
                continue
            }
            if manager.fileExists(atPath: url.path), (try? manager.removeItem(at: url)) != nil {
                removed.append(url.path)
            }
        }

        UserDefaults.standard.removePersistentDomain(forName: Self.defaultsDomain)
        UserDefaults.standard.removeObject(forKey: "hasSizedInitialWindow")
        removed.append(Self.defaultsDomain)

        let keys = keychain.removeAllAppItems()
        if keys > 0 { removed.append(String(localized: "Keychain: записей удалено \(keys)")) }

        log(.warning, "Приложение", "Удалены данные приложения: \(removed.count) объектов\(includingBackups ? ", включая резервные копии" : ", резервные копии сохранены")")
        return removed
    }

    private static func size(of url: URL, excluding: [URL]) -> Int64 {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        let skip = Set(excluding.map(\.standardizedFileURL.path))
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if skip.contains(where: { fileURL.standardizedFileURL.path.hasPrefix($0) }) { continue }
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
