import Foundation

/// Сколько места занимает приложение на диске — по частям.
///
/// Считается объём файлов, как и у резервных копий на их экране: одно число
/// для одной папки по всему приложению. Занятое место бывает меньше: копии
/// базы снимаются клонированием APFS и, пока база не изменилась, делят с ней
/// блоки. Честно посчитать это без системных утилит нельзя — поэтому рядом
/// стоит свободное место тома, и оно не врёт.
///
/// Обход — по всему дереву, на копиях в десятки гигабайт это секунды: звать
/// только не на главном потоке.
public struct DiskUsageReport: Sendable {
    /// Части служебных данных — то, что лежит в папке приложения и не стоит
    /// отдельной строкой.
    public struct Part: Identifiable, Hashable, Sendable {
        public var id: String { name }
        /// Имя файла или папки внутри папки приложения.
        public let name: String
        public let bytes: Int64
    }

    /// Строки отчёта — чтобы сказать, какую из них прочитать не удалось.
    public enum Row: String, Sendable, Hashable {
        case database, idleDatabase, engine, backups, trash, cache, logs, service
    }

    public let measuredAt: Date
    /// Папка базы, с которой работает приложение: локальной или сервера,
    /// которым оно управляет. `nil` — база на чужом сервере.
    public let databaseBytes: Int64?
    /// Своя локальная база, когда приложение сейчас работает с другой, —
    /// осталась от режима локальной базы. `nil` — такой нет.
    public let idleDatabaseBytes: Int64?
    /// Отдельно стоящий движок (`bin`) и окружение Python (`venv`); `nil` —
    /// такой установки нет.
    public let engineBinaryBytes: Int64?
    public let engineVenvBytes: Int64?
    public let backupsBytes: Int64
    public let trashBytes: Int64
    /// Файл кэша вместе с его журналом и разделяемой памятью SQLite.
    public let embeddingCacheBytes: Int64
    public let logsBytes: Int64
    /// По убыванию размера.
    public let serviceParts: [Part]
    /// Свободно на томе с данными приложения.
    public let freeBytes: Int64?
    /// Свободно на томе с базой — только если это другой том.
    public let databaseVolumeFreeBytes: Int64?
    /// Что прочитано не целиком: папка без доступа считается тем, что удалось
    /// прочитать, и молчать об этом нельзя — ноль выглядел бы как правда.
    public let unreadable: Set<Row>

    public init(
        measuredAt: Date, databaseBytes: Int64?, idleDatabaseBytes: Int64? = nil,
        engineBinaryBytes: Int64?, engineVenvBytes: Int64?,
        backupsBytes: Int64, trashBytes: Int64, embeddingCacheBytes: Int64, logsBytes: Int64,
        serviceParts: [Part], freeBytes: Int64?, databaseVolumeFreeBytes: Int64?,
        unreadable: Set<Row> = []
    ) {
        self.measuredAt = measuredAt
        self.databaseBytes = databaseBytes
        self.idleDatabaseBytes = idleDatabaseBytes
        self.engineBinaryBytes = engineBinaryBytes
        self.engineVenvBytes = engineVenvBytes
        self.backupsBytes = backupsBytes
        self.trashBytes = trashBytes
        self.embeddingCacheBytes = embeddingCacheBytes
        self.logsBytes = logsBytes
        self.serviceParts = serviceParts
        self.freeBytes = freeBytes
        self.databaseVolumeFreeBytes = databaseVolumeFreeBytes
        self.unreadable = unreadable
    }

    public var serviceBytes: Int64 { serviceParts.reduce(0) { $0 + $1.bytes } }

    public var totalBytes: Int64 {
        [databaseBytes, idleDatabaseBytes, engineBinaryBytes, engineVenvBytes].compactMap { $0 }.reduce(0, +)
            + backupsBytes + trashBytes + embeddingCacheBytes + logsBytes + serviceBytes
    }

    /// Поместится ли ещё одна копия базы — по тому же правилу, по которому
    /// копию и пускают (`BackupService.requiredSpace`): база и запас сверху.
    /// `nil` — сказать нечего: базы на диске нет или прочитана она не вся.
    public var nextBackupFits: Bool? {
        guard let databaseBytes, let freeBytes, !unreadable.contains(.database) else { return nil }
        return freeBytes >= BackupService.requiredSpace(forDatabaseBytes: databaseBytes)
    }
}

public enum DiskUsage {
    /// Части приложения, посчитанные по папке `support` и логам `logs`.
    ///
    /// `databaseURL` — база, с которой приложение работает сейчас; своя
    /// папка базы в `support` (как по умолчанию), если с ней сейчас не
    /// работают, — отдельной строкой «не используется», а не служебными
    /// данными под сырым именем.
    ///
    /// Имена частей берутся из тех же мест, что и пути, по которым приложение
    /// пишет: переименуй одно — и строка не уехала бы в служебные данные,
    /// посчитанная дважды. Параметры — для тестов.
    public static func measure(
        databaseURL: URL?,
        support: URL = AppPaths.supportDirectory,
        logs: URL = AppPaths.logsDirectory,
        now: Date = Date()
    ) -> DiskUsageReport {
        let manager = FileManager.default
        let supportPath = support.standardizedFileURL.path
        let database = databaseURL?.standardizedFileURL
        var unreadable: Set<DiskUsageReport.Row> = []
        func existing(_ name: String) -> URL? {
            let url = support.appendingPathComponent(name)
            return manager.fileExists(atPath: url.path) ? url : nil
        }
        func measured(_ url: URL, as row: DiskUsageReport.Row) -> Int64 {
            let result = measuredSize(of: url)
            if !result.complete { unreadable.insert(row) }
            return result.bytes
        }

        let backupsName = AppPaths.backupsDirectory.lastPathComponent
        let binName = ToolLocator.managedBinDirectory.lastPathComponent
        let venvName = AppPaths.venvDirectory.lastPathComponent
        let trashName = AppPaths.trashFile.lastPathComponent
        let cacheNames = ["", "-wal", "-shm"].map { EmbeddingCache.defaultFileName + $0 }
        let idleName = AppPaths.defaultEmbeddedDatabase.lastPathComponent

        // База в папке приложения — своей строкой, а не служебными данными.
        let databaseName: String? = database.flatMap { url in
            url.deletingLastPathComponent().path == supportPath ? url.lastPathComponent : nil
        }
        let idleURL: URL? = databaseName == idleName ? nil : existing(idleName)
        let ownRows = Set([backupsName, binName, venvName, trashName, idleName] + cacheNames)
            .union(databaseName.map { [$0] } ?? [])

        let children = (try? manager.contentsOfDirectory(
            at: support, includingPropertiesForKeys: nil, options: []
        )) ?? []
        var parts: [DiskUsageReport.Part] = []
        for child in children where !ownRows.contains(child.lastPathComponent) {
            let bytes = measured(child, as: .service)
            if bytes > 0 { parts.append(DiskUsageReport.Part(name: child.lastPathComponent, bytes: bytes)) }
        }
        parts.sort { left, right in
            left.bytes == right.bytes ? left.name < right.name : left.bytes > right.bytes
        }

        var cacheBytes: Int64 = 0
        for name in cacheNames {
            if let url = existing(name) { cacheBytes += measured(url, as: .cache) }
        }
        let databaseFree: Int64? = database.flatMap { url in
            sameVolume(url, support) ? nil : freeSpace(at: url)
        }
        return DiskUsageReport(
            measuredAt: now,
            databaseBytes: database.map { measured($0, as: .database) },
            idleDatabaseBytes: idleURL.map { measured($0, as: .idleDatabase) },
            engineBinaryBytes: existing(binName).map { measured($0, as: .engine) },
            engineVenvBytes: existing(venvName).map { measured($0, as: .engine) },
            backupsBytes: existing(backupsName).map { measured($0, as: .backups) } ?? 0,
            trashBytes: existing(trashName).map { measured($0, as: .trash) } ?? 0,
            embeddingCacheBytes: cacheBytes,
            logsBytes: manager.fileExists(atPath: logs.path) ? measured(logs, as: .logs) : 0,
            serviceParts: parts,
            freeBytes: freeSpace(at: support),
            databaseVolumeFreeBytes: databaseFree,
            unreadable: unreadable
        )
    }

    /// Объём файлов папки или файла. Ссылки не раскрываются: ссылка на
    /// чужую папку — не наш объём.
    public static func size(of url: URL, excluding: [URL] = []) -> Int64 {
        measuredSize(of: url, excluding: excluding).bytes
    }

    /// Объём и то, прочитано ли всё. Папка, которую нельзя прочитать, или
    /// ошибка на середине обхода — неполный ответ, и он так и помечается.
    public static func measuredSize(of url: URL, excluding: [URL] = []) -> (bytes: Int64, complete: Bool) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        if let values = try? url.resourceValues(forKeys: Set(keys)) {
            if values.isSymbolicLink == true { return (0, true) }
            if values.isRegularFile == true { return (Int64(values.fileSize ?? 0), true) }
        }
        guard manager.isReadableFile(atPath: url.path) else {
            return (0, !manager.fileExists(atPath: url.path))
        }
        var complete = true
        guard let enumerator = manager.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in
                complete = false
                return true
            }
        ) else { return (0, false) }
        // Исключается папка целиком, а не всё, что начинается с её имени:
        // рядом с «backups» может лежать «backups-old», и это другая папка.
        let skip = excluding.map(\.standardizedFileURL.path)
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if !skip.isEmpty {
                let path = fileURL.standardizedFileURL.path
                if skip.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return (total, complete)
    }

    static func freeSpace(at url: URL) -> Int64? {
        var probe = url
        // Папки базы может ещё не быть — спрашиваем ближайшую существующую.
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func sameVolume(_ first: URL, _ second: URL) -> Bool {
        func volume(_ url: URL) -> NSObject? {
            var probe = url
            while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
                probe.deleteLastPathComponent()
            }
            return (try? probe.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let left = volume(first), let right = volume(second) else { return true }
        return left.isEqual(right)
    }
}
